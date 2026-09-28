# macOS relay

The Zig 0.16 relay serves the Messages account on a logged-in Mac. It reads
Apple's SQLite database without modifying it, exposes a TLS 1.3 HTTPS/SSE API
requiring an enrolled client certificate, and sends through a bounded Messages
AppleScript subprocess. Its native menu bar interface uses AppKit, with system
SQLite and no Homebrew runtime dependency. The Linux client never receives Apple
account credentials.

Follow [first-run setup](setup.md) to install dependencies, build, generate
configuration with mkcert, install the app, and enroll Linux. For an existing
installation, see [updates](#update-the-running-relay). Local builds/tools default
to **Zimbr Relay Dev**; Homebrew uses **Zimbr Relay**. Their identities, data and
ports are separate; see [profiles](macos-profiles.md).

## Menu bar and settings

The installed LaunchAgent starts `serve --menu-bar`. Open **Zimbr Relay Dev.app** to
show Settings; closing the window keeps the relay running. The monochrome bridge
icon uses a template image so macOS supplies its appearance. A monochrome
exclamation mark indicates a warning. The menu shows reading/sending readiness,
delayed synchronization, startup errors, and certificate expiry warnings. It also
offers **Check Permissions**, **Open Logs**, **Restart Relay**, and **Quit Relay**.
When Messages reading, sending, and Contacts access are ready, **Check Permissions**
shows a simple confirmation with an **OK** button. Otherwise it shows the current
status and permission setup actions.

Settings edits the existing `relay.json`: listening address, port, server name,
and optional Contacts phone region. **Advanced** exposes file pickers for the
server certificate, server key, client CA, and device list. **Save and Restart**
uses the same configuration and credential validation as startup, then replaces
the file atomically with mode 0600. If the file changed while editing, reload it
before saving again. Invalid settings leave the existing file untouched.
Unsupported JSON entries are removed on save, with a notice in the window.

Startup failures leave the interface available for repair. Missing or malformed
configuration can be replaced through Settings after credentials have been
provisioned. The interface does not issue certificates, enroll devices, or edit
the contents of the device list. Permissions still require macOS approval.
Changing the server name requires matching certificate identities; changing the
address or port may also require updating clients.

Restart starts a fresh process. Installed services retain LaunchAgent supervision
with a one-second minimum launch interval; manual launches retain their original
command and arguments. The icon appears independently of backend initialization,
and status refreshes every 250 milliseconds for the first five seconds before
returning to its two-second cadence. Closing Settings does not stop the service.

**Quit Relay**, below Restart, stops the app and relay. For an installed service,
it unloads the current LaunchAgent job so `KeepAlive` does not immediately restart
it. Login startup remains enabled. Open the app to run it manually again, or use
the selected profile’s service helper with `start` to restore service supervision
before the next login. The command-line equivalent is that helper with `stop`.
Quitting a manual launch simply exits that process. Quit is unavailable while
settings are loading or saving, or a restart is underway.

Opening the app manually does not install a LaunchAgent or enable login startup.
Logs opened from the menu are the installed service's log; command-line launches
write to their inherited output.

Info logs report ingestion readiness, message and media-metadata backfill
completion, contact readiness changes, and send outcomes. Debug builds include
batch counts, contact refresh timing, and image preparation results. Warnings
report temporary delays, lost Contacts access, and unusable images; errors report
source, queue, cache, or persistence failures. Sync logs use counts and opaque
asset IDs without including message bodies or contact names.

Initial history import favors throughput with 1,000-row backfill pages committed
together. Live, recent, and requested-conversation scans retain their 100-row
limits. Once initial import finishes, periodic reconciliation also runs in
100-row pages to keep subsequent sync responsive. Import progress is durable:
restarting resumes an unfinished import, while restarting a completed relay
keeps the smaller batches. New imports collect contact identities and message
metadata directly, avoiding separate upgrade scans over the same records.

Plain `serve` is headless and cannot reveal Settings. Use `serve --menu-bar` to
include the native interface.

Use the [menu validation checklist](macos-menu-bar-validation.md) after changes
to native UI, settings, or lifecycle behavior.

## Homebrew

When a release is available in the tap, install the Apple Silicon relay on
macOS 27 or newer with:

```sh
brew install --cask hspak/tap/zimbr-relay
```

The cask installs `~/Applications/Zimbr Relay.app` and exposes `zimbr-relay` and
`zimbr-relay-service`. Credentials and history live in
`~/Library/Application Support/Zimbr`.
A dev-profile installation can remain installed alongside the cask.

Use a source checkout matching the installed release for the certificate
administration tools; these scripts are not included in the cask. You can also
download and extract the matching source archive from the
[release page](https://github.com/hspak/zimbr/releases). Run the following
commands from that source directory on the Mac to prepare their Python environment:

```sh
brew install mkcert python
mkdir -p .tools
"$(brew --prefix)/bin/python3" -m venv .tools/python
.tools/python/bin/python3 -m pip install -r tools/requirements-tls.txt
```

For a new installation, generate the release configuration with the installed
relay. Replace the example hostname with one that resolves to the Mac from both
computers and the example IP with a specific local address on the Mac:

```sh
.tools/python/bin/python3 tools/tls_admin.py setup --profile release \
  --relay "$HOME/Applications/Zimbr Relay.app/Contents/MacOS/relay" \
  --directory "$HOME/Library/Application Support/Zimbr" \
  --server-name relay.example --listen-address 192.0.2.10
zimbr-relay check-config
```

This direct setup requires an empty data directory; for an existing installation
retain its configuration and credentials. The TLS CA remains outside runtime
state, at `~/.config/zimbr-release-ca` by default. Keep its private key on the Mac;
Zimbr uses explicit CA trust, so `mkcert -install` is unnecessary.

Add `~/Applications/Zimbr Relay.app` to **System Settings → Privacy & Security →
Full Disk Access**. Then run the permission check from the Mac's Terminal,
approve Messages Automation, and start the login service:

```sh
open -n -W -a "$HOME/Applications/Zimbr Relay.app" --args doctor --check-automation
zimbr-relay-service start
zimbr-relay-service status
```

Use **Check Permissions** and **Open Logs** in the relay menu to verify readiness.
Then follow [AUR client setup](linux-setup.md) to enroll Linux and connect on the
default release port, 8731. The published app is already signed, so no local
signing identity or Zig build is required for this installation.

The service helper validates the existing TLS configuration and installs the
per-user LaunchAgent with login startup and restart-on-exit behavior. It does
not provision credentials or grant macOS permissions. Use
`zimbr-relay-service stop` to stop it.

Homebrew upgrades stop the old service. Run `zimbr-relay-service start` after
`brew upgrade --cask hspak/tap/zimbr-relay`, then check `zimbr-relay doctor` and
the relay log. Uninstalling stops the service and preserves configuration,
credentials, and history. Homebrew installs the publisher's signed app; moving
from a locally signed build may require granting macOS permissions again.
The current packaging flow does not notarize the app, so Gatekeeper approval
may also be needed. It does not disable quarantine or Gatekeeper checks.

For maintainers, see [combined releases](linux-packaging.md).

## Build and test

Install Zig **0.16.0**, Apple's Command Line Tools, and a target build of
**OpenSSL 3.5 LTS** with static archives. The packaged build uses 3.5.8; use current
3.5 security patches and rebuild/re-sign the app when updating OpenSSL. The relay
uses system SQLite and native AppKit, with no Homebrew runtime dependency.
Zig fetches and statically builds the pinned nghttp2 HTTP/2 engine.

For an Apple M1 target, an optional optimized build selects its CPU features:

```sh
zig build relay -Doptimize=ReleaseFast -Dtarget=aarch64-macos -Dcpu=apple_m1 \
  -Dopenssl-prefix=/absolute/openssl-3.5
```

Use matching arm64 OpenSSL archives. The relay gives user requests and send
dispatch higher QoS than ingestion and enrichment; macOS chooses the cores.
Omit `-Doptimize` for a Debug build.

```sh
zig build relay fake-relay test -Dopenssl-prefix=/absolute/openssl-3.5
zig build test-macos-enrichment -Dopenssl-prefix=/absolute/openssl-3.5
python3 -m pip install -r tools/requirements-tls.txt
python3 tests/integration.py
python3 tests/enrichment.py
python3 tests/relay_reset.py
python3 tests/assets.py
python3 tests/links.py
python3 tests/reactions.py
python3 tests/native_images.py
python3 tests/relay_tls.py
python3 tests/relay_http2.py
python3 tests/relay_settings.py
python3 tests/mac_menu_restart.py
python3 tests/mac_acceptance_test.py
ZIMBR_MKCERT=/path/to/mkcert python3 tests/cert_management.py
zig fmt --check build.zig src
```

Python network tests/tools require TLS 1.3 support (`ssl.HAS_TLSv1_3`); Apple's
bundled LibreSSL Python is insufficient. For cross builds, supply target-architecture
OpenSSL archives with `-Dopenssl-prefix`, `-Dtarget`, and
`-Dmacos-sdk=/path/to/MacOSX.sdk`. Native and fake relays use the same TLS wrapper.
Linux synthetic worker suites exercise the combined pair directly. Installed
two-host acceptance remains a separate deployment check.

The Mac owns certificate issuance and enrollment; clients follow the
[certificate management contract](certificate-management.md).

Tests use only synthetic Messages databases and temporary CAs, never installed in
system trust. They cover authentication before HTTP, certificate purpose/time,
strict configuration, connection bounds, SSE recovery, renewal/revocation,
idempotency, interrupted dispatch, and journal persistence.

## Contacts and media

The shared protocol and relay include Contacts identities/avatars, authenticated
image assets, stored URL metadata, stable source parts, and reaction projection.
See the [Mac enrichment guide](macos-message-enrichment.md) for the source/transport
contract and verification procedures. The native and fake relays advertise all
six enrichment capabilities: identities, contact avatars,
image assets, image attachments, stored link previews, and reactions.
Permission and source availability determine readiness separately.
The native relay pins and statically compiles its phone-number parser during the
build; fake/Linux builds have no Contacts or
Foundation dependency. Native normalization tests do not read the address book.

Contacts is optional and independent of Full Disk Access and Messages Automation.
The bundle includes a Contacts usage description. Normal startup checks permission
without prompting. Request access through Launch Services so the installed app
owns the permission prompt:

```sh
open -n -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --request-contacts --read-only
```

Optional `contacts_phone_region` in
`relay.json` supplies national-number context; doctor suggests the Mac's region,
but it is never selected automatically. Names are cached in the private relay
journal and exported only for observed addresses. Denial or successful contact
removal publishes clearing records; transient query failure marks matches stale.
Image attachments, embedded/local preview artwork, and lazy Contacts thumbnails
share a private 2 GiB derivative cache and a separately signed ImageIO helper.
Source changes retire immutable versions; missing files retry without requiring a
new message. Photos are JPEG/PNG still previews, including HEIC conversion and
orientation correction. No destination URL or remote artwork is fetched. See the
[Linux client guide](linux-client.md#contacts-and-media) for client storage,
networking, and presentation.

## Install and permissions

Use the [first-run installation command](setup.md#2-generate-credentials-and-install-on-the-mac)
after generating credentials. The installer can stage without changing the
installed app by omitting `--install --start`.

This installs `~/Applications/Zimbr Relay Dev.app` and the user LaunchAgent
`com.hsp.zimbr.relay.dev`. With `--start`, the installer persistently enables the agent
and starts it now. It starts automatically when this user logs in after a reboot,
restarts if it exits, and continues running with the screen locked. Messages needs
the user's graphical login session before the relay can operate.
The installer validates credentials and signs the app before stopping the old
process, takes a consistent journal backup, and preserves its epoch and send IDs.
It installs TLS material in owner-only directories outside the app.
The CA signing key is never installed. Subsequent upgrades
may omit `--tls-config` to retain the installed credentials. Startup failures
leave the relay stopped for repair.
It uses the persistent local signing identity by default; pass
`--identity 'SIGNING IDENTITY'` to select another identity. Disposable ad-hoc
builds (`--identity -`) may require granting permissions again. The executable
path and bundle identifier remain stable.

Complete these steps together in the Mac UI:

1. Confirm Messages is signed into the intended account and sends normally.
2. Add `~/Applications/Zimbr Relay Dev.app` under **System Settings → Privacy &
   Security → Full Disk Access**.
3. Run the installed doctor interactively and allow Messages Automation:

   ```sh
   open -n -W -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --check-automation
   ```

4. Restart the agent if macOS requires a restart after the grant:

   ```sh
   launchctl kickstart -k "gui/$(id -u)/com.hsp.zimbr.relay.dev"
   ```

Full Disk Access has no supported `tccutil` grant command; the tool only resets
existing decisions. Launch Services attributes the check to the installed app;
direct terminal execution does not establish LaunchAgent access.
The service stays reachable with degraded status when integration access fails.
Automation is probed only after database reads succeed. It does not send a test
message automatically. Screen locking must be tested separately from logging out.
After logout/reboot, this agent requires the user's graphical login session.

## Update the running relay

Run this on the Mac, in Terminal or over SSH as the user who runs the relay.
Keep that user logged into the Mac's graphical session. From the checkout, run:

```sh
./tools/update-relay.sh --profile dev --release=safe
```

The script builds the current checkout, including local edits, in ReleaseSafe
and runs the relay and native enrichment tests before installing. It uses a fresh
build output directory and stops if a step fails. It reuses the installed
credentials and persistent signing identity, preserves existing messages and
routes, backs up the journal under `~/Library/Application Support/Zimbr Dev/backups/`,
and restarts the LaunchAgent. It then checks the build UUIDs, signed binary hashes,
and the running process's executable path and inode, printing the verified PID
and relay SHA-256. It does not switch branches or pull changes.

Defaults use the Apple Silicon Zig, OpenSSL, and Python installations under
`.tools`, with PATH fallbacks for Zig and Python. Use `ZIMBR_ZIG`, `ZIMBR_PYTHON`,
`ZIMBR_OPENSSL_PREFIX`, and `ZIMBR_OPENSSL_LICENSE` to override those paths;
`./tools/update-relay.sh --help` describes the options. Run without `sudo`.

The client's **Settings → Client and relay data → Reset client and relay…**
action resets both caches after confirmation. A relay with incompatible stored
IDs stays reachable for status and authenticated reset requests while ingestion,
sends and ordinary reads are paused. Updating an existing installation preserves
that journal so the client can request recovery; no manual database removal is
needed. An old binary must be updated once to expose the reset API.

To instead archive and reset the relay's generated state during installation:

```sh
./tools/update-relay.sh --profile dev --reset-cache
```

Use `--profile release` for the release installation. This stops the relay,
backs up the journal (including committed WAL records), and archives the old
database, sidecars, and cached media under the profile's `backups/` directory.
The new relay creates a fresh epoch and rebuilds messages, identities, and media
from their sources. Connection settings, TLS credentials, and Apple Messages
are preserved. Relay send history and pending sends remain only in the backup;
check Messages before resending anything whose outcome was uncertain.

`InvalidEpoch` in the client can mean the relay still serves an old UUID epoch.
The offline client `--reset-cache` command cannot change the relay's epoch.
A current relay reports `relay_cache_reset_required` for ordinary API requests
until the client requests a reset, instead of serving incompatible IDs.
The reset option also installs the current binary, since an old binary would
generate old IDs even with a fresh database.

The installer also checks that the restarted service opens its configured
listener. For configuration and Messages access diagnostics, run:

```sh
"$HOME/Applications/Zimbr Relay Dev.app/Contents/MacOS/relay" doctor
```

## Operation

```sh
zig-out/bin/relay setup
zig-out/bin/relay doctor
zig-out/bin/relay probe
zig-out/bin/relay serve
zig-out/bin/relay check-config
```

`doctor` and `probe` report aggregate database/decoder diagnostics, without
printing message content or participant addresses. Only `--check-automation`
performs the optional no-send Automation probe. Real sends require API requests.

Options are `--data-dir PATH`, `--messages-db PATH` (always read-only in `relay`),
`--config PATH`, and `--event-limit COUNT`. The default configuration is
`~/Library/Application Support/Zimbr Dev/relay.json`. `setup` creates private state
and initializes the journal; it does not generate credentials. `check-config`
validates TLS configuration without opening Messages or a listener. `doctor`
also reports certificate expiry, fingerprint, enabled-device count, and integration
readiness. `serve --read-only` disables automation/sending while retaining mTLS.

Every route requires a valid clientAuth leaf from the dedicated CA and an enabled
SHA-256 leaf fingerprint. Configuration explicitly selects an IP to bind; failed
binds and invalid/missing configuration are errors. TLS 1.3 and HTTP/2 are required,
with session resumption and early data disabled.
Certificates, keys, and configuration must be owner-only files in 0700 directories,
with no symlinks. The journal retains plaintext normalized history under the Mac
account's filesystem protections.

Read status using the separately enrolled Mac administrative identity:

```sh
python3 - <<'PYTLS'
import sys
from pathlib import Path
sys.path.insert(0, 'tools')
from mac_acceptance import Client
print(Client(Path.home()/'Library/Application Support/Zimbr Dev').request('/v1/status'))
PYTLS
```

See [certificate provisioning, renewal, and revocation](macos-tls.md).
Device changes are local administrative actions applied by a verified restart;
existing streams and pooled connections close with the old process. Certificate
expiry closes active sessions as well as rejecting new connections.

Stop/start the agent with `launchctl bootout gui/$(id -u)/com.hsp.zimbr.relay.dev` and
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hsp.zimbr.relay.dev.plist`.
To uninstall, stop it and remove that plist and app bundle. Keep the Application
Support directory unless deliberately discarding history and idempotency records.

Validate routing, recipient delivery, and locked-screen operation using the
[macOS validation guide](mac-validation.md#real-account-validation). Installation
alone does not establish those results. The [API reference](api.md) describes
synchronization, send recovery, and protocol limits.
