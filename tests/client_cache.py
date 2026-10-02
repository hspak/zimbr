#!/usr/bin/env python3
"""Cache continuity through resync, source pruning, and independent relay clients."""
from contextlib import closing
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
from urllib.parse import urlsplit

from client_tls import EPOCH, Handler
from fixture import add_message, create
from performance import Probe, wait
from relay_fixture import Fixture
from tls_fixture import PKI, TLSServer

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'
CHAT = 'EREREREREREREREREREREQ'
MESSAGE = 'IiIiIiIiIiIiIiIiIiIiIg'


def rows(path, sql, args=()):
    with closing(sqlite3.connect(path)) as db:
        return db.execute(sql, args).fetchall()


def execute(path, sql, args=()):
    with closing(sqlite3.connect(path)) as db:
        db.execute(sql, args)
        db.commit()


def audit(path):
    with closing(sqlite3.connect(path)) as db:
        db.executescript('''
            CREATE TABLE cache_deletions(id TEXT);
            CREATE TRIGGER audit_cache_delete AFTER DELETE ON records
            WHEN OLD.kind='message'
            BEGIN INSERT INTO cache_deletions VALUES(OLD.id); END;
            CREATE TABLE identity_deletions(id TEXT);
            CREATE TRIGGER audit_identity_delete AFTER DELETE ON identities
            BEGIN INSERT INTO identity_deletions VALUES(OLD.id); END;
        ''')


class ClientErrors(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-cache-errors-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.pki = PKI(self.root / 'tls')
        self.identities = False
        self.paths = []
        test = self

        class Endpoint(Handler):
            def response(self, body, status=200):
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                test.paths.append(self.path)
                self.response(dict(error_info=dict(code='request_conflict', message='Conflict')), 409)

            def do_GET(self):
                path = urlsplit(self.path).path
                test.paths.append(path)
                if path == '/v1/status':
                    return self.response(dict(
                        api_version='1', server_epoch=EPOCH, adapter_ready=True, degraded_reasons=[],
                        capabilities=dict(send_direct=True, reply_existing=True,
                                          identity_directory_v1=test.identities),
                        event_extensions=['identity-v1'] if test.identities else []))
                if path == '/v1/conversations':
                    return self.response(dict(conversations=[dict(id=CHAT, service='imessage')], next=None))
                if path.endswith('/messages'):
                    return self.response(dict(messages=[dict(
                        id=MESSAGE, revision='1', conversation_id=CHAT, sender='peer@example.invalid',
                        direction='incoming', service='imessage', timestamp='2026-01-01T00:00:00Z',
                        kind='text', text='Cached history', decoding='plain', observed_status='received',
                    )], next=None))
                if path == '/v1/identities':
                    return self.response(dict(identities=[], next=None))
                if path == '/v1/events':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Zimbr-Event-Extensions',
                                     'identity-v1' if test.identities else '')
                    self.end_headers()
                    try:
                        while True:
                            self.wfile.write(b': heartbeat\n\n')
                            self.wfile.flush()
                            time.sleep(.1)
                    except OSError:
                        pass
                    return
                return super().do_GET()

        server = TLSServer(Endpoint, self.pki.context())
        server.mode, server.requests = 'ok', []
        self.addCleanup(server.close)
        self.log = (self.root / 'client.log').open('w+')
        self.addCleanup(self.log.close)
        self.data = self.root / 'client'
        self.db = self.data / 'client.db'
        self.probe = Probe([str(BIN / 'client-probe'), '--control', '--data-dir', str(self.data),
                            *self.pki.client_args(server.server_port)], self.log)
        self.addCleanup(self.probe.close)
        self.probe.until(lambda v: v['online'])
        self.probe.command(kind='select', key=CHAT)
        self.probe.until(lambda v: v['messages'] == 1)
        audit(self.db)

    def test_send_conflict_does_not_bootstrap_or_erase_history(self):
        self.probe.command(kind='send', key=CHAT, text='Conflicting fixture request')
        wait(lambda: rows(self.db, "SELECT state FROM outbox") == [('failed',)])
        # Wait for a subsequent successful status poll, including any recovery.
        checked = self.probe.latest['diagnostics']['last_status_ms']
        self.probe.until(lambda v: v['online'] and v['diagnostics']['last_status_ms'] > checked)
        self.assertEqual(self.paths.count('/v1/sync'), 1)
        self.assertEqual(rows(self.db, 'SELECT * FROM cache_deletions'), [])

    def test_enabling_contacts_does_not_repeat_message_bootstrap(self):
        self.identities = True
        self.probe.until(lambda v: v['online'] and
                         rows(self.db, "SELECT value FROM meta WHERE key='accepted_extensions'") == [('identity-v1',)])
        self.assertIn('/v1/identities', self.paths)
        self.assertEqual(self.paths.count('/v1/sync'), 1)
        self.assertEqual(rows(self.db, 'SELECT * FROM cache_deletions'), [])


class SharedRelay(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-shared-cache-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source.db'
        self.journal = self.root / 'relay/relay.db'
        create(self.source, count=440)
        self.source.with_suffix('.db.contacts.json').write_text(json.dumps(dict(
            permission='authorized', generation=1, failed=False,
            contacts=[dict(id='alice', name='Cached Alice', emails=['alice@example.invalid'],
                           has_image=True, thumbnail='ZIMBR-IMAGE avatar')],
        )))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.tls = Fixture(self.root, sock.getsockname()[1])
        self.tls.issue('second')
        self.tls.enroll('second')
        self.args = ['--data-dir', str(self.journal.parent), '--messages-db', str(self.source),
                     '--config', str(self.tls.config)]
        subprocess.run([str(BIN / 'fake-relay'), 'setup', *self.args], check=True, capture_output=True)
        self.log = (self.root / 'relay.log').open('w+')
        self.addCleanup(self.log.close)
        self.server = subprocess.Popen([str(BIN / 'fake-relay'), 'serve', *self.args],
                                       stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop_relay)
        wait(lambda: rows(self.journal, "SELECT value FROM ingestion_progress WHERE key='backfill'") == [('0',)])
        self.epoch = self.get('/v1/sync')['server_epoch']
        self.chat = rows(self.journal, "SELECT id FROM conversations WHERE source_row=1")[0][0]
        self.clients = {}

    def stop_relay(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)

    def get(self, path):
        with closing(self.tls.connection()) as connection:
            connection.request('GET', path)
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())

    def start_client(self, name):
        data = self.root / name
        log = (self.root / (name + '.log')).open('a+')
        self.addCleanup(log.close)
        probe = Probe([str(BIN / 'client-probe'), '--control', '--data-dir', str(data),
                       *self.tls.client_args(name='second' if name == 'second' else 'client')], log)
        self.addCleanup(lambda: probe.close() if probe.proc.stdin and not probe.proc.stdin.closed else None)
        probe.until(lambda v: v['online'])
        wait(lambda: rows(data / 'client.db',
                         "SELECT json_extract(record,'$.display_name') FROM identities WHERE address='alice@example.invalid'") == [('Cached Alice',)])
        self.clients[name] = probe
        return probe

    def db(self, name):
        return self.root / name / 'client.db'

    def load_history(self, name):
        probe = self.clients[name]
        probe.command(kind='select', key=self.chat)
        probe.until(lambda v: v['messages'] == 100)
        probe.command(kind='older')
        probe.until(lambda v: v['messages'] == 200)
        audit(self.db(name))
        return rows(self.db(name), "SELECT id FROM records WHERE kind='message' ORDER BY sort_key LIMIT 1")[0][0]

    def incoming(self, text, names=('first', 'second')):
        with closing(sqlite3.connect(self.source)) as db:
            add_message(db, text)
            db.commit()
        for name in names:
            wait(lambda: rows(self.db(name),
                             "SELECT count(*) FROM records WHERE kind='message' AND json_extract(record,'$.text')=?",
                             (text,)) == [(1,)])

    def cached_avatar(self, name):
        probe = self.clients[name]
        probe.command(kind='media_context', epoch=self.epoch, chat=self.chat)

        def fetch():
            record = json.loads(rows(self.db(name),
                                     "SELECT record FROM identities WHERE address='alice@example.invalid'")[0][0])
            self.assertEqual(record['display_name'], 'Cached Alice')
            probe.command(kind='media', asset=record['avatar'])
            probe.until(lambda v: 'media' in v)
            result = probe.latest['media']
            if result['state'] != 'ready':
                time.sleep(.1)
                return None
            path = self.root / name / 'media' / result['key']
            return record['avatar'], path.stat().st_ino

        return wait(fetch, timeout=15)

    def test_clients_reconnect_and_expired_replay_preserve_independent_caches(self):
        self.start_client('first')
        oldest = self.load_history('first')
        self.start_client('second')
        self.load_history('second')
        avatars = {name: self.cached_avatar(name) for name in ('first', 'second')}
        self.incoming('Both independent subscribers receive this')
        # A slow/offline client's replay expires while the other stays current.
        self.clients['second'].close()
        self.incoming('First keeps receiving while second is offline', names=('first',))
        execute(self.journal, 'UPDATE relay_meta SET pruned_through=sequence')
        execute(self.journal, 'DELETE FROM events')
        self.start_client('second')
        self.incoming('Both receive after one client reboots its snapshot')
        self.assertEqual(self.get('/v1/sync')['server_epoch'], self.epoch)
        for name in ('first', 'second'):
            self.assertEqual(rows(self.db(name), 'SELECT * FROM cache_deletions'), [])
            self.assertEqual(rows(self.db(name), 'SELECT * FROM identity_deletions'), [])
            self.assertEqual(rows(self.db(name), "SELECT id FROM records WHERE kind='message' AND id=?", (oldest,)), [(oldest,)])
            self.assertEqual(self.cached_avatar(name), avatars[name], 'Reconnect replaced cached avatar bytes')

    def test_deleted_source_anchors_do_not_reset_any_client(self):
        self.start_client('first')
        self.load_history('first')
        self.start_client('second')
        self.load_history('second')
        anchors = rows(self.journal, 'SELECT source_row FROM ordinary_anchors ORDER BY source_row')
        # Periodic cleanup can delete an old anchor and the ingestion high-water row.
        with closing(sqlite3.connect(self.source)) as db:
            for row, in (anchors[0], anchors[-1]):
                db.execute('DELETE FROM chat_message_join WHERE message_id=?', (row,))
                db.execute('DELETE FROM message WHERE ROWID=?', (row,))
            db.commit()
        wait(lambda: int(rows(self.journal, "SELECT value FROM ingestion_progress WHERE key='live'")[0][0]) < anchors[-1][0])
        self.assertEqual(self.get('/v1/sync')['server_epoch'], self.epoch)
        self.incoming('New message after source cleanup')
        for name in ('first', 'second'):
            self.assertEqual(rows(self.db(name), 'SELECT * FROM cache_deletions'), [])
            self.assertEqual(rows(self.db(name), 'SELECT * FROM identity_deletions'), [])
        # A different GUID at a surviving anchor still requires a new epoch.
        execute(self.source, "UPDATE message SET guid='replaced-source-guid' WHERE ROWID=?", anchors[1])
        wait(lambda: self.get('/v1/sync')['server_epoch'] != self.epoch)
        for name in ('first', 'second'):
            wait(lambda: rows(self.db(name), "SELECT value FROM meta WHERE key='epoch'")[0][0] != self.epoch)
            self.assertTrue(rows(self.db(name), 'SELECT * FROM cache_deletions'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
