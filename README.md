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

Follow the [Mac + Linux setup guide](docs/setup.md). It covers dependencies,
building both apps, mkcert certificate issuance, Mac permissions, and device
enrollment. The Linux importer opens Settings with verified credentials filled in.

You need Zig **0.16.0**, a Mac signed into Messages, a Linux Wayland desktop,
and direct network access between them. Source builds use the **dev** profile
(port 8732); packaged releases use **release** (port 8731).

Enter sends; Shift+Enter adds a line. Ctrl+N starts a conversation, Ctrl+F searches,
and Ctrl+D opens connection details and **Reconnect**.

To update the development relay, run on the Mac from this checkout:

```sh
./tools/update-relay.sh --profile dev --release=safe
```

See [relay updates](docs/macos-relay.md#update-the-running-relay) for prerequisites
and verification. [Dev and release profiles](docs/macos-profiles.md) keep local
builds separate from the Homebrew installation.

## Limits to know

The Mac needs its graphical login session; verify sends and locked-screen behavior
with the [validation guide](docs/mac-validation.md). Closing the Linux client stops
notifications. Offline drafts are saved, but new sends are not queued offline;
retrying an uncertain send can create a duplicate. Local caches contain plaintext.

Sending is limited to iMessage text in direct or existing conversations. Group
creation, attachment/reaction sending, video/audio playback, full input-method
integration, and accessibility support remain unimplemented.
