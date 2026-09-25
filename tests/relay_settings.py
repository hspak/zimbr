#!/usr/bin/env python3
"""Exercise the native settings save backend through the relay CLI with synthetic TLS."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/fake-relay'


class RelaySettings(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-settings-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.tls = Fixture(self.root, 8731)
        self.original = self.tls.config.read_bytes()
        self.snapshot = self.tls.root / 'original.json'
        self.snapshot.write_bytes(self.original)
        self.snapshot.chmod(0o600)
        self.proposal = self.tls.root / 'proposal.json'
        self.value = json.loads(self.original)

    def save(self, value=None, *, destination=None, new=False):
        self.proposal.write_text(json.dumps(self.value if value is None else value))
        self.proposal.chmod(0o600)
        return subprocess.run([
            str(BIN), 'save-config', '--messages-db', str(self.root / 'unused.db'),
            '--config', str(destination or self.tls.config),
            '--settings-input', str(self.proposal),
            *(['--settings-new'] if new else ['--settings-original', str(self.snapshot)]),
        ], capture_output=True, timeout=10)

    def test_valid_settings_replace_file_and_pass_startup_validation(self):
        self.value['port'] = 9876
        self.value['contacts_phone_region'] = 'US'
        result = self.save()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['saved'])
        self.assertEqual(json.loads(self.tls.config.read_bytes()), self.value)
        self.assertEqual(stat.S_IMODE(self.tls.config.stat().st_mode), 0o600)
        checked = subprocess.run([
            str(BIN), 'check-config', '--messages-db', str(self.root / 'unused.db'),
            '--config', str(self.tls.config),
        ], capture_output=True, timeout=10)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(json.loads(checked.stdout)['server_sha256'], self.tls.fingerprint('server'))
        self.assertEqual(list(self.tls.root.glob('.relay-settings-*')), [])

    def test_invalid_settings_leave_original_bytes_and_inode_untouched(self):
        inode = self.tls.config.stat().st_ino
        for changes in (
            {'port': 0}, {'port': 65536}, {'listen_address': '0.0.0.0'},
            {'listen_address': 'example.invalid'}, {'server_name': 'wrong.invalid'},
            {'server_key_file': str(self.tls.root / 'client-key.pem')},
            {'contacts_phone_region': 'not-a-region'}, {'unknown_setting': True},
        ):
            with self.subTest(changes=changes):
                result = self.save({**self.value, **changes})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.tls.config.read_bytes(), self.original)
                self.assertEqual(self.tls.config.stat().st_ino, inode)
                self.assertEqual(list(self.tls.root.glob('.relay-settings-*')), [])

    def test_external_edit_is_preserved_until_the_window_reloads(self):
        external = {**self.value, 'port': 9765}
        changed = json.dumps(external).encode()
        self.tls.config.write_bytes(changed)
        result = self.save({**self.value, 'port': 9876})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'ConfigurationChanged', result.stderr)
        self.assertEqual(self.tls.config.read_bytes(), changed)
        self.snapshot.write_bytes(changed)
        result = self.save({**external, 'contacts_phone_region': 'US'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.tls.config.read_bytes())['port'], 9765)

    def test_missing_configuration_can_be_created_but_never_clobbers_a_new_file(self):
        self.tls.config.unlink()
        result = self.save(new=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.tls.config.read_bytes()
        result = self.save({**self.value, 'port': 9876}, new=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'ConfigurationChanged', result.stderr)
        self.assertEqual(self.tls.config.read_bytes(), saved)

    def test_deleted_file_is_not_recreated_using_a_stale_snapshot(self):
        self.tls.config.unlink()
        result = self.save()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'ConfigurationChanged', result.stderr)
        self.assertFalse(self.tls.config.exists())

    def test_malformed_and_empty_files_can_be_repaired_with_exact_snapshot(self):
        for invalid in (b'{broken json', b''):
            with self.subTest(invalid=invalid):
                self.tls.config.write_bytes(invalid)
                self.snapshot.write_bytes(invalid)
                result = self.save()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.tls.config.read_bytes()), self.value)

    def test_symlink_and_hardlink_destinations_are_never_replaced(self):
        destination = self.tls.root / 'linked.json'
        destination.symlink_to(self.tls.config)
        result = self.save(destination=destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.is_symlink())
        destination.unlink()
        os.link(self.tls.config, destination)
        result = self.save(destination=destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.stat().st_ino, self.tls.config.stat().st_ino)
        self.assertEqual(self.tls.config.read_bytes(), self.original)

    def test_unsafe_parent_file_and_credentials_are_rejected(self):
        self.tls.config.chmod(0o644)
        result = self.save()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.tls.config.read_bytes(), self.original)
        self.tls.config.chmod(0o600)
        self.tls.root.chmod(0o755)
        self.assertNotEqual(self.save().returncode, 0)
        self.tls.root.chmod(0o700)
        key = self.tls.root / 'server-key.pem'
        key.chmod(0o644)
        self.assertNotEqual(self.save().returncode, 0)
        self.assertEqual(self.tls.config.read_bytes(), self.original)

    def test_symlink_parent_and_non_regular_destination_are_rejected(self):
        parent = self.root / 'link'
        parent.symlink_to(self.tls.root, target_is_directory=True)
        self.assertNotEqual(self.save(destination=parent / 'relay.json').returncode, 0)
        fifo = self.tls.root / 'pipe.json'
        os.mkfifo(fifo, 0o600)
        self.assertNotEqual(self.save(destination=fifo).returncode, 0)
        self.assertEqual(self.tls.config.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
