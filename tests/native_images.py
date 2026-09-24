#!/usr/bin/env python3
"""Generate synthetic native image fixtures without account or Contacts access."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    if sys.platform != 'darwin':
        raise SystemExit('ImageIO runtime verification requires macOS')
    with tempfile.TemporaryDirectory(prefix='zimbr-native-images-') as temporary:
        root = Path(temporary).resolve()
        binary = root / 'native-images'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/native_images.m'), str(ROOT / 'src/relay/media.c'),
                        '-framework', 'Foundation', '-framework', 'ImageIO', '-framework', 'CoreGraphics',
                        '-lz', '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(ROOT / 'zig-out/bin/image-helper'),
                        str(ROOT / 'zig-out/bin/fake-image-helper'), str(root)], check=True, timeout=60)


if __name__ == '__main__':
    main()
