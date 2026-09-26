#!/usr/bin/env python3
"""Exercise the real relay TLS boundary with synthetic data and hostile peers."""
import datetime as dt
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch
from cryptography import x509
from cryptography.x509.oid import ExtendedKeyUsageOID
from contextlib import closing
from fixture import create, add_message
from relay_fixture import Fixture, save_json
from tls_admin import create_key, validate_extensions, restart
from tls_support import Credentials, origin

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT/'zig-out/bin/fake-relay'
REAL = ROOT/'zig-out/bin/relay'


class RelayTls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zimbr-tls-')
        self.root = Path(self.temp.name).resolve()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); self.port = sock.getsockname()[1]
        self.tls = Fixture(self.root, self.port)
        self.source = self.root/'source.db'; create(self.source, count=4)
        self.args = ['--data-dir', str(self.root/'data'), '--messages-db', str(self.source), '--config', str(self.tls.config)]
        subprocess.run([str(BIN), 'setup', *self.args], check=True, stdout=subprocess.DEVNULL)
        self.log = (self.root/'log').open('w+')
        self.proc = None
        self.start()

    def tearDown(self):
        self.stop(); self.log.close(); self.temp.cleanup()

    def start(self, readiness=True):
        self.proc = subprocess.Popen([str(BIN), 'serve', *self.args], stdout=self.log, stderr=self.log)
        deadline = time.monotonic()+8
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                self.log.seek(0); self.fail(self.log.read())
            try:
                if not readiness:
                    with socket.create_connection(('127.0.0.1', self.port), timeout=.2): return
                elif self.get('/v1/status')['adapter_ready']: return
            except (OSError, http.client.HTTPException): pass
            time.sleep(.05)
        self.fail('Relay not ready')

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate(); self.proc.wait(timeout=5)

    def get(self, path, name='client'):
        c = self.tls.connection(name=name)
        try:
            c.request('GET', path); r = c.getresponse(); self.assertEqual(r.status, 200)
            return json.loads(r.read())
        finally: c.close()

    def reject(self, ctx, headers=b'', session=None):
        # Receiving a TLS alert/EOF, rather than an HTTP error, demonstrates that
        # even a valid API-shaped request never reaches the HTTP handler.
        raw = socket.create_connection(('127.0.0.1', self.port), timeout=2)
        try:
            with ctx.wrap_socket(raw, server_hostname='localhost', session=session) as tls:
                tls.sendall(b'GET /v1/status HTTP/1.1\r\nHost: localhost\r\n'+headers+b'\r\n')
                try: result = tls.recv(4096)
                except (ssl.SSLError, ConnectionError): return
                self.assertEqual(result, b'', 'Unauthorized peer received application data')
        except (ssl.SSLError, ConnectionError): pass
        finally: raw.close()

    def allow(self, *names):
        save_json(self.tls.root/'devices.json', [{'label': n, 'sha256': self.tls.fingerprint(n), 'enabled': True} for n in names])

    def test_authentication_before_http(self):
        now = dt.datetime.now(dt.timezone.utc)
        self.tls.issue('expired', before=now-dt.timedelta(days=2), after=now-dt.timedelta(days=1))
        self.tls.issue('future', before=now+dt.timedelta(days=1), after=now+dt.timedelta(days=2))
        self.tls.issue('wrong-eku', eku=[ExtendedKeyUsageOID.SERVER_AUTH])
        self.tls.issue('no-eku', eku='absent')
        self.tls.issue('unlisted')
        self.allow('client', 'expired', 'future', 'wrong-eku', 'no-eku')
        self.stop(); self.start()
        self.reject(self.tls.context(None))
        self.reject(self.tls.context(None), b'Authorization: Bearer '+b'0'*64+b'\r\n')
        for name in ['expired', 'future', 'wrong-eku', 'no-eku', 'unlisted']:
            with self.subTest(name=name): self.reject(self.tls.context(name))
        other = self.root/'other'; other.mkdir(mode=0o700)
        foreign = Fixture(other, self.port)
        self.reject(foreign.context(ca=self.tls.root/'ca.pem'))
        ctx = self.tls.context(); ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_2
        self.reject(ctx)
        with socket.create_connection(('127.0.0.1', self.port), timeout=2) as plain:
            plain.sendall(b'GET /v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n')
            try: self.assertFalse(plain.recv(4096).startswith(b'HTTP/'))
            except ConnectionError: pass
        self.assertTrue(self.get('/v1/status')['adapter_ready'])
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)
        self.stop(); self.allow(); self.start(readiness=False)
        self.reject(self.tls.context())

    def test_config_fail_closed(self):
        self.stop()
        original = json.loads(self.tls.config.read_text())
        def bad(cfg, expected):
            self.tls.config.write_text(json.dumps(cfg))
            result = subprocess.run([str(BIN), 'serve', *self.args], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
            with self.assertRaises(OSError): socket.create_connection(('127.0.0.1', self.port), timeout=.2)
        bad({**original, 'listen_address': '0.0.0.0'}, b'Wildcard')
        bad({**original, 'server_key_file': str(self.tls.root/'missing.pem')}, b'key missing')
        bad({**original, 'server_key_file': str(self.tls.root/'client-key.pem')}, b'key mismatch')
        bad({**original, 'server_name': 'wrong.invalid'}, b'SAN')
        cert_path = self.tls.root/'server.pem'
        cert_bytes = cert_path.read_bytes()
        cert_path.write_bytes(cert_bytes + (self.tls.root/'server-key.pem').read_bytes())
        bad(original, b'invalid PEM'); cert_path.write_bytes(cert_bytes)
        key = self.tls.root/'server-key.pem'; key.chmod(0o644)
        bad(original, b'unsafe'); key.chmod(0o600)
        self.tls.root.chmod(0o755); bad(original, b'0700'); self.tls.root.chmod(0o700)
        link = self.tls.root/'linked.pem'; link.symlink_to(key)
        bad({**original, 'server_key_file': str(link)}, b'unsafe')
        dirlink = self.root/'linked'; dirlink.symlink_to(self.tls.root)
        bad({**original, 'server_key_file': str(dirlink/'server-key.pem')}, b'unsafe')
        for devices in [[{'sha256': 'invalid', 'label': 'bad', 'enabled': True}], self.tls.devices*2, {'not': 'an array'}]:
            save_json(self.tls.root/'devices.json', devices); bad(original, b'Device')
        save_json(self.tls.root/'devices.json', self.tls.devices)
        bad({**original, 'obsolete': True}, b'InvalidTlsConfiguration')
        now = dt.datetime.now(dt.timezone.utc)
        self.tls.issue('expired-server', server=True, before=now-dt.timedelta(days=2), after=now-dt.timedelta(days=1))
        bad({**original, 'server_cert_file': str(self.tls.root/'expired-server.pem'), 'server_key_file': str(self.tls.root/'expired-server-key.pem')}, b'currently valid')
        save_json(self.tls.config, original)
        info = json.loads(subprocess.check_output([str(BIN), 'check-config', *self.args]))
        self.assertTrue(info['expiry_warning']); self.assertEqual(info['enabled_devices'], 1)
        self.assertEqual(info['server_sha256'], self.tls.fingerprint('server'))

    def test_handshake_and_request_bounds(self):
        # Existing application connections remain usable when all handshake slots stall.
        persistent = self.tls.connection(timeout=15)
        persistent.request('GET', '/v1/status'); persistent.getresponse().read()
        stalled = [socket.create_connection(('127.0.0.1', self.port), timeout=7) for _ in range(4)]
        stalled[0].sendall(b'\x16\x03\x03\x00\xff\x01')  # Partial TLS record.
        time.sleep(.2)
        start = time.monotonic()
        with socket.create_connection(('127.0.0.1', self.port), timeout=1) as extra:
            try: self.assertEqual(extra.recv(1), b'')
            except ConnectionResetError: pass
        persistent.request('GET', '/v1/status'); self.assertEqual(persistent.getresponse().status, 200)
        for sock in stalled:
            try: self.assertEqual(sock.recv(1), b'')
            except ConnectionResetError: pass
            finally: sock.close()
        self.assertLess(time.monotonic()-start, 6)
        persistent.close()
        peer = self.tls.context().wrap_socket(socket.create_connection(('127.0.0.1', self.port)), server_hostname='localhost')
        peer.settimeout(12); peer.sendall(b'GET /v1/status HTTP/1.1\r\nHost:')
        start = time.monotonic(); self.assertEqual(peer.recv(1), b'')
        self.assertLess(time.monotonic()-start, 11); peer.close()
        # Clean and abrupt TLS closure release slots; neither crashes the relay.
        for clean in [True, False]*20:
            peer = self.tls.context().wrap_socket(socket.create_connection(('127.0.0.1', self.port)), server_hostname='localhost')
            if clean: peer.unwrap().close()
            else: os.close(peer.detach())
        self.assertTrue(self.get('/v1/status')['adapter_ready'])

    def test_total_connection_limit(self):
        peers = []
        try:
            for _ in range(32):
                c = self.tls.connection(); c.request('GET', '/v1/status')
                r = c.getresponse(); self.assertEqual(r.status, 200); r.read(); peers.append(c)
            with self.assertRaises((OSError, http.client.HTTPException)):
                self.get('/v1/status')
        finally:
            for c in peers: c.close()
        time.sleep(.2)
        self.assertTrue(self.get('/v1/status')['adapter_ready'])

    def test_mac_tools_verify_server_and_use_client_identity(self):
        from mac_acceptance import Client
        client = Client(self.root, self.tls.admin)
        self.assertTrue(client.request('/v1/status')['adapter_ready'])
        ctx = client.credentials.context
        self.assertEqual(len(ctx.get_ca_certs()), 1)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)
        raw = socket.create_connection(('127.0.0.1', self.port))
        with self.assertRaises(ssl.SSLCertVerificationError):
            ctx.wrap_socket(raw, server_hostname='wrong.invalid')
        raw.close()
        other = self.root/'unrelated'; other.mkdir(mode=0o700)
        foreign = Fixture(other, self.port)
        raw = socket.create_connection(('127.0.0.1', self.port))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.tls.context(ca=foreign.root/'ca.pem').wrap_socket(raw, server_hostname='localhost')
        raw.close()
        for bad in ('http://localhost', 'https://user@localhost', 'https://localhost/path', 'https://localhost?query', 'https://localhost#fragment'):
            with self.assertRaises(ValueError): origin(bad)

    def test_renewal_revocation_and_recovery(self):
        baseline = self.get('/v1/sync')
        pooled = self.tls.connection(); pooled.request('GET', '/v1/status'); pooled.getresponse().read()
        old_socket = pooled.sock
        old_session, old_context = old_socket.session, pooled._context
        stream = self.tls.connection(); stream.request('GET', '/v1/events?after='+baseline['cursor'])
        response = stream.getresponse(); self.assertEqual(response.status, 200)
        self.assertEqual(response.readline(), b': connected\n'); self.assertEqual(response.readline(), b'\n')
        self.assertFalse(old_socket.session.has_ticket)
        self.tls.issue('renewed'); self.allow('client', 'renewed')
        self.stop(); self.start()
        self.assertEqual(old_socket.recv(1), b'')
        self.assertEqual(response.readline(), b''); response.close(); stream.close(); pooled.close()
        self.assertTrue(self.get('/v1/status', name='renewed')['adapter_ready'])
        self.assertTrue(self.get('/v1/status')['adapter_ready'])
        self.allow('renewed'); self.stop(); self.start(readiness=False)
        self.reject(self.tls.context())
        self.reject(old_context, session=old_session)
        # Renewal replaces only credentials; the durable epoch/cursor remains.
        self.assertEqual(self.get('/v1/sync', name='renewed')['server_epoch'], baseline['server_epoch'])
        with closing(sqlite3.connect(self.source)) as db:
            add_message(db, 'missed while disconnected'); db.commit()
        deadline = time.monotonic()+5
        while self.get('/v1/sync', name='renewed')['cursor'] == baseline['cursor']:
            self.assertLess(time.monotonic(), deadline); time.sleep(.1)
        replay = self.tls.connection(name='renewed'); replay.request('GET', '/v1/events?after='+baseline['cursor'])
        body = replay.getresponse(); self.assertEqual(body.status, 200)
        while not body.readline().startswith(b'data: '): pass
        body.close(); replay.close()

    def test_expiry_during_send_body_and_http_version(self):
        peer = self.tls.context().wrap_socket(socket.create_connection(('127.0.0.1', self.port)), server_hostname='localhost')
        peer.sendall(b'GET /v1/status HTTP/1.0\r\nHost: localhost\r\n\r\n')
        self.assertTrue(peer.recv(4096).startswith(b'HTTP/1.1 400')); peer.close()
        self.tls.issue('brief-body', after=dt.datetime.now(dt.timezone.utc)+dt.timedelta(seconds=3))
        self.allow('client', 'brief-body'); self.stop(); self.start()
        body = json.dumps({'request_id': str(uuid.uuid4()), 'server_epoch': self.get('/v1/sync')['server_epoch'],
            'target': {'recipient': {'address': 'synthetic@example.invalid', 'service': 'imessage'}}, 'text': 'never dispatch'}).encode()
        peer = self.tls.context('brief-body').wrap_socket(socket.create_connection(('127.0.0.1', self.port)), server_hostname='localhost')
        peer.settimeout(5)
        peer.sendall(f'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body[:1])
        time.sleep(3.1); peer.sendall(body[1:]); self.assertEqual(peer.recv(4096), b''); peer.close()
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)

    def test_expired_active_sessions(self):
        now = dt.datetime.now(dt.timezone.utc)
        self.tls.issue('brief', after=now+dt.timedelta(seconds=4))
        self.allow('client', 'brief'); self.stop(); self.start()
        pooled = self.tls.connection(name='brief'); pooled.request('GET', '/v1/status'); pooled.getresponse().read()
        stream = self.tls.connection(name='brief'); stream.request('GET', '/v1/events?after='+self.get('/v1/sync')['cursor'])
        response = stream.getresponse(); response.readline(); response.readline()
        time.sleep(4.2)
        deadline = time.monotonic()+3
        while response.readline(): self.assertLess(time.monotonic(), deadline)
        with self.assertRaises((OSError, http.client.HTTPException)):
            pooled.request('GET', '/v1/status'); pooled.getresponse()
        pooled.close(); response.close(); stream.close()
        self.reject(self.tls.context('brief'))

    def test_slow_event_readers_release_stream_slots(self):
        baseline = self.get('/v1/sync')
        streams = []
        for _ in range(8):
            raw = socket.socket(); raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            raw.settimeout(3); raw.connect(('127.0.0.1', self.port))
            peer = self.tls.context().wrap_socket(raw, server_hostname='localhost')
            peer.sendall(f'GET /v1/events?after={baseline["cursor"]} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
            peer.recv(4096); streams.append(peer)
        # Fill the synthetic journal through the real importer, beyond socket buffers.
        with closing(sqlite3.connect(self.source)) as db:
            for _ in range(250): add_message(db, 'x'*60000)
            db.commit()
        deadline = time.monotonic()+22
        while time.monotonic() < deadline:
            c = self.tls.connection(); c.request('GET', '/v1/events?after='+self.get('/v1/sync')['cursor'])
            r = c.getresponse(); status = r.status; r.close(); c.close()
            if status == 200: break
            self.assertEqual(status, 503); time.sleep(.25)
        else: self.fail('Slow readers retained all stream slots past write deadline')
        for peer in streams: peer.close()
        self.assertTrue(self.get('/v1/status')['adapter_ready'])


class ProvisioningTests(unittest.TestCase):
    def test_csr_policy(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder).resolve()
            csr_path = create_key(directory, 'client', ['device.zimbr.invalid'])
            csr = x509.load_pem_x509_csr(csr_path.read_bytes())
            validate_extensions(csr, 'client', ['device.zimbr.invalid'])
            with self.assertRaises(ValueError): validate_extensions(csr, 'server', ['localhost'])
            with self.assertRaises(ValueError): create_key(directory, 'client', ['device.zimbr.invalid'])

    def test_failed_restart_is_not_success(self):
        import tls_admin
        with patch.object(tls_admin, 'pid_of_service', return_value=123), patch.object(tls_admin.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'launchctl')):
            with self.assertRaises(subprocess.CalledProcessError): restart({}, tls_admin.PROFILES['dev'])


if __name__ == '__main__': unittest.main(verbosity=2)
