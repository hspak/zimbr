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

## Permissions and existing installations

The same persistent local signing certificate can sign both profiles. Their
designated requirements contain different bundle identifiers. Grant Full Disk
Access, Messages Automation, and optional Contacts access to the intended app
separately. Grants and validation results for the release identity do not prove
dev access, or vice versa.

Pre-profile source installs used the release app, data directory, and service
label. A normal dev install deliberately does not import or stop that installation.
For an intentional migration:

1. Back up the old app, LaunchAgent, configuration, credentials, and journal.
   Install the dev app with separately copied credentials and the desired port.
2. Grant permissions to the dev app while the old relay remains available.
3. Stop the old relay and hold its journal lock. Copy its stopped journal and
   asset cache into the dev directory, preserving epoch and durable request IDs.
   Keep dev configuration and credentials pointing into the dev directory.
4. Archive the old app, LaunchAgent plist, and data outside their active paths so
   login or a future Homebrew installation cannot start the old send queue again.
5. Start only the dev LaunchAgent and verify its listener, permissions, epoch,
   and history. Update clients if the endpoint changed.

Keep the backup for rollback. Never run two copied journals with pending sends.
Provision a future release installation independently instead of pointing both
profiles at the same data directory or credential files.

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
