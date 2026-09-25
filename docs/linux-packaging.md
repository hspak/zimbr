# Linux and macOS releases

Keep the AUR recipe in a separate checkout and point `release.sh` at it:

```sh
export ZIMBR_AUR_DIR=/path/to/aur/zimbr
export ZIMBR_TAP_DIR=/path/to/homebrew-tap
```

The package builds the native Wayland client with Zig 0.16, `ReleaseSafe`, and
baseline CPU features. It includes `zimbr`, `zimbr-provision`, the desktop
launcher, the scalable SVG, PNG icons from 16 to 512 px, setup documentation,
and license notices. Provisioning uses Python cryptography and OpenSSL.
The macOS relay is distributed as the `zimbr-relay` Homebrew cask. Every release
publishes both components at the version in `build.zig.zon`, even when only one
component changed.

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

Run `python3 tests/release.py` and `python3 tests/mac_release.py` to check release
ordering, failure handling, and archive validation using temporary local Git
remotes and simulated build and hosting services.

## Build the relay archive

Commit and push all source changes, then check out that exact commit on an
Apple Silicon Mac running macOS 27 or newer. Install the Zig version in
`.zigversion`, Apple's Command Line Tools, and static OpenSSL 3.5 archives as
described in [macOS TLS setup](macos-tls.md#build).

```sh
export ZIMBR_OPENSSL_PREFIX=/absolute/openssl-3.5
export ZIMBR_OPENSSL_LICENSE=/absolute/openssl-source/LICENSE.txt
python3 packaging/macos/release.py build
```

The builder runs the relay and native enrichment tests, creates and signs a
credential-free app, verifies its signature after a ZIP round trip, and writes
`zig-out/release/zimbr-relay-0.1.0-aarch64-macos.zip`. It requires a clean checkout
and records the source commit, version, architecture, and payload checksums.
It does not read TLS configuration, install the app, or restart the relay.
Copy the archive to the Arch release host.

The default signing identity is the persistent identity created by
`packaging/macos/signing.py setup`. Use `--identity NAME_OR_SHA1` for a separately
managed certificate and keep that certificate stable across releases. Ad-hoc
signing is rejected for release archives. This workflow does not notarize the
app; a local signing certificate does not give other Macs Developer ID trust.
Gatekeeper approval and app privacy grants remain required on receiving Macs.

To rehearse both packages without publishing:

```sh
./release.sh 0.1.0 --check --macos-archive /path/to/zimbr-relay-0.1.0-aarch64-macos.zip
```

This checks that the relay was built from the current commit, renders the cask,
and builds the Linux package. Omitting the archive with `--check` retains the
Linux-only local check; publishing always requires the matching relay archive.

## Publish a release

Set `build.zig.zon` to the intended version, commit all release files, and push
the source branch to GitHub. Use an Arch environment with the package's build
dependencies, Ruby, GitHub CLI authentication, and permission to push the AUR
repo and Homebrew tap.
The AUR checkout must be its own git repository on `master`, with origin
`ssh://aur@aur.archlinux.org/zimbr.git`. An empty repository is supported for
the first submission; existing tracked packaging edits must be committed first.
The tap must have a clean tracked checkout on a branch synchronized with origin.
The script generates `Casks/zimbr-relay.rb` from the template in this repository;
existing formulae are preserved. The initial cask is disabled and uses an
all-zero checksum that rejects downloads until the first release replaces it
with the real archive checksum. Releases require the exact relay ZIP SHA-256
in the cask and the exact source archive SHA-256 in the PKGBUILD and `.SRCINFO`;
`:no_check` and `SKIP` are rejected before publishing package metadata.

```sh
./release.sh 0.1.0 --macos-archive /path/to/zimbr-relay-0.1.0-aarch64-macos.zip
```

The script:

1. Validates the relay archive and cask, source version, checkouts, remotes, and
   GitHub authentication.
2. Builds the Linux client and runs its headless unit tests.
3. Pushes the version tag and creates a draft GitHub release with commit notes.
4. Downloads that tag's source archive, computes its checksum, and builds and
   tests the updated PKGBUILD in a temporary directory.
5. Uploads the relay archive and `SHA256SUMS` to the draft release.
6. Updates and commits `PKGBUILD` and generated `.SRCINFO`, then pushes the AUR.
7. Updates and commits the Homebrew cask with the same version and the uploaded
   archive's SHA-256, then pushes the tap.
8. Publishes the GitHub release.

The recipe is updated only after the tagged-source package passes. Matching
tags and draft releases can be reused if a release is interrupted. A failure
prints the temporary directory for inspection. Resolve any local tracked
changes before retrying; if an AUR or tap commit succeeded but its push failed,
push that commit before rerunning the script with the same relay archive. The
repository pushes are sequential; a late failure may leave one repository
updated while GitHub remains a draft. A failed publish never
automatically removes a tag or a draft release.
