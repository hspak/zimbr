# Zimbr

**iMessage on Linux, through your Mac.** A native Wayland desktop client and a
self-hosted macOS relay, written in Zig 0.16.0. The Mac stays signed into Messages;
Linux never receives your Apple account credentials.

[AUR setup](docs/linux-setup.md) · [Linux client](docs/linux-client.md) · [Mac setup](docs/macos-relay.md) ·
[Documentation](docs/README.md) · [API](docs/api.md)

## Features

- Browse conversations, search names and addresses, and load older history on demand.
- Send direct iMessages and reply to existing conversations, including groups.
- Receive live updates and desktop notifications while the client is running.
- Keep cached history, Unicode drafts, contact names, and photos available offline.
- View inline images, stored link previews, and reactions when the relay supplies them.
- Drop local images and files into a draft, review them, and send with an optional caption.

The relay reads the Messages database without modifying it and sends through
Messages Automation. Every API and live-event connection requires HTTP/2 over TLS 1.3 and an
enrolled device certificate.

## Get started

1. On the Mac, install the relay and configure it with a hostname Linux can reach:

   ```sh
   brew install --cask hspak/tap/zimbr-relay
   zimbr-relay-setup relay.example
   ```

2. On Linux, install from AUR and connect through the Mac's SSH login:

   ```sh
   yay -S zimbr
   zimbr-provision setup user@relay.example
   ```

Setup handles certificates, enrollment, login startup, and saved connection
settings. Neither machine needs the Zimbr source. You need a Mac signed into
Messages, a Linux Wayland desktop, SSH access, and direct HTTPS access to the Mac.
Grant the required [macOS permissions](docs/macos-relay.md#permissions).
The [setup guide](docs/setup.md) covers these prerequisites and retries.

Later, open **Zimbr** or run `zimbr`. Enter sends; Shift+Enter adds a line.
Ctrl+N starts a conversation, Ctrl+F searches, and Ctrl+D opens connection details.

Building from source? Use [development setup](docs/development.md) with Zig
**0.16.0**. [Dev and release profiles](docs/macos-profiles.md) keep local builds
separate from packaged installations.

## Limits to know

The Mac needs its graphical login session; verify sends and locked-screen behavior
with the [validation guide](docs/mac-validation.md). Closing the Linux client stops
notifications. Offline drafts are saved, but new sends are not queued offline;
retrying an uncertain send can create a duplicate. Local caches contain plaintext.

Sending supports iMessage text and local files in direct or existing conversations.
Attachment dispatch still needs [real Mac acceptance](docs/attachment-relay-validation.md);
automated checks use a synthetic Messages adapter. Group creation, reaction sending,
video/audio playback, full input-method integration, and accessibility support remain
unimplemented. See [sending files](docs/linux-client.md#sending-files) for limits.
