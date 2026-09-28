#!/usr/bin/env python3
"""Package-only setup with real mkcert/validation; simulate SSH and macOS services.

Build relay first. No source files are available to the copied package helpers.
ZIMBR_PROVISION_SCRIPT can select the pre-fix helper for the regression check.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from cryptography import x509
from cryptography.hazmat.primitives import hashes

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'packaging/macos'))
import bundle
from profiles import PROFILES


class Bootstrap(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-bootstrap-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.mac = self.root/'mac'
        self.linux = self.root/'linux'
        self.linux.mkdir(mode=0o700)
        self.bin = self.root/'bin'
        self.bin.mkdir()
        self.app = PROFILES['release'].app(self.mac)
        for name in ('relay', 'image-helper', 'openssl-license', 'phone-license'):
            (self.root/name).write_text('fixture')
        with mock.patch.object(bundle.subprocess, 'check_output', side_effect=lambda command, **kw:
                               json.dumps(PROFILES['release'].__dict__) if command[-1] == 'profile'
                               else 'binary:\n /usr/lib/libSystem.B.dylib\n'), mock.patch.object(bundle, 'sign'):
            bundle.stage(self.app, *(self.root/name for name in
                                    ('relay', 'image-helper', 'openssl-license', 'phone-license')),
                         profile=PROFILES['release'])
        self.resources = self.app/'Contents/Resources'
        # The relay profile is release; configuration validation executes the native relay.
        relay = self.app/'Contents/MacOS/relay'
        self.script(relay, f'''import json, os, sys
if sys.argv[1] == 'profile': print({json.dumps(PROFILES['release'].__dict__)!r})
else: os.execv({str(ROOT/'zig-out/bin/relay')!r}, ['relay', *sys.argv[1:]])
''')
        service = self.resources/'zimbr-relay-service'
        self.script(service, f'''import os, pathlib, plistlib
home = pathlib.Path.home()
data = home/'Library/Application Support/Zimbr'
agent = home/'Library/LaunchAgents/com.hsp.zimbr.relay.plist'
agent.parent.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({{'ProgramArguments': [{str(relay)!r}, 'serve', '--config', str(data/'relay.json')]}}))
''')
        self.driver = self.root/'mac-driver'
        self.script(self.driver, f'''import argparse, os, sys
sys.path.insert(0, {str(self.resources)!r})
import bootstrap, tls_admin
bootstrap.pid_of_service = lambda profile: 123
bootstrap.listener_ready = lambda config, pid: True
def restart(config, profile):
    if os.environ.get('FAIL_RESTART'): raise RuntimeError('fixture restart rejected')
    return {{'restart_complete': True, 'pid': 123}}
tls_admin.restart = restart
os.umask(0o077)
if sys.argv[1] == 'setup':
    bootstrap.bootstrap(argparse.Namespace(profile='release', server_name='localhost',
                                           listen_address='127.0.0.1', port=8731))
else:
    sys.argv = ['zimbr-relay-admin', 'issue-ssh', '--profile', 'release']
    tls_admin.main()
''')
        self.script(self.bin/'ssh', f'''import json, os, subprocess, sys
assert sys.argv[1:6] == ['-T', '-o', 'StrictHostKeyChecking=ask', '--', 'mac-alias']
assert sys.argv[6] == 'exec "$HOME/Applications/Zimbr Relay.app/Contents/Resources/zimbr-relay-admin" issue-ssh'
request = sys.stdin.read()
with open({str(self.root/'ssh-requests')!r}, 'a') as log: log.write(request + '\\n')
result = subprocess.run([{str(self.driver)!r}, 'issue-ssh'], input=request, text=True,
                        stdout=subprocess.PIPE, env=dict(os.environ, HOME={str(self.mac)!r}))
if result.returncode: sys.exit(result.returncode)
response = json.loads(result.stdout)
if os.environ.get('BAD_ENDPOINT'): response['relay_url'] = 'http://attacker.example'
if os.environ.get('BAD_CERT'): response['cert'] = response['ca']
print(json.dumps(response))
''')
        self.script(self.bin/'zimbr', f'''import json, pathlib, sys
if sys.argv[1:] == ['--help']: print('Profile: release\\n--save-connection')
else: pathlib.Path({str(self.root/'launch.json')!r}).write_text(json.dumps(sys.argv[1:]))
''')
        source = Path(os.environ.get('ZIMBR_PROVISION_SCRIPT', ROOT/'packaging/linux/provision.py'))
        shutil.copy2(source, self.bin/'zimbr-provision')
        (self.bin/'zimbr-provision').chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.linux), XDG_CONFIG_HOME=str(self.linux/'config'),
                        PATH=str(self.bin)+os.pathsep+os.environ['PATH'], PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('PYTHONPATH', None)
        result = subprocess.run([str(self.driver), 'setup'], env=dict(self.env, HOME=str(self.mac)),
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.tls = self.linux/'config/zimbr/tls'
        self.data = PROFILES['release'].data(self.mac)

    def script(self, path, body):
        path.write_text(f'#!{sys.executable}\n'+body)
        path.chmod(0o755)

    def provision(self, **env):
        return subprocess.run([str(self.bin/'zimbr-provision'), 'setup', 'mac-alias',
                               '--label', 'Desktop; $(must-not-run)'], env=dict(self.env, **env),
                              cwd=self.root, capture_output=True, text=True, timeout=30)

    def test_package_only_setup_and_retries_preserve_identity(self):
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        launch = json.loads((self.root/'launch.json').read_text())
        self.assertEqual(launch, ['--save-connection', '--relay-url', 'https://localhost:8731',
                                 '--ca-file', str(self.tls/'ca.pem'), '--client-cert-file', str(self.tls/'client.pem'),
                                 '--client-key-file', str(self.tls/'client-key.pem')])
        originals = {name: (self.tls/name).read_bytes() for name in ('client-key.pem', 'client.csr', 'client.pem')}
        config = json.loads((self.data/'relay.json').read_text())
        devices = Path(config['device_allowlist_file'])
        before = devices.read_bytes()
        self.assertEqual(len(json.loads(before)), 2)
        cert = x509.load_pem_x509_certificate(originals['client.pem'])
        self.assertEqual(json.loads(before)[1]['sha256'], cert.fingerprint(hashes.SHA256()).hex())
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(devices.read_bytes(), before)
        for name, content in originals.items():
            self.assertEqual((self.tls/name).read_bytes(), content)
        for line in (self.root/'ssh-requests').read_text().splitlines():
            request = json.loads(line)
            self.assertEqual(set(request), {'schema', 'csr', 'name', 'label'})
            self.assertNotIn('PRIVATE KEY', line)
        for path in self.tls.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.linux.rglob('rootCA-key.pem')))
        self.assertFalse(list(self.app.rglob('*.pem')))
        self.assertFalse(list(self.app.rglob('__pycache__')))
        original_server = Path(config['server_key_file']).read_bytes()
        again = subprocess.run([str(self.driver), 'setup'], env=dict(self.env, HOME=str(self.mac)),
                               capture_output=True, text=True)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(Path(config['server_key_file']).read_bytes(), original_server)
        self.assertEqual(devices.read_bytes(), before)

    def test_failed_restart_returns_no_credentials_and_retry_reuses_the_csr(self):
        result = self.provision(FAIL_RESTART='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.tls/'client.pem').exists())
        self.assertFalse((self.root/'launch.json').exists())
        key = (self.tls/'client-key.pem').read_bytes()
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tls/'client-key.pem').read_bytes(), key)
        config = json.loads((self.data/'relay.json').read_text())
        self.assertEqual(len(json.loads(Path(config['device_allowlist_file']).read_text())), 2)

    def test_brew_symlinks_launch_bundled_helpers_with_the_dependency_python(self):
        # PlistBuddy is the only macOS-specific operation in this launcher.
        buddy = self.bin/'PlistBuddy'
        self.script(buddy, "print('release')\n")
        prefix = self.root/'brew prefix'
        python = prefix/'opt/python@3.14/bin/python3.14'
        python.parent.mkdir(parents=True)
        self.script(python, f'''import os, sys
assert os.environ['ZIMBR_PROFILE'] == 'release'
assert os.environ['PYTHONDONTWRITEBYTECODE'] == '1'
assert sys.argv[1].startswith({str(self.resources)!r})
os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])
''')
        self.script(self.bin/'brew', f"print({str(prefix)!r})\n")
        for suffix in ('setup', 'admin'):
            helper = self.resources/f'zimbr-relay-{suffix}'
            helper.write_text(helper.read_text().replace('/usr/libexec/PlistBuddy', str(buddy)))
            alias = self.bin/helper.name
            alias.symlink_to(helper)
            environment = dict(self.env)
            environment.pop('ZIMBR_PYTHON', None)
            result = subprocess.run([str(alias), '--help'], env=environment, cwd=self.root,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('usage:', result.stdout)
        self.assertFalse(list(self.app.rglob('__pycache__')))

    def test_interrupted_request_preserves_the_private_key(self):
        self.tls.parent.mkdir(parents=True, mode=0o700)
        result = subprocess.run([str(self.bin/'zimbr-provision'), 'request', '--tls-dir', str(self.tls),
                                 '--name', 'desktop.zimbr.invalid'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = (self.tls/'client-key.pem').read_bytes()
        (self.tls/'client.csr').unlink()
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tls/'client-key.pem').read_bytes(), key)
        self.assertTrue((self.root/'launch.json').exists())

    def test_invalid_response_cannot_replace_credentials_or_launch_client(self):
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        originals = {name: (self.tls/name).read_bytes() for name in ('ca.pem', 'client.pem', 'client-key.pem')}
        (self.root/'launch.json').unlink()
        for variable in ('BAD_ENDPOINT', 'BAD_CERT'):
            with self.subTest(variable=variable):
                result = self.provision(**{variable: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root/'launch.json').exists())
                for name, content in originals.items():
                    self.assertEqual((self.tls/name).read_bytes(), content)


if __name__ == '__main__':
    unittest.main(verbosity=2)
