#!/usr/bin/env python3
"""Initial import throughput, durable restart, and subsequent small sync batches.

Uses synthetic Messages rows and the production relay workers. --benchmark
reports initial import timings without asserting the new scheduling policy.
"""
import argparse
from contextlib import closing
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time

from fixture import add_message, create
from integration import database
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]


class Relay:
    def __init__(self, root, binary, messages):
        self.source = root / 'source.db'
        self.journal = root / 'relay' / 'relay.db'
        create(self.source, count=messages - 4)
        with database(self.source) as db:
            db.executescript('''
                CREATE INDEX fixture_message_chat ON chat_message_join(message_id,chat_id);
                CREATE INDEX fixture_message_attachment ON message_attachment_join(message_id,attachment_id);
            ''')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.tls = Fixture(root, sock.getsockname()[1])
        self.args = [str(binary), '--data-dir', str(self.journal.parent),
                     '--messages-db', str(self.source), '--config', str(self.tls.config)]
        subprocess.run([self.args[0], 'setup', *self.args[1:]], check=True, capture_output=True)
        with database(self.journal) as db:
            db.executescript('''
                CREATE TABLE sync_checkpoints(kind TEXT,previous INTEGER,current INTEGER);
                CREATE TRIGGER record_sync_checkpoint AFTER UPDATE ON ingestion_progress
                WHEN NEW.key IN ('live','backfill','rolling') AND OLD.value!=NEW.value
                BEGIN
                    INSERT INTO sync_checkpoints VALUES(NEW.key,OLD.value,NEW.value);
                END;
            ''')
        self.log = (root / 'relay.log').open('w+')
        self.process = None

    def start(self):
        self.process = subprocess.Popen([self.args[0], 'serve', *self.args[1:]],
                                        stdout=self.log, stderr=self.log)

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None

    def close(self):
        self.stop()
        self.log.close()

    def rows(self, sql, args=()):
        with closing(sqlite3.connect(self.journal)) as db:
            return db.execute(sql, args).fetchall()

    def scalar(self, sql, args=()):
        rows = self.rows(sql, args)
        return rows[0][0] if rows else None

    def position(self, key):
        return self.scalar('SELECT CAST(value AS INTEGER) FROM ingestion_progress WHERE key=?', (key,))

    def wait(self, predicate, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert self.process.poll() is None, 'Fixture relay exited'
            if predicate():
                return
            time.sleep(.01)
        self.log.flush()
        self.log.seek(0)
        raise AssertionError('Timed out waiting for sync: ' + self.log.read()[-4000:])

    def imported(self, count):
        return (self.position('backfill') == 0 and
                self.scalar('SELECT count(*) FROM messages') == count and
                self.scalar("SELECT count(*) FROM conversations WHERE json_extract(record,'$.history_complete')=0") == 0)


def exercise(root, binary, messages, benchmark):
    relay = Relay(root, binary, messages)
    try:
        started = time.monotonic()
        relay.start()
        relay.wait(lambda: relay.imported(messages), timeout=180)
        elapsed = (time.monotonic() - started) * 1000
        batches = [previous - current for previous, current in relay.rows(
            "SELECT previous,current FROM sync_checkpoints WHERE kind='backfill'")]
        result = dict(messages=messages, initial_ingest_ms=round(elapsed, 2),
                      backfill_transactions=len(batches), largest_backfill_batch=max(batches))
        if benchmark:
            return result
        assert batches[0] == 1000, batches
        assert all(0 < count <= 1000 for count in batches), batches
        assert sum(batches) == messages, batches

        # Reopening a completed journal must stay in the small-batch mode.
        relay.stop()
        with database(relay.source) as db:
            for index in range(250):
                add_message(db, f'Live after restart {index}')
            db.execute("UPDATE message SET text='Old message edited' WHERE ROWID=1500")
        relay.start()
        relay.wait(lambda: relay.scalar('SELECT count(*) FROM messages') == messages + 250)
        relay.wait(lambda: relay.position('live') == messages + 250)
        live_batches = [current - previous for previous, current in relay.rows(
            "SELECT previous,current FROM sync_checkpoints WHERE kind='live'")]
        assert live_batches == [100, 100, 50], live_batches
        assert relay.scalar("SELECT count(*) FROM events WHERE type='message.upsert' AND "
                            "json_extract(record,'$.text') LIKE 'Live after restart %' AND origin='live'") == 250
        relay.wait(lambda: relay.scalar("SELECT count(*) FROM messages WHERE text='Old message edited'") == 1)
        rolling_batches = [current - previous for previous, current in relay.rows(
            "SELECT previous,current FROM sync_checkpoints WHERE kind='rolling' AND current>previous")]
        assert rolling_batches and all(count <= 100 for count in rolling_batches), rolling_batches
        with closing(relay.tls.connection()) as connection:
            connection.request('GET', '/v1/status')
            response = connection.getresponse()
            assert response.status == 200
            assert json.loads(response.read())['capabilities']['read_history']
        return result
    finally:
        relay.close()


def interrupted(root, binary):
    relay = Relay(root, binary, 2500)
    try:
        # Allow one whole import transaction, then fail inside the next one.
        with database(relay.journal) as db:
            db.executescript('''
                CREATE TRIGGER interrupt_import BEFORE INSERT ON messages
                WHEN (SELECT count(*) FROM messages)>=1250
                BEGIN SELECT RAISE(ABORT,'synthetic interrupted import'); END;
            ''')
        relay.start()
        relay.wait(lambda: relay.position('backfill') == 1500)
        relay.wait(lambda: (relay.log.flush() or
                           'Message ingestion stopped' in Path(relay.log.name).read_text()))
        relay.stop()
        assert relay.scalar('SELECT count(*) FROM messages') == 1000
        assert relay.position('backfill') == 1500
        retained = relay.rows('SELECT id,source FROM messages ORDER BY id')
        epoch = relay.scalar('SELECT epoch FROM relay_meta')
        with database(relay.journal) as db:
            db.execute('DROP TRIGGER interrupt_import')
        relay.start()
        relay.wait(lambda: relay.imported(2500))
        assert relay.scalar('SELECT epoch FROM relay_meta') == epoch
        assert set(retained) <= set(relay.rows('SELECT id,source FROM messages'))
        assert relay.scalar("SELECT count(*) FROM events WHERE type='message.upsert'") == 2500
        assert relay.rows("SELECT previous-current FROM sync_checkpoints WHERE kind='backfill'") == [
            (1000,), (1000,), (500,)]
    finally:
        relay.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'zig-out' / 'bin')
    parser.add_argument('--messages', type=int, default=3500)
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()
    assert args.messages >= 2500 and args.samples > 0
    binary = args.bin_dir.resolve() / 'fake-relay'
    results = []
    for sample in range(args.samples):
        with tempfile.TemporaryDirectory(prefix='zimbr-initial-sync-') as temporary:
            results.append(exercise(Path(temporary), binary, args.messages, args.benchmark))
    if not args.benchmark:
        with tempfile.TemporaryDirectory(prefix='zimbr-interrupted-sync-') as temporary:
            interrupted(Path(temporary), binary)
    print(json.dumps(dict(samples=results, checks='benchmark' if args.benchmark else 'passed')))


if __name__ == '__main__':
    main()
