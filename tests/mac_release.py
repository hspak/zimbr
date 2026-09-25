#!/usr/bin/env python3
"""Validate public archive contents without requiring Apple build tools."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/macos'))
import bundle
import release as mac_release


def make_archive(path, revision, version='0.1.0', *, extra=None, arch=0x0100000C):
    """Synthetic Mach-O headers; no fixture is a runnable or signed application."""
    files = {name: b'fixture' for name in mac_release.REQUIRED}
    for name in ('relay', 'image-helper'):
        files[f'{mac_release.APP}/MacOS/{name}'] = struct.pack('<II', 0xFEEDFACF, arch)
    files[f'{mac_release.APP}/Info.plist'] = plistlib.dumps({
        'CFBundleIdentifier': bundle.LABEL, 'CFBundleExecutable': 'relay',
        'CFBundleVersion': version, 'CFBundleShortVersionString': version,
        'LSMinimumSystemVersion': bundle.MINIMUM_MACOS,
    })
    manifest = {'schema': 1, 'project': 'zimbr', 'version': version, 'revision': revision,
                'architecture': 'aarch64', 'minimum_macos': bundle.MINIMUM_MACOS,
                'files': {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
    files['release.json'] = json.dumps(manifest).encode()
    if extra:
        files.update(extra)
    with zipfile.ZipFile(path, 'w') as archive:
        for name, content in files.items():
            item = zipfile.ZipInfo(name)
            executable = '/MacOS/' in name or name.endswith('/zimbr-relay-service')
            item.external_attr = (0o100755 if executable else 0o100644) << 16
            archive.writestr(item, content)


class MacRelease(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-mac-release-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.archive = self.root / 'relay.zip'

    def test_matching_archive_renders_exact_download_checksum(self):
        make_archive(self.archive, 'a' * 40)
        mac_release.validate(self.archive, '0.1.0', 'a' * 40)
        cask = self.root / 'zimbr-relay.rb'
        mac_release.render_cask(self.archive, '0.1.0', cask)
        self.assertIn(hashlib.sha256(self.archive.read_bytes()).hexdigest(), cask.read_text())
        self.assertIn('version "0.1.0"', cask.read_text())
        self.assertNotIn('@SHA256@', cask.read_text())

    def test_cask_checksum_bypass_is_rejected(self):
        make_archive(self.archive, 'a' * 40)
        template = (ROOT / 'packaging/homebrew/zimbr-relay.rb.in').read_text()
        target = self.root / 'packaging/homebrew/zimbr-relay.rb.in'
        target.parent.mkdir(parents=True)
        target.write_text(template.replace('sha256 "@SHA256@"', 'sha256 :no_check'))
        with mock.patch.object(mac_release, 'ROOT', self.root), self.assertRaisesRegex(ValueError, 'SHA-256'):
            mac_release.render_cask(self.archive, '0.1.0', self.root / 'zimbr-relay.rb')

    def test_different_commit_or_version_is_rejected(self):
        make_archive(self.archive, 'a' * 40)
        for version, revision in (('0.1.1', 'a' * 40), ('0.1.0', 'b' * 40)):
            with self.subTest(version=version, revision=revision), self.assertRaises(ValueError):
                mac_release.validate(self.archive, version, revision)

    def test_private_material_and_unknown_payload_are_rejected(self):
        for name in ('server.key', f'{mac_release.APP}/Resources/relay.json', '../escape'):
            with self.subTest(name=name):
                make_archive(self.archive, 'a' * 40, extra={name: b'private fixture'})
                with self.assertRaises(ValueError):
                    mac_release.validate(self.archive, '0.1.0', 'a' * 40)

    def test_wrong_architecture_and_modified_payload_are_rejected(self):
        make_archive(self.archive, 'a' * 40, arch=0x01000007)
        with self.assertRaisesRegex(ValueError, 'arm64'):
            mac_release.validate(self.archive, '0.1.0', 'a' * 40)
        make_archive(self.archive, 'a' * 40, extra={f'{mac_release.APP}/MacOS/relay': b'changed'})
        with self.assertRaisesRegex(ValueError, 'checksums'):
            mac_release.validate(self.archive, '0.1.0', 'a' * 40)

    def test_shared_bundle_uses_source_version_without_tls_configuration(self):
        for name in ('relay', 'image-helper', 'openssl-license', 'phone-license'):
            (self.root / name).write_bytes(b'fixture')
        app = self.root / 'Zimbr Relay.app'
        with mock.patch.object(bundle.subprocess, 'check_output', return_value='binary:\n /usr/lib/libSystem.B.dylib\n'), \
                mock.patch.object(bundle, 'sign') as sign:
            bundle.stage(app, self.root / 'relay', self.root / 'image-helper',
                         self.root / 'openssl-license', self.root / 'phone-license', identity='fixture')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], bundle.source_version())
        self.assertEqual(info['CFBundleVersion'], bundle.source_version())
        self.assertEqual(sign.call_count, 2)
        self.assertTrue((app / 'Contents/Resources/zimbr-relay-service').stat().st_mode & 0o111)
        self.assertFalse(list(app.rglob('*.key')))
        self.assertFalse(list(app.rglob('relay.json')))

    def test_non_system_dynamic_dependency_is_rejected_before_signing(self):
        with mock.patch.object(bundle.subprocess, 'check_output',
                               return_value='binary:\n /private/build/libsqlite3.dylib (compatibility version 9.0.0)\n'), \
                mock.patch.object(bundle, 'sign') as sign, self.assertRaisesRegex(RuntimeError, 'system libraries'):
            bundle.stage(self.root / 'Zimbr Relay.app', self.root / 'relay',
                         self.root / 'image-helper', self.root / 'openssl-license',
                         self.root / 'phone-license')
        sign.assert_not_called()


if __name__ == '__main__':
    unittest.main()
