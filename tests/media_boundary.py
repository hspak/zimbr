"""Exercise the helper process boundary without decoding or accessing real media."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-media-boundary-') as temporary:
        root = Path(temporary).resolve()
        binary = root / 'media-boundary'
        subprocess.run([
            'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
            str(ROOT / 'tests/media_boundary.c'), str(ROOT / 'src/relay/media.c'),
            '-o', str(binary),
        ], check=True)
        subprocess.run([str(binary), str(binary), str(root / 'source'), str(root / 'output')],
                       check=True, timeout=15)


if __name__ == '__main__':
    main()
