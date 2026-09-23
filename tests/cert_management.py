#!/usr/bin/env python3
"""Exercise the authoritative Mac signer with real mkcert, without installing trust.

Run with ZIMBR_MKCERT=/path/to/mkcert python3 tests/cert_management.py.
All CA and device material is temporary and stays outside runtime directories.
"""
import json
import os
from pathlib import Path
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


class CertificateManagement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zimbr-issuer-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mkcert = os.environ.get('ZIMBR_MKCERT', 'mkcert')

    def sign(self, csr, role, names, output):
        args = [sys.executable, str(ROOT/'tools/tls_admin.py'), 'sign',
                '--caroot', str(self.root/'issuer'), '--csr', str(csr),
                '--cert', str(output), '--role', role, '--mkcert', self.mkcert]
        for name in names:
            args += ['--name', name]
        return subprocess.run(args, capture_output=True, text=True, timeout=30)

    def linux(self, *args):
        return subprocess.run([sys.executable, str(ROOT/'packaging/linux/provision.py'), *map(str, args)],
                              capture_output=True, text=True, timeout=30)

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
        ca_path = self.root/'issuer/rootCA.pem'
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
                ca = x509.load_pem_x509_certificate((self.root/'issuer/rootCA.pem').read_bytes())
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
        self.assertEqual((self.root/'issuer/rootCA-key.pem').stat().st_mode & 0o777, 0o600)

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
                self.assertFalse((self.root/'issuer/rootCA-key.pem').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
