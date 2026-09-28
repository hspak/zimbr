#!/usr/bin/env python3
"""Configure and start an installed relay without a source checkout."""
import argparse
import ipaddress
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from profiles import PROFILES
from tls_admin import administration_lock, atomic, listener_ready, migrate_credentials, pid_of_service, prepare_ca, save_json, setup, sync_directory
from tls_support import admin_files, private_directory, private_path, read_json, relay_files


def local_address(host):
    for family, kind, protocol, _, address in socket.getaddrinfo(host, 0, type=socket.SOCK_STREAM):
        if ipaddress.ip_address(address[0]).is_unspecified:
            continue
        with socket.socket(family, kind, protocol) as probe:
            try:
                probe.bind(address)
                return address[0]
            except OSError:
                continue
    raise ValueError('Server name does not resolve to a local address; pass --listen-address IP')


def bootstrap(args):
    profile = PROFILES[args.profile]
    data = profile.data(Path.home())
    relay = profile.app(Path.home())/'Contents/MacOS/relay'
    profile.verify_binary(relay)
    with administration_lock(data):
        config_path = data/'relay.json'
        if config_path.exists():
            config = read_json(config_path)
            if ((args.server_name and args.server_name != config['server_name']) or
                    (args.listen_address and args.listen_address != config['listen_address']) or
                    (args.port is not None and args.port != config['port'])):
                raise ValueError('Relay is already configured differently; use its Settings to change the endpoint')
            config = migrate_credentials(data, relay)
            prepare_ca(profile, data/'ca.pem')
        else:
            host = args.server_name or socket.gethostname()
            address = args.listen_address or local_address(host)
            caroot = prepare_ca(profile)
            # Retain a complete candidate until publication so retries reuse its keys.
            generation = data/'.setup'
            if not generation.exists():
                with tempfile.TemporaryDirectory(prefix='.setup-', dir=data) as temporary:
                    staged = Path(temporary)
                    setup(argparse.Namespace(
                        profile=args.profile, relay=relay, server_name=host, listen_address=address,
                        port=args.port if args.port is not None else profile.default_port, name=[],
                        directory=staged, caroot=caroot, mkcert='mkcert',
                    ), quiet=True)
                    staged.rename(generation)
                    sync_directory(data)
            private_directory(generation)
            config = read_json(generation/'relay.json')
            if (config['server_name'] != host or config['listen_address'] != address or
                    config['port'] != (args.port if args.port is not None else profile.default_port)):
                raise ValueError('An interrupted setup used a different endpoint; retry with its original endpoint')
            for source in (*relay_files(generation).values(), *admin_files(generation).values()):
                destination = data/source.relative_to(generation)
                if destination.exists() and private_path(destination).read_bytes() != private_path(source).read_bytes():
                    raise ValueError('Credentials already exist; preserve them before repairing setup')
            for source in (*relay_files(generation).values(), *admin_files(generation).values()):
                atomic(data/source.relative_to(generation), private_path(source).read_bytes())
            save_json(data/'admin.json', read_json(generation/'admin.json'))
            save_json(config_path, config)
            shutil.rmtree(generation)
        subprocess.run([str(relay), 'check-config', '--config', str(config_path)], check=True)
        service = relay.parent.parent/'Resources'/(profile.command + '-service')
        subprocess.run([str(service), 'start'], check=True, stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            pid = pid_of_service(profile)
            if pid and listener_ready(config, pid):
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Relay listener did not start. Check macOS permissions and the relay logs, then rerun this command.')
    print('Relay ready. On Linux, install zimbr and run:')
    print(f'  zimbr-provision setup {os.environ.get("USER", "user")}@{config["server_name"]}')
    print('Use the Mac login account and an SSH host name reachable from Linux.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server_name', nargs='?', help='DNS name or IP reachable from Linux (default: Mac hostname)')
    parser.add_argument('--listen-address', help='local bind IP (default: resolve server name on this Mac)')
    parser.add_argument('--port', type=int, help='default: profile port')
    parser.add_argument('--profile', choices=PROFILES, default=os.environ.get('ZIMBR_PROFILE', 'release'))
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.getuid() == 0:
        parser.exit(1, 'Run as the Mac login user, without sudo.\n')
    os.umask(0o077)
    try:
        bootstrap(args)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'Relay setup failed: {exc}\n')


if __name__ == '__main__':
    main()
