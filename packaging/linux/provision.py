#!/usr/bin/env python3
"""Set up Zimbr over SSH, or manually request/import device credentials.

Requires Python cryptography and OpenSSL. Never generates or transfers CA keys.
For renewal, use a new private directory, enroll its fingerprint on the Mac,
then point the client configuration at the new files and restart the client.
Replacing validated files at existing paths is applied by Reconnect.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import tempfile
import uuid
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
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


def read_private(fd, name):
    keyfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        info = os.fstat(keyfd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or not 0 < info.st_size <= 1024*1024:
            raise ValueError(f'{name} must be a private owned 0600 regular file (at most 1 MiB)')
        with os.fdopen(keyfd, 'rb', closefd=False) as source:
            data = source.read(1024*1024+1)
            if len(data) > 1024*1024:
                raise ValueError(f'{name} is too large')
            return data
    finally:
        os.close(keyfd)


def device_name(value):
    name = value.lower()
    if (len(name) > 253 or not name.endswith('.zimbr.invalid') or
            any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in name.split('.'))):
        raise ValueError('Use an explicit ASCII device DNS name under zimbr.invalid, e.g. linux-desktop.zimbr.invalid')
    return name


def client_profile(obj):
    required = {ExtensionOID.BASIC_CONSTRAINTS, ExtensionOID.KEY_USAGE,
                ExtensionOID.EXTENDED_KEY_USAGE, ExtensionOID.SUBJECT_ALTERNATIVE_NAME}
    allowed = required | ({ExtensionOID.SUBJECT_KEY_IDENTIFIER, ExtensionOID.AUTHORITY_KEY_IDENTIFIER}
                          if isinstance(obj, x509.Certificate) else set())
    extensions = {ext.oid: ext for ext in obj.extensions}
    if not required <= extensions.keys() or extensions.keys() - allowed:
        raise ValueError('Missing or unexpected client certificate/CSR extensions; regenerate old CSRs with --name')
    bc = extensions[ExtensionOID.BASIC_CONSTRAINTS]
    ku = extensions[ExtensionOID.KEY_USAGE]
    if not bc.critical or bc.value.ca or bc.value.path_length is not None:
        raise ValueError('Client leaf must have critical non-CA Basic Constraints')
    if list(extensions[ExtensionOID.EXTENDED_KEY_USAGE].value) != [ExtendedKeyUsageOID.CLIENT_AUTH]:
        raise ValueError('Client leaf must have only clientAuth EKU')
    usage = ku.value
    if not ku.critical or not usage.digital_signature or any((usage.key_cert_sign, usage.crl_sign,
                                                            usage.key_agreement, usage.data_encipherment, usage.content_commitment)):
        raise ValueError('Unexpected client key usage')
    sans = list(extensions[ExtensionOID.SUBJECT_ALTERNATIVE_NAME].value)
    if len(sans) != 1 or not isinstance(sans[0], x509.DNSName):
        raise ValueError('Client SAN must be exactly one explicit device DNS name')
    device_name(sans[0].value)
    pub = obj.public_key()
    # Mirror the Mac enrollment minimums: P-256 EC or RSA-2048.
    if not ((isinstance(pub, ec.EllipticCurvePublicKey) and pub.key_size >= 256) or
            (isinstance(pub, rsa.RSAPublicKey) and pub.key_size >= 2048)):
        raise ValueError('Unsupported or weak client public key')
    return sans


def write_new(fd, name, data):
    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    with os.fdopen(out, 'wb') as dest:
        dest.write(data)
        dest.flush()
        os.fsync(dest.fileno())


def client_request(key, name, label):
    return (x509.CertificateSigningRequestBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, label)]))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(device_name(name))]), critical=False)
            .sign(key, hashes.SHA256()))


def request(args, *, quiet=False):
    device_san = device_name(args.name)
    path, fd = private_dir(args.tls_dir, create=True)
    try:
        for name in ('client-key.pem', 'client.csr'):
            try:
                os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise ValueError(f'{name} already exists; use a new directory for renewal')
        # Generate a compact P-256 client key accepted by both endpoint TLS stacks.
        key = ec.generate_private_key(ec.SECP256R1())
        csr = client_request(key, device_san, args.label)
        write_new(fd, 'client-key.pem', key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        write_new(fd, 'client.csr', csr.public_bytes(serialization.Encoding.PEM))
        if not quiet:
            print(f'Created {path}/client.csr. Transfer only the CSR to the administrator; keep client-key.pem here.')
            print(f'Ask the Mac signer to use --role client --name {device_san}. Keep client.csr here for import verification.')
    finally:
        os.close(fd)


def public_key(key):
    return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def relay_origin(value):
    endpoint = urlsplit(value)
    if (endpoint.scheme != 'https' or not endpoint.hostname or endpoint.username is not None or
            endpoint.password is not None or endpoint.path not in ('', '/') or
            '?' in value or '#' in value or endpoint.port == 0 or
            any(c.isspace() for c in value)):
        raise ValueError('Use an HTTPS origin without credentials, query, fragment or path')
    return value


def setup(args):
    if not args.host or args.host.startswith('-') or any(c.isspace() or ord(c) < 32 for c in args.host):
        raise ValueError('Use an SSH destination such as user@mac.example or an SSH config alias')
    for tool in ('ssh', 'openssl'):
        if not shutil.which(tool):
            raise ValueError(f'Required command not found: {tool}')
    sibling = Path(__file__).resolve().with_name('zimbr')
    launch = args.launch or (str(sibling) if sibling.is_file() else shutil.which('zimbr'))
    if not launch:
        raise ValueError('Install zimbr first, or pass --launch /path/to/zimbr')
    help_text = subprocess.check_output([launch, '--help'], text=True)
    if f'Profile: {args.profile}\n' not in help_text or '--save-connection' not in help_text:
        raise ValueError(f'Client must support setup and use the {args.profile} profile; check --launch')
    directory_name = 'zimbr' if args.profile == 'release' else 'zimbr-dev'
    if args.tls_dir is None:
        config_home = Path(os.environ.get('XDG_CONFIG_HOME', ''))
        if not config_home.is_absolute():
            config_home = Path.home()/'.config'
        parent = config_home/directory_name
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        args.tls_dir = parent/'tls'
    path, fd = private_dir(args.tls_dir, create=True)
    try:
        lockfd = os.open('setup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(lockfd, 'r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not (path/'client.csr').exists():
                name = args.name or f'linux-{uuid.uuid4().hex}.zimbr.invalid'
                if (path/'client-key.pem').exists():
                    # An interrupted first run may have committed the key before its CSR.
                    key = serialization.load_pem_private_key(read_private(fd, 'client-key.pem'), password=None)
                    csr = client_request(key, name, args.label)
                    write_new(fd, 'client.csr', csr.public_bytes(serialization.Encoding.PEM))
                else:
                    request(argparse.Namespace(tls_dir=path, name=name, label=args.label), quiet=True)
            csr_bytes = read_private(fd, 'client.csr')
            csr = x509.load_pem_x509_csr(csr_bytes)
            name = client_profile(csr)[0].value
            key = serialization.load_pem_private_key(read_private(fd, 'client-key.pem'), password=None)
            if not csr.is_signature_valid or public_key(key.public_key()) != public_key(csr.public_key()):
                raise ValueError('Retained CSR does not match its local key')
            if args.name and device_name(args.name) != name:
                raise ValueError('Existing request has a different name; use a new --tls-dir')
            app = 'Zimbr Relay' if args.profile == 'release' else 'Zimbr Relay Dev'
            command = 'zimbr-relay' if args.profile == 'release' else 'zimbr-relay-dev'
            # Only fixed package paths enter the remote shell. User values travel as JSON on stdin.
            remote = f'exec "$HOME/Applications/{app}.app/Contents/Resources/{command}-admin" issue-ssh'
            print(f'Enrolling through SSH on {args.host}…', flush=True)
            result = subprocess.run(['ssh', '-T', '-o', 'StrictHostKeyChecking=ask', '--', args.host, remote],
                                    input=json.dumps({'schema': 1, 'csr': csr_bytes.decode('ascii'),
                                                      'name': name, 'label': args.label}),
                                    stdout=subprocess.PIPE, text=True, check=True)
            # Bound SSH enrollment responses to 64 KiB before parsing credentials and configuration.
            if len(result.stdout) > 65536:
                raise ValueError('Enrollment response is too large')
            response = json.loads(result.stdout)
            if (not isinstance(response, dict) or set(response) != {'schema', 'relay_url', 'ca', 'cert'} or
                    response['schema'] != 1 or any(not isinstance(response[k], str) for k in ('relay_url', 'ca', 'cert'))):
                raise ValueError('Unsupported enrollment response')
            endpoint = relay_origin(response['relay_url'])
            ca = x509.load_pem_x509_certificate(response['ca'].encode('ascii'))
            # SSH authenticates both the CA and endpoint. The existing importer verifies the leaf.
            with tempfile.TemporaryDirectory(prefix='.ssh-', dir=path) as temporary:
                returned_ca, returned_cert = Path(temporary)/'ca.pem', Path(temporary)/'client.pem'
                returned_ca.write_text(response['ca'])
                returned_cert.write_text(response['cert'])
                import_certificate(argparse.Namespace(
                    tls_dir=path, ca=returned_ca, cert=returned_cert,
                    ca_sha256=ca.fingerprint(hashes.SHA256()).hex(), launch=None,
                ), quiet=True)
    finally:
        os.close(fd)
    print(f'Opening Zimbr at {endpoint}. Connection settings will be saved.', flush=True)
    subprocess.run([launch, '--save-connection', '--relay-url', endpoint,
                    '--ca-file', str(path/'ca.pem'), '--client-cert-file', str(path/'client.pem'),
                    '--client-key-file', str(path/'client-key.pem')], check=True)


def import_certificate(args, *, quiet=False):
    path, fd = private_dir(args.tls_dir)
    try:
        ca_data, cert_data = Path(args.ca).read_bytes(), Path(args.cert).read_bytes()
        if ca_data.count(b'-----BEGIN CERTIFICATE-----') != 1 or cert_data.count(b'-----BEGIN CERTIFICATE-----') != 1 or b'PRIVATE KEY' in ca_data+cert_data:
            raise ValueError('Import exactly one CA and one client certificate, never private keys')
        ca, cert = x509.load_pem_x509_certificate(ca_data), x509.load_pem_x509_certificate(cert_data)
        expected = args.ca_sha256.lower().replace(':', '')
        # SHA-256 fingerprints contain exactly 64 hexadecimal characters.
        if len(expected) != 64 or ca.fingerprint(hashes.SHA256()).hex() != expected:
            raise ValueError('CA SHA-256 does not match the independently authenticated fingerprint')
        if not ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise ValueError('Trust certificate is not a CA')
        ca.verify_directly_issued_by(ca)
        cert.verify_directly_issued_by(ca)
        for item in (ca, cert):
            if not item.not_valid_before_utc <= datetime.now(timezone.utc) < item.not_valid_after_utc:
                raise ValueError('Certificate is expired or not yet valid')
        csr = x509.load_pem_x509_csr(read_private(fd, 'client.csr'))
        if not csr.is_signature_valid:
            raise ValueError('Local CSR signature is invalid')
        if client_profile(cert) != client_profile(csr):
            raise ValueError('Issued client SAN does not exactly match the local CSR')
        key = serialization.load_pem_private_key(read_private(fd, 'client-key.pem'), password=None)
        if public_key(key.public_key()) != public_key(csr.public_key()) or public_key(key.public_key()) != public_key(cert.public_key()):
            raise ValueError('Issued client certificate/CSR does not match the local private key')
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
        if not quiet:
            print('Imported verified credentials.')
            print('Enroll this entire-leaf DER SHA-256 on the Mac: '+cert.fingerprint(hashes.SHA256()).hex())
            print('Client certificate expires: '+cert.not_valid_after_utc.isoformat())
            print('Enter these paths in Settings and Save and connect, or Reconnect after replacing files:')
            for field, name in (('ca_file', 'ca.pem'), ('client_cert_file', 'client.pem'), ('client_key_file', 'client-key.pem')):
                print(f'  {field}: {path/name}')
        if args.launch:
            subprocess.run([args.launch, '--settings', '--relay-url', args.relay_url,
                            '--ca-file', str(path/'ca.pem'), '--client-cert-file', str(path/'client.pem'),
                            '--client-key-file', str(path/'client-key.pem')], check=True)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    bootstrap = commands.add_parser('setup', help='enroll over SSH, save the connection, and open Zimbr')
    bootstrap.add_argument('host', help='Mac login account: user@mac.example (SSH config aliases work)')
    bootstrap.add_argument('--profile', choices=('release', 'dev'), default='release')
    bootstrap.add_argument('--tls-dir', type=Path, help='default: $XDG_CONFIG_HOME/zimbr/tls or ~/.config/zimbr/tls')
    bootstrap.add_argument('--name', help='device SAN (default: generated once, reused on retries)')
    bootstrap.add_argument('--label', default=socket.gethostname(), help='device display label')
    bootstrap.add_argument('--launch', metavar='EXECUTABLE', help='client executable (default: packaged sibling zimbr)')
    req = commands.add_parser('request', help='create a new local key and clientAuth CSR')
    req.add_argument('--tls-dir', required=True)
    req.add_argument('--name', required=True, help='explicit device SAN, e.g. linux-desktop.zimbr.invalid; must match the Mac signer --name')
    req.add_argument('--label', default='Zimbr Linux device')
    imp = commands.add_parser('import', help='validate and import issued public credentials')
    imp.add_argument('--tls-dir', required=True)
    imp.add_argument('--ca', required=True)
    imp.add_argument('--cert', required=True)
    imp.add_argument('--ca-sha256', required=True, help='CA DER SHA-256 verified over trusted SSH or independently')
    imp.add_argument('--relay-url', help='HTTPS relay origin for --launch')
    imp.add_argument('--launch', metavar='EXECUTABLE', help='open the client Settings with the verified paths filled in; click Save and connect')
    args = parser.parse_args()
    if args.command == 'import' and args.launch:
        if not args.relay_url:
            parser.error('--launch requires --relay-url')
        try:
            relay_origin(args.relay_url)
        except ValueError as exc:
            parser.error(str(exc))
    os.umask(0o077)
    try:
        {'setup': setup, 'request': request, 'import': import_certificate}[args.command](args)
    except (ValueError, TypeError, OSError, InvalidSignature, UnsupportedAlgorithm, x509.ExtensionNotFound, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'Provisioning failed: {exc}\n')


if __name__ == '__main__':
    main()
