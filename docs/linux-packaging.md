# Arch Linux packaging and releases

Keep the AUR recipe in a separate checkout and point `release.sh` at it:

```sh
export ZIMBR_AUR_DIR=/path/to/aur/zimbr
```

The package builds the native Wayland client with Zig 0.16, `ReleaseSafe`, and
baseline CPU features. It includes `zimbr`, `zimbr-provision`, the desktop
launcher, the scalable SVG, PNG icons from 16 to 512 px, setup documentation,
and license notices. Provisioning uses Python cryptography and OpenSSL.
The macOS relay is installed separately on the Mac.

Zig dependencies are fetched during `prepare()`. `build()` and `check()` use
the extracted `zig-pkg` directory in offline system mode. Package checks run
the headless client unit tests, validate the desktop entry, and exercise the
provisioning helper's CLI. They do not launch the GUI or contact a live relay.

## Build the initial package

```sh
cd "$ZIMBR_AUR_DIR"
makepkg -si
```

There is no release tag yet, so the initial recipe pins public commit
`7fbc3fe3f5ac9d7fcb3a2f07980e5fc34fe808f1` with a SHA-256 checksum. It packages
the artwork in that commit. The first release will include the new icons once
they are committed, and switch `_ref` to the release tag.

To validate the current checkout, including uncommitted icon changes, from the
Zimbr repository:

```sh
./release.sh 0.1.0 --check
```

This runs `makepkg` against a temporary source snapshot and leaves the checked
package in `zig-out/release/`. It does not alter the AUR checkout or publish
anything. Install the dependencies listed in the PKGBUILD before running it;
the script does not install packages automatically.

Run `python3 tests/release.py` to check release ordering and failure handling
using temporary local Git remotes and simulated build and hosting services.

## Publish a release

Set `build.zig.zon` to the intended version, commit all release files, and push
the source branch to GitHub. Use an Arch environment with the package's build
dependencies, GitHub CLI authentication, and permission to push the AUR repo.
The AUR checkout must be its own git repository on `master`, with origin
`ssh://aur@aur.archlinux.org/zimbr.git`. An empty repository is supported for
the first submission; existing tracked packaging edits must be committed first.

```sh
./release.sh 0.1.0
```

The script:

1. Checks the source version, clean checkout, remotes, and GitHub authentication.
2. Builds the Linux client and runs its headless unit tests.
3. Pushes the version tag and creates a draft GitHub release with commit notes.
4. Downloads that tag's source archive, computes its checksum, and builds and
   tests the updated PKGBUILD in a temporary directory.
5. Updates and commits `PKGBUILD` and generated `.SRCINFO`, then pushes the AUR.
6. Publishes the GitHub release.

The recipe is updated only after the tagged-source package passes. Matching
tags and draft releases can be reused if a release is interrupted. A failure
prints the temporary directory for inspection. Resolve any local tracked
changes before retrying; if the AUR commit succeeded but its push failed,
push that commit before rerunning the script. A failed publish never
automatically removes a tag or a draft release.

No macOS binary or Homebrew formula is published by this Linux release flow.
