#!/usr/bin/env python3
"""Stage a disposable signed app; never install, launch, or request Contacts."""
from pathlib import Path
import argparse
import plistlib
import subprocess
import sys
import tempfile

from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'packaging/macos'))
from profiles import PROFILES


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This packaging check requires macOS')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=PROFILES, default='dev')
    parser.add_argument('--prefix', type=Path, default=ROOT/'zig-out')
    args = parser.parse_args()
    profile = PROFILES[args.profile]
    with tempfile.TemporaryDirectory(prefix='zimbr-enrichment-package-') as temporary:
        tls = Fixture(Path(temporary), 8731)
        subprocess.run([
            sys.executable, str(ROOT / 'packaging/macos/install.py'),
            '--identity', '-', '--tls-config', str(tls.config),
            '--profile', profile.name, '--binary', str(args.prefix/'bin/relay'),
            '--phone-license', str(args.prefix/'share/zimbr/licenses/libPhoneNumber-LICENSE'),
        ], check=True, stdout=subprocess.DEVNULL)
    bundle = ROOT / 'zig-out/macos' / profile.name / profile.app_name
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == profile.bundle_id
    assert info['ZimbrProfile'] == profile.name
    assert info['ZimbrDataDirectory'] == profile.data_directory
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
