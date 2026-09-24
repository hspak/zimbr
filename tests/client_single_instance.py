#!/usr/bin/env python3
"""Check duplicate launches without a display or relay.

Build with: zig build client client-probe
"""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-single-instance-') as temp:
        root = Path(temp)
        env = {
            **os.environ,
            'XDG_CONFIG_HOME': str(root / 'config'),
            'XDG_RUNTIME_DIR': str(root),
            'WAYLAND_DISPLAY': str(root / 'no-display'),
            'DISPLAY': '',
        }
        # Missing credentials keep the worker offline; no relay is needed.
        args = [
            '--data-dir', str(root / 'client'),
            '--relay-url', 'https://localhost:1',
            '--ca-file', str(root / 'ca.pem'),
            '--client-cert-file', str(root / 'cert.pem'),
            '--client-key-file', str(root / 'key.pem'),
        ]
        processes = []

        def start(extra=()):
            proc = subprocess.Popen(
                [str(BIN / 'client-probe'), '--control', *args, *extra],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, bufsize=0,
            )
            processes.append(proc)
            assert select.select([proc.stdout], [], [], 10)[0], 'No initial snapshot'
            line = proc.stdout.readline()
            assert line, proc.stderr.read().decode()
            json.loads(line)
            assert proc.poll() is None
            return proc

        def stop(proc):
            _, stderr = proc.communicate(b'quit\n', timeout=10)
            assert proc.returncode == 0, stderr.decode()

        try:
            owner = start()
            # The GUI must reject a duplicate before even trying to connect to
            # Wayland. A graphics initialization attempt cannot succeed here.
            duplicate = subprocess.run(
                [str(BIN / 'zimbr'), *args], env=env, capture_output=True,
                timeout=5,
            )
            assert duplicate.returncode == 1, duplicate.stderr.decode()
            assert duplicate.stderr == (
                b'zimbr: another client is already using this data directory.\n'
            ), duplicate.stderr.decode()
            assert not duplicate.stdout, duplicate.stdout.decode()
            probe = subprocess.run(
                [str(BIN / 'client-probe'), '--control', *args], env=env,
                input=b'', capture_output=True, timeout=5,
            )
            assert probe.returncode != 0
            assert b'ClientAlreadyRunning' in probe.stderr, probe.stderr.decode()
            assert not probe.stdout
            assert owner.poll() is None, 'Duplicate launch stopped the owner'
            # Independent caches may still run concurrently.
            independent = start(['--data-dir', str(root / 'other-client')])
            stop(independent)
            # Both graceful shutdown and process death must release the lock.
            stop(owner)
            owner = start()
            owner.kill()
            owner.wait(timeout=5)
            owner = start()
            stop(owner)
            print('PASS: duplicates exit before GUI startup; cache locks release on exit and crash')
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
                for stream in (proc.stdin, proc.stdout, proc.stderr):
                    stream.close()


if __name__ == '__main__':
    main()
