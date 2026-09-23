#!/usr/bin/env python3
"""Production Linux worker enrollment, renewal and revocation on the native relay.

Every message and credential is synthetic. No Apple account or installed service
is touched. The relay process is completely stopped before policy takes effect.
"""
import http.client
from contextlib import closing
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest

from cryptography import x509
from fixture import create, add_message
from performance import Probe
from relay_fixture import Fixture, save_json
from tls_admin import atomic

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT/'zig-out/bin'


class NativeClient(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zimbr-native-client-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.previous_config = os.environ.get('XDG_CONFIG_HOME')
        os.environ['XDG_CONFIG_HOME'] = str(self.root/'config')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.tls = Fixture(self.root, port)
        self.tls.issue('admin'); self.tls.enroll('admin')
        self.source = self.root/'source.db'
        create(self.source, count=8)
        self.args = ['--data-dir', str(self.root/'relay'), '--messages-db', str(self.source), '--config', str(self.tls.config)]
        subprocess.run([str(BIN/'fake-relay'), 'setup', *self.args], check=True, capture_output=True)
        self.log = (self.root/'process.log').open('w+')
        self.server = None
        self.probe = None
        self.start_server()

    def tearDown(self):
        if self.probe:
            self.probe.close()
        self.stop_server()
        self.log.close()
        if self.previous_config is None:
            os.environ.pop('XDG_CONFIG_HOME', None)
        else:
            os.environ['XDG_CONFIG_HOME'] = self.previous_config

    def start_server(self):
        self.server = subprocess.Popen([str(BIN/'fake-relay'), 'serve', *self.args], stdout=self.log, stderr=self.log)
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if self.server.poll() is not None:
                self.log.seek(0); self.fail(self.log.read())
            conn = self.tls.connection(name='admin')
            try:
                conn.request('GET', '/v1/status')
                if json.loads(conn.getresponse().read())['adapter_ready']:
                    return
            except (OSError, http.client.HTTPException):
                pass
            finally:
                conn.close()
            time.sleep(.05)
        self.fail('Native relay not ready')

    def stop_server(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)

    def restart_server(self):
        self.stop_server()
        self.start_server()

    def start_client(self, name='client'):
        self.probe = Probe([str(BIN/'client-probe'), '--control', '--data-dir', str(self.root/'client'),
                            *self.tls.client_args(name=name)], self.log)
        return self.probe

    def rows(self, query, args=(), source=False):
        with closing(sqlite3.connect(self.source if source else self.root/'client/client.db')) as db:
            return db.execute(query, args).fetchall()

    def wait_rows(self, query, args=(), expected=None, source=False, timeout=30):
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            rows = self.rows(query, args, source)
            matched = rows == expected if expected is not None else bool(rows)
            if matched:
                return rows
            time.sleep(.05)
        self.log.flush()
        self.log.seek(0)
        self.fail(f'Expected database result missing: {query}; last rows: {rows!r}\n{self.log.read()}')

    def denied(self, probe):
        probe.until(lambda v: not v['online'] and v['diagnostics']['transport']['failure'] in ('tls', 'client_rejected'))
        d = probe.latest['diagnostics']
        self.assertEqual(d['last_http_status'], 0)
        self.assertGreater(d['transport']['curl_code'], 0)
        self.assertIn('enrollment', probe.latest['status'])
        if d['transport']['failure'] == 'tls':
            # OpenSSL application-verification failure currently sends the
            # generic handshake-failure alert: don't invent a definite cause.
            self.assertFalse(d['auth_blocked'])
            self.assertGreater(d['retry_at'], 0)
        else:
            self.assertTrue(d['auth_blocked'])

    def test_unenrolled_device_then_enrollment(self):
        self.tls.issue('unlisted')
        probe = self.start_client('unlisted')
        self.denied(probe)
        self.assertEqual(probe.latest['diagnostics']['transport']['fingerprint'], self.tls.fingerprint('unlisted'))
        self.tls.enroll('unlisted')
        self.restart_server()
        probe.command(kind='reconnect')
        probe.until(lambda v: v['online'] and v['chats'] == 4)

    def test_renewal_revocation_and_restart_preserve_worker_state(self):
        old = self.tls.fingerprint('client')
        for suffix in ('.pem', '-key.pem'):
            atomic(self.tls.root/('old'+suffix), (self.tls.root/('client'+suffix)).read_bytes())
        probe = self.start_client()
        probe.until(lambda v: v['online'] and v['chats'] == 4)
        epoch = probe.latest['diagnostics']['server']['server_epoch']
        cid = self.rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1")[0][0]
        probe.command(kind='select', key=cid)
        probe.until(lambda v: v['selected'] == cid and v['messages'] > 0)
        probe.command(kind='send', key=cid, text='Native renewal fixture send')
        request_id = self.wait_rows('SELECT id FROM outbox')[0][0]
        # Confirmation waits for the full 10-second observation window.
        self.wait_rows('SELECT state FROM outbox WHERE id=?', (request_id,), [('delivered',)], timeout=15)
        draft = 'Draft survives renewal 👩‍💻'
        probe.command(kind='draft', key=cid, text=draft)
        self.wait_rows('SELECT text FROM drafts WHERE key=?', (cid,), [(draft,)])
        cursor = self.rows("SELECT value FROM meta WHERE key='cursor'")[0][0]
        self.tls.issue('renewed', sans=[x509.DNSName('client.zimbr.invalid')])
        new = self.tls.fingerprint('renewed')
        self.assertNotEqual(old, new)
        self.tls.enroll('renewed')
        self.stop_server()
        probe.until(lambda v: not v['online'])
        with closing(sqlite3.connect(self.source)) as db, db:
            add_message(db, 'Missed during native TLS restart')
        self.start_server()
        # Ordinary network/relay failure recovers without a credential reload.
        probe.until(lambda v: v['online'])
        self.wait_rows("SELECT id FROM records WHERE kind='message' AND json_extract(record,'$.text')='Missed during native TLS restart'")
        self.assertEqual(probe.latest['diagnostics']['transport']['fingerprint'], old)
        self.assertNotEqual(self.rows("SELECT value FROM meta WHERE key='cursor'")[0][0], cursor)
        for suffix in ('.pem', '-key.pem'):
            atomic(self.tls.root/('client'+suffix), (self.tls.root/('renewed'+suffix)).read_bytes())
        probe.command(kind='reconnect')
        probe.until(lambda v: v['online'] and v['diagnostics']['transport']['fingerprint'] == new)
        # Keep old-device HTTP and SSE connections open across revocation.
        pooled = self.tls.connection(name='old')
        stream = self.tls.connection(name='old')
        try:
            pooled.request('GET', '/v1/sync')
            sync = json.loads(pooled.getresponse().read())
            stream.request('GET', '/v1/events?after='+sync['cursor'])
            events = stream.getresponse()
            self.assertEqual(events.status, 200)
            self.assertEqual(events.readline(), b': connected\n')
            self.assertEqual(events.readline(), b'\n')
            self.assertIsNotNone(pooled.sock)
            for device in self.tls.devices:
                if device['sha256'] == old:
                    device['enabled'] = False
            save_json(self.tls.root/'devices.json', self.tls.devices)
            self.restart_server()
            try:
                self.assertEqual(pooled.sock.recv(1), b'')
            except TimeoutError:
                self.fail('Revoked pooled HTTP connection remained open')
            except OSError:
                pass
            try:
                deadline = time.monotonic()+4
                while events.readline():
                    self.assertLess(time.monotonic(), deadline, 'Revoked SSE connection remained open')
            except TimeoutError:
                self.fail('Revoked SSE connection remained open')
            except (OSError, http.client.HTTPException):
                pass
        finally:
            pooled.close(); stream.close()
        rejected = self.tls.connection(name='old')
        try:
            with self.assertRaises((OSError, http.client.HTTPException)):
                rejected.request('GET', '/v1/status')
                rejected.getresponse()
        finally:
            rejected.close()
        probe.until(lambda v: v['online'])
        # Revoke the active worker too; its saved state remains available.
        for device in self.tls.devices:
            if device['sha256'] == new:
                device['enabled'] = False
        save_json(self.tls.root/'devices.json', self.tls.devices)
        self.restart_server()
        self.denied(probe)
        self.assertEqual(self.rows("SELECT value FROM meta WHERE key='epoch'"), [(epoch,)])
        self.assertEqual(self.rows('SELECT text FROM drafts WHERE key=?', (cid,)), [(draft,)])
        self.assertEqual(self.rows('SELECT id FROM outbox'), [(request_id,)])
        self.assertEqual(self.rows("SELECT count(*) FROM message WHERE text='Native renewal fixture send'", source=True), [(1,)])
        self.tls.enroll('client')
        self.restart_server()
        probe.command(kind='reconnect')
        probe.until(lambda v: v['online'] and v['diagnostics']['transport']['fingerprint'] == new)


if __name__ == '__main__':
    unittest.main(verbosity=2)
