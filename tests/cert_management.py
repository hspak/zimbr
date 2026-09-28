#!/usr/bin/env python3
"""Exercise the authoritative Mac signer with real mkcert, without installing trust.

Build the dev-profile relay and fake-relay first, then run with
ZIMBR_MKCERT=/path/to/mkcert python3 tests/cert_management.py.
All CA and device material stays in temporary test directories.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtendedKeyUsageOID, ExtensionOID

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from tls_admin import atomic, create_key, verify_leaf
from tls_support import Credentials
from fixture import create
from integration import wait_for


class CertificateManagement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zimbr-issuer-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mkcert = os.environ.get('ZIMBR_MKCERT', 'mkcert')
        self.home = self.root/'home'
        self.home.mkdir(mode=0o700)
        self.issuer = self.home/'Library/Application Support/Zimbr Dev/ca'
        self.environment = dict(os.environ, HOME=str(self.home))

    def sign(self, csr, role, names, output):
        args = [sys.executable, str(ROOT/'tools/tls_admin.py'), 'sign',
                '--profile', 'dev', '--csr', str(csr),
                '--cert', str(output), '--role', role, '--mkcert', self.mkcert]
        for name in names:
            args += ['--name', name]
        return subprocess.run(args, env=self.environment, capture_output=True, text=True, timeout=30)

    def linux(self, *args):
        return subprocess.run([sys.executable, str(ROOT/'packaging/linux/provision.py'), *map(str, args)],
                              capture_output=True, text=True, timeout=30)

    def admin(self, *args, env=None):
        return subprocess.run([sys.executable, str(ROOT/'tools/tls_admin.py'), *map(str, args)],
                              env=env or self.environment, capture_output=True, text=True, timeout=30)

    def test_default_dev_issuer_supports_setup_and_manual_device_issuance(self):
        home = self.home
        environment = dict(os.environ, HOME=str(home))
        directory = self.root/'setup'
        relay = ROOT/'zig-out/bin/relay'
        result = self.admin('setup', '--directory', directory, '--relay', relay,
                            '--server-name', 'localhost', '--listen-address', '127.0.0.1',
                            '--mkcert', self.mkcert, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        issuer = home/'Library/Application Support/Zimbr Dev/ca'
        original_key = (issuer/'rootCA-key.pem').read_bytes()
        linux = self.root/'linux'
        result = self.linux('request', '--tls-dir', linux, '--name', 'desktop.zimbr.invalid')
        self.assertEqual(result.returncode, 0, result.stderr)
        handoff = self.root/'handoff'
        result = self.admin('issue-device', '--csr', linux/'client.csr', '--name', 'desktop.zimbr.invalid',
                            '--label', 'Desktop', '--directory', handoff, '--config', directory/'relay.json',
                            '--relay', relay, '--stage', '--mkcert', self.mkcert, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        cert = x509.load_pem_x509_certificate((handoff/'client.pem').read_bytes())
        cert.verify_directly_issued_by(x509.load_pem_x509_certificate((issuer/'rootCA.pem').read_bytes()))
        self.assertEqual((issuer/'rootCA-key.pem').read_bytes(), original_key)
        self.assertFalse((home/'.config').exists())

    def test_turnkey_setup_and_device_handoff_with_real_relay_validation(self):
        relay = ROOT/'zig-out/bin/relay'
        directory = self.root/'setup'
        issuer = self.issuer
        args = ('setup', '--directory', directory, '--relay', relay,
                '--server-name', 'localhost', '--listen-address', '127.0.0.1',
                '--name', '127.0.0.1', '--mkcert', self.mkcert)
        result = self.admin(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads((directory/'relay.json').read_text())
        self.assertEqual(config['port'], 8732)
        self.assertEqual(config['server_name'], 'localhost')
        admin = json.loads((directory/'admin.json').read_text())
        self.assertEqual(admin['relay_url'], 'https://localhost:8732')
        devices_path = directory/'devices.json'
        devices = json.loads(devices_path.read_text())
        admin_cert = x509.load_pem_x509_certificate((directory/'admin/client.pem').read_bytes())
        self.assertEqual(devices, [{'label': 'Mac administrator', 'enabled': True,
                                   'sha256': admin_cert.fingerprint(hashes.SHA256()).hex()}])
        original_key = (directory/'server-key.pem').read_bytes()
        self.assertNotEqual(self.admin(*args).returncode, 0)
        self.assertEqual((directory/'server-key.pem').read_bytes(), original_key)
        self.assertFalse(list(directory.rglob('rootCA-key.pem')))
        for path in directory.rglob('*'):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)

        linux = self.root/'linux'
        name = 'desktop.zimbr.invalid'
        self.assertEqual(self.linux('request', '--tls-dir', linux, '--name', name).returncode, 0)
        handoff = self.root/'handoff'
        args = ('issue-device', '--csr', linux/'client.csr', '--name', name, '--label', 'Desktop',
                '--directory', handoff, '--config', directory/'relay.json',
                '--relay', relay, '--stage', '--mkcert', self.mkcert)
        result = self.admin(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"restart_complete": false', result.stdout)
        self.assertEqual({p.name for p in handoff.iterdir()}, {'ca.pem', 'client.pem'})
        ca = x509.load_pem_x509_certificate((handoff/'ca.pem').read_bytes())
        pin = ca.fingerprint(hashes.SHA256()).hex()
        self.assertIn(pin, result.stdout)
        cert = x509.load_pem_x509_certificate((handoff/'client.pem').read_bytes())
        devices = json.loads(devices_path.read_text())
        self.assertEqual(len(devices), 2)
        self.assertEqual(devices[1], {'label': 'Desktop', 'enabled': True,
                                     'sha256': cert.fingerprint(hashes.SHA256()).hex()})

        # Exercise the real import and its GUI argument handoff without a display.
        launcher = self.root/'client'
        captured = self.root/'launch.json'
        launcher.write_text(f'#!{sys.executable}\nimport json, pathlib, sys\n'
                            f'pathlib.Path({str(captured)!r}).write_text(json.dumps(sys.argv[1:]))\n')
        launcher.chmod(0o700)
        args = ('import', '--tls-dir', linux, '--ca', handoff/'ca.pem', '--cert', handoff/'client.pem',
                '--relay-url', admin['relay_url'], '--launch', launcher, '--ca-sha256')
        self.assertNotEqual(self.linux(*args, '0'*64).returncode, 0)
        self.assertFalse(captured.exists())
        result = self.linux(*args, pin)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(captured.read_text()), [
            '--settings', '--relay-url', admin['relay_url'], '--ca-file', str(linux/'ca.pem'),
            '--client-cert-file', str(linux/'client.pem'), '--client-key-file', str(linux/'client-key.pem'),
        ])

        # The generated identities must work with the production TLS listener,
        # beyond passing offline certificate/configuration validation.
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        config['port'] = port
        atomic(directory/'relay.json', json.dumps(config).encode())
        source = self.root/'source.db'
        create(source, count=0)
        common = ['--messages-db', str(source), '--data-dir', str(self.root/'data'),
                  '--config', str(directory/'relay.json')]
        fixture = ROOT/'zig-out/bin/fake-relay'
        subprocess.run([str(fixture), 'setup', *common], check=True, capture_output=True)
        with (self.root/'relay.log').open('w') as log:
            process = subprocess.Popen([str(fixture), 'serve', *common], stdout=log, stderr=log)
            try:
                for client, folder in (('admin', directory/'admin'), ('linux', linux)):
                    client_config = self.root/client/'admin.json'
                    client_config.parent.mkdir(mode=0o700, exist_ok=True)
                    for filename in ('ca.pem', 'client.pem', 'client-key.pem'):
                        atomic(client_config.parent/'admin'/filename, (folder/filename).read_bytes())
                    atomic(client_config, json.dumps({'relay_url': f'https://localhost:{port}'}).encode())
                    credentials = Credentials(client_config)
                    def status():
                        connection = credentials.connection(timeout=2)
                        try:
                            connection.request('GET', '/v1/status')
                            response = connection.getresponse()
                            self.assertEqual(response.status, 200)
                            return json.loads(response.read())
                        finally:
                            connection.close()
                    self.assertEqual(wait_for(status)['api_version'], '1')
            finally:
                process.terminate()
                process.wait(timeout=10)

    def test_signer_rejects_custom_issuer_path_override(self):
        result = self.admin('sign', '--role', 'client', '--csr', self.root/'client.csr',
                            '--cert', self.root/'client.pem', '--name', 'desktop.zimbr.invalid',
                            '--caroot', self.root/'other-ca')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unrecognized arguments: --caroot', result.stderr)
        self.assertFalse((self.root/'other-ca').exists())

    def test_setup_rejects_invalid_inputs_before_issuance(self):
        base = ('setup', '--directory', self.root/'setup',
                '--relay', ROOT/'zig-out/bin/relay', '--server-name', 'localhost',
                '--listen-address', '127.0.0.1', '--mkcert', self.mkcert)
        for extra in (('--port', '0'), ('--port', '65536'), ('--profile', 'release'),
                      ('--listen-address', '0.0.0.0'), ('--listen-address', '::'),
                      ('--listen-address', 'not-an-ip'), ('--mkcert', str(self.root/'missing-mkcert'))):
            with self.subTest(extra=extra):
                result = self.admin(*base, *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.issuer/'rootCA-key.pem').exists())

    def test_linux_request_mac_signer_and_linux_import(self):
        directory = self.root/'linux'
        name = 'linux-desktop.zimbr.invalid'
        result = self.linux('request', '--tls-dir', directory, '--name', name, '--label', 'Workstation display label')
        self.assertEqual(result.returncode, 0, result.stderr)
        csr_path = directory/'client.csr'
        csr = x509.load_pem_x509_csr(csr_path.read_bytes())
        from cryptography.x509.oid import NameOID
        self.assertEqual(csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value, 'Workstation display label')
        self.assertEqual(list(csr.extensions.get_extension_for_class(x509.SubjectAlternativeName).value), [x509.DNSName(name)])
        original_key = (directory/'client-key.pem').read_bytes()
        issued = directory/'issued.pem'
        result = self.sign(csr_path, 'client', [name], issued)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        ca_path = self.issuer/'rootCA.pem'
        ca = x509.load_pem_x509_certificate(ca_path.read_bytes())
        args = ('import', '--tls-dir', directory, '--ca', ca_path, '--cert', issued, '--ca-sha256')
        result = self.linux(*args, '0'*64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((directory/'client.pem').exists())
        result = self.linux(*args, ca.fingerprint(hashes.SHA256()).hex())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(report['sha256'], result.stdout)
        self.assertEqual((directory/'client.pem').read_bytes(), issued.read_bytes())
        self.assertEqual((directory/'client-key.pem').read_bytes(), original_key)
        self.assertFalse((directory/'rootCA-key.pem').exists())
        # Existing keys are never replaced by another request operation.
        self.assertNotEqual(self.linux('request', '--tls-dir', directory, '--name', name).returncode, 0)
        self.assertEqual((directory/'client-key.pem').read_bytes(), original_key)

        # A valid certificate from the correct CA with the same key but a
        # different approved device name must still fail local import.
        key = serialization.load_pem_private_key(original_key, None)
        wrong_name = 'other-device.zimbr.invalid'
        builder = x509.CertificateSigningRequestBuilder().subject_name(csr.subject)
        for ext in csr.extensions:
            value = x509.SubjectAlternativeName([x509.DNSName(wrong_name)]) if ext.oid == ExtensionOID.SUBJECT_ALTERNATIVE_NAME else ext.value
            builder = builder.add_extension(value, ext.critical)
        changed = directory/'other.csr'
        atomic(changed, builder.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
        wrong_cert = directory/'other.pem'
        result = self.sign(changed, 'client', [wrong_name], wrong_cert)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (directory/'client.pem').read_bytes()
        result = self.linux('import', '--tls-dir', directory, '--ca', ca_path, '--cert', wrong_cert,
                            '--ca-sha256', ca.fingerprint(hashes.SHA256()).hex())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SAN does not exactly match', result.stderr)
        self.assertEqual((directory/'client.pem').read_bytes(), installed)
        # The retained request is security configuration, not an unchecked hint.
        original_csr = csr_path.read_bytes()
        csr_path.unlink()
        csr_path.symlink_to(changed)
        result = self.linux(*args, ca.fingerprint(hashes.SHA256()).hex())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((directory/'client.pem').read_bytes(), installed)
        csr_path.unlink()
        atomic(csr_path, original_csr)
        csr_path.chmod(0o644)
        self.assertNotEqual(self.linux(*args, ca.fingerprint(hashes.SHA256()).hex()).returncode, 0)
        self.assertEqual((directory/'client.pem').read_bytes(), installed)

    def test_linux_requires_an_explicit_device_dns_name(self):
        directory = self.root/'linux'
        self.assertNotEqual(self.linux('request', '--tls-dir', directory).returncode, 0)
        for name in ('linux-desktop', '*.zimbr.invalid', 'user@zimbr.invalid', '127.0.0.1',
                     '-device.zimbr.invalid', 'device..zimbr.invalid'):
            with self.subTest(name=name):
                result = self.linux('request', '--tls-dir', directory, '--name', name)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((directory/'client-key.pem').exists())

    def test_actual_mkcert_preserves_client_and_server_contract(self):
        for role, names, eku in (
            ('client', ['linux-desktop.zimbr.invalid'], ExtendedKeyUsageOID.CLIENT_AUTH),
            ('server', ['localhost', '127.0.0.1'], ExtendedKeyUsageOID.SERVER_AUTH),
        ):
            with self.subTest(role=role):
                directory = self.root/role
                csr_path = create_key(directory, role, names)
                output = directory/f'{role}.pem'
                result = self.sign(csr_path, role, names, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                cert = x509.load_pem_x509_certificate(output.read_bytes())
                ca = x509.load_pem_x509_certificate((self.issuer/'rootCA.pem').read_bytes())
                csr = x509.load_pem_x509_csr(csr_path.read_bytes())
                key = serialization.load_pem_private_key((directory/f'{role}-key.pem').read_bytes(), None)
                verify_leaf(cert, ca, role, names)
                self.assertEqual(cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME).value,
                                 csr.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME).value)
                self.assertEqual(list(cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value), [eku])
                self.assertEqual(cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo),
                                 key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))
                self.assertEqual(report['sha256'], cert.fingerprint(hashes.SHA256()).hex())
                self.assertEqual(report['expires'], cert.not_valid_after_utc.isoformat())
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.issuer/'rootCA-key.pem').stat().st_mode & 0o777, 0o600)

    def test_signer_rejects_absent_or_unapproved_client_san(self):
        directory = self.root/'client'
        names = ['linux-desktop.zimbr.invalid']
        csr_path = create_key(directory, 'client', names)
        csr = x509.load_pem_x509_csr(csr_path.read_bytes())
        key = serialization.load_pem_private_key((directory/'client-key.pem').read_bytes(), None)
        builder = x509.CertificateSigningRequestBuilder().subject_name(csr.subject)
        for extension in csr.extensions:
            if extension.oid != ExtensionOID.SUBJECT_ALTERNATIVE_NAME:
                builder = builder.add_extension(extension.value, extension.critical)
        missing = directory/'without-san.csr'
        atomic(missing, builder.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
        for request, expected in ((missing, names), (csr_path, ['another-device.zimbr.invalid'])):
            with self.subTest(request=request.name, expected=expected):
                output = directory/'rejected.pem'
                result = self.sign(request, 'client', expected, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('SANs do not exactly match', result.stderr)
                self.assertFalse(output.exists())
                self.assertFalse((self.issuer/'rootCA-key.pem').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
