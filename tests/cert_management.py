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
