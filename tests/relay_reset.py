#!/usr/bin/env python3
"""Exercise incompatible relay journals and the installer's explicit cache reset."""
import fcntl
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/macos'))
import install

BINARY = ROOT / 'zig-out/bin/fake-relay'
OLD_EPOCH = '00112233-4455-6677-8899-aabbccddeeff'


class RelayReset(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-relay-reset-', dir=ROOT / 'zig-out')
        self.addCleanup(temporary.cleanup)
        self.data = Path(temporary.name) / 'state'
        self.setup_relay()
        with closing(sqlite3.connect(self.data / 'relay.db')) as db:
            db.execute('UPDATE relay_meta SET epoch=?', (OLD_EPOCH,))
            db.commit()
        self.original = (self.data / 'relay.db').read_bytes()

    def setup_relay(self, success=True):
        result = subprocess.run([str(BINARY), 'setup', '--data-dir', str(self.data),
                                 '--messages-db', str(self.data.parent / 'source.db')],
                                capture_output=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result

    def test_old_epoch_is_rejected_without_changing_the_journal(self):
        result = self.setup_relay(success=False)
        self.assertNotEqual(result.returncode, 0, 'Relay accepted an old-format epoch')
        self.assertIn(b'RelayCacheResetRequired', result.stderr)
        with closing(sqlite3.connect(self.data / 'relay.db')) as db:
            self.assertEqual(db.execute('SELECT epoch FROM relay_meta').fetchone(), (OLD_EPOCH,))

    def test_reset_archives_wal_and_assets_then_creates_a_new_epoch(self):
        # Preserve a committed request record that exists only in a crash-left WAL.
        subprocess.run([sys.executable, '-c', '''
import os, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA journal_mode=WAL')
db.execute('CREATE TABLE old_send_history(id TEXT, outcome TEXT)')
db.execute("INSERT INTO old_send_history VALUES('old request', 'unknown')")
db.commit()
os._exit(0)
''', str(self.data / 'relay.db')], check=True)
        self.assertTrue((self.data / 'relay.db-wal').exists())
        assets = self.data / 'assets'
        assets.mkdir(mode=0o700)
        (assets / 'old-avatar').write_bytes(b'cached avatar')
        retained = self.data / 'tls'
        retained.mkdir(mode=0o700)
        (retained / 'key.pem').write_bytes(b'credential')
        (self.data / 'relay.json').write_bytes(b'configuration')
        backup = install.prepare_journal(self.data, reset=True)
        with closing(sqlite3.connect(backup / 'relay.db')) as db:
            self.assertEqual(db.execute('SELECT epoch FROM relay_meta').fetchone(), (OLD_EPOCH,))
            self.assertEqual(db.execute('SELECT * FROM old_send_history').fetchall(),
                             [('old request', 'unknown')])
        self.assertEqual((backup / 'original/assets/old-avatar').read_bytes(), b'cached avatar')
        for name in ('relay.db', 'relay.db-wal', 'relay.db-shm', 'relay.db-journal', 'assets'):
            self.assertFalse((self.data / name).exists(), name)
        self.assertEqual((retained / 'key.pem').read_bytes(), b'credential')
        self.assertEqual((self.data / 'relay.json').read_bytes(), b'configuration')
        self.setup_relay()
        with closing(sqlite3.connect(self.data / 'relay.db')) as db:
            epoch = db.execute('SELECT epoch FROM relay_meta').fetchone()[0]
            self.assertEqual(len(epoch), 22)
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone(), (0,))
            self.assertEqual(db.execute('SELECT count(*) FROM asset_sources').fetchone(), (0,))
        self.setup_relay()
        with closing(sqlite3.connect(self.data / 'relay.db')) as db:
            self.assertEqual(db.execute('SELECT epoch FROM relay_meta').fetchone(), (epoch,))

    def test_normal_update_preserves_journal_and_assets(self):
        assets = self.data / 'assets'
        assets.mkdir(mode=0o700)
        (assets / 'avatar').write_bytes(b'cached avatar')
        backup = install.prepare_journal(self.data)
        self.assertEqual((self.data / 'relay.db').read_bytes(), self.original)
        self.assertEqual((assets / 'avatar').read_bytes(), b'cached avatar')
        with closing(sqlite3.connect(backup / 'relay.db')) as db:
            self.assertEqual(db.execute('SELECT epoch FROM relay_meta').fetchone(), (OLD_EPOCH,))

    def test_cache_reset_preserves_issuer_and_provisioning(self):
        issuer = self.data / 'ca'
        issuer.mkdir(mode=0o700)
        originals = {
            issuer / 'rootCA-key.pem': b'CA signing key',
            issuer / 'rootCA.pem': b'CA certificate',
            issuer / 'zimbr-dedicated-ca': b'dedicated issuer',
            self.data / 'server.pem': b'server certificate',
            self.data / 'server-key.pem': b'server key',
            self.data / 'ca.pem': b'client trust',
            self.data / 'devices.json': b'enrolled devices',
            self.data / 'admin/ca.pem': b'administrative trust',
            self.data / 'admin/client.pem': b'administrative certificate',
            self.data / 'admin/client-key.pem': b'administrative key',
            self.data / 'admin.json': b'administrative endpoint',
        }
        for path, content in originals.items():
            path.parent.mkdir(mode=0o700, exist_ok=True)
            path.write_bytes(content)
            path.chmod(0o600)
        backup = install.prepare_journal(self.data, reset=True)
        self.setup_relay()
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertFalse(list(backup.rglob('rootCA-key.pem')))

    def test_running_relay_prevents_reset(self):
        with (self.data / 'relay.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, 'running'):
                install.prepare_journal(self.data, reset=True)
        self.assertEqual((self.data / 'relay.db').read_bytes(), self.original)
        self.assertFalse((self.data / 'backups').exists())

    def test_backup_symlink_is_rejected_before_reset(self):
        outside = self.data.parent / 'outside'
        outside.mkdir(mode=0o700)
        (self.data / 'backups').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            install.prepare_journal(self.data, reset=True)
        self.assertEqual((self.data / 'relay.db').read_bytes(), self.original)
        self.assertEqual(list(outside.iterdir()), [])

    def test_failed_archive_restores_moved_assets(self):
        assets = self.data / 'assets'
        assets.mkdir(mode=0o700)
        (assets / 'avatar').write_bytes(b'cached avatar')
        rename = Path.rename

        def fail_journal(path, target):
            if path == self.data / 'relay.db':
                raise OSError('injected rename failure')
            return rename(path, target)

        with patch.object(Path, 'rename', fail_journal):
            with self.assertRaisesRegex(OSError, 'injected'):
                install.prepare_journal(self.data, reset=True)
        self.assertEqual((self.data / 'relay.db').read_bytes(), self.original)
        self.assertEqual((assets / 'avatar').read_bytes(), b'cached avatar')


if __name__ == '__main__':
    unittest.main()
