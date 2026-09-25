#!/usr/bin/env python3
"""Build a public relay archive on macOS; validate it on the release host."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile

from bundle import MINIMUM_MACOS, ROOT, source_version, stage
from signing import LABEL, default_directory

APP = 'Zimbr Relay.app/Contents'
REQUIRED = {
    f'{APP}/Info.plist', f'{APP}/MacOS/relay', f'{APP}/MacOS/image-helper',
    f'{APP}/Resources/zimbr-relay-service', f'{APP}/Resources/zimbr.icns',
    f'{APP}/Resources/LICENSE', f'{APP}/Resources/OpenSSL-LICENSE.txt',
    f'{APP}/Resources/libPhoneNumber-LICENSE.txt', f'{APP}/_CodeSignature/CodeResources',
}


def digest(content):
    return hashlib.sha256(content).hexdigest()


def validate(archive, version, revision):
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate archive members')
        if set(names) != REQUIRED | {'release.json'}:
            raise ValueError('Archive must contain only the signed app and release manifest')
        for item in package.infolist():
            path = PurePosixPath(item.filename)
            if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('Unsafe archive member')
        manifest = json.loads(package.read('release.json'))
        expected = {'schema': 1, 'project': 'zimbr', 'version': version,
                    'revision': revision, 'architecture': 'aarch64', 'minimum_macos': MINIMUM_MACOS}
        for field, value in expected.items():
            if manifest.get(field) != value:
                raise ValueError(f'Relay archive {field} does not match this release')
        if manifest.get('files') != {name: digest(package.read(name)) for name in REQUIRED}:
            raise ValueError('Relay archive payload checksums do not match its manifest')
        info = plistlib.loads(package.read(f'{APP}/Info.plist'))
        for field, value in {
            'CFBundleIdentifier': LABEL, 'CFBundleExecutable': 'relay',
            'CFBundleVersion': version, 'CFBundleShortVersionString': version,
            'LSMinimumSystemVersion': MINIMUM_MACOS,
        }.items():
            if info.get(field) != value:
                raise ValueError(f'App {field} does not match this release')
        for name in ('relay', 'image-helper'):
            path = f'{APP}/MacOS/{name}'
            binary = package.read(path)
            if binary[:8] != struct.pack('<II', 0xFEEDFACF, 0x0100000C):
                raise ValueError(f'{name} is not an arm64 Mach-O executable')
        for name in ('MacOS/relay', 'MacOS/image-helper', 'Resources/zimbr-relay-service'):
            if not package.getinfo(f'{APP}/{name}').external_attr >> 16 & 0o111:
                raise ValueError(f'{name} is not executable')


def render_cask(archive, version, destination):
    template = (ROOT / 'packaging/homebrew/zimbr-relay.rb.in').read_text()
    checksum = digest(archive.read_bytes())
    cask = template.replace('@VERSION@', version).replace('@SHA256@', checksum)
    if re.findall(r'^\s*sha256\s+([^\n]+)$', cask, re.M) != [f'"{checksum}"']:
        raise ValueError('Cask must pin the relay archive SHA-256; checksum bypasses are forbidden')
    destination.write_text(cask)


def build(args):
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise ValueError('Build the relay archive on an Apple Silicon Mac')
    if int(platform.mac_ver()[0].split('.')[0]) < int(MINIMUM_MACOS.split('.')[0]):
        raise ValueError(f'The relay requires macOS {MINIMUM_MACOS} or newer')
    if args.identity == '-':
        raise ValueError('Public release archives require a persistent signing identity')
    status = subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'], text=True)
    if status.strip():
        raise ValueError('Commit the source checkout before building a release archive')
    revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    version = source_version()
    zig = os.environ.get('ZIMBR_ZIG', str(ROOT / '.tools/zig-aarch64-macos-0.16.0/zig'))
    if 'ZIMBR_ZIG' not in os.environ and not Path(zig).exists():
        zig = 'zig'
    if subprocess.check_output([zig, 'version'], text=True).strip() != (ROOT / '.zigversion').read_text().strip():
        raise ValueError('Use the Zig version pinned in .zigversion')
    openssl = Path(os.environ.get('ZIMBR_OPENSSL_PREFIX', ROOT / '.tools/openssl-3.5')).resolve()
    license_path = Path(os.environ.get('ZIMBR_OPENSSL_LICENSE',
                        ROOT / '.tools/openssl-build/openssl-3.5.8/LICENSE.txt')).resolve()
    for required in (openssl / 'lib/libssl.a', openssl / 'lib/libcrypto.a', license_path):
        if not required.is_file():
            raise ValueError(f'Missing required file: {required}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zimbr-macos-release-') as temporary:
        work = Path(temporary)
        prefix = work / 'build'
        subprocess.run([
            zig, 'build', 'relay', 'test', 'test-macos-enrichment',
            '-Doptimize=ReleaseSafe', '-Dtarget=aarch64-macos.27.0', '-Dcpu=apple_m1',
            f'-Dopenssl-prefix={openssl}', '--prefix', str(prefix),
        ], cwd=ROOT, check=True)
        payload = work / 'payload'
        stage(payload / 'Zimbr Relay.app', prefix / 'bin/relay', prefix / 'bin/image-helper',
              license_path, prefix / 'share/zimbr/licenses/libPhoneNumber-LICENSE',
              identity=args.identity, signing_directory=args.signing_directory)
        files = {path.relative_to(payload).as_posix(): digest(path.read_bytes())
                 for path in (payload / 'Zimbr Relay.app').rglob('*') if path.is_file()}
        manifest = {'schema': 1, 'project': 'zimbr', 'version': version, 'revision': revision,
                    'architecture': 'aarch64', 'minimum_macos': MINIMUM_MACOS, 'files': files}
        (payload / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
        archive = work / f'zimbr-relay-{version}-aarch64-macos.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
            for name in sorted(files.keys() | {'release.json'}):
                package.write(payload / name, name)
        validate(archive, version, revision)
        extracted = work / 'extracted'
        with zipfile.ZipFile(archive) as package:
            package.extractall(extracted)
            for item in package.infolist():
                (extracted / item.filename).chmod(stat.S_IMODE(item.external_attr >> 16))
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep',
                        str(extracted / 'Zimbr Relay.app')], check=True)
        # Reject source edits made while the compiler was running.
        if subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']).strip() or \
                subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip() != revision:
            raise ValueError('Source changed while building the relay archive')
        shutil.copy2(archive, output / archive.name)
        print(output / archive.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build', help='Build, test, sign, and archive on macOS')
    builder.add_argument('--identity', help='Explicit codesign identity; default: persistent local identity')
    builder.add_argument('--signing-directory', type=Path, default=default_directory())
    builder.add_argument('--output', type=Path, default=ROOT / 'zig-out/release')
    checker = commands.add_parser('validate', help='Validate a Mac-built archive without executing it')
    checker.add_argument('archive', type=Path)
    checker.add_argument('--version', required=True)
    checker.add_argument('--revision', required=True)
    checker.add_argument('--cask-output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args)
        else:
            validate(args.archive, args.version, args.revision)
            if args.cask_output:
                render_cask(args.archive, args.version, args.cask_output)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f'release.py: {error}\n')


if __name__ == '__main__':
    main()
