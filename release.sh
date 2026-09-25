#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <version> [--check]" >&2
  echo "  --check builds the current checkout as an Arch package without publishing." >&2
}

die() {
  echo "release.sh: $*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must use the X.Y.Z format"
check_only=false
if [[ $# -eq 2 ]]; then
  [[ $2 == --check ]] || { usage; exit 2; }
  check_only=true
fi

for command in git makepkg python3 sha256sum mktemp install zig; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aur_dir=$(cd -- "${ZIMBR_AUR_DIR:-$repo_dir/../../aur/zimbr}" && pwd) ||
  die "AUR directory not found; set ZIMBR_AUR_DIR to override ../../aur/zimbr"
pkgbuild=$aur_dir/PKGBUILD
[[ -f $pkgbuild ]] || die "PKGBUILD not found at $pkgbuild"
python3 - "$repo_dir/build.zig.zon" "$version" <<'PY'
from pathlib import Path
import re
import sys
versions = re.findall(r'^\s*\.version\s*=\s*"([^"]+)"', Path(sys.argv[1]).read_text(), re.M)
if versions != [sys.argv[2]]:
    sys.exit('release.sh: build.zig.zon must declare the requested version')
PY

# Build from a scratch recipe, and update the AUR checkout only after it passes.
release_dir=$(mktemp -d -t "zimbr-release-$version.XXXXXXXX")
stage=$release_dir/package
mkdir -p "$stage"
cleanup() {
  local status=$?
  if [[ $status -eq 0 ]]; then
    rm -rf -- "$release_dir"
  else
    echo "Release stopped; inspection files remain at $release_dir" >&2
  fi
}
trap cleanup EXIT

stage_recipe() {
  local archive=$1 checksum
  checksum=$(sha256sum "$archive")
  checksum=${checksum%% *}
  python3 - "$pkgbuild" "$stage/PKGBUILD" "$version" "$checksum" <<'PY'
from pathlib import Path
import re
import sys
source, destination, version, checksum = sys.argv[1:]
text = Path(source).read_text()
for field, value in (('pkgver', version), ('pkgrel', '1'), ('_ref', version),
                     ('sha256sums', f'("{checksum}")')):
    text, count = re.subn(rf'^{field}=.*$', f'{field}={value}', text, flags=re.M)
    if count != 1:
        sys.exit(f'release.sh: expected exactly one {field} in PKGBUILD')
Path(destination).write_text(text)
PY
}

build_package() {
  (
    cd -- "$stage"
    export PKGDEST="$stage" SRCDEST="$stage" BUILDDIR="$stage" LOGDEST="$stage"
    makepkg --printsrcinfo >.SRCINFO
    makepkg --force --cleanbuild --noconfirm
  )
}

if $check_only; then
  # Include uncommitted artwork and source edits for a useful local rehearsal.
  # Git's ignore rules exclude build output and local credential material.
  archive=$stage/zimbr-$version.tar.gz
  python3 - "$repo_dir" "$archive" "$version" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tarfile
root, destination, version = sys.argv[1:]
paths = subprocess.check_output(['git', '-C', root, 'ls-files', '-z', '--cached',
                                 '--others', '--exclude-standard']).split(b'\0')
with tarfile.open(destination, 'w:gz') as archive:
    for name in sorted(set(paths) - {b''}):
        name = os.fsdecode(name)
        path = Path(root) / name
        if path.exists() or path.is_symlink():
            archive.add(path, arcname=f'zimbr-{version}/{name}', recursive=False)
PY
  stage_recipe "$archive"
  build_package
  output=$repo_dir/zig-out/release
  mkdir -p "$output"
  package_list=$(cd -- "$stage" && PKGDEST="$stage" makepkg --packagelist)
  [[ -n $package_list ]] || die "makepkg did not report any package artifacts"
  while IFS= read -r archive; do
    install -m644 "$archive" "$output/"
    echo "Checked package: $output/${archive##*/}"
  done <<<"$package_list"
  echo "Local package check passed; no tags, releases, or AUR changes were published."
  exit 0
fi

for command in curl gh; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done
[[ -z $(git -C "$repo_dir" status --porcelain) ]] ||
  die "commit the source checkout's changes (including untracked release assets) first"
branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD) || die "source HEAD is detached"
revision=$(git -C "$repo_dir" rev-parse HEAD)
remote_revision=$(git -C "$repo_dir" ls-remote origin "refs/heads/$branch")
[[ ${remote_revision%%[[:space:]]*} == "$revision" ]] ||
  die "push or pull the source branch so HEAD matches origin/$branch"
[[ $(git -C "$aur_dir" rev-parse --show-toplevel) == "$aur_dir" ]] ||
  die "initialize the AUR directory as its own git repository first"
[[ $(git -C "$aur_dir" symbolic-ref --quiet --short HEAD) == master ]] ||
  die "the AUR checkout must be on its master branch"
git -C "$aur_dir" diff --quiet -- && git -C "$aur_dir" diff --cached --quiet -- ||
  die "the AUR checkout has uncommitted tracked changes"
git -C "$aur_dir" var GIT_AUTHOR_IDENT >/dev/null || die "configure the AUR git author first"
remote_revision=$(git -C "$aur_dir" ls-remote origin refs/heads/master)
if [[ -n $remote_revision ]]; then
  [[ $(git -C "$aur_dir" rev-parse HEAD) == "${remote_revision%%[[:space:]]*}" ]] ||
    die "push or pull the AUR checkout so it matches origin/master"
fi
gh auth status --hostname github.com >/dev/null 2>&1 || die "run gh auth login first"
github_repo=$(cd -- "$repo_dir" && gh repo view --json nameWithOwner --jq .nameWithOwner)
[[ $github_repo == hspak/zimbr ]] || die "the PKGBUILD targets hspak/zimbr, not $github_repo"
draft=$(gh release view "$version" --repo "$github_repo" --json isDraft --jq .isDraft 2>/dev/null || true)
[[ $draft != false ]] || die "GitHub release $version is already published"

# Existing matching tags/drafts are reusable after an interrupted release.
remote_tag=$(git -C "$repo_dir" ls-remote origin "refs/tags/$version")
if [[ -n $remote_tag ]]; then
  git -C "$repo_dir" fetch origin "refs/tags/$version:refs/tags/$version"
fi
if git -C "$repo_dir" rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
  [[ $(git -C "$repo_dir" rev-parse "refs/tags/$version^{commit}") == "$revision" ]] ||
    die "tag $version does not identify the current source commit"
fi

echo "Building and testing the Linux client before tagging..."
(cd -- "$repo_dir" && zig build client test-client -Doptimize=ReleaseSafe -Dcpu=baseline)
previous_tag=$(git -C "$repo_dir" describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' \
  --exclude "$version" HEAD 2>/dev/null || true)
git -C "$repo_dir" log --no-decorate --format='- %s (%h)' \
  "${previous_tag:+$previous_tag..}HEAD" >"$release_dir/notes.md"
[[ -s $release_dir/notes.md ]] || die "there are no release notes to publish"
if ! git -C "$repo_dir" rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
  git -C "$repo_dir" tag "$version"
fi
git -C "$repo_dir" push origin "refs/tags/$version"
if [[ $draft == true ]]; then
  gh release edit "$version" --repo "$github_repo" --notes-file "$release_dir/notes.md"
else
  gh release create "$version" --repo "$github_repo" --draft --verify-tag \
    --title "Zimbr $version" --notes-file "$release_dir/notes.md"
fi

archive=$stage/zimbr-$version.tar.gz
curl --fail --location --silent --show-error --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$archive" "https://github.com/$github_repo/archive/$version.tar.gz"
stage_recipe "$archive"
build_package

install -m644 "$stage/PKGBUILD" "$aur_dir/PKGBUILD"
install -m644 "$stage/.SRCINFO" "$aur_dir/.SRCINFO"
(
  cd -- "$aur_dir"
  git diff --check
  git add -- PKGBUILD .SRCINFO
  if ! git diff --cached --quiet --; then
    git commit -m "release: publish version $version"
  fi
  git push --set-upstream origin HEAD:master
)
gh release edit "$version" --repo "$github_repo" --draft=false
echo "Published Zimbr $version to GitHub and the AUR."
