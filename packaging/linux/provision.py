#!/usr/bin/env python3
"""Create a local client key/CSR or import a verified Zimbr CA and device leaf.

Requires Python cryptography and OpenSSL. Never generates or transfers CA keys.
For renewal, use a new private directory, enroll its fingerprint on the Mac,
then point the client configuration at the new files and restart the client.
Replacing validated files at existing paths is applied by Reconnect.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import stat
import subprocess
import tempfile

from cryptography import x509
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID, ExtensionOID


def private_dir(path, create=False):
    path = Path(os.path.abspath(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            last = index == len(path.parts)-2
            parent = os.fstat(fd)
            if parent.st_uid not in (0, os.getuid()) or (parent.st_mode & 0o022 and not (parent.st_uid == 0 and parent.st_mode & stat.S_ISVTX)):
                raise ValueError('Untrusted writable parent directory')
            if create and last:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('TLS directory must be owned by you with mode 0700')
        return path, fd
    except BaseException:
        os.close(fd)
        raise


def read_key(fd):
    keyfd = os.open('client-key.pem', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        info = os.fstat(keyfd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError('Client key must be a private owned 0600 regular file')
        with os.fdopen(keyfd, 'rb', closefd=False) as source:
            return serialization.load_pem_private_key(source.read(1024*1024), password=None)
    finally:
        os.close(keyfd)


def write_new(fd, name, data):
    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    with os.fdopen(out, 'wb') as dest:
        dest.write(data)
        dest.flush()
        os.fsync(dest.fileno())


def request(args):
    path, fd = private_dir(args.tls_dir, create=True)
    try:
        for name in ('client-key.pem', 'client.csr'):
            try:
                os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise ValueError(f'{name} already exists; use a new directory for renewal')
        key = ec.generate_private_key(ec.SECP256R1())
        csr = (x509.CertificateSigningRequestBuilder()
               .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, args.label)]))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
               .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
               .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
               .sign(key, hashes.SHA256()))
        write_new(fd, 'client-key.pem', key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        write_new(fd, 'client.csr', csr.public_bytes(serialization.Encoding.PEM))
        print(f'Created {path}/client.csr. Transfer only the CSR to the administrator; keep client-key.pem here.')
    finally:
        os.close(fd)


def public_key(key):
    return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def import_certificate(args):
    path, fd = private_dir(args.tls_dir)
    try:
        ca_data, cert_data = Path(args.ca).read_bytes(), Path(args.cert).read_bytes()
        if ca_data.count(b'-----BEGIN CERTIFICATE-----') != 1 or cert_data.count(b'-----BEGIN CERTIFICATE-----') != 1 or b'PRIVATE KEY' in ca_data+cert_data:
            raise ValueError('Import exactly one CA and one client certificate, never private keys')
        ca, cert = x509.load_pem_x509_certificate(ca_data), x509.load_pem_x509_certificate(cert_data)
        expected = args.ca_sha256.lower().replace(':', '')
        if len(expected) != 64 or ca.fingerprint(hashes.SHA256()).hex() != expected:
            raise ValueError('CA SHA-256 does not match the independently authenticated fingerprint')
        if not ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise ValueError('Trust certificate is not a CA')
        ca.verify_directly_issued_by(ca)
        cert.verify_directly_issued_by(ca)
        for item in (ca, cert):
            if not item.not_valid_before_utc <= datetime.now(timezone.utc) < item.not_valid_after_utc:
                raise ValueError('Certificate is expired or not yet valid')
        if cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise ValueError('Client certificate must not be a CA')
        if list(cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value) != [ExtendedKeyUsageOID.CLIENT_AUTH]:
            raise ValueError('Client leaf must have only clientAuth EKU')
        allowed = {ExtensionOID.BASIC_CONSTRAINTS, ExtensionOID.KEY_USAGE, ExtensionOID.EXTENDED_KEY_USAGE,
                   ExtensionOID.SUBJECT_KEY_IDENTIFIER, ExtensionOID.AUTHORITY_KEY_IDENTIFIER}
        if any(ext.oid not in allowed for ext in cert.extensions):
            raise ValueError('Unexpected extension in client certificate')
        usage = cert.extensions.get_extension_for_class(x509.KeyUsage).value
        if not usage.digital_signature or usage.key_cert_sign or usage.crl_sign:
            raise ValueError('Unexpected client key usage')
        if public_key(read_key(fd).public_key()) != public_key(cert.public_key()):
            raise ValueError('Issued client certificate does not match the local private key')
        # Stage public files, verify with the same purpose checks as the runtime,
        # and atomically replace only after all validation has succeeded.
        with tempfile.TemporaryDirectory(prefix='.import-', dir=path) as staging:
            staging = Path(staging)
            for name, data in (('ca.pem', ca_data), ('client.pem', cert_data)):
                (staging/name).write_bytes(data)
                (staging/name).chmod(0o600)
            subprocess.run(['openssl', 'verify', '-no-CApath', '-no-CAstore', '-CAfile', str(staging/'ca.pem'),
                            '-purpose', 'sslclient', str(staging/'client.pem')], check=True, capture_output=True)
            # dir_fd pins the private destination even if its pathname changes.
            os.replace(staging/'ca.pem', 'ca.pem', dst_dir_fd=fd)
            os.replace(staging/'client.pem', 'client.pem', dst_dir_fd=fd)
            os.fsync(fd)
        print('Imported verified credentials.')
        print('Enroll this entire-leaf DER SHA-256 on the Mac: '+cert.fingerprint(hashes.SHA256()).hex())
        print('Client certificate expires: '+cert.not_valid_after_utc.isoformat())
        print('Configure these absolute paths, then Reconnect (restart if configuration paths changed):')
        for field, name in (('ca_file', 'ca.pem'), ('client_cert_file', 'client.pem'), ('client_key_file', 'client-key.pem')):
            print(f'  {field}: {path/name}')
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    req = commands.add_parser('request', help='create a new local key and clientAuth CSR')
    req.add_argument('--tls-dir', required=True)
    req.add_argument('--label', default='Zimbr Linux device')
    imp = commands.add_parser('import', help='validate and import issued public credentials')
    imp.add_argument('--tls-dir', required=True)
    imp.add_argument('--ca', required=True)
    imp.add_argument('--cert', required=True)
    imp.add_argument('--ca-sha256', required=True, help='CA DER SHA-256 verified over trusted SSH or independently')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        (request if args.command == 'request' else import_certificate)(args)
    except (ValueError, OSError, InvalidSignature, UnsupportedAlgorithm, x509.ExtensionNotFound, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'Provisioning failed: {exc}\n')


if __name__ == '__main__':
    main()
