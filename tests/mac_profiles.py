#!/usr/bin/env python3
"""Exercise both compiled profiles with disposable bundles, TLS, and journals."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import time

from fixture import create
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'packaging/macos'))
from bundle import stage
from install import launch_agent
from profiles import PROFILES


def request(tls, path='/v1/sync'):
    connection = tls.connection()
    try:
        connection.request('GET', path)
        response = connection.getresponse()
        assert response.status == 200
        return json.loads(response.read())
    finally:
        connection.close()


def wait_ready(tls):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            if request(tls, '/v1/status')['adapter_ready']:
                return request(tls)['server_epoch']
        except OSError:
            pass
        time.sleep(.05)
    raise AssertionError('Fixture relay did not become ready')


def stop(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dev-prefix', type=Path, default=ROOT/'zig-out/profile-dev')
    parser.add_argument('--release-prefix', type=Path, default=ROOT/'zig-out/profile-release')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='zimbr-profiles-') as temporary, ExitStack() as cleanup:
        root = Path(temporary).resolve()
        fake_bin = root/'commands'
        fake_bin.mkdir()
        # Exercise the packaged helper's target selection without touching installed jobs.
        (fake_bin/'launchctl').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        (fake_bin/'launchctl').chmod(0o755)
        environment = {**os.environ, 'PATH': str(fake_bin) + ':' + os.environ['PATH']}
        instances = {}
        for name, profile in PROFILES.items():
            prefix = getattr(args, name + '_prefix').resolve()
            binary = prefix/'bin/relay'
            profile.verify_binary(binary)
            other = PROFILES['release' if name == 'dev' else 'dev']
            try:
                other.verify_binary(binary)
            except ValueError:
                pass
            else:
                raise AssertionError('Wrong profile binary was accepted')
            app = profile.app(root)
            stage(app, binary, prefix/'bin/image-helper',
                  ROOT/'.tools/openssl-build/openssl-3.5.8/LICENSE.txt',
                  prefix/'share/zimbr/licenses/libPhoneNumber-LICENSE', identity='-', profile=profile)
            info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
            assert info['CFBundleIdentifier'] == profile.bundle_id
            assert info['CFBundleDisplayName'] == profile.display_name
            assert info['ZimbrDataDirectory'] == profile.data_directory
            subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R',
                            f'=identifier "{profile.bundle_id}"', str(app)], check=True)
            helper = app/'Contents/Resources'/(profile.command + '-service')
            for action, command in (('stop', 'bootout'), ('status', 'print')):
                output = subprocess.check_output([str(helper), action], env=environment, text=True)
                assert output.splitlines() == [command, f'gui/{os.getuid()}/{profile.bundle_id}']

            work = root/name
            work.mkdir()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            tls = Fixture(work, port)
            source = work/'messages.db'
            create(source)
            data = profile.data(root)
            agent = launch_agent(app, data, root, profile)
            assert agent['Label'] == profile.bundle_id
            # The fixture executable has no AppKit; keep the actual agent's data arguments.
            command = [str(prefix/'bin/fake-relay'), *agent['ProgramArguments'][1:]]
            command.remove('--menu-bar')
            command[command.index('--config') + 1] = str(tls.config)
            command += ['--messages-db', str(source), '--read-only']
            setup = [command[0], 'setup', *command[2:]]
            subprocess.run(setup, check=True, stdout=subprocess.DEVNULL)
            log = cleanup.enter_context((work/'relay.log').open('w'))
            process = subprocess.Popen(command, stdout=log, stderr=log)
            cleanup.callback(stop, process)
            epoch = wait_ready(tls)
            instances[name] = (process, command, tls, epoch, log)
            assert (data/'relay.db').exists() and (data/'relay.lock').exists()
        dev, release = instances['dev'], instances['release']
        assert dev[3] != release[3], 'Profiles shared a journal'
        stop(dev[0])
        assert release[0].poll() is None and request(release[2])['server_epoch'] == release[3]
        replacement = subprocess.Popen(dev[1], stdout=dev[4], stderr=dev[4])
        cleanup.callback(stop, replacement)
        assert wait_ready(dev[2]) == dev[3], 'Dev restart lost its own journal'
        assert request(release[2])['server_epoch'] == release[3], 'Dev restart affected release state'
    print('PASS: both binaries and signatures, mismatched-profile rejection, helper targets, '
          'simultaneous listeners, separate journals, and independent restart')


if __name__ == '__main__':
    main()
