"""Build the same credential-free app for local installation and distribution."""
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from signing import LABEL, sign

ROOT = Path(__file__).resolve().parents[2]
MINIMUM_MACOS = '27.0'


def source_version():
    versions = re.findall(r'^\s*\.version\s*=\s*"([^"]+)"',
                          (ROOT / 'build.zig.zon').read_text(), re.M)
    if len(versions) != 1:
        raise ValueError('Expected one version in build.zig.zon')
    return versions[0]


def stage(bundle, binary, image_helper, openssl_license, phone_license, *,
          identity=None, signing_directory=None):
    for executable in (binary, image_helper):
        links = subprocess.check_output(['otool', '-L', str(executable)], text=True)
        libraries = [line.strip().split(' (', 1)[0] for line in links.splitlines()[1:]]
        if any(not path.startswith(('/usr/lib/', '/System/Library/')) for path in libraries):
            raise RuntimeError('Relay and image helper must link only system libraries dynamically')
    if bundle.exists():
        shutil.rmtree(bundle)
    contents = bundle / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    for source, name in ((binary, 'relay'), (image_helper, 'image-helper')):
        shutil.copy2(source, macos / name)
        (macos / name).chmod(0o755)
    for source, name in ((ROOT / 'packaging/macos/zimbr.icns', 'zimbr.icns'),
                         (ROOT / 'LICENSE', 'LICENSE'),
                         (openssl_license, 'OpenSSL-LICENSE.txt'),
                         (phone_license, 'libPhoneNumber-LICENSE.txt')):
        shutil.copy2(source, resources / name)
    # Shell scripts are sealed resources; signing them as nested Mach-O code
    # can rely on extended attributes that a ZIP archive would not preserve.
    shutil.copy2(ROOT / 'packaging/macos/service.sh', resources / 'zimbr-relay-service')
    (resources / 'zimbr-relay-service').chmod(0o755)
    version = source_version()
    info = {
        'CFBundleIdentifier': LABEL,
        'CFBundleName': 'Zimbr Relay',
        'CFBundleDisplayName': 'Zimbr Relay',
        'CFBundleExecutable': 'relay',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': version,
        'CFBundleShortVersionString': version,
        'CFBundleIconFile': 'zimbr.icns',
        'LSUIElement': True,
        'LSMinimumSystemVersion': MINIMUM_MACOS,
        'NSAppleEventsUsageDescription': 'Zimbr sends text through your Messages account when you submit a message to your authenticated relay.',
        'NSContactsUsageDescription': 'Zimbr uses contact names and photos to identify conversations on your enrolled clients.',
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    entitlements = bundle.parent / 'entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.automation.apple-events': True}))
    sign(macos / 'image-helper', identity=identity, directory=signing_directory)
    sign(bundle, entitlements, identity=identity, directory=signing_directory)
