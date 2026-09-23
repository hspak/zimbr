#!/bin/sh
# Install the already-built application into a user-controlled prefix.
set -eu
prefix=${1:-"$HOME/.local"}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
install -Dm755 "$root/zig-out/bin/zimbr" "$prefix/bin/zimbr"
install -Dm755 "$root/packaging/linux/provision.py" "$prefix/bin/zimbr-provision"
install -Dm644 "$root/packaging/linux/zimbr.svg" "$prefix/share/icons/hicolor/scalable/apps/zimbr.svg"
# Quote the absolute executable path so the launcher works without a modified PATH.
python3 - "$root/packaging/linux/zimbr.desktop" "$prefix/share/applications/zimbr.desktop" "$prefix/bin/zimbr" <<'PY'
import pathlib, sys
source, destination, executable = map(pathlib.Path, sys.argv[1:])
text = source.read_text().replace('Exec=zimbr', 'Exec="' + str(executable.absolute()).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"')
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text)
PY
printf 'Installed %s/bin/zimbr\n' "$prefix"
