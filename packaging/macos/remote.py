#!/usr/bin/env python3
"""Run over SSH: build an isolated source revision and stream its ZIP on stdout."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def build(repository, version, revision):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Expected an X.Y.Z version')
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Expected a full source commit')
    repository = Path(repository).expanduser()
    if not repository.is_absolute():
        repository = Path.home() / repository
    repository = repository.resolve()
    if not (repository / '.git').exists():
        raise ValueError(f'Missing Mac source checkout: {repository}')

    # Borrow the installed toolchain and signing identity, not the working tree.
    env = dict(os.environ)
    zig = repository / '.tools/zig-aarch64-macos-0.16.0/zig'
    if zig.is_file():
        env.setdefault('ZIMBR_ZIG', str(zig))
    env.setdefault('ZIMBR_OPENSSL_PREFIX', str(repository / '.tools/openssl-3.5'))
    env.setdefault('ZIMBR_OPENSSL_LICENSE',
                   str(repository / '.tools/openssl-build/openssl-3.5.8/LICENSE.txt'))
    python = repository / '.tools/python/bin/python3'
    if not python.is_file():
        python = sys.executable

    def run(*command):
        subprocess.run([str(arg) for arg in command], env=env, check=True, stdout=sys.stderr)

    with tempfile.TemporaryDirectory(prefix='zimbr-release-') as temporary:
        work = Path(temporary)
        source = work / 'source'
        run('git', 'clone', '--shared', '--no-checkout', '--', repository, source)
        run('git', '-C', source, 'fetch', '--no-tags', 'https://github.com/hspak/zimbr.git', revision)
        run('git', '-C', source, 'checkout', '--detach', revision)
        output = work / 'output'
        run(python, source / 'packaging/macos/release.py', 'build', '--output', output)
        archive = output / f'zimbr-relay-{version}-aarch64-macos.zip'
        run(python, source / 'packaging/macos/release.py', 'validate', archive,
            '--version', version, '--revision', revision)
        with archive.open('rb') as package:
            shutil.copyfileobj(package, sys.stdout.buffer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', help='Existing checkout supplying the Mac toolchain')
    parser.add_argument('version')
    parser.add_argument('revision')
    args = parser.parse_args()
    try:
        build(args.repository, args.version, args.revision)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'remote.py: {error}\n')


if __name__ == '__main__':
    main()
