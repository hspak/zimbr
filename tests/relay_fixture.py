"""Synthetic dedicated CAs/identities; never installed in a trust store."""
import datetime as dt
import http.client
import json
import os
from pathlib import Path
import ssl
import sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from tls_admin import atomic, save_json

UTC = dt.timezone.utc


class Fixture:
    def __init__(self, directory, port):
        self.root = Path(directory).resolve()/'tls'
        self.root.mkdir(mode=0o700)
        self.port = port
        self.ca_key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Synthetic Zimbr CA')])
        now = dt.datetime.now(UTC)
        self.ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(self.ca_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-dt.timedelta(days=1)).not_valid_after(now+dt.timedelta(days=30))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(self.ca_key.public_key()), critical=False)
            .sign(self.ca_key, hashes.SHA256()))
        atomic(self.root/'ca.pem', self.ca.public_bytes(serialization.Encoding.PEM))
        self.issue('server', server=True)
        self.issue('client')
        self.devices = [{'label': 'synthetic admin', 'sha256': self.fingerprint('client'), 'enabled': True}]
        save_json(self.root/'devices.json', self.devices)
        self.config = self.root/'relay.json'
        save_json(self.config, {'listen_address': '127.0.0.1', 'port': port, 'server_name': 'localhost',
            'server_cert_file': str(self.root/'server.pem'), 'server_key_file': str(self.root/'server-key.pem'),
            'client_ca_file': str(self.root/'ca.pem'), 'device_allowlist_file': str(self.root/'devices.json')})
        self.admin = self.root/'admin.json'
        save_json(self.admin, {'relay_url': f'https://localhost:{port}', 'ca_file': str(self.root/'ca.pem'),
            'client_cert_file': str(self.root/'client.pem'), 'client_key_file': str(self.root/'client-key.pem')})

    def issue(self, name, server=False, before=None, after=None, eku=None, sans=None):
        now = dt.datetime.now(UTC)
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
        builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(self.ca.subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(before or now-dt.timedelta(minutes=1)).not_valid_after(after or now+dt.timedelta(days=7))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self.ca_key.public_key()), critical=False))
        if eku != 'absent':
            builder = builder.add_extension(x509.ExtendedKeyUsage(eku or [ExtendedKeyUsageOID.SERVER_AUTH if server else ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
        if server:
            import ipaddress
            builder = builder.add_extension(x509.SubjectAlternativeName(sans or [x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
        cert = builder.sign(self.ca_key, hashes.SHA256())
        atomic(self.root/(name+'.pem'), cert.public_bytes(serialization.Encoding.PEM))
        atomic(self.root/(name+'-key.pem'), key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        return cert

    def fingerprint(self, name):
        return x509.load_pem_x509_certificate((self.root/(name+'.pem')).read_bytes()).fingerprint(hashes.SHA256()).hex()

    def context(self, name='client', ca=None):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_verify_locations(cafile=str(ca or self.root/'ca.pem'))
        if name: ctx.load_cert_chain(str(self.root/(name+'.pem')), str(self.root/(name+'-key.pem')))
        ctx.set_alpn_protocols(['http/1.1'])
        return ctx

    def connection(self, auth=True, timeout=4, name='client'):
        return http.client.HTTPSConnection('127.0.0.1', self.port, timeout=timeout, context=self.context(name if auth else None))
