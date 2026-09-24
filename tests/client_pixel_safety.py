#!/usr/bin/env python3
"""Compare sanitized pixel paths with the security-pass baseline; synthetic data only."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='1aa4f0b621091726db1ba35e02df0fff0db0d669', help='Git revision before the performance changes')
    args = parser.parse_args()
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libcurl', 'openssl', 'pangocairo', 'gio-2.0', 'libpng', 'libjpeg'], text=True))
    env = os.environ.copy()
    # Font libraries keep process-global caches. Check bounds and undefined
    # behavior here; persistent third-party caches are not a leak test.
    env['ASAN_OPTIONS'] = 'detect_leaks=0:halt_on_error=1'
    env['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'
    with tempfile.TemporaryDirectory(prefix='zimbr-pixel-safety-build-') as temporary:
        root = Path(temporary)
        before = root/'before'
        before.mkdir()
        for file in ['bridge.c', 'media.c']:
            (before/file).write_bytes(subprocess.check_output(['git', 'show', args.baseline+':src/client/'+file], cwd=ROOT))
        outputs = []
        for name, source in [('before', before), ('after', ROOT/'src/client')]:
            binary = root/name if name == 'after' else root/'baseline'
            subprocess.run([os.environ.get('CC', 'clang'), '-O2', '-march=native', '-g', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer',
                            '-I', str(ROOT/'src'), '-I', str(ROOT/'src/client'), str(ROOT/'tests/client_pixel_safety.c'),
                            str(source/'bridge.c'), str(source/'media.c'), str(ROOT/'src/platform.c'), *flags, '-lm', '-o', str(binary)], check=True)
            output = subprocess.check_output([str(binary)], env=env, text=True, timeout=180).strip()
            outputs.append(output)
            print(name+': '+output, flush=True)
        if outputs[0] != outputs[1]:
            raise RuntimeError('Pixel output or rejection behavior changed from the security baseline')
        print('PASS: ASan/UBSan pixel checks match the security baseline')


if __name__ == '__main__':
    main()
