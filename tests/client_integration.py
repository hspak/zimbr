#!/usr/bin/env python3
"""Drive the production Linux client worker against the production fixture relay.
Only synthetic databases and recipients are used. No GPU or Apple account needed.
"""
import json
from relay_fixture import Fixture
import os
from pathlib import Path
import select
import socket
import sqlite3
import subprocess
import tempfile
import time
from fixture import create, add_message

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'


def wait(fn, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except (sqlite3.OperationalError, OSError):
            pass
        time.sleep(.08)
    raise AssertionError('Timed out waiting for client behavior')


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-client-') as tmp:
        root = Path(tmp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        source, relay, client = root / 'source.db', root / 'relay', root / 'client'
        create(source)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        tls = Fixture(root, port)
        opts = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN / 'fake-relay'), 'setup', *opts], check=True, capture_output=True)
        logfile = open(root / 'relay.log', 'w+')
        server = subprocess.Popen([str(BIN / 'fake-relay'), 'serve', *opts], stdout=logfile, stderr=logfile)
        proc = None
        views = []
        def rows(sql, args=(), path=client / 'client.db'):
            with sqlite3.connect(path) as db:
                return db.execute(sql, args).fetchall()
        def pump():
            if proc.poll() is not None:
                raise AssertionError('Client exited: ' + proc.stderr.read().decode())
            while select.select([proc.stdout], [], [], 0)[0]:
                line = proc.stdout.readline()
                if not line:
                    break
                views.append(json.loads(line))
            return views[-1] if views else {}
        def online():
            return pump().get('online')
        def send(**cmd):
            if cmd.get('kind') == 'reconnect':
                pump(); views.clear()
            proc.stdin.write((json.dumps(cmd) + '\n').encode())
            proc.stdin.flush()
        def start():
            views.clear()
            return subprocess.Popen([str(BIN / 'client-probe'), '--control', '--data-dir', str(client), *tls.client_args()], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        def stop():
            proc.stdin.write(b'quit\n'); proc.stdin.flush()
            assert proc.wait(timeout=10) == 0, proc.stderr.read().decode()
        try:
            proc = start()
            wait(online)
            assert rows("SELECT count(*) FROM records WHERE kind='conversation'")[0][0] == 4
            cid = rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1")[0][0]
            send(kind='select', key=cid)
            wait(lambda: rows("SELECT count(*) FROM records WHERE kind='message' AND chat=?", (cid,))[0][0] >= 100)
            assert rows('SELECT count(*) FROM unread')[0][0] == 0
            draft = 'Café e\u0301 👩‍💻 🇺🇸\n你好 — clipboard & draft'
            send(kind='draft', key=cid, text=draft)
            wait(lambda: rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [(draft,)])
            send(kind='older')
            wait(lambda: rows("SELECT count(*) FROM records WHERE kind='message' AND chat=?", (cid,))[0][0] == 121)
            # At-least-once replay uses the last durable cursor after a crash.
            stop(); proc = start(); wait(online)
            assert rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [(draft,)]
            send(kind='viewed', text='no')
            time.sleep(.2)
            with sqlite3.connect(source) as db:
                add_message(db, 'Live while connected')
            wait(lambda: rows("SELECT count(*) FROM records WHERE kind='message' AND json_extract(record,'$.text')='Live while connected'")[0][0] == 1)
            wait(lambda: rows('SELECT count FROM unread WHERE chat=?', (cid,)) == [(1,)])
            before = rows("SELECT value FROM meta WHERE key='cursor'")[0][0]
            send(kind='reconnect'); wait(online)
            assert rows("SELECT count(*) FROM records WHERE kind='message' AND json_extract(record,'$.text')='Live while connected'")[0][0] == 1
            # A real client submit goes through durable local outbox and echo merge.
            send(kind='send', key=cid, text='Client fixture send 👋\nSecond line')
            wait(lambda: rows('SELECT count(*) FROM outbox')[0][0] == 1)
            request_id = rows('SELECT id FROM outbox')[0][0]
            assert rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [('',)]
            wait(lambda: rows("SELECT state FROM outbox WHERE id=?", (request_id,)) == [('delivered',)], timeout=45)
            wait(lambda: pump().get('pending') == 0)
            assert rows("SELECT count(*) FROM message WHERE text='Client fixture send 👋\nSecond line'", path=source)[0][0] == 1
            # A new direct target transitions into the observed conversation; group replies
            # retain the existing group route. No synthetic send reaches Apple.
            send(kind='select', key='new:bob@example.invalid')
            send(kind='send', key='new:bob@example.invalid', recipient='bob@example.invalid', text='New direct fixture')
            wait(lambda: rows("SELECT count(*) FROM outbox WHERE state='delivered'")[0][0] == 2, timeout=45)
            wait(lambda: not pump().get('selected', 'new:').startswith('new:'))
            group=rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.title')='Fixture group'")[0][0]
            send(kind='select', key=group)
            send(kind='send', key=group, text='Existing group fixture')
            wait(lambda: rows("SELECT count(*) FROM outbox WHERE state='delivered'")[0][0] == 3, timeout=45)
            assert rows("SELECT cm.chat_id FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID WHERE m.text='Existing group fixture'", path=source) == [(2,)]
            send(kind='select', key=cid)
            # Definitive rejection and ambiguous adapter outcome retain their payload.
            send(kind='send', key=cid, text='[fake:reject]')
            wait(lambda: rows("SELECT count(*) FROM outbox WHERE state='failed'")[0][0] == 1)
            send(kind='send', key=cid, text='[fake:unknown]')
            wait(lambda: rows("SELECT count(*) FROM outbox WHERE state='unknown'")[0][0] >= 1, timeout=40)
            count = rows('SELECT count(*) FROM message', path=source)[0][0]
            # Abrupt client restart preserves accepted identities without resubmitting.
            proc.kill(); proc.wait(); proc=start(); wait(online)
            time.sleep(1)
            assert rows('SELECT count(*) FROM message', path=source)[0][0] == count
            # Drop the relay: read cache and save drafts; reconnect recovers missed data.
            server.terminate(); server.wait(timeout=5)
            wait(lambda: not online())
            send(kind='draft', key=cid, text=draft)
            wait(lambda: rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [(draft,)])
            send(kind='send', key=cid, text=draft)
            time.sleep(.3)
            assert rows('SELECT count(*) FROM outbox')[0][0] == 5
            with sqlite3.connect(source) as db:
                add_message(db, 'Missed while offline')
            server=subprocess.Popen([str(BIN/'fake-relay'),'serve',*opts],stdout=logfile,stderr=logfile)
            send(kind='reconnect'); wait(online)
            wait(lambda: rows("SELECT count(*) FROM records WHERE json_extract(record,'$.text')='Missed while offline'")[0][0] == 1)
            # Force expiration of a saved cursor and verify explicit resynchronization.
            stop()
            with sqlite3.connect(client/'client.db') as db:
                db.execute("UPDATE meta SET value=? WHERE key='cursor'", (before,))
            with sqlite3.connect(relay/'relay.db') as db:
                db.execute('UPDATE relay_meta SET pruned_through=sequence')
                db.execute('DELETE FROM events')
            proc=start(); wait(online)
            assert rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [(draft,)]
            # Rebuild source identity; old send requests must be held, never POSTed.
            old_epoch=rows("SELECT value FROM meta WHERE key='epoch'")[0][0]
            replacement=root/'replacement.db'; create(replacement); os.replace(replacement,source)
            wait(lambda: rows("SELECT value FROM meta WHERE key='epoch'")[0][0] != old_epoch, timeout=25)
            wait(online)
            assert rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [(draft,)]
            assert rows('SELECT count(*) FROM outbox')[0][0] == 5
            stop(); proc=None
            print('PASS: snapshots, pagination, live SSE, deduplication, Unicode drafts, echo merging, failed/uncertain sends, crash recovery, offline behavior, expired cursor, and epoch reset')
        finally:
            if proc and proc.poll() is None:
                proc.kill(); proc.wait()
            if server.poll() is None:
                server.terminate(); server.wait(timeout=5)
            logfile.close()

if __name__ == '__main__':
    main()
