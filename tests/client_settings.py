#!/usr/bin/env python3
"""Client settings migration, restart persistence, overrides and state paths."""
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile

from client_tls import server
from tls_fixture import PKI, private_write

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/client-probe'


def run(env, *args, error=None):
    result = subprocess.run([str(BIN), *args], env=env, capture_output=True, timeout=10)
    if error:
        assert result.returncode != 0 and error.encode() in result.stderr, result.stderr.decode()
    else:
        assert result.returncode == 0 and b'Connected:' in result.stderr, result.stderr.decode()
    return result


def saved(path):
    with sqlite3.connect(path / 'client.db') as db:
        return db.execute('SELECT relay_url,ca_file,client_cert_file,client_key_file,enter_to_send '
                          'FROM settings WHERE id=1').fetchone()


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-settings-') as temp:
        root = Path(temp)
        env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
                   XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'unused'))
        run(env, error='InvalidRelayOrigin')
        default = root / 'state/zimbr'
        assert saved(default) == ('', '', '', '', 1)
        assert stat.S_IMODE(default.stat().st_mode) == 0o700
        assert stat.S_IMODE((default / 'client.db').stat().st_mode) == 0o600
        assert not (root / 'unused').exists()
        for state in ('', 'relative/path'):
            run(dict(env, XDG_STATE_HOME=state), error='InvalidRelayOrigin')
            assert (root / 'home/.local/share/zimbr/client.db').exists()
        no_state = dict(env)
        no_state.pop('XDG_STATE_HOME')
        run(no_state, error='InvalidRelayOrigin')
        no_home = dict(env)
        no_home.pop('HOME')
        run(no_home, error='InvalidRelayOrigin')
        no_home.pop('XDG_STATE_HOME')
        explicit = root / 'explicit'
        run(no_home, '--data-dir', str(explicit), error='InvalidRelayOrigin')
        assert saved(explicit) == ('', '', '', '', 1)
        run(no_home, error='HomeRequired')

        pki = PKI(root / 'tls')
        srv = server(pki)
        try:
            conf = root / 'config/zimbr'
            conf.mkdir(parents=True, mode=0o700)
            legacy = conf / 'config.json'
            preferences = dict(relay_url=f'https://localhost:{srv.server_port}',
                               ca_file=str(pki.root / 'ca.pem'),
                               client_cert_file=str(pki.root / 'client.pem'),
                               client_key_file=str(pki.root / 'client-key.pem'),
                               enter_to_send=False, data_dir=str(root / 'obsolete'), theme='light')
            private_write(legacy, json.dumps(preferences).encode())
            migrated = root / 'migrated'
            args = ('--data-dir', str(migrated))
            run(env, *args)
            expected = tuple(preferences[key] for key in (
                'relay_url', 'ca_file', 'client_cert_file', 'client_key_file', 'enter_to_send'))
            assert saved(migrated) == expected
            assert not (root / 'obsolete').exists()
            # Later legacy changes, unsafe permissions and deletion cannot replace DB settings.
            legacy.write_text('{ invalid json')
            legacy.chmod(0o644)
            run(env, *args)
            legacy.unlink()
            run(env, *args)
            # Even an explicitly empty override must win over a saved value for this launch.
            run(env, *args, '--relay-url', '', error='InvalidRelayOrigin')
            run(env, *args, '--relay-url', 'http://invalid.example', error='InvalidRelayOrigin')
            run(env, *args, '--client-key-file', 'relative.pem', error='CredentialPathsRequired')
            assert saved(migrated) == expected
            run(env, *args)
            # Fresh databases can recover from malformed, obsolete and unsafe legacy files.
            for name, raw, mode, reason in (
                ('malformed', b'{', 0o600, 'UnexpectedEndOfInput'),
                ('obsolete', b'{"token_file":"old"}', 0o600, 'ObsoleteTransportConfiguration'),
                ('unsafe', json.dumps(preferences).encode(), 0o644, 'UnsafeConfiguration'),
            ):
                private_write(legacy, raw)
                legacy.chmod(mode)
                path = root / name
                result = run(env, '--data-dir', str(path), error='InvalidRelayOrigin')
                assert reason.encode() in result.stderr, result.stderr.decode()
                assert saved(path) == ('', '', '', '', 1)
                # Import is attempted only once, even if that file is repaired later.
                private_write(legacy, json.dumps(preferences).encode())
                run(env, '--data-dir', str(path), error='InvalidRelayOrigin')
            legacy.unlink()
        finally:
            srv.close()
    print('PASS: settings migration, persistence, temporary overrides and state directory precedence')


if __name__ == '__main__':
    main()
