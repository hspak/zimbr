#!/usr/bin/env python3
"""Stage/install the signed mTLS relay under its stable per-user identity."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from tls_support import private_path, read_json
from signing import default_directory
from bundle import stage
from profiles import PROFILES


def write_json(path, value):
    if path.is_symlink(): raise ValueError('Refusing symlink configuration destination')
    fd, temporary = tempfile.mkstemp(prefix='.'+path.name+'.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def service_pid(service):
    result = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
    match = re.search(r'^\s*pid = (\d+)$', result.stdout, re.M)
    return int(match.group(1)) if match else None


def launch_agent(app, data, home, profile=PROFILES['dev']):
    # HTTPS requests cannot obtain Adaptive's XPC boosts. Use Standard and let
    # per-thread QoS distinguish user requests from ingestion/enrichment work.
    return {
        'Label': profile.bundle_id,
        'ProgramArguments': [str(app/'Contents/MacOS/relay'), 'serve', '--menu-bar',
                             '--data-dir', str(data), '--config', str(data/'relay.json')],
        # launchd also applies this delay to explicit kickstart requests.
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1,
        'ProcessType': 'Standard', 'LimitLoadToSessionType': 'Aqua',
        'WorkingDirectory': str(data),
        'StandardOutPath': str(data/'relay.log'), 'StandardErrorPath': str(data/'relay.log'),
        'Umask': 0o077, 'EnvironmentVariables': {'HOME': str(home)},
    }


def wait_exit(pid):
    if not pid: return
    deadline = time.monotonic()+15
    while time.monotonic() < deadline:
        try: os.kill(pid, 0)
        except ProcessLookupError: return
        time.sleep(.1)
    raise RuntimeError('Previous relay process has not exited; installation stopped')


def wait_listener(service, cfg):
    deadline = time.monotonic()+30
    while time.monotonic() < deadline:
        pid = service_pid(service)
        if pid:
            result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN'], capture_output=True, text=True)
            host = cfg['listen_address']
            if ':' in host: host = '['+host+']'
            if f'{host}:{cfg["port"]} (LISTEN)' in result.stdout: return pid
        time.sleep(.2)
    subprocess.run(['launchctl', 'bootout', service], capture_output=True)
    raise RuntimeError('Configured TLS listener did not start; relay left stopped for repair')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--install', action='store_true')
    p.add_argument('--start', action='store_true')
    p.add_argument('--profile', choices=PROFILES, default='dev', help='Installation identity (default: dev)')
    p.add_argument('--identity', help='Explicit codesign identity override; use - only for disposable ad-hoc builds')
    p.add_argument('--signing-directory', type=Path, default=default_directory(), help='Persistent local signing state (created by signing.py setup)')
    p.add_argument('--binary', type=Path, default=ROOT/'zig-out/bin/relay')
    p.add_argument('--image-helper', type=Path, help='Bounded ImageIO helper (default: image-helper beside the relay binary)')
    p.add_argument('--tls-config', type=Path, help='Validated relay configuration/material to install (default: existing installed config)')
    p.add_argument('--admin-config', type=Path, help='Optional separately enrolled Mac administrative identity to install')
    p.add_argument('--openssl-license', type=Path, default=ROOT/'.tools/openssl-build/openssl-3.5.8/LICENSE.txt')
    p.add_argument('--phone-license', type=Path, default=ROOT/'zig-out/share/zimbr/licenses/libPhoneNumber-LICENSE')
    args = p.parse_args()
    profile = PROFILES[args.profile]
    profile.verify_binary(args.binary)
    args.image_helper = args.image_helper or args.binary.parent/'image-helper'
    if args.start and not args.install: p.error('--start requires --install')
    os.umask(0o077)
    home = Path.home(); data = profile.data(home)
    destination = profile.app(home)
    if destination.is_symlink(): raise RuntimeError('Refusing symlink app destination')
    if destination.exists():
        with (destination/'Contents/Info.plist').open('rb') as f: old = plistlib.load(f)
        if old.get('CFBundleIdentifier') != profile.bundle_id: raise RuntimeError('Refusing to replace unrelated app')
    # Validate everything before touching the running service. Never package issuer keys.
    source_config = args.tls_config or data/'relay.json'
    cfg = read_json(source_config)
    subprocess.run([str(args.binary), 'check-config', '--config', str(source_config)], check=True)
    materials = {field: private_path(cfg[field]).read_bytes() for field in
        ('server_cert_file', 'server_key_file', 'client_ca_file', 'device_allowlist_file')}
    admin = read_json(args.admin_config) if args.admin_config else None
    admin_material = {field: private_path(admin[field]).read_bytes() for field in
        ('ca_file', 'client_cert_file', 'client_key_file')} if admin else None
    if admin:
        from tls_support import Credentials
        Credentials(args.admin_config)  # Check key matching, CA loading and strict origin syntax.
    staging = ROOT/'zig-out/macos'/profile.name; staging.mkdir(parents=True, exist_ok=True)
    bundle = staging/profile.app_name
    stage(bundle, args.binary, args.image_helper, args.openssl_license, args.phone_license,
          identity=args.identity, signing_directory=args.signing_directory, profile=profile)
    config = launch_agent(destination, data, home, profile)
    plist = staging/(profile.bundle_id+'.plist')
    with plist.open('wb') as f: plistlib.dump(config, f)
    subprocess.run(['plutil', '-lint', str(plist)], check=True)
    if not args.install:
        print('Staged signed app and LaunchAgent at', staging); return
    service = f'gui/{os.getuid()}/{profile.bundle_id}'
    previous = service_pid(service)
    stopped = subprocess.run(['launchctl', 'bootout', service], capture_output=True)
    if stopped.returncode and previous: raise RuntimeError('Failed to stop previous LaunchAgent')
    wait_exit(previous)
    data.mkdir(mode=0o700, parents=True, exist_ok=True)
    if data.is_symlink() or data.stat().st_uid != os.getuid() or data.stat().st_mode & 0o077:
        raise RuntimeError('Unsafe relay state directory; relay left stopped')
    # SQLite backup is consistent after the service exits; retain epoch and request IDs.
    if (data/'relay.db').exists():
        backup = data/'backups'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        backup.mkdir(mode=0o700, parents=True)
        with sqlite3.connect((data/'relay.db').as_uri()+'?mode=ro', uri=True) as source, sqlite3.connect(backup/'relay.db') as target:
            source.backup(target)
        print('Consistent journal backup:', backup/'relay.db')
    # Immutable credential generation: never overwrite files a running process used.
    generation = Path(tempfile.mkdtemp(prefix='tls-', dir=data))
    filenames = {'server_cert_file': 'server.pem', 'server_key_file': 'server-key.pem', 'client_ca_file': 'ca.pem', 'device_allowlist_file': 'devices.json'}
    for field, content in materials.items():
        path = generation/filenames[field]; path.write_bytes(content); path.chmod(0o600); cfg[field] = str(path)
    write_json(data/'relay.json', cfg)
    if admin:
        admin_dir = Path(tempfile.mkdtemp(prefix='admin-', dir=data))
        for field, filename in {'ca_file': 'ca.pem', 'client_cert_file': 'client.pem', 'client_key_file': 'client-key.pem'}.items():
            path = admin_dir/filename; path.write_bytes(admin_material[field]); path.chmod(0o600); admin[field] = str(path)
        write_json(data/'admin.json', admin)
    subprocess.run([str(args.binary), 'check-config', '--config', str(data/'relay.json')], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(bundle, destination)
    subprocess.run([str(destination/'Contents/MacOS/relay'), 'setup'], check=True)
    (data/'token').unlink(missing_ok=True)
    (data/'relay.log').touch(mode=0o600); (data/'relay.log').chmod(0o600)
    agents = home/'Library/LaunchAgents'; agents.mkdir(parents=True, exist_ok=True)
    installed_plist = agents/plist.name; shutil.copy2(plist, installed_plist); installed_plist.chmod(0o600)
    if args.start:
        subprocess.run(['launchctl', 'enable', service], check=True)
        subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(installed_plist)], check=True)
        print('Running configured HTTPS listener, pid', wait_listener(service, cfg))
    print('Installed', destination)
    print('Verify Full Disk Access and Messages Automation under this installed identity.')


if __name__ == '__main__': main()
