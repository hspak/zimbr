#!/usr/bin/env python3
"""Linux production-worker TLS rejection, credential reload and isolation tests."""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import ssl
import subprocess
import tempfile
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtendedKeyUsageOID
from tls_fixture import PKI, TLSServer, private_write
from performance import Probe

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT/'zig-out/bin/client-probe'
EPOCH = '12345678-1234-1234-1234-123456789012'


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        assert self.connection.version() == 'TLSv1.3'
        assert self.connection.getpeercert(binary_form=True)
        assert not self.headers.get('Authorization')
        self.server.requests.append((self.path, hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest(), id(self.connection)))
        if self.server.mode == 'redirect':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:1/should-never-be-followed')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.server.mode == 'http_error':
            self.send_response(503)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/v1/events'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            try:
                while True:
                    self.wfile.write(b': heartbeat\n\n')
                    self.wfile.flush()
                    if self.server.mode == 'close':
                        return
                    time.sleep(.2)
            except OSError:
                pass
            return
        if self.path == '/v1/status':
            body = dict(api_version='1', server_epoch=EPOCH, adapter_ready=True,
                        capabilities=dict(send_direct=True, reply_existing=True), degraded_reasons=[])
        elif '/messages?' in self.path:
            body = dict(messages=[], next=None)
        elif self.path == '/v1/sync':
            body = dict(server_epoch=EPOCH, cursor=EPOCH+':0')
        else:
            body = dict(conversations=[], next=None)
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def server(pki, *, name='server', client_ca=None, mode='ok', context=None):
    srv = TLSServer(Handler, context or pki.context(name, client_ca))
    srv.mode = mode
    srv.requests = []
    return srv


def failure(probe, kind):
    try:
        probe.until(lambda v: v['diagnostics']['transport']['failure'] == kind)
    except AssertionError:
        raise AssertionError(f'Expected {kind}: {probe.latest}') from None
    return probe.latest['diagnostics']


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-tls-') as temp:
        root = Path(temp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        os.environ['XDG_STATE_HOME'] = str(root/'state')
        pki, other = PKI(root/'tls'), PKI(root/'other')
        counter = 0
        def start(srv, *, args=None, data=None):
            nonlocal counter
            counter += 1
            return Probe([str(BIN), '--control', '--data-dir', str(data or root/f'client-{counter}'), *(args or pki.client_args(srv.server_port))], log)
        def negative(srv, kind, *, args=None):
            probe = start(srv, args=args)
            try:
                d = failure(probe, kind)
                assert d['auth_blocked'] and d['retry_at'] == 0, d
                assert d['transport']['detail']
                count = len(srv.requests)
                time.sleep(1.2)
                assert len(srv.requests) == count, 'Explicit failures must wait for Reconnect'
                assert not srv.requests, 'No API may run on an invalid TLS connection'
                return d
            finally:
                probe.close()
                srv.close()
        with (root/'client.log').open('w+') as log:
            # CA, DNS SAN, IP SAN, lifetime, and server-purpose validation.
            d = negative(server(other, client_ca=pki.root/'ca.pem'), 'server_trust')
            assert d['transport']['curl_code'] == 60 and d['transport']['verify_result'] != 0
            pki.issue('wrong-name', server=True, san=[x509.DNSName('wrong.invalid')])
            negative(server(pki, name='wrong-name'), 'server_trust')
            pki.issue('dns-only', server=True, san=[x509.DNSName('localhost')])
            srv = server(pki, name='dns-only')
            negative(srv, 'server_trust', args=pki.client_args(srv.server_port, host='127.0.0.1'))
            pki.issue('expired-server', server=True, starts=-10, days=-1)
            negative(server(pki, name='expired-server'), 'server_trust')
            pki.issue('future-server', server=True, starts=1, days=30)
            negative(server(pki, name='future-server'), 'server_trust')
            pki.issue('wrong-purpose', server=True, eku=[ExtendedKeyUsageOID.CLIENT_AUTH])
            negative(server(pki, name='wrong-purpose'), 'server_trust')
            # Explicit TLS alert from a server which does not trust this device.
            negative(server(pki, client_ca=other.root/'ca.pem'), 'client_rejected')
            for name, kw in [('expired',dict(starts=-10,days=-1)), ('future',dict(starts=1)), ('server-only',dict(eku=[ExtendedKeyUsageOID.SERVER_AUTH]))]:
                pki.issue(name, **kw)
                srv = server(pki)
                negative(srv, 'credentials', args=pki.client_args(srv.server_port, name=name))
            # Missing, mismatched, encrypted, symlinked, and unsafe local files.
            cert = (pki.root/'client.pem').read_bytes()
            key = (pki.root/'client-key.pem').read_bytes()
            for mode in ('missing', 'mismatch', 'symlink', 'permissions', 'directory', 'encrypted', 'owner', 'parent-symlink'):
                path = pki.root/'client-key.pem'
                args = None
                if mode == 'missing': path.unlink()
                elif mode == 'mismatch': private_write(path, (other.root/'client-key.pem').read_bytes())
                elif mode == 'symlink': path.unlink(); path.symlink_to(other.root/'client-key.pem')
                elif mode == 'permissions': path.chmod(0o644)
                elif mode == 'directory': pki.root.chmod(0o755)
                elif mode == 'encrypted':
                    local = serialization.load_pem_private_key(key, password=None)
                    private_write(path, local.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.BestAvailableEncryption(b'fixture-only')))
                elif mode == 'owner':
                    if os.geteuid() != 0:
                        continue  # Exercise only when ownership can actually be changed.
                    os.chown(path, 65534, -1)
                srv = server(pki)
                if mode == 'parent-symlink':
                    alias = root/'alias'
                    alias.symlink_to(pki.root, target_is_directory=True)
                    args = pki.client_args(srv.server_port)
                    args[-1] = str(alias/'client-key.pem')
                negative(srv, 'credentials', args=args)
                pki.root.chmod(0o700)
                path.unlink(missing_ok=True)
                private_write(path, key)
            # Redirects remain visible HTTP errors and cannot downgrade to HTTP.
            srv = server(pki, mode='redirect')
            probe = start(srv)
            try:
                d = failure(probe, 'http')
                assert d['last_http_status'] == 302 and d['auth_blocked']
                time.sleep(1.2)
                assert len(srv.requests) == 1
            finally:
                probe.close(); srv.close()
            # A protocol-version TLS alert is ambiguous, never called rejection.
            ctx = pki.context()
            ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_2
            srv = server(pki, context=ctx)
            probe = start(srv)
            try:
                d = failure(probe, 'tls')
                assert not d['auth_blocked'] and d['retry_at'] > 0
            finally:
                probe.close(); srv.close()
            # DNS/network and relay failures retain bounded backoff.
            srv = server(pki, mode='http_error')
            probe = start(srv)
            try:
                d = failure(probe, 'http')
                assert d['last_http_status'] == 503 and not d['auth_blocked'] and d['retry_at'] > 0
            finally:
                probe.close(); srv.close()
            srv = server(pki)
            args = pki.client_args(srv.server_port, host='no-such-zimbr-host.invalid')
            probe = start(srv, args=args)
            try:
                d = failure(probe, 'network')
                assert d['transport']['curl_code'] == 6 and not d['auth_blocked']
            finally:
                probe.close(); srv.close()
            # Stalled and partial-record handshakes obey the 3s connect bound.
            for partial in (False, True):
                with socket.socket() as listener:
                    listener.bind(('127.0.0.1', 0)); listener.listen()
                    listener.settimeout(10)
                    released = threading.Event()
                    def stall():
                        sock, _ = listener.accept()
                        with sock:
                            if partial: sock.sendall(b'\x16\x03\x03\x00')
                            released.wait(10)
                    thread = threading.Thread(target=stall, daemon=True)
                    thread.start()
                    srv = type('Endpoint', (), {'server_port': listener.getsockname()[1]})()
                    started = time.monotonic()
                    probe = start(srv)
                    try:
                        d = failure(probe, 'network')
                        assert d['transport']['curl_code'] == 28
                        assert not d['auth_blocked'] and time.monotonic()-started < 6
                    finally:
                        probe.close(); released.set(); thread.join(2)
            srv = server(pki, mode='close')
            probe = start(srv)
            try:
                d = failure(probe, 'network')
                assert d['last_http_status'] == 200 and not d['auth_blocked']
                srv.mode = 'ok'
                probe.until(lambda v: v['online'])
                assert all(path.endswith(EPOCH+':0') or path.endswith('123456789012%3A0') for path, _, _ in srv.requests if path.startswith('/v1/events'))
            finally:
                probe.close(); srv.close()
            # Live credentials are immutable until Reconnect destroys both pools.
            srv = server(pki)
            probe = start(srv)
            try:
                probe.until(lambda v: v['online'])
                old = probe.latest['diagnostics']['transport']['fingerprint']
                assert len(srv.peers) == 1, 'Sequential API requests and the initial SSE attach should reuse a connection'
                probe.command(kind='select', key=EPOCH)
                probe.until(lambda v: any('/messages?' in path for path, _, _ in srv.requests))
                assert len(srv.peers) == 2, 'An API request concurrent with SSE authenticates a second connection'
                new = pki.issue('client', days=20)
                assert new != old
                probe.command(kind='check')
                time.sleep(.3)
                assert set(srv.peers) == {old}
                probe.command(kind='reconnect')
                probe.until(lambda v: v['online'] and v['diagnostics']['transport']['fingerprint'] == new)
                assert probe.latest['diagnostics']['transport']['expiring']
                assert 'renew' in probe.latest['status']
                probe.command(kind='select', key=EPOCH)
                probe.until(lambda v: any('/messages?' in path and peer == new for path, peer, _ in srv.requests))
                assert srv.peers.count(new) == 2
                paths = [path for path, peer, _ in srv.requests if peer == new]
                assert '/v1/status' in paths and any(p.startswith('/v1/events') for p in paths)
                assert '/v1/sync' not in paths, 'Credential renewal must preserve the epoch and durable cache'
                # Broken replacement leaves cached state available until fixed.
                (pki.root/'client-key.pem').chmod(0o644)
                probe.command(kind='reconnect')
                failure(probe, 'credentials')
                (pki.root/'client-key.pem').chmod(0o600)
                probe.command(kind='reconnect')
                probe.until(lambda v: v['online'] and not v['diagnostics']['auth_blocked'])
            finally:
                probe.close(); srv.close()
            default_trust(root, pki, other, negative)
            configuration(root, pki)
            provisioning(root, pki)
        print('PASS: server identity/purpose/validity, explicit rejection, local credential safety, HTTPS origins, redirects, TLS diagnostics/backoff, isolated CA trust, pooled API + SSE authentication, renewal and provisioning')


def default_trust(root, pki, other, negative):
    # A temporary hashed trust directory substitutes for an OS/backend default
    # without installing a CA. A control HTTPS client must trust this root.
    trust = root/'default-trust'
    trust.mkdir()
    (trust/'ca.pem').write_bytes((other.root/'ca.pem').read_bytes())
    subprocess.run(['openssl','rehash',str(trust)], check=True, capture_output=True)
    env = dict(os.environ)
    os.environ['SSL_CERT_FILE'] = str(trust/'ca.pem')
    os.environ['SSL_CERT_DIR'] = str(trust)
    srv = server(other, client_ca=pki.root/'ca.pem')
    try:
        ctx = ssl.create_default_context()
        ctx.load_cert_chain(pki.root/'client.pem', pki.root/'client-key.pem')
        connection = http.client.HTTPSConnection('localhost', srv.server_port, context=ctx)
        try:
            connection.request('GET', '/v1/status')
            assert connection.getresponse().status == 200
        finally:
            connection.close()
        srv.requests.clear()
        negative(srv, 'server_trust')
        # Simulate a backend/build-time CA-directory fallback already installed
        # in SSL_CTX. The callback must replace its lookup methods, not just add
        # our CA alongside them. An unisolated libcurl control proves fallback.
        shim = root/'default-ca.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT/'tests/default_ca.c'), '-o', str(shim), '-lssl', '-lcrypto', '-ldl'], check=True)
        os.environ['LD_PRELOAD'] = str(shim)
        os.environ['ZIMBR_TEST_DEFAULT_CA_DIR'] = str(trust)
        srv = server(other, client_ca=pki.root/'ca.pem')
        result = subprocess.run(['curl', '--silent', '--show-error', '--noproxy', '*', '--http1.1', '--tlsv1.3',
                                 '--cacert', str(pki.root/'ca.pem'), '--cert', str(pki.root/'client.pem'),
                                 '--key', str(pki.root/'client-key.pem'), f'https://localhost:{srv.server_port}/v1/status'],
                                capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        srv.requests.clear()
        negative(srv, 'server_trust')
    finally:
        srv.close()
        os.environ.clear(); os.environ.update(env)


def configuration(root, pki):
    args = [str(BIN), '--data-dir', str(root/'config-client'), *pki.client_args(1)]
    for url in ('http://localhost:1', 'https://user@localhost', 'https://localhost/path', 'https://localhost?x', 'https://localhost#x', 'https://localhost:0', 'https://localhost:65536'):
        command = list(args); command[command.index('--relay-url')+1] = url
        result = subprocess.run(command, capture_output=True, timeout=5)
        assert result.returncode != 0 and b'InvalidRelayOrigin' in result.stderr
    for flag in ('--port', '--token-file'):
        result = subprocess.run([*args, flag, '8731'], capture_output=True, timeout=5)
        assert b'ObsoleteTransportConfiguration' in result.stderr
    conf = root/'config/zimbr'
    conf.mkdir(parents=True, mode=0o700)
    # Legacy import failures now allow interactive repair instead of preventing
    # launch. Each fresh database attempts import once and reports the problem.
    for field in ('port', 'token_file', 'token_path'):
        private_write(conf/'config.json', json.dumps({field: None}).encode())
        fresh = list(args)
        fresh[fresh.index('--data-dir')+1] = str(root/f'legacy-{field}')
        fresh[fresh.index('--relay-url')+1] = 'http://invalid'
        result = subprocess.run(fresh, capture_output=True, timeout=5)
        assert b'ObsoleteTransportConfiguration' in result.stderr
        assert b'InvalidRelayOrigin' in result.stderr
    (conf/'config.json').chmod(0o644)
    fresh[fresh.index('--data-dir')+1] = str(root/'unsafe-legacy')
    result = subprocess.run(fresh, capture_output=True, timeout=5)
    assert b'UnsafeConfiguration' in result.stderr
    (conf/'config.json').unlink()
    # Import retains its own strings after clearing the secure read buffer.
    # The directory is selected by XDG_STATE_HOME or the explicit flag; the
    # obsolete JSON data_dir field no longer redirects the database.
    srv = server(pki)
    private_write(conf/'config.json', json.dumps(dict(
        relay_url='http://obsolete-value-overridden-by-cli',
        ca_file=str(pki.root/'ca.pem'), client_cert_file=str(pki.root/'client.pem'),
        client_key_file=str(pki.root/'client-key.pem'), data_dir=str(root/'configured-cache'),
        theme='dark', enter_to_send=False)).encode())
    probe = Probe([str(BIN), '--control', '--relay-url', f'https://localhost:{srv.server_port}'], None)
    try:
        probe.until(lambda v: v['online'])
        assert (root/'state/zimbr/client.db').exists()
        assert not (root/'configured-cache').exists()
    finally:
        probe.close(); srv.close(); (conf/'config.json').unlink()
    missing = list(args)
    missing[missing.index('--client-key-file')+1] = str(root/'missing-key.pem')
    result = subprocess.run(missing, capture_output=True, timeout=5)
    assert b'ConnectionNeedsAttention' in result.stderr and b'Client key missing or unsafe' in result.stderr


def provisioning(root, pki):
    tool = ROOT/'packaging/linux/provision.py'
    dest = root/'provisioned'
    command = ['python3', str(tool)]
    subprocess.run([*command, 'request', '--tls-dir', str(dest), '--name', 'linux-desktop.zimbr.invalid'], check=True, capture_output=True)
    csr = x509.load_pem_x509_csr((dest/'client.csr').read_bytes())
    assert csr.is_signature_valid
    assert list(csr.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value) == [ExtendedKeyUsageOID.CLIENT_AUTH]
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(csr.subject).issuer_name(pki.ca.subject)
               .public_key(csr.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now-timedelta(hours=1)).not_valid_after(now+timedelta(days=60)))
    for ext in csr.extensions:
        builder = builder.add_extension(ext.value, ext.critical)
    cert = builder.sign(pki.ca_key, hashes.SHA256())
    returned = root/'issued.pem'
    returned.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    args = [*command, 'import', '--tls-dir', str(dest), '--ca', str(pki.root/'ca.pem'), '--cert', str(returned), '--ca-sha256']
    assert subprocess.run([*args, '0'*64], capture_output=True).returncode != 0
    assert not (dest/'ca.pem').exists()
    result = subprocess.run([*args, pki.ca.fingerprint(hashes.SHA256()).hex()], capture_output=True, check=True)
    assert cert.fingerprint(hashes.SHA256()).hex().encode() in result.stdout
    assert (dest/'client.pem').stat().st_mode & 0o777 == 0o600
    original = (dest/'client-key.pem').read_bytes()
    assert subprocess.run([*command, 'request', '--tls-dir', str(dest), '--name', 'linux-desktop.zimbr.invalid'], capture_output=True).returncode != 0
    assert (dest/'client-key.pem').read_bytes() == original
    installed = (dest/'client.pem').read_bytes()
    returned.write_bytes((pki.root/'client.pem').read_bytes())
    assert subprocess.run([*args, pki.ca.fingerprint(hashes.SHA256()).hex()], capture_output=True).returncode != 0
    assert (dest/'client.pem').read_bytes() == installed, 'Bad renewal must leave installed credentials intact'
    assert (dest/'client-key.pem').read_bytes() == original


if __name__ == '__main__':
    main()
