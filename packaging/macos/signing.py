#!/usr/bin/env python3
"""Create and reuse a private, local code-signing identity for relay updates."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from tls_support import private_directory, private_path, read_json
from profiles import PROFILES

LABEL = 'com.hsp.zimbr.relay'
NAME = 'Zimbr Local Signing'


def default_directory():
    return Path.home()/'.config/zimbr-code-signing'


def run(command, *, secret=None):
    # Never include command arguments in exceptions: security accepts passwords
    # as arguments, and CalledProcessError would print those in a traceback.
    result = subprocess.run([str(arg) for arg in command], capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip()
        if secret: detail = detail.replace(secret, '[redacted]')
        raise RuntimeError(f'{Path(command[0]).name} {command[1]} failed: {detail}')
    return result.stdout


def write_private(path, content):
    with path.open('xb') as output:
        os.chmod(path, 0o600)
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def requirement(fingerprint, identifier=LABEL):
    if not re.fullmatch(r'[0-9A-F]{40}', fingerprint):
        raise ValueError('Invalid signing certificate fingerprint')
    if identifier not in {profile.bundle_id for profile in PROFILES.values()}:
        raise ValueError('Unknown relay signing identifier')
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'


def load(directory):
    if sys.platform == 'darwin' and os.geteuid() == 0:
        raise RuntimeError('Run signing commands as the Mac login user, without sudo')
    private_directory(directory)
    config = read_json(directory/'identity.json')
    if set(config) != {'certificate_sha1', 'label'} or config['label'] != LABEL:
        raise ValueError('Invalid local signing configuration')
    requirement(config['certificate_sha1'])
    private_path(directory/'signing.keychain-db')
    private_path(directory/'keychain-password')
    return config


def sign(bundle, entitlements=None, *, identity=None, directory=None, identifier=LABEL):
    if identifier not in {profile.bundle_id for profile in PROFILES.values()}:
        raise ValueError('Unknown relay signing identifier')
    command = ['/usr/bin/codesign', '--force', '--sign']
    if identity is not None:
        command += [identity, '--identifier', identifier]
        if entitlements: command += ['--entitlements', entitlements]
        run(command + [bundle])
    else:
        directory = directory or default_directory()
        if not (directory/'identity.json').exists():
            raise RuntimeError('No persistent signing identity. Run packaging/macos/signing.py setup first, or select --identity explicitly.')
        config = load(directory)
        password = private_path(directory/'keychain-password').read_text().strip()
        keychain = directory/'signing.keychain-db'
        run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain], secret=password)
        try:
            command += [config['certificate_sha1'], '--keychain', keychain,
                        '--identifier', identifier, '--timestamp=none',
                        # The leading '=' makes this inline requirement text;
                        # otherwise codesign interprets it as a file path.
                        '--requirements', '=designated => '+requirement(config['certificate_sha1'], identifier)]
            if entitlements: command += ['--entitlements', entitlements]
            run(command + [bundle])
            run(['/usr/bin/codesign', '--verify', '--strict', '-R', '='+requirement(config['certificate_sha1'], identifier), bundle])
        finally:
            run(['/usr/bin/security', 'lock-keychain', keychain])
    run(['/usr/bin/codesign', '--verify', '--strict', bundle])


def setup(directory):
    if sys.platform != 'darwin': raise RuntimeError('Local signing setup must run on the Mac')
    if os.geteuid() == 0: raise RuntimeError('Run signing commands as the Mac login user, without sudo')
    os.umask(0o077)
    directory = directory.absolute()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(directory)
    config_path = directory/'identity.json'
    if not config_path.exists():
        # Refuse to replace a partially created identity; losing its private key
        # would also lose the identity used by existing privacy grants.
        if any(directory.iterdir()):
            raise RuntimeError('Signing directory is not empty; preserve its existing identity before repair')
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import pkcs12
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
        key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, NAME)])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now-datetime.timedelta(minutes=5))
                .not_valid_after(now+datetime.timedelta(days=3650))
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                    key_encipherment=False, data_encipherment=False, key_agreement=False,
                    key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=True)
                .sign(key, hashes.SHA256()))
        password = secrets.token_hex(32)
        # Apple's PKCS#12 importer supports this interoperable export format.
        # The temporary archive is encrypted and removed once imported.
        encryption = (serialization.PrivateFormat.PKCS12.encryption_builder()
                      .kdf_rounds(50000).key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
                      .hmac_hash(hashes.SHA1()).build(password.encode()))
        archive = pkcs12.serialize_key_and_certificates(NAME.encode(), key, cert, None, encryption)
        write_private(directory/'certificate.pem', cert.public_bytes(serialization.Encoding.PEM))
        write_private(directory/'keychain-password', password.encode())
        write_private(directory/'identity.p12', archive)
        write_private(config_path, (json.dumps({'certificate_sha1': cert.fingerprint(hashes.SHA1()).hex().upper(), 'label': LABEL}, indent=2)+'\n').encode())
    config = read_json(config_path)
    requirement(config['certificate_sha1'])
    password = private_path(directory/'keychain-password').read_text().strip()
    keychain = directory/'signing.keychain-db'
    if not keychain.exists():
        # Creating a keychain can add it to the search list. Keep it isolated;
        # codesign selects it explicitly, without changing the login keychain.
        previous = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
        try:
            run(['/usr/bin/security', 'create-keychain', '-p', password, keychain], secret=password)
        finally:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous])
    private_path(keychain)
    run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain], secret=password)
    try:
        archive = directory/'identity.p12'
        identities = run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', keychain])
        if config['certificate_sha1'] not in identities:
            private_path(archive)
            run(['/usr/bin/security', 'import', archive, '-k', keychain, '-P', password,
                 '-x', '-T', '/usr/bin/codesign'], secret=password)
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s',
             '-k', password, keychain], secret=password)
        run(['/usr/bin/security', 'set-keychain-settings', '-lut', '300', keychain])
        # Trust only this user's code-signing policy, not TLS or other policies.
        valid = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain])
        if config['certificate_sha1'] not in valid:
            run(['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
                 '-k', keychain, private_path(directory/'certificate.pem')])
            valid = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain])
        if config['certificate_sha1'] not in valid:
            raise RuntimeError('The local certificate is not yet trusted for code signing')
        archive.unlink(missing_ok=True)
    finally:
        run(['/usr/bin/security', 'lock-keychain', keychain])
    load(directory)
    print('Persistent local signing identity ready:', config['certificate_sha1'])
    print('Private signing state:', directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup'])
    parser.add_argument('--directory', type=Path, default=default_directory())
    args = parser.parse_args()
    setup(args.directory)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
