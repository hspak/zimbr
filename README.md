# Zimbr

**iMessage on Linux, through your Mac.** A native Wayland desktop client and a
self-hosted macOS relay, written in Zig 0.16.0. The Mac stays signed into Messages;
Linux never receives your Apple account credentials.

[Linux client](docs/linux-client.md) · [Mac setup](docs/macos-relay.md) ·
[Documentation](docs/README.md) · [API](docs/api.md)

## Features

- Browse conversations, search names and addresses, and load older history on demand.
- Send direct iMessages and reply to existing conversations, including groups.
- Receive live updates and desktop notifications while the client is running.
- Keep cached history, Unicode drafts, contact names, and photos available offline.
- View inline images, stored link previews, and reactions when the relay supplies them.

The relay reads the Messages database without modifying it and sends through
Messages Automation. Every API and live-event connection requires TLS 1.3 and an
enrolled device certificate.

## Get started

You need a Mac logged into Messages, a Linux Wayland desktop, Zig **0.16.0**,
and direct network access from Linux to the relay.

1. **Set up the Mac.** Follow the [relay guide](docs/macos-relay.md) to build,
   [provision certificates](docs/macos-tls.md), install, and grant Full Disk Access
   and Messages Automation. Contacts access is optional.
2. **Enroll Linux.** Follow [Linux mTLS setup](docs/linux-mtls.md) to create the
   device key, have its certificate signed and enrolled, and enter the paths in Settings.
3. **Build and run.** Install the [Linux dependencies](docs/linux-client.md#build-and-install),
   then run from this checkout:

   ```sh
   zig build client -Doptimize=ReleaseSafe
   packaging/linux/install.sh  # User-local executable, icon, and launcher
   zig build run -Doptimize=ReleaseSafe
   ```

Enter sends; Shift+Enter adds a line. Ctrl+N starts a conversation, Ctrl+F searches,
and Ctrl+D opens connection details and **Reconnect**.

To update an installed relay, run on the Mac from this checkout:

```sh
./tools/update-relay.sh --release=safe
```

See [relay updates](docs/macos-relay.md#update-the-running-relay) for prerequisites
and verification.

## Limits to know

The Mac needs its graphical login session; verify sends and locked-screen behavior
with the [validation guide](docs/mac-validation.md). Closing the Linux client stops
notifications. Offline drafts are saved, but new sends are not queued offline;
retrying an uncertain send can create a duplicate. Local caches contain plaintext.

Sending is limited to iMessage text in direct or existing conversations. Group
creation, attachment/reaction sending, video/audio playback, full input-method
integration, and accessibility support remain unimplemented.
