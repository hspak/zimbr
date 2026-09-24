"""Permission-only child contract: no HOME, configuration, output, or prompt."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    binaries = [('fake-relay', {104})]
    if sys.platform == 'darwin':
        binaries.append(('relay', set(range(100, 105))))
    for name, expected in binaries:
        result = subprocess.run(
            [str(ROOT / 'zig-out/bin' / name), 'contacts-permission-status'],
            env={}, capture_output=True, timeout=5,
        )
        assert result.returncode in expected, (name, result.returncode)
        assert not result.stdout and not result.stderr, name
        reader = subprocess.run(
            [str(ROOT / 'zig-out/bin' / name), 'contacts-reader'],
            env={}, capture_output=True, timeout=5,
        )
        assert reader.returncode == 105, (name, reader.returncode)
        assert not reader.stdout and not reader.stderr, name
    print('PASS: permission child returns only a bounded status without environment or configuration')


if __name__ == '__main__':
    main()
