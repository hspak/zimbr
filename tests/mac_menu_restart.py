#!/usr/bin/env python3
"""Check AppKit restart and quit with disposable apps/jobs; never use installed account data."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/macos'))
from install import launch_agent


def observe(root, name, process=None):
    deadline = time.monotonic() + 25
    while not (root / (name + '-again.json')).exists() and time.monotonic() < deadline:
        if process is not None:
            process.poll()  # Reap the old parent so the probe's exit check can finish.
        time.sleep(.1)
    results = []
    for suffix in ('before', 'after', 'again'):
        path = root / f'{name}-{suffix}.json'
        assert path.exists(), f'{name}: relaunched app did not finish startup'
        result = json.loads(path.read_text())
        assert result['registered_pid'] == result['pid'], 'AppKit lost the running app registration'
        assert result['item_created'] and result['item_visible'], 'Status item missing'
        assert result['timer_valid'], 'Status refresh did not start'
        results.append(result)
    assert len({result['pid'] for result in results}) == 3, 'Relaunch must use fresh processes'
    gaps = [results[i + 1]['uptime'] - results[i]['uptime'] for i in range(2)]
    assert max(gaps) < 5, f'{name}: restart stalled: {gaps}'
    print(f'{name}: Restart Relay {gaps[0]:.2f}s; Save and Restart {gaps[1]:.2f}s '
          '(includes one-second observation delay)', flush=True)


def manual(root, bundle, binary, name):
    environment = dict(os.environ)
    environment.pop('XPC_SERVICE_NAME', None)
    command = [str(binary), str(root / name), 'argument with spaces']
    if name == 'launch-services':
        command = ['open', '-n', '-W', '-a', str(bundle), '--args', *command[1:]]
    process = subprocess.Popen(command, env=environment)
    try:
        observe(root, name, process)
        process.wait(timeout=5)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def supervised(root, binary, identifier):
    agent = root / 'agent.plist'
    config = launch_agent(binary.parents[2], root, Path.home())
    config.update({
        'Label': identifier,
        'ProgramArguments': [str(binary), str(root / 'launch-agent'), 'argument with spaces'],
        'StandardOutPath': str(root / 'agent.log'),
        'StandardErrorPath': str(root / 'agent.log'),
    })
    agent.write_bytes(plistlib.dumps(config))
    domain = f'gui/{os.getuid()}'
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
    try:
        observe(root, 'launch-agent')
    finally:
        subprocess.run(['launchctl', 'bootout', f'{domain}/{identifier}'],
                       capture_output=True, check=True)


def quit_relay(root, bundle, binary, identifier):
    environment = dict(os.environ)
    environment.pop('XPC_SERVICE_NAME', None)
    for name in ('direct', 'launch-services', 'rejected'):
        output = root / ('quit-' + name)
        mode = 'check-quit-rejected' if name == 'rejected' else 'check-quit'
        command = [str(binary), mode, str(output)]
        if name == 'launch-services':
            command = ['open', '-n', '-W', '-a', str(bundle), '--args', *command[1:]]
        if name == 'rejected':
            environment['XPC_SERVICE_NAME'] = identifier  # No such job is loaded.
        subprocess.run(command, env=environment, check=True, timeout=10)
        assert output.exists(), f'{name}: Quit Relay was not invoked'
        if name == 'rejected':
            assert output.with_name(output.name + '-rejected').exists(), 'Stop rejection was not handled'

    agent = root / 'quit-agent.plist'
    output = root / 'quit-agent'
    config = launch_agent(bundle, root, Path.home())
    config.update({
        'Label': identifier,
        'ProgramArguments': [str(binary), 'check-quit', str(output)],
    })
    original = plistlib.dumps(config)
    agent.write_bytes(original)
    domain = f'gui/{os.getuid()}'
    service = f'{domain}/{identifier}'
    try:
        # Reload the same job to prove Quit did not persistently disable startup.
        for _ in range(2):
            output.unlink(missing_ok=True)
            subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                loaded = subprocess.run(['launchctl', 'print', service], capture_output=True)
                if loaded.returncode != 0:
                    break
                time.sleep(.05)
            else:
                raise AssertionError('Quit left the KeepAlive job loaded')
            assert output.exists(), 'Job exited without invoking Quit Relay'
            pid = int(output.read_text())
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.05)
            else:
                raise AssertionError('Quit did not stop the relay process')
            time.sleep(1.2)  # Observe beyond the installed job's restart interval.
            assert subprocess.run(['launchctl', 'print', service], capture_output=True).returncode != 0
            assert agent.read_bytes() == original, 'Quit changed login startup configuration'
    finally:
        subprocess.run(['launchctl', 'bootout', service], capture_output=True)
    print('PASS: Quit Relay exits manual launches, unloads KeepAlive jobs, permits later startup, '
          'and handles rejected stops', flush=True)


def handoff(root, relay):
    tls = Fixture(root, 8731)
    parent = subprocess.Popen(['/bin/sleep', '30'])
    child = None
    try:
        command = [str(relay), 'menu-relaunch', str(parent.pid), str(relay),
                   'check-config', '--config', str(tls.config)]
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(.2)
        assert child.poll() is None, 'Replacement did not wait for the old process'
        parent.terminate()
        parent.wait(timeout=5)
        stdout, stderr = child.communicate(timeout=5)
        assert child.returncode == 0, stderr.decode()
        assert json.loads(stdout)['server_sha256'] == tls.fingerprint('server')
        completed = subprocess.run(command, capture_output=True, timeout=5)
        assert completed.returncode == 0, 'Already-exited parent prevented recovery'
        command[2] = '0'
        rejected = subprocess.run(command, capture_output=True, timeout=5)
        assert rejected.returncode != 0 and b'InvalidArguments' in rejected.stderr
    finally:
        for process in (child, parent):
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


def main():
    if sys.platform != 'darwin':
        raise SystemExit('AppKit restart verification requires a macOS graphical session')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay', type=Path, default=ROOT / 'zig-out/bin/relay')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='zimbr-menu-restart-') as temporary:
        root = Path(temporary).resolve()
        identifier = 'com.hsp.zimbr.restart-probe-' + uuid.uuid4().hex
        bundle = root / 'Restart Probe.app'
        binary = bundle / 'Contents/MacOS/restart-probe'
        binary.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier,
            'CFBundleExecutable': binary.name,
            'CFBundleName': 'Restart Probe',
            'CFBundlePackageType': 'APPL',
            'LSUIElement': True,
        }))
        subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            str(ROOT / 'tests/mac_menu_restart.m'), '-framework', 'AppKit', '-o', str(binary),
        ], check=True)
        subprocess.run([str(binary), 'check-startup-refresh'], check=True, timeout=10)
        for name in ('direct', 'launch-services'):
            manual(root, bundle, binary, name)
        supervised(root, binary, identifier)
        quit_relay(root, bundle, binary, identifier)
        handoff(root, args.relay.resolve())
        print('PASS: two restarts each for direct, Launch Services, and supervised launches; '
              'AppKit registration, status item, startup refresh, arguments, and native startup handoff')


if __name__ == '__main__':
    main()
