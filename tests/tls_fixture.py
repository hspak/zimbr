"""Ephemeral authenticated TLS endpoints for Linux client negative/fault tests.

Ordinary worker integration uses the native relay and tests/relay_fixture.py.
No test CA is installed in a system trust store.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import http.server
import ipaddress
from pathlib import Path
import socket
import ssl
import threading

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def private_write(path, data):
    path.write_bytes(data)
    path.chmod(0o600)


class PKI:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(mode=0o700)
        self.ca_key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.now(timezone.utc)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Zimbr temporary test CA '+self.root.name)])
        self.ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                   .public_key(self.ca_key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now-timedelta(days=1)).not_valid_after(now+timedelta(days=90))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(self.ca_key.public_key()), critical=False)
                   .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self.ca_key.public_key()), critical=False)
                   .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
                   .sign(self.ca_key, hashes.SHA256()))
        private_write(self.root/'ca.pem', self.ca.public_bytes(serialization.Encoding.PEM))
        self.issue('server', server=True)
        self.issue('client')

    def issue(self, name, *, server=False, san=None, days=60, starts=-1, eku=None, issuer=None):
        issuer = issuer or self
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.now(timezone.utc)
        builder = (x509.CertificateBuilder()
                   .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)]))
                   .issuer_name(issuer.ca.subject).public_key(key.public_key())
                   .serial_number(x509.random_serial_number())
                   .not_valid_before(now+timedelta(days=starts)).not_valid_after(now+timedelta(days=days))
                   .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
                   .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer.ca_key.public_key()), critical=False)
                   .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
                   .add_extension(x509.ExtendedKeyUsage(eku or [ExtendedKeyUsageOID.SERVER_AUTH if server else ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False))
        if server:
            builder = builder.add_extension(x509.SubjectAlternativeName(san if san is not None else [x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
        cert = builder.sign(issuer.ca_key, hashes.SHA256())
        private_write(self.root/f'{name}.pem', cert.public_bytes(serialization.Encoding.PEM))
        private_write(self.root/f'{name}-key.pem', key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        return cert.fingerprint(hashes.SHA256()).hex()

    def client_args(self, port, *, name='client', host='localhost', ca=None):
        return ['--relay-url', f'https://{host}:{port}', '--ca-file', str(ca or self.root/'ca.pem'),
                '--client-cert-file', str(self.root/f'{name}.pem'), '--client-key-file', str(self.root/f'{name}-key.pem')]

    def context(self, name='server', client_ca=None):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(self.root/f'{name}.pem', self.root/f'{name}-key.pem')
        ctx.load_verify_locations(client_ca or self.root/'ca.pem')
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.num_tickets = 0
        ctx.set_alpn_protocols(['http/1.1'])
        return ctx


class TLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, handler, context, port=0):
        self.context = context
        self.peers = []
        self.sockets = []
        super().__init__(('127.0.0.1', port), handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def get_request(self):
        sock, addr = super().get_request()
        sock.settimeout(8)
        tls = self.context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        self.sockets.append(tls)
        return tls, addr

    def finish_request(self, request, client_address):
        request.do_handshake()
        self.peers.append(hashlib.sha256(request.getpeercert(binary_form=True)).hexdigest())
        super().finish_request(request, client_address)

    def handle_error(self, request, client_address):
        pass  # Expected peer aborts/negative handshakes.

    def close(self):
        self.shutdown()
        for sock in self.sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        self.server_close()
        self.thread.join(timeout=2)
