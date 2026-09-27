# macOS development and release profiles

Local builds and source-install tools default to `dev`. The Homebrew archive
builder explicitly selects `release`. This choice is independent of Debug,
ReleaseSafe, or ReleaseFast optimization.

| Setting | Development | Homebrew / release |
| --- | --- | --- |
| App in `~/Applications` | `Zimbr Relay Dev.app` | `Zimbr Relay.app` |
| Bundle ID and LaunchAgent label | `com.hsp.zimbr.relay.dev` | `com.hsp.zimbr.relay` |
| Directory in `~/Library/Application Support` | `Zimbr Dev` | `Zimbr` |
| Default port | `8732` | `8731` |
| Packaged service helper | `zimbr-relay-dev-service` | `zimbr-relay-service` |

Each directory owns its configuration, credentials, journal, process lock,
assets, and logs. Existing explicit configuration ports take precedence over the
defaults; choose different listening endpoints when running both profiles.
Both profiles can read the same Messages account. Profiles separate relay state,
not the underlying Apple account or its messages.

The menu header, tooltip, Settings title, and permission guidance identify the
selected app. Reopening Settings, Restart, and Quit target that profile only.
The Homebrew cask installs and removes only the release app and LaunchAgent.

## Build and update

Use [first-run setup](setup.md) to generate credentials and configure dependencies.

```sh
zig build relay -Dprofile=dev -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=/absolute/openssl-3.5
zig-out/bin/relay profile
python3 packaging/macos/install.py --profile dev --install --start \
  --tls-config /private/staging/dev/relay.json \
  --admin-config /private/staging/dev/admin.json
./tools/update-relay.sh --profile dev --release=safe
```

Use `-Dprofile=release` and `--profile release` consistently for a local release
installation. Staging directories are `zig-out/macos/dev` and
`zig-out/macos/release`. The installer and bundle builder reject a binary whose
compiled profile does not match the requested package before replacing files or
stopping services. Public archive validation also requires release metadata.

The profile definitions in `packaging/macos/profiles.json` feed both the Zig build
and Python packaging. The executable's `profile` command reports its compiled
identity without opening configuration, Messages, or a listener. There is no
runtime switch that changes an app's signed identity.

For source installs, invoke the service helper from the app bundle:

```sh
"$HOME/Applications/Zimbr Relay Dev.app/Contents/Resources/zimbr-relay-dev-service" status
```

The Homebrew cask exposes its release commands on PATH. Installing a dev app does
not replace those commands. Administrative tools also default to dev:

```sh
python3 tools/tls_admin.py enroll --profile release --cert /private/staging/client.pem --label client
python3 tools/mac_acceptance.py --profile dev --enrichment --output /private/evidence/dev.json
python3 tools/mac_conversation_probe.py --profile dev --conversation CONVERSATION_ID
```

## Permissions

The same persistent local signing certificate can sign both profiles. Their
designated requirements contain different bundle identifiers. Grant Full Disk
Access, Messages Automation, and optional Contacts access to the intended app
separately. Grants and validation results for the release identity do not prove
dev access, or vice versa.

Installing through Homebrew does not itself transfer privacy grants. macOS uses
the app's signed identity, not just its display name. The release builder defaults
to the persistent local signing identity; a release using that same certificate
and bundle identifier can retain its privacy grants. Switching to a Developer ID
identity changes the signed identity, so plan to grant permissions again. See Apple's
[code-signing identity guidance](https://developer.apple.com/library/archive/technotes/tn2206/).

Provision each profile independently with its own data directory and credential
files. Never run two copied journals with pending sends.

## Validation

Build both profiles into `zig-out/profile-dev` and `zig-out/profile-release`,
including `relay`, `fake-relay`, and their image helpers, then run:

```sh
python3 tests/mac_profiles.py
python3 tests/mac_release.py
python3 tests/mac_signing.py
python3 tests/mac_menu_restart.py --relay zig-out/profile-dev/bin/relay
```

The profile test uses disposable bundles, CAs, endpoints, and journals. It checks
package/signature identity, mismatched binary rejection, service-helper targets,
simultaneous listeners, and independent restart. It does not grant permissions,
send account messages, or operate on installed LaunchAgents.
