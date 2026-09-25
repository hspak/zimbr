#!/usr/bin/env python3
"""Exercise release ordering and retries with local Git remotes and fake services."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.1.0'
PACKAGE = f'zimbr-{VERSION}-1-x86_64.pkg.tar.zst'

# Git remains real; external services and the expensive compiler/package builder
# are replaced so failure paths cannot publish anything outside the fixture.
FAKE_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

root = Path(os.environ['ZIMBR_RELEASE_TEST'])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'events').open('a') as events:
    events.write(json.dumps([tool, *args]) + '\n')
if tool == 'zig':
    sys.exit(1 if os.environ.get('FAIL_ZIG') else 0)
if tool == 'curl':
    shutil.copyfile(root / 'release.tar.gz', args[args.index('--output') + 1])
elif tool == 'makepkg':
    if '--printsrcinfo' in args:
        print('pkgbase = zimbr\n\tpkgver = 0.1.0\npkgname = zimbr')
    elif '--packagelist' in args:
        print(Path(os.environ['PKGDEST']) / 'zimbr-0.1.0-1-x86_64.pkg.tar.zst')
    else:
        if os.environ.get('FAIL_PACKAGE'):
            sys.exit(1)
        with tarfile.open('zimbr-0.1.0.tar.gz') as archive:
            (root / 'snapshot.json').write_text(json.dumps(archive.getnames()))
            if 'zimbr-0.1.0/dirty.txt' in archive.getnames():
                (root / 'snapshot-dirty').write_bytes(
                    archive.extractfile('zimbr-0.1.0/dirty.txt').read())
        (Path(os.environ['PKGDEST']) / 'zimbr-0.1.0-1-x86_64.pkg.tar.zst').write_bytes(b'package')
elif tool == 'gh':
    state = root / 'draft'
    if args[:2] == ['auth', 'status']:
        pass
    elif args[:2] == ['repo', 'view']:
        print('hspak/zimbr')
    elif args[:2] == ['release', 'view']:
        if not state.exists():
            sys.exit(1)
        print(state.read_text())
    elif args[:2] == ['release', 'create']:
        assert '--draft' in args
        subprocess.run(['git', '--git-dir', str(root / 'source.git'),
                        'rev-parse', '--verify', 'refs/tags/0.1.0'], check=True)
        state.write_text('true')
    elif args[:2] == ['release', 'edit']:
        if '--draft=false' in args:
            # Publishing must happen after the package metadata reaches the AUR.
            recipe = subprocess.check_output([
                'git', '--git-dir', str(root / 'aur.git'), 'show', 'master:PKGBUILD'])
            assert b'_ref=0.1.0\n' in recipe
            state.write_text('false')
    else:
        raise AssertionError(args)
else:
    raise AssertionError(tool)
'''


class Release(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zimbr-release-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source'
        self.aur = self.root / 'aur'
        self.env = {
            **os.environ,
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'Release Test',
            'GIT_AUTHOR_EMAIL': 'test@example.invalid',
            'GIT_COMMITTER_NAME': 'Release Test',
            'GIT_COMMITTER_EMAIL': 'test@example.invalid',
            'ZIMBR_RELEASE_TEST': str(self.root),
            'ZIMBR_AUR_DIR': str(self.aur),
            'TMPDIR': str(self.root),
        }
        for repo, branch in ((self.source, 'main'), (self.aur, 'master')):
            self.git(self.root, 'init', '--bare', f'--initial-branch={branch}', f'{repo}.git')
            self.git(self.root, 'init', f'--initial-branch={branch}', str(repo))
            self.git(repo, 'remote', 'add', 'origin', f'{repo}.git')
        shutil.copy2(ROOT / 'release.sh', self.source / 'release.sh')
        (self.source / 'build.zig.zon').write_text('.{\n    .version = "0.1.0",\n}\n')
        (self.source / '.gitignore').write_text('zig-out/\n*.key\n')
        self.git(self.source, 'add', '.')
        self.git(self.source, 'commit', '-m', 'fixture: create release source')
        self.git(self.source, 'push', '-u', 'origin', 'main')
        subprocess.run([
            'git', '-C', str(self.source), 'archive', '--format=tar.gz',
            '--prefix=zimbr-0.1.0/', f'--output={self.root / "release.tar.gz"}', 'HEAD',
        ], check=True, env=self.env)
        self.initial_recipe = 'pkgver=0.0.0\npkgrel=3\n_ref=old\nsha256sums=("old")\n'
        (self.aur / 'PKGBUILD').write_text(self.initial_recipe)
        commands = self.root / 'bin'
        commands.mkdir()
        for name in ('gh', 'curl', 'zig', 'makepkg'):
            script = commands / name
            script.write_text(FAKE_TOOL)
            script.chmod(0o755)
        self.env['PATH'] = f'{commands}:{os.environ["PATH"]}'

    def git(self, repo, *args):
        return subprocess.check_output(
            ['git', '-C', str(repo), *args], env=self.env, stderr=subprocess.PIPE,
            text=True,
        ).strip()

    def release(self, *args, **env):
        return subprocess.run(
            ['bash', str(self.source / 'release.sh'), VERSION, *args],
            env={**self.env, **env}, capture_output=True, text=True,
        )

    def events(self):
        return [json.loads(line) for line in (self.root / 'events').read_text().splitlines()]

    def assert_no_remote_tag(self):
        self.assertEqual(self.git(self.source, 'ls-remote', 'origin', 'refs/tags/*'), '')

    def test_compiler_failure_leaves_no_tag_or_draft(self):
        result = self.release(FAIL_ZIG='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_remote_tag()
        self.assertFalse((self.root / 'draft').exists())
        self.assertEqual((self.aur / 'PKGBUILD').read_text(), self.initial_recipe)

    def test_package_failure_can_resume_without_publishing_early(self):
        result = self.release(FAIL_PACKAGE='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'draft').read_text(), 'true')
        self.assertEqual((self.aur / 'PKGBUILD').read_text(), self.initial_recipe)
        self.assertEqual(self.git(self.aur, 'ls-remote', 'origin', 'refs/heads/master'), '')
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'draft').read_text(), 'false')
        recipe = self.git(self.root / 'aur.git', 'show', 'master:PKGBUILD')
        checksum = hashlib.sha256((self.root / 'release.tar.gz').read_bytes()).hexdigest()
        self.assertIn(f'sha256sums=("{checksum}")', recipe)
        self.assertIn('_ref=0.1.0', recipe)
        self.assertIn('pkgrel=1', recipe)
        self.assertIn('pkgname = zimbr', self.git(self.root / 'aur.git', 'show', 'master:.SRCINFO'))
        self.assertEqual(self.git(self.aur, 'status', '--porcelain'), '')
        self.assertEqual(self.events()[-1], [
            'gh', 'release', 'edit', VERSION, '--repo', 'hspak/zimbr', '--draft=false',
        ])

    def test_aur_push_failure_keeps_release_draft(self):
        hook = self.root / 'aur.git/hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'draft').read_text(), 'true')
        self.assertEqual(self.git(self.aur, 'ls-remote', 'origin', 'refs/heads/master'), '')

    def test_check_packages_dirty_checkout_without_publishing(self):
        (self.source / 'dirty.txt').write_text('current artwork')
        (self.source / 'private.key').write_text('ignored fixture')
        result = self.release('--check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.source / 'zig-out/release' / PACKAGE).read_bytes(), b'package')
        self.assertEqual((self.root / 'snapshot-dirty').read_text(), 'current artwork')
        self.assertNotIn('zimbr-0.1.0/private.key', json.loads((self.root / 'snapshot.json').read_text()))
        self.assertEqual({event[0] for event in self.events()}, {'makepkg'})
        self.assertEqual((self.aur / 'PKGBUILD').read_text(), self.initial_recipe)
        self.assert_no_remote_tag()

    def test_unpushed_source_is_rejected_before_tagging(self):
        self.git(self.source, 'commit', '--allow-empty', '-m', 'fixture: unpushed change')
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('HEAD matches origin/main', result.stderr)
        self.assert_no_remote_tag()
        self.assertFalse((self.root / 'events').exists())


if __name__ == '__main__':
    unittest.main()
