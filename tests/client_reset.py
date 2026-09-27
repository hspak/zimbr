#!/usr/bin/env python3
"""Exercise the GUI executable's offline reset without opening a display."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/zimbr')
    parser.add_argument('--profile', choices=('dev', 'release'), default='dev')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = 'zimbr-dev' if args.profile == 'dev' else 'zimbr'
    other_directory = 'zimbr' if args.profile == 'dev' else 'zimbr-dev'
    with tempfile.TemporaryDirectory(prefix='zimbr-reset-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, HOME=str(root / 'home'), XDG_STATE_HOME=str(root / 'state'),
                   XDG_CONFIG_HOME=str(root / 'config'), WAYLAND_DISPLAY='unavailable', DISPLAY='')
        data = root / 'state' / directory
        data.mkdir(parents=True, mode=0o700)
        other = root / 'state' / other_directory
        other.mkdir(mode=0o700)
        (other / 'client.db').write_bytes(b'Other profile must survive')
        credentials = data / 'tls'
        credentials.mkdir(mode=0o700)
        for name in ('ca.pem', 'client.pem', 'client-key.pem'):
            path = credentials / name
            path.write_bytes(b'Offline reset must not require valid or current certificates')
            path.chmod(0o600)
        preserved = {path: path.read_bytes() for path in credentials.iterdir()}
        preserved[other / 'client.db'] = (other / 'client.db').read_bytes()
        (data / 'keep.txt').write_text('Unrelated file')
        preserved[data / 'keep.txt'] = (data / 'keep.txt').read_bytes()
        settings = ('https://offline.example:8731', str(credentials / 'ca.pem'),
                    str(credentials / 'client.pem'), str(credentials / 'client-key.pem'), 0)
        # Leave real WAL/SHM files behind, as after a crash before checkpointing.
        subprocess.run(['python3', '-c', '''
import json, os, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA journal_mode=WAL')
db.execute('CREATE TABLE settings(id INTEGER PRIMARY KEY, relay_url TEXT, ca_file TEXT, client_cert_file TEXT, client_key_file TEXT, enter_to_send INTEGER)')
db.execute('INSERT INTO settings VALUES(1,?,?,?,?,?)', json.loads(sys.argv[2]))
db.execute('CREATE TABLE obsolete_cache(private_text TEXT)')
db.execute("INSERT INTO obsolete_cache VALUES('old cached message')")
db.commit()
os._exit(0)
''', str(data / 'client.db'), json.dumps(settings)], check=True)
        assert (data / 'client.db-wal').exists()
        media = data / 'media'
        (media / 'nested').mkdir(parents=True)
        (media / ('a' * 64)).write_bytes(b'cached avatar')
        (media / 'nested' / 'image').write_bytes(b'cached image')
        (media / 'outside').symlink_to(credentials, target_is_directory=True)

        def reset(*extra, error=None):
            result = subprocess.run([str(binary), '--reset-cache', *extra], env=env,
                                    capture_output=True, timeout=10)
            if error:
                assert result.returncode != 0 and error.encode() in result.stderr, result.stderr
            else:
                assert result.returncode == 0 and b'Local database and media reset' in result.stderr, result.stderr
            return result

        def saved():
            with sqlite3.connect(data / 'client.db') as db:
                return db.execute('SELECT relay_url,ca_file,client_cert_file,client_key_file,enter_to_send FROM settings').fetchone()

        with (data / 'client.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_inode = (data / 'client.lock').stat().st_ino
            old_inode = (data / 'client.db').stat().st_ino
            reset(error='another client is already using this data directory')
            assert (media / ('a' * 64)).read_bytes() == b'cached avatar'
            assert (data / 'client.db').stat().st_ino == old_inode
        reset('--relay-url', 'https://temporary-override.example')
        assert not media.exists()
        assert (data / 'client.db').stat().st_ino != old_inode
        assert (data / 'client.lock').stat().st_ino == lock_inode
        assert stat.S_IMODE((data / 'client.db').stat().st_mode) == 0o600
        assert saved() == settings
        with sqlite3.connect(data / 'client.db') as db:
            assert db.execute("SELECT count(*) FROM sqlite_master WHERE name='obsolete_cache'").fetchone() == (0,)
            for table in ('records', 'drafts', 'outbox', 'identities', 'enrichment_cache', 'enrichment_pages', 'pages'):
                assert db.execute('SELECT count(*) FROM ' + table).fetchone() == (0,)
            assert db.execute("SELECT count(*) FROM meta WHERE key IN ('epoch','cursor','bootstrapped')").fetchone() == (0,)
        for suffix in ('-wal', '-shm', '-journal'):
            assert not (data / ('client.db' + suffix)).exists()
        assert not list(data.glob('.client-reset-*'))
        reset()
        assert saved() == settings
        # A media symlink is removed itself; its target and credentials survive.
        media.symlink_to(credentials, target_is_directory=True)
        reset()
        assert not media.is_symlink() and saved() == settings
        # A corrupt database can be reset even when settings cannot be recovered.
        (data / 'client.db').write_bytes(b'not a SQLite database')
        (data / 'client.db-journal').write_bytes(b'old rollback journal')
        result = reset()
        assert b'could not recover settings' in result.stderr
        assert saved() == ('', '', '', '', 1)
        assert not (data / 'client.db-journal').exists()
        # Replacing a database symlink must not open or change its target.
        (data / 'client.db').unlink()
        (data / 'client.db').symlink_to(other / 'client.db')
        reset()
        assert not (data / 'client.db').is_symlink()
        assert saved() == ('', '', '', '', 1)
        explicit = root / 'explicit'
        reset('--data-dir', str(explicit))
        assert (explicit / 'client.db').exists()
        for path, original in preserved.items():
            assert path.read_bytes() == original, path
    print('PASS: offline cache reset, real SQLite sidecars, saved settings, credentials, '
          'profile isolation, active-client lock, corrupt databases and symlink boundaries')


if __name__ == '__main__':
    main()
