# Linux and macOS releases

Keep the AUR recipe in a separate checkout and point `release.sh` at it:

```sh
export ZIMBR_AUR_DIR=/path/to/aur/zimbr
export ZIMBR_TAP_DIR=/path/to/homebrew-tap
```

The package builds the native Wayland client with Zig 0.16, `ReleaseSafe`,
`-Dprofile=release`, and baseline CPU features. Source builds default to dev,
so package recipes must select release explicitly in their `zig build` commands.
`release.sh` adds this selection to the staged recipe before building or publishing it.
It includes `zimbr`, `zimbr-provision`, the desktop
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

Run `python3 tests/release.py`, `python3 tests/mac_release.py`, and
`python3 tests/mac_remote.py` to check release ordering, failure handling,
archive validation, and isolated Mac builds using temporary local Git remotes
and simulated build and hosting services.

## Configure the Mac builder

Use an Apple Silicon Mac running macOS 27 or newer, reachable with noninteractive
SSH authentication. Keep a source checkout there with the Zig version in
`.zigversion`, Apple's Command Line Tools, static OpenSSL 3.5 archives, and a
persistent signing identity as described in [macOS TLS setup](macos-tls.md#build).
The existing `.tools` layout used by `tools/update-relay.sh` is supported; the
builder also respects `ZIMBR_ZIG`, `ZIMBR_OPENSSL_PREFIX`, and
`ZIMBR_OPENSSL_LICENSE` in the remote environment.

Configure the release host once:

```sh
export ZIMBR_MACOS_HOST=builder@mac.example
export ZIMBR_MACOS_REPO=code/zimbr
```

The checkout path defaults to `code/zimbr` relative to the Mac user's home;
absolute paths are also accepted. `--macos-host HOST` overrides the host.
The script clones an isolated temporary checkout, fetches the exact source
commit from GitHub, and borrows the existing checkout's toolchain. It leaves
the original checkout and installed relay untouched. The Mac must be able to
download the source commit and Zig dependencies.

No manual build or ZIP transfer is needed. On the first run, `release.sh` builds,
tests, and signs the relay over SSH, transfers the ZIP, validates it, and uploads
it to GitHub. Retries reuse the existing GitHub asset without contacting the Mac.

## Optional local relay archive

To supply an archive yourself, commit and push all source changes and check out
that exact commit on the Mac, then run:

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
Copy the archive to the Arch release host and pass `--macos-archive PATH`.

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
Linux-only local check, even if a Mac host is configured. Check mode never
invokes the remote builder or publishes anything.

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
./release.sh 0.1.0
```

The script:

1. Validates the source version, checkouts, remotes, GitHub authentication, and
   any explicitly supplied relay archive.
2. Builds the Linux client and runs its headless unit tests.
3. Pushes the version tag and creates a draft GitHub release with commit notes.
4. Downloads that tag's source archive, computes its checksum, and builds and
   tests the updated PKGBUILD in a temporary directory.
5. Reuses the existing GitHub ZIP or builds the relay on the configured Mac.
   Validates its version, commit, and payload, then uploads the new ZIP and
   `SHA256SUMS` to the draft release.
6. Updates and commits `PKGBUILD` and generated `.SRCINFO`, then pushes the AUR.
7. Publishes the GitHub release and checks that its public ZIP download matches
   the validated archive byte for byte.
8. Updates and commits the Homebrew cask with the same version and the uploaded
   archive's SHA-256, then pushes the tap.

The recipe is updated only after the tagged-source package passes. Matching
tags and draft or published releases can be reused if a release is interrupted.
A failure prints the temporary directory for inspection. Resolve any local tracked
changes before retrying; if an AUR or tap commit succeeded but its push failed,
push that commit before rerunning the script. Uploaded ZIPs are reused without
rebuilding or replacing them; supplying a different local ZIP for an existing
asset is rejected. A missing ZIP on a published release is also rejected.
The repository pushes are sequential: an AUR update can precede a failed GitHub
publish, and a failed tap push leaves GitHub published so its download remains
available. A failed GitHub publish or public download check leaves the tap
unchanged. A failed run never automatically removes a tag or release.
