#!/usr/bin/env python3
"""Local Zimbr certificate provisioning and device lifecycle. Never installs system trust."""
import argparse
from contextlib import contextmanager, redirect_stdout
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, ExtensionOID, NameOID
from tls_support import Credentials, admin_files, private_path, private_directory, read_json, relay_files

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'packaging/macos'))
from profiles import PROFILES
UTC = dt.timezone.utc


@contextmanager
def administration_lock(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(directory)
    descriptor = os.open(directory/'administration.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'r+') as lock:
        private_path(directory/'administration.lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


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
        sync_directory(path.parent)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def sync_directory(path):
    directory = os.open(path, os.O_RDONLY)
    try: os.fsync(directory)
    finally: os.close(directory)


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
    # Accept P-256-or-larger EC and RSA-2048-or-larger keys; reject weaker enrollment keys.
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
    # P-256 keeps generated TLS keys compact and interoperable with both endpoint stacks.
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
    if not shutil.which(args.mkcert):
        raise ValueError('mkcert is required for issuance; install it with brew install mkcert on macOS')
    caroot = args.caroot.absolute()
    if caroot.is_relative_to(Path(__file__).resolve().parents[1]):
        raise ValueError('CAROOT must remain outside the source directory and app bundle')
    caroot.mkdir(parents=True, mode=0o700, exist_ok=True)
    private_directory(caroot)
    # Explicit marker prevents accidentally reusing the normal mkcert development CA.
    marker = caroot / 'zimbr-dedicated-ca'
    if (caroot / 'rootCA.pem').exists() and not marker.exists(): raise ValueError('Refusing an existing non-Zimbr CA')
    if not marker.exists(): atomic(marker, b'Zimbr setup-time issuer; never install in system trust.\n')
    for existing in (marker, caroot/'rootCA.pem', caroot/'rootCA-key.pem'):
        if existing.exists(): private_path(existing)
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
        subprocess.run([args.mkcert, '-cert-file', str(staged_cert), '-csr', str(staged_csr)],
                       env=env, check=True, stdout=sys.stderr)
        for path in (caroot/'rootCA.pem', caroot/'rootCA-key.pem', staged_cert): path.chmod(0o600)
        ca = certificate(caroot/'rootCA.pem'); cert = certificate(staged_cert)
        verify_leaf(cert, ca, args.role, args.name)
        if cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != csr.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo):
            raise ValueError('Issued certificate does not match CSR')
        atomic(args.cert, staged_cert.read_bytes())
    print(json.dumps({'sha256': cert.fingerprint(hashes.SHA256()).hex(), 'expires': cert.not_valid_after_utc.isoformat()}))


def ca_directory(profile):
    return profile.data(Path.home())/'ca'


def validate_issuer(directory, ca_file):
    private_directory(directory)
    private_path(directory/'zimbr-dedicated-ca')
    ca = certificate(directory/'rootCA.pem')
    key = serialization.load_pem_private_key(private_path(directory/'rootCA-key.pem').read_bytes(), None)
    encoding, form = serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    if key.public_key().public_bytes(encoding, form) != ca.public_key().public_bytes(encoding, form):
        raise ValueError('Signing CA private key does not match its certificate')
    if ca_file is not None and ca.fingerprint(hashes.SHA256()) != certificate(ca_file).fingerprint(hashes.SHA256()):
        raise ValueError('Signing CA does not match the installed relay CA')


def prepare_ca(profile, ca_file=None):
    """Select the issuer and migrate the old default with the data administration lock held.

    The directory rename preserves all issuer bytes. A retry repairs provisioning
    if interrupted after the rename. Custom issuers are copied so another
    installation sharing the old issuer retains its original files.
    """
    data = profile.data(Path.home())
    destination = ca_directory(profile)
    legacy = Path.home()/'.config'/f'zimbr-{profile.name}-ca'
    settings_path = data/'provisioning.json'
    settings = read_json(settings_path) if settings_path.exists() else {}
    selected = Path(settings.get('caroot', legacy if legacy.exists() or legacy.is_symlink() else destination))
    if selected != destination and (selected.exists() or selected.is_symlink()):
        validate_issuer(selected, ca_file)
        if selected == legacy and (destination.exists() or destination.is_symlink()):
            raise ValueError('Both legacy and data-directory CAs exist; resolve the conflicting directories before migrating')
        if selected == legacy:
            legacy.rename(destination)
            sync_directory(data)
            sync_directory(legacy.parent)
        else:
            material = {name: private_path(selected/name).read_bytes()
                        for name in ('rootCA.pem', 'rootCA-key.pem', 'zimbr-dedicated-ca')}
            if destination.exists() or destination.is_symlink():
                validate_issuer(destination, ca_file)
                if any(private_path(destination/name).read_bytes() != content for name, content in material.items()):
                    raise ValueError('The fixed CA directory contains a different issuer')
            else:
                with tempfile.TemporaryDirectory(prefix='.ca-', dir=data) as temporary:
                    staged = Path(temporary)/'ca'
                    for name, content in material.items(): atomic(staged/name, content)
                    staged.rename(destination)
                    sync_directory(data)
    elif ca_file is not None or selected != destination:
        validate_issuer(destination, ca_file)
    if settings_path.exists():
        settings_path.unlink()
        sync_directory(data)
    return destination


def read_credentials(config_path, admin_path=None):
    """Read current or legacy credentials without modifying their source files."""
    data = config_path.parent
    config = read_json(config_path)
    admin = read_json(admin_path) if admin_path is not None else None
    server_paths = relay_files(data)
    material = {path.relative_to(data): private_path(config.get(field, path)).read_bytes()
                for field, path in server_paths.items()}
    if admin:
        admin_paths = admin_files(admin_path.parent)
        material.update({path.relative_to(admin_path.parent): private_path(admin.get(field, path)).read_bytes()
                         for field, path in admin_paths.items()})
        admin = {key: value for key, value in admin.items() if key not in admin_paths}
    config = {key: value for key, value in config.items() if key not in server_paths}
    return config, admin, material


def stage_credentials(directory, relay, config, admin, material):
    for relative, content in material.items(): atomic(directory/relative, content)
    save_json(directory/'relay.json', config)
    subprocess.run([str(relay), 'check-config', '--config', str(directory/'relay.json')],
                   check=True, stdout=subprocess.DEVNULL)
    if admin:
        save_json(directory/'admin.json', admin)
        Credentials(directory/'admin.json')


def migrate_credentials(data, relay):
    """Publish fixed credential locations with the data administration lock held.

    Validate the whole candidate before copying files. Keep legacy source files
    for recovery; publish configurations last so interrupted copies can retry.
    """
    config_path, admin_path = data/'relay.json', data/'admin.json'
    config = read_json(config_path)
    admin = read_json(admin_path) if admin_path.exists() else None
    if not (set(config) & relay_files(data).keys() or (admin and set(admin) & admin_files(data).keys())):
        return config
    config, admin, material = read_credentials(config_path, admin_path if admin is not None else None)
    for relative, content in material.items():
        path = data/relative
        if (path.exists() or path.is_symlink()) and private_path(path).read_bytes() != content:
            raise ValueError(f'Fixed credential destination already contains different material: {path}')
    with tempfile.TemporaryDirectory(prefix='.credentials-', dir=data) as temporary:
        staged = Path(temporary)
        stage_credentials(staged, relay, config, admin, material)
        for relative, content in material.items():
            if not (data/relative).exists(): atomic(data/relative, content)
        if admin: save_json(admin_path, admin)
        save_json(config_path, config)
    return config


def fresh_directory(path):
    path = path.absolute()
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    private_directory(path)
    if any(path.iterdir()):
        raise ValueError(f'Use a new empty staging directory; existing credentials are preserved: {path}')
    return path


def setup(args, *, quiet=False):
    """Stage a complete first-run configuration; installation owns service changes."""
    profile = PROFILES[args.profile]
    profile.verify_binary(args.relay)
    address = ipaddress.ip_address(args.listen_address)
    if address.is_unspecified:
        raise ValueError('Use a specific local IP address, not a wildcard listener')
    if not 1 <= args.port <= 65535:
        raise ValueError('Port must be between 1 and 65535')
    expected_names = list(dict.fromkeys([args.server_name, *args.name]))
    names(expected_names)
    if not shutil.which(args.mkcert):
        raise ValueError('mkcert is required; install it with brew install mkcert on macOS')
    directory = fresh_directory(args.directory)
    for role, folder, identities in (
            ('server', directory, expected_names),
            ('client', directory/'admin', ['mac-admin.zimbr.invalid'])):
        csr = create_key(folder, role, identities)
        sign(argparse.Namespace(caroot=args.caroot, csr=csr, cert=folder/f'{role}.pem',
                                role=role, name=identities, mkcert=args.mkcert))
    ca = private_path(args.caroot.absolute()/'rootCA.pem').read_bytes()
    atomic(directory/'ca.pem', ca)
    atomic(directory/'admin/ca.pem', ca)
    admin_cert = certificate(directory/'admin/client.pem')
    save_json(directory/'devices.json', [{
        'label': 'Mac administrator', 'sha256': admin_cert.fingerprint(hashes.SHA256()).hex(),
        'enabled': True,
    }])
    save_json(directory/'relay.json', {
        'listen_address': str(address), 'port': args.port, 'server_name': args.server_name,
    })
    host = f'[{args.server_name}]' if ':' in args.server_name else args.server_name
    save_json(directory/'admin.json', {
        'relay_url': f'https://{host}:{args.port}',
    })
    subprocess.run([str(args.relay), 'check-config', '--config', str(directory/'relay.json')], check=True)
    if not quiet:
        print('Ready to install: ' + shlex.join([
            '--tls-config', str(directory/'relay.json'), '--admin-config', str(directory/'admin.json'),
        ]))
        print(f'Keep the signing CA on this Mac: {args.caroot.absolute()}')


def issue_device(args):
    """Sign a received CSR, enroll it, and export only public certificates."""
    profile = PROFILES[args.profile]
    args.config = args.config or profile.data(Path.home())/'relay.json'
    with administration_lock(profile.data(Path.home())):
        args.caroot = prepare_ca(profile, args.config.parent/'ca.pem')
    ca_path = args.caroot.absolute()/'rootCA.pem'
    if certificate(ca_path).fingerprint(hashes.SHA256()) != certificate(args.config.parent/'ca.pem').fingerprint(hashes.SHA256()):
        raise ValueError('Signing CA does not match the installed relay CA')
    directory = fresh_directory(args.directory)
    args.cert = directory/'client.pem'
    args.role = 'client'
    sign(args)
    # No private key or administrative credential is included in the handoff.
    atomic(directory/'ca.pem', private_path(ca_path).read_bytes())
    args.action = 'enroll'
    device(args)
    print('CA DER SHA-256 (authenticate this output before Linux import): ' +
          certificate(ca_path).fingerprint(hashes.SHA256()).hex())
    print(f'Return {directory}/client.pem and {directory}/ca.pem to Linux.')


def pid_of_service(profile):
    result = subprocess.run(['launchctl', 'print', f'gui/{os.getuid()}/{profile.bundle_id}'], capture_output=True, text=True, check=True)
    match = re.search(r'^\s*pid = (\d+)$', result.stdout, re.M)
    return int(match.group(1)) if match else None


def listener_ready(config, pid):
    sockets = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN'], capture_output=True, text=True)
    endpoint = config['listen_address']
    if ':' in endpoint: endpoint = '[' + endpoint + ']'
    return f'{endpoint}:{config["port"]} (LISTEN)' in sockets.stdout


def restart(config, profile):
    old = pid_of_service(profile)
    subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/{profile.bundle_id}'], check=True)
    # Bound relay restart verification to 30 seconds so administration cannot wait forever.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        new = pid_of_service(profile)
        old_gone = old is None
        if old is not None:
            try: os.kill(old, 0)
            except ProcessLookupError: old_gone = True
        if old_gone and new and new != old:
            if listener_ready(config, new):
                return {'old_pid': old, 'pid': new, 'restart_complete': True}
        # Check restart readiness five times per second while waiting for launchd.
        time.sleep(.2)
    raise RuntimeError('Restart failed: old process exit and new configured listener were not both verified; policy is staged, revocation is NOT complete')


def device(args):
    profile = PROFILES[args.profile]
    config = args.config or profile.data(Path.home())/'relay.json'
    with administration_lock(config.parent):
        update_device(args)


def update_device(args):
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
    path = args.config.parent/'devices.json'; devices = read_json(path)
    if args.action == 'enroll':
        cert = certificate(args.cert)
        verify_leaf(cert, certificate(args.config.parent/'ca.pem'), 'client')
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
        for source in relay_files(args.config.parent).values():
            if source != path: atomic(Path(folder)/source.name, private_path(source).read_bytes())
        save_json(candidate, devices); save_json(candidate_config, cfg)
        subprocess.run([str(args.relay), 'check-config', '--config', str(candidate_config)], check=True, stdout=subprocess.DEVNULL)
        save_json(path, devices)
    if args.stage:
        print(json.dumps({'sha256': fingerprint, 'restart_complete': False, 'notice': 'Staged only; restart required to apply access changes'}))
    else:
        print(json.dumps({'sha256': fingerprint, **restart(cfg, profile)}))


def issue_ssh(args):
    """The authenticated SSH login authorizes enrollment; stdout is one JSON response."""
    # Read one byte beyond 64 KiB to detect oversized SSH enrollment requests.
    raw = sys.stdin.buffer.read(65537)
    if len(raw) > 65536:
        raise ValueError('Enrollment request is too large')
    request = json.loads(raw)
    if not isinstance(request, dict) or set(request) != {'schema', 'csr', 'name', 'label'} or request['schema'] != 1:
        raise ValueError('Unsupported enrollment request')
    if any(not isinstance(request[key], str) for key in ('csr', 'name', 'label')):
        raise ValueError('Enrollment fields must be strings')
    name = request['name']
    # Apply DNS's 253-character name and 63-character label bounds to device SANs.
    if (len(name) > 253 or not name.endswith('.zimbr.invalid') or
            any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part) for part in name.split('.'))):
        raise ValueError('Expected a device name under zimbr.invalid')
    # Match the relay allowlist's 128-character label cap and exclude control characters.
    if not 1 <= len(request['label']) <= 128 or any(ord(c) < 32 for c in request['label']):
        raise ValueError('Invalid device label')
    csr_bytes = request['csr'].encode('ascii')
    csr = x509.load_pem_x509_csr(csr_bytes)
    if not csr.is_signature_valid:
        raise ValueError('Invalid CSR signature')
    validate_extensions(csr, 'client', [name])
    profile = PROFILES[args.profile]
    data = profile.data(Path.home())
    with administration_lock(data):
        cfg = migrate_credentials(data, profile.app(Path.home())/'Contents/MacOS/relay')
        caroot = prepare_ca(profile, data/'ca.pem')
    ca = certificate(caroot/'rootCA.pem')
    if ca.fingerprint(hashes.SHA256()) != certificate(data/'ca.pem').fingerprint(hashes.SHA256()):
        raise ValueError('Signing CA does not match the installed relay CA')
    # Retain public results by CSR so interrupted SSH exchanges retry the same identity.
    directory = data/'enrollments'/hashlib.sha256(csr_bytes).hexdigest()
    with administration_lock(directory), redirect_stdout(sys.stderr):
        cert_path = directory/'client.pem'
        if not cert_path.exists():
            atomic(directory/'client.csr', csr_bytes)
            sign(argparse.Namespace(caroot=caroot, csr=directory/'client.csr', cert=cert_path,
                                    role='client', name=[name], mkcert=args.mkcert))
        cert = certificate(cert_path)
        verify_leaf(cert, ca, 'client', [name])
        encoding = serialization.Encoding.DER
        form = serialization.PublicFormat.SubjectPublicKeyInfo
        if cert.public_key().public_bytes(encoding, form) != csr.public_key().public_bytes(encoding, form):
            raise ValueError('Issued certificate does not match CSR')
        device(argparse.Namespace(profile=args.profile, config=None, relay=None, stage=False,
                                  action='enroll', cert=cert_path, label=request['label']))
        host = cfg['server_name']
        if ':' in host: host = '[' + host + ']'
        response = {'schema': 1, 'relay_url': f'https://{host}:{cfg["port"]}',
                    'ca': private_path(caroot/'rootCA.pem').read_text(),
                    'cert': private_path(cert_path).read_text()}
    print(json.dumps(response))


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    remote = sub.add_parser('issue-ssh', help='enroll a CSR received as JSON over authenticated SSH')
    remote.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'dev'))
    remote.add_argument('--mkcert', default='mkcert')
    key = sub.add_parser('create-key')
    key.add_argument('--directory', type=Path, required=True)
    key.add_argument('--role', choices=['server', 'client'], required=True)
    key.add_argument('--name', action='append', default=[])
    issue = sub.add_parser('sign')
    issue.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'dev'))
    issue.add_argument('--csr', type=Path, required=True)
    issue.add_argument('--cert', type=Path, required=True)
    issue.add_argument('--role', choices=['server', 'client'], required=True)
    issue.add_argument('--name', action='append', default=[])
    issue.add_argument('--mkcert', default='mkcert')
    setup_parser = sub.add_parser('setup', help='stage server/admin credentials and configuration using mkcert')
    setup_parser.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'dev'))
    setup_parser.add_argument('--directory', type=Path, help='new staging directory (default: ~/.config/zimbr-PROFILE-setup)')
    setup_parser.add_argument('--relay', type=Path, help='default: installed app for packaged helpers, zig-out/bin/relay from source')
    setup_parser.add_argument('--server-name', required=True, help='DNS name or IP Linux uses to reach this Mac')
    setup_parser.add_argument('--listen-address', required=True, help='local IP address to bind')
    setup_parser.add_argument('--port', type=int, help='default: profile port (dev 8732, release 8731)')
    setup_parser.add_argument('--name', action='append', default=[], help='additional server certificate SAN')
    setup_parser.add_argument('--mkcert', default='mkcert')
    handoff = sub.add_parser('issue-device', help='sign a client CSR, enroll/restart, and export public credentials')
    handoff.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'dev'))
    handoff.add_argument('--config', type=Path)
    handoff.add_argument('--relay', type=Path)
    handoff.add_argument('--csr', type=Path, required=True)
    handoff.add_argument('--name', action='append', required=True)
    handoff.add_argument('--label', required=True)
    handoff.add_argument('--directory', type=Path, required=True, help='new directory for returned public certificates')
    handoff.add_argument('--mkcert', default='mkcert')
    handoff.add_argument('--stage', action='store_true', help='stage enrollment only; restart is still required')
    for action in ('enroll', 'revoke'):
        d = sub.add_parser(action)
        d.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'dev'))
        d.add_argument('--config', type=Path)
        d.add_argument('--relay', type=Path)
        d.add_argument('--stage', action='store_true', help='Stage only; explicitly does not complete enrollment/revocation')
        if action == 'enroll':
            d.add_argument('--cert', type=Path, required=True); d.add_argument('--label', required=True)
        else: d.add_argument('--sha256', required=True)
    args = p.parse_args()
    if args.action in ('setup', 'sign', 'issue-device'):
        args.caroot = None
    if args.action == 'setup':
        profile = PROFILES[args.profile]
        args.relay = args.relay or (profile.app(Path.home())/'Contents/MacOS/relay'
                                   if 'ZIMBR_PROFILE' in os.environ else Path('zig-out/bin/relay'))
        args.directory = args.directory or Path.home()/'.config'/f'zimbr-{profile.name}-setup'
        if args.port is None: args.port = profile.default_port
    try:
        if args.action == 'create-key': print(create_key(args.directory, args.role, args.name))
        elif args.action == 'sign':
            profile = PROFILES[args.profile]
            data = profile.data(Path.home())
            with administration_lock(data):
                args.caroot = prepare_ca(profile, data/'ca.pem' if (data/'relay.json').exists() else None)
                sign(args)
        elif args.action == 'setup':
            data = profile.data(Path.home())
            with administration_lock(data):
                args.caroot = prepare_ca(profile, data/'ca.pem' if (data/'relay.json').exists() else None)
                setup(args)
        elif args.action == 'issue-device': issue_device(args)
        elif args.action == 'issue-ssh': issue_ssh(args)
        else: device(args)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        p.exit(1, f'Certificate operation failed: {exc}\n')


if __name__ == '__main__': main()
