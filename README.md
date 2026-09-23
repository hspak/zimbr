# Zimbr macOS relay

A Zig 0.16 relay for the Messages account on a logged-in Mac. It reads Apple's
SQLite database without modifying it, exposes an authenticated loopback HTTP/SSE
API, and sends text through a bounded Messages AppleScript subprocess.

The Linux GUI is not implemented in this work. The relay, fixture adapter,
protocol, and recovery tests are available. Real-account acceptance is tracked in
[docs/mac-validation.md](docs/mac-validation.md); installation alone does not prove
send routing or locked-screen operation.

## Build and test

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
headers/library; Linux execution is not yet validated in this Mac environment.
There is no `client` target until the Linux client is implemented.

The tests use temporary synthetic databases. They cover HTTP authentication,
Unicode and independent Foundation archive fixtures, stable pagination, delayed
joins, event replay, transaction rollback, persistence failures, idempotency,
observed delivery, uncertain correlation, stalled and interrupted dispatch,
source replacement, and token rotation. They never modify the real Messages DB.

## Install and permissions

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

## Operation

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

The API always binds **127.0.0.1**, default port **8731**. It never falls back to a
public interface. From Linux, establish the tunnel using your normal SSH trust
and authentication:

```sh
ssh -N -T -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8731:127.0.0.1:8731 user@mac-mini
```

Configure the client with the token through an owner-readable file or secret
store. Do not place it in URLs, process arguments, or logs. Every API endpoint,
including status and events, requires `Authorization: Bearer TOKEN`. The relay
stores plaintext normalized history in its separate journal and relies on the
Mac account/disk protections at rest. Apple credentials remain on the Mac.

To inspect status locally without putting the token in command arguments:

```sh
python3 - <<'PY'
import http.client, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Zimbr/token'
c = http.client.HTTPConnection('127.0.0.1', 8731)
c.request('GET', '/v1/status', headers={'Authorization': 'Bearer ' + p.read_text().strip()})
print(c.getresponse().read().decode())
PY
```

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
