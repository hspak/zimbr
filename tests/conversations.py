#!/usr/bin/env python3
"""Conversation regressions using synthetic source data and the real worker.

All sends below go only to fake-relay's fixture adapter, never Messages.
"""
import json
import os
from pathlib import Path
import select
import socket
import sqlite3
import subprocess
import tempfile
import uuid

from fixture import create, add_message, apple_ns
from relay_fixture import Fixture
from client_integration import wait

BIN = Path(__file__).resolve().parents[1] / 'zig-out/bin'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-conversations-') as tmp:
        root = Path(tmp)
        source, relay, client = root/'source.db', root/'relay', root/'client'
        create(source, count=0)
        now = apple_ns()
        with sqlite3.connect(source) as db:
            for name, kind in [('style', 'INTEGER'), ('account_id', 'TEXT'),
                               ('chat_identifier', 'TEXT'), ('last_addressed_handle', 'TEXT'),
                               ('room_name', 'TEXT')]:
                db.execute(f'ALTER TABLE chat ADD COLUMN {name} {kind}')
            db.execute("UPDATE chat SET guid='any;+;fixture-group',service_name='SMS' WHERE ROWID=2")
            add_message(db, 'Older SMS', chat=2, date=now-100, service='SMS')
            add_message(db, 'Current iMessage', chat=2, date=now, is_from_me=1)
            add_message(db, 'SMS reaction ignored', chat=2, date=now+100, service='SMS', associated_message_type=2001)
            for row, peer, local, account in [
                    (5, 'self@example.invalid', '+14155550124', 'account-one'),
                    (6, '+14155550124', 'self@example.invalid', 'account-one'),
                    (7, 'other@example.invalid', '+14155550125', 'account-two'),
                    (8, '+14155550125', 'other@example.invalid', 'different-account'),
                    (9, 'ambiguous@example.invalid', '+14155550126', 'account-three'),
                    (10, '+14155550126', 'ambiguous@example.invalid', 'account-three'),
                    (11, '+14155550126', 'ambiguous@example.invalid', 'account-three')]:
                db.execute('INSERT INTO handle VALUES(?,?,?)', (row, peer, 'iMessage'))
                db.execute('INSERT INTO chat VALUES(?,?,?,?,?,?,?,?,?)',
                           (row, f'any;-;fixture-{row}', 'iMessage', 'Same name', 45, account, peer, local, ''))
                db.execute('INSERT INTO chat_handle_join VALUES(?,?)', (row, row))
            for index in range(130):
                add_message(db, f'Self history {index}', chat=5+index % 2, date=now-1000+index, handle_id=5+index % 2)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        tls = Fixture(root, port)
        args = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN/'fake-relay'), 'setup', *args], check=True, capture_output=True)
        log = open(root/'relay.log', 'w+')
        server = subprocess.Popen([str(BIN/'fake-relay'), 'serve', *args], stdout=log, stderr=log)
        worker = None

        def request(path, body=None):
            connection = tls.connection()
            connection.request('GET' if body is None else 'POST', path,
                               None if body is None else json.dumps(body),
                               {} if body is None else {'Content-Type': 'application/json'})
            response = connection.getresponse()
            status, value = response.status, json.loads(response.read())
            connection.close()
            return status, value

        def chats():
            return request('/v1/conversations?limit=200')[1].get('conversations', [])

        def rows(sql, params=(), path=relay/'relay.db'):
            with sqlite3.connect(path) as db:
                return db.execute(sql, params).fetchall()

        def command(**cmd):
            worker.stdin.write((json.dumps(cmd)+'\n').encode())
            worker.stdin.flush()

        views = []

        def view():
            assert worker.poll() is None, worker.stderr.read().decode()
            while select.select([worker.stdout], [], [], 0)[0]:
                line = worker.stdout.readline()
                if line:
                    views.append(json.loads(line))
            return views[-1] if views else {}

        try:
            wait(lambda: len(chats()) == 11)
            ids = dict(rows('SELECT source_row,id FROM conversations'))
            records = {c['id']: c for c in chats()}
            assert records[ids[2]]['service'] == 'imessage' and records[ids[2]]['sendable']
            assert not records[ids[3]]['sendable']  # An explicit SMS route remains blocked.
            assert records[ids[5]]['thread_id'] == records[ids[6]]['thread_id'] == ids[5]
            assert all(not records[ids[row]]['is_self'] for row in (1, 2, 3, 4, 7, 8, 9, 10, 11))
            wait(lambda: rows('SELECT count(*) FROM messages WHERE conversation_id IN (?,?)', (ids[5], ids[6]))[0][0] == 130)
            epoch = request('/v1/sync')[1]['server_epoch']
            original_ids = set(row[0] for row in rows('SELECT id FROM messages'))
            for selected in (ids[5], ids[6]):
                found, cursor = [], None
                while True:
                    path = f'/v1/conversations/{selected}/messages?limit=13'
                    if cursor:
                        path += '&before='+cursor
                    status, page = request(path)
                    assert status == 200
                    found.extend(page['messages'])
                    cursor = page['next']
                    if cursor is None:
                        break
                assert len(found) == len({m['id'] for m in found}) == 130
                assert {m['conversation_id'] for m in found} == {ids[5], ids[6]}
            env = dict(os.environ, XDG_CONFIG_HOME=str(root/'config'))
            worker = subprocess.Popen([str(BIN/'client-probe'), '--control', '--data-dir', str(client), *tls.client_args()],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, env=env)
            wait(lambda: view().get('online') and view().get('chats') == 10)
            command(kind='select', key=ids[6])
            wait(lambda: view().get('selected') == ids[5] and view().get('messages') == 100)
            command(kind='older')
            wait(lambda: view().get('messages') == 130)
            # Synthetic dispatch must use the existing any route, never create a chat.
            send = {'request_id': str(uuid.uuid4()), 'server_epoch': epoch,
                    'target': {'conversation_id': ids[2]}, 'text': 'Fixture group reply'}
            assert request('/v1/messages', send)[0] in (200, 202)
            wait(lambda: request('/v1/send-requests/'+send['request_id'])[1].get('state') == 'delivered')
            with sqlite3.connect(source) as db:
                assert db.execute('SELECT count(*) FROM chat').fetchone()[0] == 11
                assert db.execute("SELECT j.chat_id FROM message m JOIN chat_message_join j ON m.ROWID=j.message_id WHERE m.text='Fixture group reply'").fetchall() == [(2,)]
                # More recent ordinary SMS disables sending even though an even
                # newer iMessage reaction exists. A later backfill cannot undo it.
                later = apple_ns()+10**9
                add_message(db, 'Now SMS', chat=2, date=later, service='SMS')
                add_message(db, 'Reaction', chat=2, date=later+1, associated_message_type=2001)
                add_message(db, 'Late old history', chat=2, date=now-200)
            wait(lambda: not next(c for c in chats() if c['id'] == ids[2])['sendable'])
            send['request_id'] = str(uuid.uuid4())
            status, blocked = request('/v1/messages', send)
            assert status == 400 and blocked['error_info']['code'] == 'unsupported_target', (status, blocked)
            assert original_ids <= {row[0] for row in rows('SELECT id FROM messages')}
            assert request('/v1/sync')[1]['server_epoch'] == epoch
            print('Conversation regressions passed: service selection, exact route, self grouping, pagination, worker, and immutable IDs.')
        finally:
            if worker is not None:
                if worker.poll() is None:
                    worker.stdin.write(b'quit\n'); worker.stdin.flush()
                worker.wait(timeout=10)
            server.terminate()
            server.wait(timeout=10)
            log.close()


if __name__ == '__main__':
    main()
