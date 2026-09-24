#!/bin/bash
# Build and deploy the current checkout to this user's macOS LaunchAgent.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/update-relay.sh [--release=safe]

Build the relay and run its tests in ReleaseSafe, install the signed app using
the existing credentials/signing identity, restart it, and verify the running
executable. Run as the Mac login user, without sudo.

Defaults use the toolchain under .tools, falling back to zig/python3 on PATH.
Overrides: ZIMBR_ZIG, ZIMBR_PYTHON, ZIMBR_OPENSSL_PREFIX, ZIMBR_OPENSSL_LICENSE.
The current checkout is built, including local edits; no git update is performed.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --release=safe) shift ;;
esac
if [ "$#" -ne 0 ]; then usage >&2; exit 2; fi
if [ "$(uname -s)" != Darwin ]; then
  echo 'This script requires macOS.' >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo 'Run as the Mac login user, without sudo.' >&2
  exit 1
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo"
zig=${ZIMBR_ZIG:-"$repo/.tools/zig-aarch64-macos-0.16.0/zig"}
python=${ZIMBR_PYTHON:-"$repo/.tools/python/bin/python3"}
if [ -z "${ZIMBR_ZIG:-}" ] && [ ! -x "$zig" ]; then zig=zig; fi
if [ -z "${ZIMBR_PYTHON:-}" ] && [ ! -x "$python" ]; then python=python3; fi
openssl_prefix=${ZIMBR_OPENSSL_PREFIX:-"$repo/.tools/openssl-3.5"}
openssl_license=${ZIMBR_OPENSSL_LICENSE:-"$repo/.tools/openssl-build/openssl-3.5.8/LICENSE.txt"}
if [ "$("$zig" version)" != "$(cat .zigversion)" ]; then
  echo "Expected Zig $(cat .zigversion); set ZIMBR_ZIG to that compiler." >&2
  exit 1
fi
command -v "$python" >/dev/null
for required in "$openssl_prefix/lib/libssl.a" "$openssl_prefix/lib/libcrypto.a" "$openssl_license"; do
  if [ ! -f "$required" ]; then echo "Missing required file: $required" >&2; exit 1; fi
done

# A fresh prefix prevents stale binaries or licenses from a previous build
# being installed. The compiler cache still avoids unnecessary compilation.
mkdir -p "$repo/zig-out"
build_dir=$(mktemp -d "$repo/zig-out/relay-release-safe.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
revision=$(git describe --always --dirty)
printf 'Building relay %s with --release=safe\n' "$revision"
"$zig" build relay test test-macos-enrichment --release=safe \
  "-Dopenssl-prefix=$openssl_prefix" --prefix "$build_dir" \
  --cache-dir "$repo/.tools/zig-cache" --global-cache-dir "$repo/.tools/cache" \
  --summary all

# install.py signs/validates before stopping the old process, backs up the
# journal, waits for process exit, then bootstraps and checks the new listener.
"$python" packaging/macos/install.py --install --start \
  --binary "$build_dir/bin/relay" --image-helper "$build_dir/bin/image-helper" \
  --phone-license "$build_dir/share/zimbr/licenses/libPhoneNumber-LICENSE" \
  --openssl-license "$openssl_license"

"$python" - "$repo" "$build_dir" "$revision" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

repo, build = map(Path, sys.argv[1:3])
sys.path.insert(0, str(repo / 'packaging/macos'))
from install import LABEL, service_pid

installed = Path.home() / 'Applications/Zimbr Relay.app/Contents/MacOS'
staged = repo / 'zig-out/macos/Zimbr Relay.app/Contents/MacOS'
service = f'gui/{os.getuid()}/{LABEL}'

def fail(message):
    raise SystemExit('Deployment verification failed: ' + message)

def uuids(path):
    output = subprocess.check_output(['/usr/bin/dwarfdump', '--uuid', str(path)], text=True)
    values = re.findall(r'^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output, re.M)
    if not values:
        fail(f'No Mach-O UUID for {path}')
    return sorted(values)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for name in ('relay', 'image-helper'):
    # Signing changes file bytes, but preserves the Mach-O build UUID.
    if uuids(build / 'bin' / name) != uuids(installed / name):
        fail(f'Installed {name} does not match the new build UUID')
    if digest(staged / name) != digest(installed / name):
        fail(f'Installed {name} differs from the signed staging copy')

pid = service_pid(service)
if pid is None:
    fail('LaunchAgent has no running PID')
# Check the mapped executable's inode as well as its path, so an old process
# still mapping a replaced file cannot satisfy verification.
output = subprocess.check_output(
    ['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-F', 'fin'], text=True)
files = []
entry = {}
for line in output.splitlines():
    if line.startswith('f'):
        files.append(entry)
        entry = {}
    elif line[:1] in ('i', 'n'):
        entry[line[0]] = line[1:]
files.append(entry)
binary = installed / 'relay'
if not any(f.get('n') == str(binary) and f.get('i') == str(binary.stat().st_ino) for f in files):
    fail('LaunchAgent PID is not mapping the installed relay executable')
if service_pid(service) != pid:
    fail('LaunchAgent restarted during verification; inspect the relay log')

print(f'Verified ReleaseSafe relay {sys.argv[3]}: PID {pid}')
print(f'Executable: {binary}')
print(f'Signed SHA-256: {digest(binary)}')
PY
