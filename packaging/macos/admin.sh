#!/bin/bash
# Resolve Homebrew symlinks and use its Python even in a minimal SSH environment.
set -euo pipefail
script=${BASH_SOURCE[0]}
while [[ -L $script ]]; do
  directory=$(cd -- "$(dirname -- "$script")" && pwd)
  script=$(readlink "$script")
  [[ $script == /* ]] || script=$directory/$script
done
resources=$(cd -- "$(dirname -- "$script")" && pwd)
export ZIMBR_PROFILE=$(/usr/libexec/PlistBuddy -c 'Print :ZimbrProfile' "$resources/../Info.plist")
export PYTHONDONTWRITEBYTECODE=1
if [[ -n ${ZIMBR_PYTHON:-} ]]; then
  python=$ZIMBR_PYTHON
else
  brew=$(command -v brew || true)
  [[ -n $brew ]] || brew=/opt/homebrew/bin/brew
  prefix=$("$brew" --prefix)
  export PATH="$prefix/bin:$PATH"
  python="$prefix/opt/python@3.14/bin/python3.14"
fi
case $script in
  *-setup) exec "$python" "$resources/bootstrap.py" "$@" ;;
  *-admin) exec "$python" "$resources/tls_admin.py" "$@" ;;
  *) echo 'Unknown relay helper name.' >&2; exit 1 ;;
esac
