# Linux client

The native Wayland desktop client uses Zig, Clay, raylib, and Pango. It supports
conversation browsing, cached history, live updates, direct messages,
existing-conversation replies, Unicode drafts, desktop notifications, send
recovery, contact names/photos, inline images, stored link cards, and reaction
chips when supplied by the relay.

First [set up the Mac relay](macos-relay.md), then follow
[Linux mTLS setup](linux-mtls.md) to enroll this device. Both endpoints share the
[certificate management contract](certificate-management.md). Linux worker tests
exercise the native mTLS relay directly; installed two-host acceptance is separate.

Run the commands below from the repository root.

## Build and install

Use Zig **0.16.0**, `pkg-config`, and development headers/libraries for SQLite,
libcurl (7.88+ with the OpenSSL 3 backend), OpenSSL 3, Pango/Cairo, GLib/GIO,
libpng, libjpeg, OpenGL, Wayland, and xkbcommon, plus `wayland-scanner`. Clay
and raylib are pinned in [`build.zig.zon`](../build.zig.zon); Install a system
sans-serif font and an emoji font for the scripts you use.

```sh
zig build client -Doptimize=ReleaseFast
# After provisioning and configuration below:
zig build run -Doptimize=ReleaseFast
# Optional user-local executable, icon, and application launcher:
packaging/linux/install.sh
```

For Arch packages and maintainer releases, see [Linux packaging](linux-packaging.md).

## Provisioning and configuration

Provision a local device key/CSR and import the verified CA and signed leaf with
`packaging/linux/provision.py`, following [Linux mTLS setup](linux-mtls.md).
Request an explicit `--name linux-desktop.zimbr.invalid`, have the Mac signer
approve that same name, and retain `client.csr` for import verification.
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
and options fail with migration guidance. Legacy `theme` settings in the config
file and saved appearance are ignored; the color scheme is fixed.
`--details` opens diagnostics at launch. After replacing credentials click
**Reconnect** in the Details pane, which reloads the files and discards all old
TLS connections.
Configuration path or endpoint changes require restart. Certificate errors wait
for correction and Reconnect; transient network failures use bounded backoff.
A client-certificate expiry warning starts 30 days before its actual expiry.

## Conversations and history

The client uses a Slack-inspired dark layout: a plum navigation rail and sidebar,
a sidebar search bar (Ctrl+F), and a compact conversation list with unread counts.
Group and direct conversations appear together, ordered by their latest message,
newest first, beside a charcoal conversation pane. Incoming and outgoing messages
share a left-aligned feed with square avatars, sender labels, timestamps, and
outgoing delivery checkmarks: one for sent, two for delivered.
Unknown delivery states and uncertain-send warnings appear only after 30 seconds
from the send time; pending sends show “Sending…” during this grace period.
Confirmed failures appear immediately.
Pending and uncertain sends stay in the timeline at their original send time;
older cached sends use an estimated position from nearby history.

The compact composer grows from one to three text lines, then scrolls for longer
drafts. Send stays the same size at the bottom right, and the input's bottom
aligns with the conversation list. The conversation pane extends to the bottom
of the window.
Read-only chats show a disabled grey composer; any existing draft is preserved.

Verified phone/email self chats appear together as **You**, with both histories
and addresses searchable. Existing saved drafts are combined without truncation.
The **You** conversation sends directly to its most recently active verified self
address, so sending still works when Messages cannot resolve the merged chat ID.

Opening a conversation loads its latest 100 messages. Older history loads when
you scroll back and remains available offline. Background relay imports and
reconciliation update sidebar previews and cached messages without copying the
full archive into the local cache. Live messages continue to arrive normally.
When upgrading a cache that predates lazy history loading, its history is trimmed
once to the latest 100 messages per conversation, including merged self chats;
drafts, send records, and their linked message echoes are preserved. Older messages
remain on the Mac and can be fetched again by scrolling back.

## Keyboard and text input

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
Lettering requests RGB subpixel antialiasing on opaque backgrounds, with a
grayscale fallback where unsupported. Transparent text overlays use grayscale
antialiasing; text on solid surfaces is composited against its actual background
to preserve the RGB coverage at glyph edges.
Combining marks and joined emoji survive editing and restart. Full input-method/preedit
integration, visual bidirectional cursor navigation, and accessibility are future
work. For input-method users, set `enter_to_send` to `false` to reserve plain Enter
for text input and use Ctrl+Enter or the Send button; paste committed text from an
IME-capable editor when needed. Missing glyphs remain copyable as original UTF-8.

## Hiding conversations

Click **Hide** in a conversation's header to remove it from the main sidebar.
Open **Hidden** in the navigation rail and click **Unhide** to restore it;
**Messages** returns to the main list. Hidden conversations stay hidden across
restarts and new messages. Hiding only affects this client's local list; message
history and drafts are kept, and it does not block the sender or change Messages
on your Mac.

## Offline use and send recovery

Offline drafts are saved but new sends are not queued offline. Each outgoing
request is persisted before its first POST; recovery checks the original UUID
without automatically sending again. While the original submission is unresolved,
new sends stay as drafts. An uncertain or failed message can be copied
to a draft for deliberate retry. Uncertain status and **Copy to draft** wait
30 seconds from the original send time; confirmed failures remain actionable
immediately. Sending again after an uncertain result can
create a duplicate. A relay epoch reset preserves drafts and outbox identities;
orphaned drafts remain discoverable as **Recovered draft**. Local unread markers
do not change Apple's read receipts.

## Contacts and media

Contact names resolve by the original service/address across the sidebar, header,
senders, reaction details, search, and new notifications. Explicit chat titles stay
intact; Details keeps participant addresses available. Names and photos remain
cached offline. A permission revocation learned from the relay clears contact
presentation; its other messaging features continue independently.

Names and photos update automatically when Contacts changes on the Mac. The relay
also scans Contacts periodically. **Details** shows **Contacts permission** and
**Contacts freshness**. If an edit made on another Apple device has not appeared,
check that it has reached Contacts on the Mac.

Messages retain captions alongside multiple images, stored URL cards, and reaction
chips. Click an image for a larger view; Left/Right navigate that message's photos,
Escape closes, and R retries a failed image. Tab focuses visible image, link, and
reaction controls; Enter activates them. Reaction details identify each actor,
including your own reaction and any unresolved target part. Clicking a URL or card
shows its actual destination and full URL before opening or copying it. Displaying
a card never fetches a website or remote artwork. Ctrl+C on selected message text
keeps the original full text. **Show more** loads overflow metadata when needed.

Images use two authenticated transfers on a separate worker, private cache files
under `media/` in the data directory, a 512 MiB disk limit, and a combined 128 MiB
image pixel/texture ceiling. Cached images work offline; evicted images download
again on demand. Reconnect reloads media credentials too. Missing, unsupported,
corrupt, or oversized images keep a descriptive placeholder. HEIC conversion and
animated images' still frames come from the Mac; Linux decodes bounded PNG/JPEG.

See [Linux enrichment acceptance](linux-message-enrichment.md) for the client
contract, recovery coverage, and verification commands. Availability remains tied
to each relay capability and its readiness shown in Details; installed Mac
validation is tracked in the [Mac enrichment acceptance record](mac-enrichment-acceptance.md).

## Notifications

Incoming live messages show desktop notifications while Zimbr is running, including
when its window is unfocused or minimized. Notifications use the
[freedesktop notification service](https://specifications.freedesktop.org/notification/latest-single/)
on the session D-Bus: KDE Plasma provides it; on Hyprland, run a notification daemon
such as mako, dunst, or SwayNotificationCenter. Install the desktop entry and icon
with the installer above so the desktop can identify Zimbr in notification settings.
Your desktop controls notification sounds, expiration, and Do Not Disturb.

Alerts contain a conversation/sender name and a short message preview. History
imports, outgoing messages, repeated events, and messages being read in the focused
conversation do not alert. Reading the conversation dismisses its current alert.
Where the daemon supports actions, clicking an alert opens its conversation and
uses the supplied Wayland activation token to request focus; the compositor decides
whether to raise the window. Hidden conversations still notify. Closing Zimbr stops
message receipt and notifications; there is no background service. A missing or
unresponsive notification daemon does not interrupt messaging.

## Connection details

Connection status appears in the sidebar. **Details** in the navigation rail
(Ctrl+D) includes **Reconnect** in its header and opens
a scrollable pane with connection and retry status, relay capabilities, saved
sync cursor, cache counts, display information,
client certificate fingerprint and expiry, TLS failure details, and local file
paths. Private-key contents are never shown. Escape or **Back** returns
to messages. The sidebar search stays fixed while the list scrolls.
Conversation lists, message history, Details, and overflowing drafts show a
scrollbar: drag its thumb or click the track to move. Wheel scrolling is 25%
faster. Participant avatars and sender labels use matching colors on the dark background.

## Rendering and performance

Linux uses Wayland exclusively. The GUI was rendered at 125% desktop scaling
and uses `zimbr` as its application ID. Movement, scrolling, and navigation target
120 FPS, returning to idle rendering after half a second without activity. The
background worker continues to receive messages while rendering sleeps.
Idle input and worker results wake rendering immediately. Settled histories reuse
their geometry when scrolling or typing; offscreen history does not need a full
layout pass each frame. See [performance measurements](performance.md).

The bottom-right FPS counter is disabled by default. Enable it with
`zig build client -Dfps-counter=true` or `zig build run -Dfps-counter=true`.

Long messages display a preview of up to 4 KiB or 64 lines; the original remains
in the cache and selecting the message then pressing Ctrl+C copies its full text.
Text that cannot be rendered safely shows a placeholder. Sidebar labels use
shorter previews. History layout starts with the newest messages, reuses prepared
rows between frames, and fills in older rows within an 8 ms frame budget. Message rows
appear at their final size. Short conversations stay aligned to the bottom, and
scrolling up keeps your reading position while more history loads. `test-gui`
checks large-history layout, scroll stability, texture eviction, and long-message
rendering; `test-client` covers Unicode, raster bounds, and fractional-scale tiles.

The relay and client use filesystem/commit notifications, socket readiness,
durable event batches, reusable HTTP connections, and shared history snapshots.
Changed histories reuse immutable message records and prepared previews, while
ingestion batches resolve each conversation once and skip unchanged writes.
Conversation pages can include small sidebar previews, avoiding a request per
conversation. See [performance measurements and architecture](performance.md)
for benchmarks, reliability constraints, and remaining platform validation.

## Verification

```sh
# Add -Dopenssl-prefix=/absolute/openssl-3.5 if system OpenSSL is another minor version.
zig build test client-probe fake-relay
python3 tests/cert_management.py  # real mkcert required
python3 tests/client_native_tls.py
python3 tests/client_tls.py
python3 tests/client_integration.py
python3 tests/conversations.py
python3 tests/client_transport.py
python3 tests/client_lazy_history.py
python3 tests/client_enrichment.py
python3 tests/contact_refresh.py
python3 tests/client_enrichment_protocol.py
python3 tests/client_media_transport.py
python3 tests/client_details.py
# Requires a running Wayland desktop:
zig build test-gui
python3 tests/integration.py
python3 tests/mac_acceptance_test.py
python3 tests/mac_enrichment_packaging.py
zig fmt --check build.zig src
# Read-only connection check, with aggregate-only output:
zig-out/bin/client-probe --data-dir /path/to/client-data
```

`test-client` runs store, SSE, and Unicode text tests without a GPU. The Python
client integration suite uses the actual client worker, temporary device/CA
certificates, and the native relay's production TLS transport. Fault injection
uses mTLS on both the worker and relay sides of its intermediary. It covers
history, pagination, direct/group sends, echo merging, uncertain outcomes,
crashes, expired cursors, and epoch changes. A Wayland screenshot
can be exported with `zimbr --screenshot /path/to/image.png --frames 90`.

`python3 tests/client_notifications.py` tests the production notification backend
against a mock freedesktop service on a private D-Bus session. It requires a C
compiler, `pkg-config`, `dbus-run-session`, and Python GObject bindings (`python-gobject`
or `python3-gi`). It checks payloads, preview escaping, actions, Wayland tokens,
dismissal, absent/restarted daemons, timeouts, and shutdown. `test-client` also checks
notification eligibility, duplicate suppression, and transaction rollback.
After building `client` and `fake-relay`, add `--gui` to exercise the complete
synthetic relay-to-notification flow on Wayland, including click-to-open,
activation-token forwarding, and quiet restart.
