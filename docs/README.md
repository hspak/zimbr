# Zimbr documentation

Start with the [macOS relay](macos-relay.md), then enroll and configure the
[Linux client](linux-client.md). Commands in these guides run from the repository
root unless noted otherwise.

## Setup and everyday use

| Guide | Contents |
| --- | --- |
| [Linux client](linux-client.md) | Dependencies, build/install, configuration, keyboard controls, notifications, offline behavior, media, and tests |
| [macOS relay](macos-relay.md) | Build/test, installation, permissions, Contacts, updates, diagnostics, and service management |
| [Linux mTLS setup](linux-mtls.md) | Device enrollment, client configuration, reconnect, and renewal |
| [macOS TLS operation](macos-tls.md) | CA and server provisioning, code signing, credential installation, renewal, and revocation |
| [macOS validation](mac-validation.md) | Installed permissions, deliberate test sends, restart recovery, and locked-session checks |
| [macOS menu bar validation](macos-menu-bar-validation.md) | Native/installed evidence and remaining icon, Settings, recovery, and lifecycle checks |

## Protocol and implementation

- [API v1](api.md): routes, synchronization, SSE, send outcomes, source resets,
  and limits.
- [Certificate management contract](certificate-management.md): issuance,
  enrollment, CSR exchange, and credential lifecycle.
- [Message security](message-security.md): parsing and storage boundaries with
  regression coverage.
- [Linux message enrichment](linux-message-enrichment.md): client behavior,
  recovery, and verification for contacts, images, links, and reactions.
- [Mac enrichment acceptance](mac-enrichment-acceptance.md): implemented
  capabilities, installed evidence, source formats, and remaining validation.
- [macOS 27 source schema](macos-27-schema.json): observed Messages database schema.

## Performance

- [Performance measurements and architecture](performance.md), with reproduction
  commands and platform validation limits.
- [Performance hardening audit](performance-hardening.md).
- [Client SIMD trials](client-simd.md).

## Design and migration records

These documents retain design decisions and earlier implementation plans; use the
guides and acceptance records above for current behavior.

- [System design](../DESIGN.md).
- [Message enrichment design](message-enrichment.md).
- [mTLS migration](mtls-migration.md).
- [Linux mTLS integration review](linux-mtls-review.md).
