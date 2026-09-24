#!/usr/bin/env python3
"""Compare complete client operations, three alternating pairs; synthetic data only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path, help='Directory containing baseline bridge.c and media.c')
    parser.add_argument('--candidate', type=Path, default=ROOT/'src/client')
    parser.add_argument('--case', choices=['raster', 'jpeg', 'layout'], required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    packages = ['libcurl', 'openssl', 'pangocairo', 'gio-2.0', 'libpng', 'libjpeg']
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', *packages], text=True))
    versions = subprocess.check_output(['pkg-config', '--modversion', *packages], text=True).splitlines()
    env = os.environ.copy()
    env.setdefault('ZIG_GLOBAL_CACHE_DIR', '/tmp/zimbr-zig-cache')
    env.setdefault('ZIG_LOCAL_CACHE_DIR', '/tmp/zimbr-build-cache')
    sources = {'before': args.baseline.resolve(), 'after': args.candidate.resolve()}
    checksums = {}
    runs = []
    with tempfile.TemporaryDirectory(prefix='zimbr-client-simd-') as temporary:
        root = Path(temporary)
        for name, source in sources.items():
            subprocess.run(['zig', 'cc', '-O3', '-march=native', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT/'src'), '-I', str(ROOT/'src/client'),
                            str(ROOT/'tests/client_simd_bench.c'), str(source/'bridge.c'), str(source/'media.c'),
                            str(ROOT/'src/platform.c'), *flags, '-lm', '-o', str(root/name)], env=env, check=True)
            checksums[name] = {file: hashlib.sha256((source/file).read_bytes()).hexdigest() for file in ['bridge.c', 'media.c']}
        for pair in range(3):
            run = {}
            for name in (['before', 'after'] if pair % 2 == 0 else ['after', 'before']):
                print(f'Pair {pair+1}: {name} {args.case}', flush=True)
                output = subprocess.check_output([str(root/name), args.case], env=env, text=True, timeout=180)
                run[name] = {value['case']: value for value in map(json.loads, output.splitlines())}
            for case in run['before']:
                if run['before'][case]['checksum'] != run['after'][case]['checksum']:
                    raise RuntimeError(f'Output changed: {case}')
            runs.append(run)
    comparison = {}
    for case in runs[0]['before']:
        values = {name: statistics.median(run[name][case]['p50_us'] for run in runs) for name in sources}
        values['reduction_percent'] = round((1-values['after']/values['before'])*100, 2)
        values['pair_reductions_percent'] = [round((1-run['after'][case]['p50_us']/run['before'][case]['p50_us'])*100, 2) for run in runs]
        comparison[case] = values
    report = {'case': args.case, 'build': 'Zig cc -O3 -march=native', 'pairs': 3, 'batches_per_process': 15,
              'compiler_version': subprocess.check_output(['zig', 'version'], text=True).strip(),
              'platform': platform.platform(), 'libraries': dict(zip(packages, versions)),
              'comparison_statistic': 'median of three per-process medians, microseconds per complete operation',
              'equal_output': True, 'source_sha256': checksums, 'comparison': comparison, 'runs': runs}
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(comparison, indent=2))


if __name__ == '__main__':
    main()
