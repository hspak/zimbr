# Zimbr documentation

For an installed AUR client, start with [AUR client setup](linux-setup.md).
For a packaged Mac relay, use [Homebrew setup](macos-relay.md#homebrew).
[Development setup](setup.md) covers building both apps from source.
Examples use generic paths and reserved network names; replace those with your
deployment values. Source-build and maintenance commands run from the repository
root unless noted otherwise. On the Mac, `python3` commands assume the setup
environment is active (`. .tools/python/bin/activate`).

## Setup and operation

| Guide | Contents |
| --- | --- |
| [AUR client setup](linux-setup.md) | Enroll and connect an installed Linux client using release paths and commands |
| [Homebrew relay setup](macos-relay.md#homebrew) | Configure the packaged Mac relay, permissions, and login startup |
| [Development setup](setup.md) | Dependencies, source builds, generated configuration, permissions, and Linux enrollment |
| [Linux client](linux-client.md) | Configuration, keyboard controls, notifications, offline use, media, and tests |
| [macOS relay](macos-relay.md) | Menu, permissions, updates, diagnostics, and service management |
| [Linux TLS](linux-mtls.md) | Credential import, diagnostics, reconnect, and renewal |
| [macOS TLS](macos-tls.md) | mkcert administration, code signing, server renewal, and revocation |
| [Profiles](macos-profiles.md) | Independent dev/release identities, data directories, and ports |
| [Mac validation](mac-validation.md) | Installed permissions, deliberate sends, restart and locked-session checks |
| [Mac menu validation](macos-menu-bar-validation.md) | Repeatable appearance, settings, recovery, and lifecycle checks |
| [Packaging and releases](linux-packaging.md) | Maintainer builds, archives, AUR, and Homebrew publishing |

## Protocol and implementation

- [API v1](api.md): routes, synchronization, SSE, send recovery, and limits.
- [Certificate contract](certificate-management.md): key ownership, validated
  issuance/import, fingerprint authorization, and lifecycle.
- [Message security](message-security.md): parsing/storage boundaries and tests.
- [Group delivery](group-delivery.md): checkmark semantics and source limitations.
- [Linux enrichment](linux-message-enrichment.md): contacts, media, links, reactions,
  and client recovery.
- [Mac enrichment](macos-message-enrichment.md): source/transport contract and
  native verification procedures.
- [System design](../DESIGN.md): architectural background; use the API and guides
  above for operational commands.
