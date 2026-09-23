# Zimbr

A Zig 0.16 relay for the Messages account on a logged-in Mac. It reads Apple's
SQLite database without modifying it and sends text through a bounded Messages
AppleScript subprocess. The Linux client now requires direct HTTPS with mTLS.
The relay transport migration is being implemented separately on macOS; the
old relay in this checkout is not compatible with the new client. See the
[migration plan](docs/mtls-migration.md) and [Linux setup](docs/linux-mtls.md).

The Linux desktop client uses Zig, Clay, raylib, and Pango. It supports conversation
browsing, cached history, live updates, direct messages, existing-conversation
replies, Unicode drafts, and send recovery. Real-account acceptance is tracked in
[docs/mac-validation.md](docs/mac-validation.md); installation alone does not prove
send routing or locked-screen operation.

## Linux client

Use Zig **0.16.0**, `pkg-config`, and development headers/libraries for SQLite,
libcurl (7.88+ with the OpenSSL 3 backend), OpenSSL 3, Pango/Cairo, OpenGL,
Wayland, and xkbcommon. Clay and raylib are pinned in
`build.zig.zon`; Flamez is not a build or runtime dependency. Install a system
sans-serif font and an emoji font for the scripts you use.

```sh
zig build client
# After provisioning and configuration below:
zig build run
# Optional user-local executable, icon, and application launcher:
packaging/linux/install.sh
```

Linux uses Wayland exclusively. The GUI was rendered at 125% desktop scaling
and uses `zimbr` as its application ID. Rendering sleeps between changes while
the background worker continues to receive messages.

The sidebar's **Dark mode / Light mode** button saves the appearance for the next
launch. **Details** (Ctrl+D) opens a scrollable pane with connection and retry
status, relay capabilities, saved sync cursor, cache counts, display information,
client certificate fingerprint and expiry, TLS failure details, and local file
paths. Private-key contents are never shown. Escape or **Back** returns
to messages. The search box and sidebar controls stay fixed while the list scrolls.
Conversation lists, message history, Details, and overflowing drafts show a
scrollbar: drag its thumb or click the track to move. Wheel scrolling is 25%
faster. Incoming group messages use subtle participant tints and matching sender
labels in both light and dark mode.

Provision a local device key/CSR and import the verified CA and signed leaf with
`packaging/linux/provision.py`, following [Linux mTLS setup](docs/linux-mtls.md).
The relay must enable the device's entire-leaf SHA-256 fingerprint. Use a directly
reachable hostname covered by its server certificate; proxies and redirects are
disabled. Both API and SSE connections require TLS 1.3 and client authentication.

Default data is `$XDG_DATA_HOME/zimbr` (fallback `~/.local/share/zimbr`). The cache
and drafts remain in their existing database and contain plaintext. Credentials
and security configuration must be owned 0600 files in 0700 directories with no
symlinks. The GUI never receives Apple account credentials.

`$XDG_CONFIG_HOME/zimbr/config.json` (fallback `~/.config/zimbr/config.json`):

```json
{
  "relay_url": "https://mac-mini.local:8731",
  "ca_file": "/home/USER/.config/zimbr/tls/ca.pem",
  "client_cert_file": "/home/USER/.config/zimbr/tls/client.pem",
  "client_key_file": "/home/USER/.config/zimbr/tls/client-key.pem",
  "enter_to_send": true
}
```

Use actual absolute paths. Matching CLI flags are `--relay-url`, `--ca-file`,
`--client-cert-file`, `--client-key-file`, and `--data-dir`. Old transport fields
and options fail with migration guidance. An optional `"theme": "dark"` or
`"theme": "light"` (or `--theme dark|light`) overrides saved appearance.
`--details` opens diagnostics at launch. After replacing credentials click
**Reconnect**, which reloads the files and discards all old TLS connections.
Configuration path or endpoint changes require restart. Certificate errors wait
for correction and Reconnect; transient network failures use bounded backoff.
A client-certificate expiry warning starts 30 days before its actual expiry.

Enter sends; Shift+Enter inserts a newline. Ctrl+A/C/X/V, Ctrl+Z, Ctrl+Shift+Z,
Ctrl+Y, Home/End, arrows, mouse selection, and clipboard are supported. Ctrl+N
starts a direct conversation; Ctrl+F searches the sidebar. Drag over message text
and press Ctrl+C to copy the highlighted portion. Click a message then Ctrl+C to
copy it in full; Ctrl+A selects the whole message. New recipients must be an
international number or email.
Unsupported services remain readable with sending disabled.

Pango supplies shaping, font fallback, wrapping, and grapheme boundaries. Text is
rasterized at the Wayland display scale and aligned to physical pixels, including
at fractional scales; moving between display scales refreshes the text cache.
Lettering uses full-opacity colors with grayscale antialiasing at glyph edges.
Combining marks and joined emoji survive editing and restart. Full input-method/preedit
integration, visual bidirectional cursor navigation, and accessibility are future
work. For input-method users, set `enter_to_send` to `false` to reserve plain Enter
for text input and use Ctrl+Enter or the Send button; paste committed text from an
IME-capable editor when needed. Missing glyphs remain copyable as original UTF-8.

Offline drafts are saved but new sends are not queued offline. Each outgoing
request is persisted before its first POST; recovery checks the original UUID
without automatically sending again. While the original submission is unresolved,
new sends stay as drafts. An uncertain or failed message can be copied
to a draft for deliberate retry. Sending again after an uncertain result can
create a duplicate. A relay epoch reset preserves drafts and outbox identities;
orphaned drafts remain discoverable as **Recovered draft**. Local unread markers
do not change Apple's read receipts. Attachments and unsupported content remain
visible as placeholders; downloads and notifications are not implemented.

Linux verification:

```sh
zig build test client-probe fake-relay
python3 tests/client_tls.py
python3 tests/client_integration.py
python3 tests/client_transport.py
python3 tests/client_details.py
# Requires a running Wayland desktop:
zig build test-gui
python3 tests/integration.py
python3 tests/mac_acceptance_test.py
zig fmt --check build.zig src
# Read-only connection check, with aggregate-only output:
zig-out/bin/client-probe --data-dir /path/to/client-data
```

`test-client` runs store, SSE, and Unicode text tests without a GPU. The Python
client integration suite uses the actual client worker, temporary device/CA
certificates, and an authenticated TLS test adapter in front of the existing
fixture relay. The adapter is temporary Linux test infrastructure pending the
native relay migration. It covers history, pagination, direct/group sends, echo merging, uncertain outcomes,
crashes, expired cursors, and epoch changes. A Wayland screenshot
can be exported with `zimbr --screenshot /path/to/image.png --frames 90`.

Long messages display a preview of up to 4 KiB or 64 lines; the original remains
in the cache and selecting the message then pressing Ctrl+C copies its full text.
Text that cannot be rendered safely shows a placeholder. Sidebar labels use
shorter previews. History layout starts with the newest messages, reuses prepared
rows between frames, and fills in older rows within an 8 ms frame budget. Bubbles
appear at their final size. Short conversations stay aligned to the bottom, and
scrolling up keeps your reading position while more history loads. `test-gui`
checks large-history layout, scroll stability, texture eviction, and long-message
rendering; `test-client` covers Unicode, raster bounds, and fractional-scale tiles.

The relay and client use filesystem/commit notifications, socket readiness,
durable event batches, reusable HTTP connections, and shared history snapshots.
Changed histories reuse immutable message records and prepared previews, while
ingestion batches resolve each conversation once and skip unchanged writes.
Conversation pages can include small sidebar previews, avoiding a request per
conversation. See [performance measurements and architecture](docs/performance.md)
for benchmarks, reliability constraints, and remaining platform validation.

## Relay build and test

Install Zig **0.16.0** and Apple's Command Line Tools. The build uses the selected
macOS SDK (`xcrun --show-sdk-path`) and system SQLite, with no GUI dependencies.
The Zig version and SDK setup follow the sibling Flamez project, without depending
on its source tree.

```sh
zig build relay fake-relay
zig build test
python3 tests/integration.py
python3 tests/mac_acceptance_test.py
zig fmt --check build.zig src
zig build macos-check -Dtarget=x86_64-macos
```

For a cross build, pass `-Dmacos-sdk=/path/to/MacOSX.sdk`. `fake-relay` and the core
unit tests also have a Linux build path, requiring system SQLite development
headers/library; Linux execution is covered by the fixture integration suites.
The real relay remains independent of GUI libraries.

The tests use temporary synthetic databases. They cover HTTP authentication,
Unicode and independent Foundation archive fixtures, stable pagination, delayed
joins, event replay, transaction rollback, persistence failures, idempotency,
observed delivery, uncertain correlation, stalled and interrupted dispatch,
source replacement, and token rotation. They never modify the real Messages DB.

## Existing macOS installation (pre-mTLS)

This section records the old relay behavior pending the macOS migration. Do not
use it to deploy the new Linux client; use the coordinated migration plan.

```sh
python3 packaging/macos/install.py                 # stage app and plist
python3 packaging/macos/install.py --install --start
```

This installs `~/Applications/Zimbr Relay.app` and the user LaunchAgent
`com.hsp.zimbr.relay`. With `--start`, the installer persistently enables the agent
and starts it now. It starts automatically when this user logs in after a reboot,
restarts if it exits, and continues running with the screen locked. Messages needs
the user's graphical login session before the relay can operate.
The installer preserves the journal and token on upgrades.
It uses ad-hoc signing by default; pass `--identity 'SIGNING IDENTITY'` to use a
persistent signing identity. Ad-hoc rebuilds may require granting permissions
again. The executable path and bundle identifier remain stable.

Complete these steps together in the Mac UI:

1. Confirm Messages is signed into the intended account and sends normally.
2. Add `~/Applications/Zimbr Relay.app` under **System Settings → Privacy &
   Security → Full Disk Access**.
3. Run the installed doctor interactively and allow Messages Automation:

   ```sh
   "$HOME/Applications/Zimbr Relay.app/Contents/MacOS/relay" doctor --check-automation
   ```

4. Restart the agent if macOS requires a restart after the grant:

   ```sh
   launchctl kickstart -k "gui/$(id -u)/com.hsp.zimbr.relay"
   ```

Full Disk Access has no supported `tccutil` grant command; the tool only resets
existing decisions. Terminal permissions do not establish LaunchAgent access.
The service stays reachable with degraded status when integration access fails.
Automation is probed only after database reads succeed. It does not send a test
message automatically. Screen locking must be tested separately from logging out.
After logout/reboot, this agent requires the user's graphical login session.

## Existing macOS operation (pre-mTLS)

```sh
zig-out/bin/relay setup
zig-out/bin/relay doctor
zig-out/bin/relay probe
zig-out/bin/relay serve
zig-out/bin/relay rotate-token
```

`doctor` and `probe` report aggregate database/decoder diagnostics, without
printing message content or participant addresses. Only `--check-automation`
performs the optional no-send Automation probe. Real sends require API requests.

Options are `--data-dir PATH`, `--messages-db PATH` (always read-only in `relay`),
`--port PORT`, and `--event-limit COUNT`. `serve --read-only` disables all
automation/sending while exposing the read API, for local integration diagnostics. The default data directory is
`~/Library/Application Support/Zimbr`; its permissions are 0700. The bearer token
is 32 random bytes encoded as 64 hexadecimal characters in a 0600 `token` file.
Token rotation is atomic; existing streams close at their next heartbeat. A
process lock prevents two relay instances from dispatching from the same journal.

The pre-migration relay binds **127.0.0.1** and requires its bearer token on every
API endpoint. Its old SSH transport is incompatible with the current Linux
client. Replace it with the matching mTLS relay before cutover; server-side setup,
smoke tools, and authorization are owned by the macOS migration. The relay's
plaintext journal still relies on Mac account/disk protections at rest.

Stop/start the agent with `launchctl bootout gui/$(id -u)/com.hsp.zimbr.relay` and
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hsp.zimbr.relay.plist`.
To uninstall, stop it and remove that plist and app bundle. Keep the Application
Support directory unless deliberately discarding history and idempotency records.

## API v1

| Method | Path | Response |
| --- | --- | --- |
| GET | `/v1/status` | Epoch, readiness, capabilities, degraded reasons |
| GET | `/v1/sync` | Epoch and durable event cursor |
| GET | `/v1/conversations?before=...&limit=50` | `conversations`, `next` |
| GET | `/v1/conversations/:id/messages?before=...&limit=50` | `messages`, `next` |
| POST | `/v1/messages` | Durable send request; 202 new, 200 retry |
| GET | `/v1/send-requests/:id` | Current send request |
| GET | `/v1/events?after=...` | SSE replay followed by live events |

Send bodies follow `DESIGN.md`: UUID `request_id`, expected `server_epoch`,
`text`, and exactly one target: `conversation_id` or
`recipient: {address, service: "imessage"}`. Use an international phone number or
unambiguous email. The adapter requires one enabled iMessage account and checks
existing chats against that account. It never chooses SMS/RCS or creates a group.
Unknown optional JSON fields are accepted. UUID casing is normalized.

Public IDs are opaque; revisions and event sequences are decimal strings.
Timestamps are UTC with source nanosecond precision. Conversation pages descend
by immutable relay ID; history pages descend by `(source timestamp, relay ID)`.
Treat `next` and event cursors as opaque strings and URL-encode them. Fetch a sync
cursor **before** fetching snapshots, then replay after it; merge by ID/revision.
History queries also enqueue bounded source reconciliation.

SSE uses `id`, `event`, and JSON `data`, with 15-second comment heartbeats. Each
event contains its cursor, sequence, full record, type, and origin (`live`,
`historical_import`, or `reconciliation`). Replays are at least once. Notify only
for newly committed incoming live events. Conflicting `Last-Event-ID` and `after`
values are rejected. Epoch mismatch returns 409; expired event cursors return
410 with `resync_required`. A connected stream closes on a reset/expired cursor.
Reconnect using the last applied cursor to receive the explicit error.

Errors use `error_info: {code, message, outcome}`. `outcome` is `unstarted` or
`uncertain`. HTTP acceptance means persistence succeeded, not delivery. A success
from AppleScript remains uncertain until a unique outgoing database record is
observed in the actual route within the dispatch window. Correlation waits 30
seconds to expose competing candidates. Multiple candidates remain unknown.
Interrupted dispatches are never automatically resent. If saving a dispatch
result fails, the worker recovers it as unknown when persistence is available,
without requiring a restart or invoking the send again. Queued requests can resume
only after route/epoch revalidation. Query by the original request ID after a
network failure. Idempotency identities are never automatically pruned.

Source inode changes, high-water regressions, or anchor GUID mismatches rebuild
normalized source state under a new epoch. Old queued/in-flight requests become
held `unknown` requests with `source_reset`, retaining their request IDs. Clients
must explicitly synchronize again. Conservative invalidation may also occur for
a benign database replacement or deletion of the anchor record.

Limits: 64 KiB request bodies, 16 KiB outgoing UTF-8 text, 1 MiB decoder inputs,
64 KiB decoded incoming text, 200 records/page, 32 connections, 8 event streams,
10-second socket timeouts, and 15-second automation runtime with 128 bytes of
retained status output. Over-limit content becomes a classified placeholder.
Events are pruned every minute to seven days and at most 100,000 records by default. Pruning does not
delete normalized history or request identities.

The attributed decoder recognizes the observed immutable/mutable typed-stream
root NSString layouts and validates their length, encoding, and string terminator.
It does not instantiate archived classes or scrape printable bytes. Unknown
formats are visible as unsupported; it does not interpret the full attribute
object graph. Attachments are metadata placeholders; no file paths or bytes are
served. Reactions and system rows remain distinct content kinds. Historical
edits/deletions, reactions as actions, group administration, read receipts, Contacts,
notifications, and attachment transfer remain outside v1.

## Real-account validation

After permissions are granted, use only a deliberately selected recipient:

```sh
python3 tools/mac_acceptance.py --recipient 'YOUR_TEST_ADDRESS' --confirm-send --restart
```

This sends two clearly labeled Unicode/multiline messages, reuses their request
IDs to check idempotency, observes the resulting history and SSE records, replies
to the identified existing conversation, and optionally verifies IDs and event
replay after restarting the LaunchAgent. Use `--conversation OPAQUE_ID` instead
of `--recipient` to test one explicitly selected existing conversation or group.
Add `--wait-for-lock 300` with `--conversation` to wait up to five minutes for the
user to lock the screen before sending that one message.

The helper saves test IDs/statuses under ignored `.local/` before submitting each
message, preserving them on failure. It refuses to overwrite an existing evidence
file; inspect that run's request IDs before authorizing another run with a new
`--output` path. Recipient-side delivery and receipt initiated from another Apple
device require separate confirmation. Locked operation is recorded only when the
helper observes the current user's locked console session throughout its send check.
