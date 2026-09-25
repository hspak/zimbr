#!/usr/bin/env python3
"""Stage a disposable signed app; never install, launch, or request Contacts."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This packaging check requires macOS')
    with tempfile.TemporaryDirectory(prefix='zimbr-enrichment-package-') as temporary:
        tls = Fixture(Path(temporary), 8731)
        subprocess.run([
            sys.executable, str(ROOT / 'packaging/macos/install.py'),
            '--identity', '-', '--tls-config', str(tls.config),
        ], check=True, stdout=subprocess.DEVNULL)
    bundle = ROOT / 'zig-out/macos/Zimbr Relay.app'
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.hsp.zimbr.relay'
    assert 'enrolled clients' in info['NSContactsUsageDescription']
    assert info['NSAppleEventsUsageDescription']
    assert info['LSUIElement']
    assert (bundle / 'Contents/Resources/statusTemplate.pdf').read_bytes().startswith(b'%PDF-')
    assert (bundle / 'Contents/Resources/libPhoneNumber-LICENSE.txt').is_file()
    assert (bundle / 'Contents/Resources/OpenSSL-LICENSE.txt').is_file()
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(bundle / 'Contents/MacOS/image-helper')], check=True)
    print('PASS: staged app has Contacts/Automation descriptions, parser license, and a valid disposable signature; no installed attribution claimed')


if __name__ == '__main__':
    main()
