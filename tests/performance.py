#!/usr/bin/env python3
"""Synthetic end-to-end latency benchmark; never opens an Apple account/cache.

Build ReleaseFast client-probe and fake-relay first. Outputs aggregates only.
View times include the probe's 20 ms sampling interval, but exclude GPU drawing.
"""
import argparse
import json
import os
from relay_fixture import Fixture
import math
from pathlib import Path
import queue
import random
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

from fixture import create, add_message


def wait(fn, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result:
                return result
        except (sqlite3.OperationalError, FileNotFoundError):
            pass
        time.sleep(.005)
    raise AssertionError('Performance scenario timed out')


def scalar(path, sql, args=()):
    with sqlite3.connect(path) as db:
        row = db.execute(sql, args).fetchone()
        return row[0] if row else None


def summary(samples):
    values = sorted(samples)
    return dict(samples=len(values), p50_ms=round(values[len(values)//2], 2),
                p95_ms=round(values[math.ceil(len(values)*.95)-1], 2),
                max_ms=round(values[-1], 2))


class Probe:
    def __init__(self, command, log):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=log, text=True, bufsize=1)
        self.views = queue.Queue()
        self.latest = {}
        def read():
            for line in self.proc.stdout:
                self.views.put((time.monotonic(), json.loads(line)))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def command(self, **value):
        self.proc.stdin.write(json.dumps(value) + '\n')
        self.proc.stdin.flush()

    def until(self, predicate, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                stamp, self.latest = self.views.get(timeout=max(.001, deadline-time.monotonic()))
            except queue.Empty:
                break
            if predicate(self.latest):
                return stamp
        raise AssertionError('Client did not publish the expected benchmark state')

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.write('quit\n')
            self.proc.stdin.flush()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdin.close()
        self.proc.stdout.close()
        self.reader.join(timeout=1)


def run(args):
    bins = args.bin_dir.resolve()
    result = {'fixture_messages': args.history + args.chats, 'conversations': args.chats, 'incoming': [], 'send_ack': [],
              'send_dispatch': [], 'send_echo': []}
    rng = random.Random(42)
    with tempfile.TemporaryDirectory(prefix='zimbr-performance-') as temp:
        root = Path(temp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        source, relay, client = root/'source.db', root/'relay', root/'client'
        create(source, count=args.history)
        with sqlite3.connect(source) as db:
            # The tiny correctness fixture omits reverse-join indexes. Include
            # them for scale measurements so per-message joins are indexed.
            db.execute('CREATE INDEX fixture_message_chat ON chat_message_join(message_id,chat_id)')
            db.execute('CREATE INDEX fixture_message_attachment ON message_attachment_join(message_id,attachment_id)')
            if args.text_bytes:
                db.execute("UPDATE message SET text=? WHERE text IS NOT NULL", ('x' * args.text_bytes,))
            for chat in range(5, args.chats+1):
                address = f'fixture-{chat}@example.invalid'
                db.execute("INSERT INTO handle(ROWID,id,service) VALUES(?,?,'iMessage')", (chat, address))
                db.execute("INSERT INTO chat VALUES(?,?,'iMessage',?)", (chat, 'iMessage;-;'+address, f'Fixture {chat}'))
                db.execute('INSERT INTO chat_handle_join VALUES(?,?)', (chat, chat))
                add_message(db, f'Conversation preview {chat}', chat=chat, handle_id=chat)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        tls = Fixture(root, port)
        options = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(bins/'fake-relay'), 'setup', *options], check=True, capture_output=True)
        with (root/'process.log').open('w') as log:
            ingest_started = time.monotonic()
            server = subprocess.Popen([str(bins/'fake-relay'), 'serve', *options], stdout=log, stderr=log)
            probe = None
            try:
                wait(lambda: scalar(relay/'relay.db', 'SELECT count(*) FROM messages') == args.history+args.chats, args.setup_timeout)
                wait(lambda: scalar(relay/'relay.db', "SELECT count(*) FROM conversations WHERE json_extract(record,'$.history_complete')=1") == args.chats, args.setup_timeout)
                result['initial_ingest_ms'] = round((time.monotonic()-ingest_started)*1000, 2)
                result['indexed_source_joins'] = True
                started = time.monotonic()
                probe = Probe([str(bins/'client-probe'), '--control', '--data-dir', str(client),
                               *tls.client_args()], log)
                connected = probe.until(lambda v: v['online'] and v['chats'] == args.chats)
                result['connect_ms'] = round((connected-started)*1000, 2)
                connected_at = started
                # Account for both batched projections and older relays that
                # fetch one full latest message per conversation.
                wait(lambda: scalar(client/'client.db', "SELECT count(*) FROM records c WHERE c.kind='conversation' AND NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.chat=c.id) AND NOT EXISTS(SELECT 1 FROM previews p WHERE p.chat=c.id)") == 0)
                result['sidebar_ready_ms'] = round((time.monotonic()-connected_at)*1000, 2)
                cid = scalar(client/'client.db', "SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1")
                started = time.monotonic()
                probe.command(kind='select', key=cid)
                opened = probe.until(lambda v: v['selected'] == cid and v['messages'] >= min(100, args.history//2+1) and not v['diagnostics']['job'] == 'history')
                result['open_history_ms'] = round((opened-started)*1000, 2)
                if args.load_history:
                    started = time.monotonic()
                    while scalar(client/'client.db', "SELECT count(*) FROM pages WHERE chat=? AND cursor IS NOT NULL", (cid,)):
                        before = probe.latest['messages']
                        probe.command(kind='older')
                        probe.until(lambda v: v['messages'] > before and v['diagnostics']['job'] != 'history')
                    result['load_cached_history_ms'] = round((time.monotonic()-started)*1000, 2)
                    result['selected_cached_messages'] = probe.latest['messages']
                    result['history_text_bytes'] = args.text_bytes
                probe.command(kind='check')
                probe.until(lambda v: v['online'])
                for i in range(args.samples):
                    time.sleep(rng.uniform(.03, .35))
                    before = scalar(client/'client.db', "SELECT count(*) FROM records WHERE kind='message'")
                    started = time.monotonic()
                    with sqlite3.connect(source) as db:
                        add_message(db, f'Benchmark incoming {i}')
                    seen = probe.until(lambda v: v['diagnostics']['cached_messages'] >= before+1)
                    result['incoming'].append((seen-started)*1000)
                for i in range(max(3, args.samples//2)):
                    time.sleep(rng.uniform(.03, .35))
                    ack = probe.latest['ack']
                    before = scalar(client/'client.db', "SELECT count(*) FROM records WHERE kind='message'")
                    body = f'Benchmark outgoing {i}'
                    started = time.monotonic()
                    probe.command(kind='send', key=cid, text=body)
                    accepted = probe.until(lambda v: v['ack'] > ack)
                    result['send_ack'].append((accepted-started)*1000)
                    wait(lambda: scalar(source, 'SELECT count(*) FROM message WHERE text=?', (body,)) == 1)
                    result['send_dispatch'].append((time.monotonic()-started)*1000)
                    # A fast relay can publish the echo in the same view as
                    # the durable acknowledgement. Do not wait for a later view.
                    seen = accepted if probe.latest['diagnostics']['cached_messages'] >= before+1 else probe.until(lambda v: v['diagnostics']['cached_messages'] >= before+1)
                    result['send_echo'].append((seen-started)*1000)
                before = scalar(client/'client.db', "SELECT count(*) FROM records WHERE kind='message'")
                started = time.monotonic()
                with sqlite3.connect(source) as db:
                    for i in range(args.burst):
                        add_message(db, f'Benchmark burst {i}')
                seen = probe.until(lambda v: v['diagnostics']['cached_messages'] >= before+args.burst)
                result['burst'] = dict(messages=args.burst, elapsed_ms=round((seen-started)*1000, 2))
                for key in ('incoming', 'send_ack', 'send_dispatch', 'send_echo'):
                    result[key] = summary(result[key])
            finally:
                if probe:
                    probe.close()
                server.terminate()
                server.wait(timeout=10)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=Path(__file__).resolve().parents[1]/'zig-out/bin')
    parser.add_argument('--samples', type=int, default=12)
    parser.add_argument('--history', type=int, default=240)
    parser.add_argument('--chats', type=int, default=4)
    parser.add_argument('--burst', type=int, default=500)
    parser.add_argument('--load-history', action='store_true', help='load every selected history page before measuring live changes')
    parser.add_argument('--text-bytes', type=int, default=0, help='replace synthetic historical text with this many ASCII bytes')
    parser.add_argument('--setup-timeout', type=float, default=180, help='seconds allowed for initial relay ingestion')
    args = parser.parse_args()
    if args.samples < 1 or args.history < 20 or args.burst < 1 or args.chats < 4:
        parser.error('samples and burst must be positive; history must be at least 20 and chats at least 4')
    if not 0 <= args.text_bytes <= 16384:
        parser.error('text-bytes must be between 0 and 16384')
    if args.setup_timeout <= 0:
        parser.error('setup-timeout must be positive')
    print(json.dumps(run(args), indent=2))
