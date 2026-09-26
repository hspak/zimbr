#!/usr/bin/env python3
"""Local Zimbr certificate provisioning and device lifecycle. Never installs system trust."""
import argparse
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import re
import plistlib
import subprocess
import sys
import tempfile
import time
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, ExtensionOID, NameOID
from tls_support import private_path, private_directory, read_json

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'packaging/macos'))
from profiles import PROFILES
UTC = dt.timezone.utc


def atomic(path, content):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('Refusing symlink destination')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(path.parent)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name + '.')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(content); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def save_json(path, value):
    atomic(path, (json.dumps(value, indent=2) + '\n').encode())


def names(values):
    result = []
    for value in values:
        try: result.append(x509.IPAddress(ipaddress.ip_address(value)))
        except ValueError:
            if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', value) or '..' in value:
                raise ValueError('Use precise ASCII DNS names/IP addresses, without wildcards')
            result.append(x509.DNSName(value.lower()))
    return result


def purpose(role):
    return ExtendedKeyUsageOID.SERVER_AUTH if role == 'server' else ExtendedKeyUsageOID.CLIENT_AUTH


def validate_extensions(obj, role, expected_names):
    # No arbitrary requested extensions are passed to the issuer.
    required = {ExtensionOID.BASIC_CONSTRAINTS, ExtensionOID.KEY_USAGE, ExtensionOID.EXTENDED_KEY_USAGE}
    allowed = required | {ExtensionOID.SUBJECT_ALTERNATIVE_NAME}
    if isinstance(obj, x509.Certificate):
        allowed |= {ExtensionOID.SUBJECT_KEY_IDENTIFIER, ExtensionOID.AUTHORITY_KEY_IDENTIFIER}
    extensions = {e.oid: e for e in obj.extensions}
    if not required <= extensions.keys() or extensions.keys() - allowed:
        raise ValueError('Missing or unexpected certificate extensions')
    bc = extensions[ExtensionOID.BASIC_CONSTRAINTS].value
    if bc.ca or bc.path_length is not None:
        raise ValueError('Only non-CA leaf requests may be signed')
    eku = extensions[ExtensionOID.EXTENDED_KEY_USAGE].value
    if list(eku) != [purpose(role)]:
        raise ValueError('Leaf must request exactly the intended authentication purpose')
    ku = extensions[ExtensionOID.KEY_USAGE].value
    if not ku.digital_signature or ku.key_cert_sign or ku.crl_sign or ku.key_agreement or ku.data_encipherment or ku.content_commitment:
        raise ValueError('Unexpected key usage')
    actual = list(extensions[ExtensionOID.SUBJECT_ALTERNATIVE_NAME].value) if ExtensionOID.SUBJECT_ALTERNATIVE_NAME in extensions else []
    if set(actual) != set(names(expected_names)) or (role == 'server' and not actual):
        raise ValueError('SANs do not exactly match the administrator-selected names')
    pub = obj.public_key()
    if not ((isinstance(pub, ec.EllipticCurvePublicKey) and pub.key_size >= 256) or
            (isinstance(pub, rsa.RSAPublicKey) and pub.key_size >= 2048)):
        raise ValueError('Unsupported or weak public key')


def certificate(path):
    return x509.load_pem_x509_certificate(private_path(path).read_bytes())


def verify_leaf(cert, ca, role, expected_names=None):
    if expected_names is None:
        try: expected_names = [str(n.value) for n in cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME).value]
        except x509.ExtensionNotFound: expected_names = []
    validate_extensions(cert, role, expected_names)
    now = dt.datetime.now(UTC)
    if not (cert.not_valid_before_utc <= now < cert.not_valid_after_utc and ca.not_valid_before_utc <= now < ca.not_valid_after_utc):
        raise ValueError('Certificate or CA is expired/not yet valid')
    if not ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
        raise ValueError('Trust certificate must be a CA')
    cert.verify_directly_issued_by(ca)


def create_key(directory, role, expected_names):
    if not expected_names: raise ValueError('Specify --name for the CSR SAN (a device label such as mac-admin.zimbr.invalid for clients)')
    directory = Path(directory).absolute()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    key_path, csr_path = directory / f'{role}-key.pem', directory / f'{role}.csr'
    if key_path.exists() or csr_path.exists():
        raise ValueError('Use a new staging directory for renewal; existing keys are never overwritten')
    key = ec.generate_private_key(ec.SECP256R1())
    builder = (x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Zimbr ' + role)]))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
        .add_extension(x509.ExtendedKeyUsage([purpose(role)]), critical=False))
    if expected_names: builder = builder.add_extension(x509.SubjectAlternativeName(names(expected_names)), critical=False)
    csr = builder.sign(key, hashes.SHA256())
    validate_extensions(csr, role, expected_names)
    atomic(key_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    atomic(csr_path, csr.public_bytes(serialization.Encoding.PEM))
    return csr_path


def sign(args):
    caroot = args.caroot.absolute()
    caroot.mkdir(parents=True, mode=0o700, exist_ok=True)
    private_directory(caroot)
    # Explicit marker prevents accidentally reusing the normal mkcert development CA.
    marker = caroot / 'zimbr-dedicated-ca'
    if (caroot / 'rootCA.pem').exists() and not marker.exists(): raise ValueError('Refusing an existing non-Zimbr CA')
    if not marker.exists(): atomic(marker, b'Zimbr setup-time issuer; never install in system trust.\n')
    for existing in (marker, caroot/'rootCA.pem', caroot/'rootCA-key.pem'):
        if existing.exists(): private_path(existing)
    if caroot.is_relative_to(Path(__file__).resolve().parents[1]) or any(caroot.is_relative_to(profile.data(Path.home())) for profile in PROFILES.values()):
        raise ValueError('CAROOT must remain outside source and runtime directories')
    csr_bytes = private_path(args.csr).read_bytes()
    csr = x509.load_pem_x509_csr(csr_bytes)
    if not csr.is_signature_valid: raise ValueError('Invalid CSR signature')
    if not args.name: raise ValueError('Specify the precise expected --name SANs, including a device label for client CSRs')
    validate_extensions(csr, args.role, args.name)
    if args.cert.exists(): raise ValueError('Use a new certificate path for renewal')
    args.cert.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if args.cert.parent.stat().st_mode & 0o077: raise ValueError('Certificate staging directory must be owner-only')
    env = dict(os.environ, CAROOT=str(caroot))
    # Sign the validated bytes in isolation, then publish only a verified leaf.
    with tempfile.TemporaryDirectory(prefix='.issue-', dir=args.cert.parent) as folder:
        staged_csr, staged_cert = Path(folder)/'request.pem', Path(folder)/'issued.pem'
        atomic(staged_csr, csr_bytes)
        subprocess.run([args.mkcert, '-cert-file', str(staged_cert), '-csr', str(staged_csr)], env=env, check=True)
        for path in (caroot/'rootCA.pem', caroot/'rootCA-key.pem', staged_cert): path.chmod(0o600)
        ca = certificate(caroot/'rootCA.pem'); cert = certificate(staged_cert)
        verify_leaf(cert, ca, args.role, args.name)
        if cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != csr.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo):
            raise ValueError('Issued certificate does not match CSR')
        atomic(args.cert, staged_cert.read_bytes())
    print(json.dumps({'sha256': cert.fingerprint(hashes.SHA256()).hex(), 'expires': cert.not_valid_after_utc.isoformat()}))


def pid_of_service(profile):
    result = subprocess.run(['launchctl', 'print', f'gui/{os.getuid()}/{profile.bundle_id}'], capture_output=True, text=True, check=True)
    match = re.search(r'^\s*pid = (\d+)$', result.stdout, re.M)
    return int(match.group(1)) if match else None


def restart(config, profile):
    old = pid_of_service(profile)
    subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/{profile.bundle_id}'], check=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        new = pid_of_service(profile)
        old_gone = old is None
        if old is not None:
            try: os.kill(old, 0)
            except ProcessLookupError: old_gone = True
        if old_gone and new and new != old:
            sockets = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(new), '-iTCP', '-sTCP:LISTEN'], capture_output=True, text=True)
            endpoint = config['listen_address']
            if ':' in endpoint: endpoint = '[' + endpoint + ']'
            if f'{endpoint}:{config["port"]} (LISTEN)' in sockets.stdout:
                return {'old_pid': old, 'pid': new, 'restart_complete': True}
        time.sleep(.2)
    raise RuntimeError('Restart failed: old process exit and new configured listener were not both verified; policy is staged, revocation is NOT complete')


def device(args):
    profile = PROFILES[args.profile]
    args.config = args.config or profile.data(Path.home())/'relay.json'
    args.relay = args.relay or profile.app(Path.home())/'Contents/MacOS/relay'
    profile.verify_binary(args.relay)
    cfg = read_json(args.config)
    if not args.stage:
        with (Path.home()/'Library/LaunchAgents'/f'{profile.bundle_id}.plist').open('rb') as f:
            installed = plistlib.load(f)['ProgramArguments']
        if '--config' not in installed or Path(installed[installed.index('--config')+1]).resolve() != args.config.resolve() or Path(installed[0]).resolve() != args.relay.resolve():
            raise ValueError('Device changes must target the configuration and executable used by the installed LaunchAgent')
    path = Path(cfg['device_allowlist_file']); devices = read_json(path)
    if args.action == 'enroll':
        cert = certificate(args.cert)
        verify_leaf(cert, certificate(cfg['client_ca_file']), 'client')
        fingerprint = cert.fingerprint(hashes.SHA256()).hex()
        devices = [d for d in devices if d['sha256'].lower() != fingerprint]
        devices.append({'label': args.label, 'sha256': fingerprint, 'enabled': True})
    else:
        fingerprint = args.sha256.lower()
        found = False
        for d in devices:
            if d['sha256'].lower() == fingerprint: d['enabled'] = False; found = True
        if not found: raise ValueError('Unknown device fingerprint')
    # Validate a candidate before replacing the live allowlist.
    with tempfile.TemporaryDirectory(prefix='.policy-', dir=path.parent) as folder:
        candidate = Path(folder)/'devices.json'; candidate_config = Path(folder)/'relay.json'
        save_json(candidate, devices); save_json(candidate_config, {**cfg, 'device_allowlist_file': str(candidate)})
        subprocess.run([str(args.relay), 'check-config', '--config', str(candidate_config)], check=True, stdout=subprocess.DEVNULL)
        save_json(path, devices)
    if args.stage:
        print(json.dumps({'sha256': fingerprint, 'restart_complete': False, 'notice': 'Staged only; restart required to apply access changes'}))
    else:
        print(json.dumps({'sha256': fingerprint, **restart(cfg, profile)}))


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    key = sub.add_parser('create-key')
    key.add_argument('--directory', type=Path, required=True)
    key.add_argument('--role', choices=['server', 'client'], required=True)
    key.add_argument('--name', action='append', default=[])
    issue = sub.add_parser('sign')
    issue.add_argument('--caroot', type=Path, required=True)
    issue.add_argument('--csr', type=Path, required=True)
    issue.add_argument('--cert', type=Path, required=True)
    issue.add_argument('--role', choices=['server', 'client'], required=True)
    issue.add_argument('--name', action='append', default=[])
    issue.add_argument('--mkcert', default='mkcert')
    for action in ('enroll', 'revoke'):
        d = sub.add_parser(action)
        d.add_argument('--profile', choices=PROFILES, default='dev')
        d.add_argument('--config', type=Path)
        d.add_argument('--relay', type=Path)
        d.add_argument('--stage', action='store_true', help='Stage only; explicitly does not complete enrollment/revocation')
        if action == 'enroll':
            d.add_argument('--cert', type=Path, required=True); d.add_argument('--label', required=True)
        else: d.add_argument('--sha256', required=True)
    args = p.parse_args()
    if args.action == 'create-key': print(create_key(args.directory, args.role, args.name))
    elif args.action == 'sign': sign(args)
    else: device(args)


if __name__ == '__main__': main()
