#!/usr/bin/env python3
"""Verify persistent signing against different binaries without running the relay."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'packaging/macos'))
from signing import default_directory, load, requirement, setup, sign
from profiles import PROFILES


def main():
    if sys.platform != 'darwin': raise SystemExit('Run this test on macOS after signing.py setup')
    directory = default_directory()
    before = load(directory)
    cert = (directory/'certificate.pem').read_bytes()
    setup(directory)
    assert load(directory) == before
    assert (directory/'certificate.pem').read_bytes() == cert
    expected = requirement(before['certificate_sha1'])
    with tempfile.TemporaryDirectory(prefix='zimbr-signing-test-') as temporary:
        root = Path(temporary)
        originals = []
        for name in ('true', 'false'):
            target = root/name
            # Copy executable bytes, not the protected flags of Apple's files.
            shutil.copyfile('/usr/bin/'+name, target)
            target.chmod(0o755)
            sign(target)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '='+expected, str(target)], check=True)
            signature = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(target)], capture_output=True, text=True, check=True)
            originals.append(next(line for line in signature.stdout.splitlines() if 'designated =>' in line))
        assert originals[0] == originals[1], 'Different builds must retain the same designated requirement'
        assert (root/'true').read_bytes() != (root/'false').read_bytes()
        dev = root/'dev'
        shutil.copyfile('/usr/bin/true', dev)
        dev.chmod(0o755)
        identifier = PROFILES['dev'].bundle_id
        sign(dev, identifier=identifier)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R',
                        '='+requirement(before['certificate_sha1'], identifier), str(dev)], check=True)
        assert subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '='+expected,
                               str(dev)], capture_output=True).returncode != 0
        # The bundle identifier alone cannot impersonate the persistent identity.
        impostor = root/'impostor'
        shutil.copyfile('/usr/bin/true', impostor)
        impostor.chmod(0o755)
        sign(impostor, identity='-')
        rejected = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '='+expected, str(impostor)], capture_output=True)
        assert rejected.returncode != 0
        try:
            sign(impostor, directory=root/'missing')
        except RuntimeError as error:
            assert 'No persistent signing identity' in str(error)
        else:
            raise AssertionError('Missing identity silently fell back to ad-hoc signing')
    print('PASS: setup reuse, different binaries retain identity, impostor rejected, missing identity fails closed')


if __name__ == '__main__': main()
