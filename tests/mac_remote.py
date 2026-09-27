#!/usr/bin/env python3
"""Exercise the SSH-side build helper with real Git and a simulated Mac builder."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

BUILDER = '''import os
from pathlib import Path
import subprocess
import sys

source = Path(__file__).resolve().parents[2]
assert not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain']).strip()
assert (source / 'source.txt').read_text() == 'committed source'
for name in ('ZIMBR_ZIG', 'ZIMBR_OPENSSL_LICENSE'):
    assert Path(os.environ[name]).read_bytes() == b'toolchain fixture'
assert Path(os.environ['ZIMBR_OPENSSL_PREFIX']).is_dir()
print('Build diagnostics belong on stderr of the SSH stream')
if os.environ.get('FAIL_REMOTE_BUILD'):
    sys.exit(1)
if sys.argv[1] == 'build':
    output = Path(sys.argv[sys.argv.index('--output') + 1])
    output.mkdir()
    (output / 'zimbr-relay-0.1.0-aarch64-macos.zip').write_bytes(b'archive bytes')
else:
    assert Path(sys.argv[2]).read_bytes() == b'archive bytes'
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == sys.argv[-1]
'''


class RemoteBuild(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-remote-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repository = self.root / 'Mac checkout'
        self.work = self.root / 'temporary builds'
        self.work.mkdir()
        commands = self.root / 'bin'
        commands.mkdir()
        self.env = {
            **os.environ,
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'Release Test',
            'GIT_AUTHOR_EMAIL': 'test@example.invalid',
            'GIT_COMMITTER_NAME': 'Release Test',
            'GIT_COMMITTER_EMAIL': 'test@example.invalid',
            'TMPDIR': str(self.work),
        }
        for name in ('ZIMBR_ZIG', 'ZIMBR_OPENSSL_PREFIX', 'ZIMBR_OPENSSL_LICENSE'):
            self.env.pop(name, None)
        self.git('init', '--initial-branch=main', str(self.repository))
        (self.repository / '.gitignore').write_text('.tools/\n__pycache__/\n')
        builder = self.repository / 'packaging/macos/release.py'
        builder.parent.mkdir(parents=True)
        builder.write_text(BUILDER)
        (self.repository / 'source.txt').write_text('committed source')
        self.git('-C', self.repository, 'add', '.')
        self.git('-C', self.repository, 'commit', '-m', 'fixture: Mac builder')
        self.revision = self.git('-C', self.repository, 'rev-parse', 'HEAD').strip()
        self.git('clone', '--bare', str(self.repository), str(self.root / 'upstream.git'))
        # Local edits and a different HEAD must not leak into the release build.
        (self.repository / 'source.txt').write_text('newer source')
        self.git('-C', self.repository, 'commit', '-am', 'fixture: newer checkout')
        (self.repository / 'source.txt').write_text('uncommitted source')
        self.original_head = self.git('-C', self.repository, 'rev-parse', 'HEAD')
        for name in ('.tools/zig-aarch64-macos-0.16.0/zig',
                     '.tools/openssl-build/openssl-3.5.8/LICENSE.txt'):
            tool = self.repository / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.write_bytes(b'toolchain fixture')
        (self.repository / '.tools/openssl-3.5').mkdir()

        # Only redirect the upstream URL; all Git operations remain real.
        real_git = shutil.which('git')
        wrapper = commands / 'git'
        wrapper.write_text(f'''#!{sys.executable}
import os
import sys
args = [{str(self.root / 'upstream.git')!r} if arg == 'https://github.com/hspak/zimbr.git'
        else arg for arg in sys.argv[1:]]
os.execv({real_git!r}, ['git', *args])
''')
        wrapper.chmod(0o755)
        self.env['PATH'] = f'{commands}:{os.environ["PATH"]}'

    def git(self, *args):
        return subprocess.check_output(['git', *map(str, args)], env=self.env,
                                       text=True, stderr=subprocess.PIPE)

    def build(self, **env):
        return subprocess.run(
            [sys.executable, '-', str(self.repository), '0.1.0', self.revision],
            input=(ROOT / 'packaging/macos/remote.py').read_bytes(),
            env={**self.env, **env}, capture_output=True,
        )

    def test_build_streams_only_archive_and_preserves_original_checkout(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b'archive bytes')
        self.assertIn(b'Build diagnostics', result.stderr)
        self.assertEqual((self.repository / 'source.txt').read_text(), 'uncommitted source')
        self.assertEqual(self.git('-C', self.repository, 'rev-parse', 'HEAD'), self.original_head)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_build_failure_emits_no_archive_and_cleans_temporary_checkout(self):
        result = self.build(FAIL_REMOTE_BUILD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'Build diagnostics', result.stderr)
        self.assertEqual((self.repository / 'source.txt').read_text(), 'uncommitted source')
        self.assertEqual(self.git('-C', self.repository, 'rev-parse', 'HEAD'), self.original_head)
        self.assertEqual(list(self.work.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
