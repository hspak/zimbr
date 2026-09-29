#!/usr/bin/env python3
"""Stage/install the signed mTLS relay under its stable per-user identity."""
import argparse
from contextlib import closing
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from tls_support import private_directory, private_path
from tls_admin import atomic, read_credentials, stage_credentials
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
    # Allow 15 seconds for the old process to exit before replacing its files.
    deadline = time.monotonic()+15
    while time.monotonic() < deadline:
        try: os.kill(pid, 0)
        except ProcessLookupError: return
        # Poll exit at 100 ms intervals to avoid a busy loop during shutdown.
        time.sleep(.1)
    raise RuntimeError('Previous relay process has not exited; installation stopped')


def wait_listener(service, cfg):
    # Give launchd 30 seconds to bring up the configured listener before declaring failure.
    deadline = time.monotonic()+30
    while time.monotonic() < deadline:
        pid = service_pid(service)
        if pid:
            result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN'], capture_output=True, text=True)
            host = cfg['listen_address']
            if ':' in host: host = '['+host+']'
            if f'{host}:{cfg["port"]} (LISTEN)' in result.stdout: return pid
        # Poll listener readiness five times per second without repeatedly running lsof at full
        # speed.
        time.sleep(.2)
    subprocess.run(['launchctl', 'bootout', service], capture_output=True)
    raise RuntimeError('Configured TLS listener did not start; relay left stopped for repair')


def prepare_journal(data, *, reset=False):
    """Back up a stopped relay, optionally archiving its DB and derived media.

    Returns the backup directory, or None if there was no journal/cache. The
    consistent SQLite copy includes committed WAL records, including send history.
    """
    private_directory(data)
    descriptor = os.open(data / 'relay.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'r+') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Refusing unsafe relay lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Relay is still running; journal left untouched') from None
        journal = data / 'relay.db'
        entries = [data / name for name in ('assets', 'relay.db-wal', 'relay.db-shm',
                                           'relay.db-journal', 'relay.db')]
        for path in entries:
            if path.is_symlink():
                raise ValueError(f'Refusing symlink relay cache: {path}')
            if path.exists():
                if path.name == 'assets':
                    private_directory(path)
                else:
                    private_path(path)
        if not journal.exists() and not (reset and any(path.exists() for path in entries)):
            return None
        backups = data / 'backups'
        backups.mkdir(mode=0o700, exist_ok=True)
        private_directory(backups)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ-')
        backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
        if journal.exists():
            # A read-only connection includes committed WAL pages without replaying sends.
            (backup / 'relay.db').touch(mode=0o600)
            with closing(sqlite3.connect(journal.as_uri()+'?mode=ro', uri=True)) as source:
                with closing(sqlite3.connect(backup / 'relay.db')) as target:
                    source.backup(target)
        if reset:
            original = backup / 'original'
            original.mkdir(mode=0o700)
            moved = []
            try:
                for path in entries:
                    if path.exists():
                        path.rename(original / path.name)
                        moved.append(path)
            except OSError:
                for path in reversed(moved):
                    (original / path.name).rename(path)
                raise
        return backup


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--install', action='store_true')
    p.add_argument('--start', action='store_true')
    p.add_argument('--reset-cache', action='store_true',
                   help='Archive relay DB, send history and cached media, then rebuild; requires --install')
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
    if args.reset_cache and not args.install: p.error('--reset-cache requires --install')
    os.umask(0o077)
    home = Path.home(); data = profile.data(home)
    destination = profile.app(home)
    if destination.is_symlink(): raise RuntimeError('Refusing symlink app destination')
    if destination.exists():
        with (destination/'Contents/Info.plist').open('rb') as f: old = plistlib.load(f)
        if old.get('CFBundleIdentifier') != profile.bundle_id: raise RuntimeError('Refusing to replace unrelated app')
    # Validate everything before touching the running service. Never package issuer keys.
    source_config = args.tls_config or data/'relay.json'
    admin_source = args.admin_config or (data/'admin.json' if (data/'admin.json').exists() else None)
    cfg, admin, material = read_credentials(source_config, admin_source)
    with tempfile.TemporaryDirectory(prefix='zimbr-credentials-') as temporary:
        stage_credentials(Path(temporary).resolve(), args.binary, cfg, admin, material)
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
    backup = prepare_journal(data, reset=args.reset_cache)
    if backup:
        print('Archived relay cache:' if args.reset_cache else 'Consistent journal backup:', backup)
    # The old process has exited; replace credentials at their fixed locations.
    for relative, content in material.items():
        atomic(data/relative, content)
    write_json(data/'relay.json', cfg)
    if admin:
        write_json(data/'admin.json', admin)
    subprocess.run([str(args.binary), 'check-config', '--config', str(data/'relay.json')], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(bundle, destination)
    # Existing incompatible journals must reach the authenticated reset API.
    if not (data/'relay.db').exists():
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
