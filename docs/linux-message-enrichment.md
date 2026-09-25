# Linux message enrichment

The Linux client consumes the shared contract from relay commit `4e65027`
(`relay: add media enrichment support`), rechecked on 2026-09-24.
No relay adapter, journal schema, or shared protocol types are changed by the
client implementation. All six native enrichment capabilities are now enabled;
the [Mac acceptance record](mac-enrichment-acceptance.md) records the installed
evidence and remaining native reaction verification limits.

## Implementation and recovery

- `IdentityDirectory.zig` resolves exact service/address pairs. Names are used in
  conversation titles, search, senders, reaction details, and new notification
  summaries. Explicit titles and routing handles remain unchanged. Details shows
  participant addresses and feature readiness, permission, and freshness.
- `Store.zig` migrates separate identity and overflow caches without discarding
  drafts or outbox records. Identity records merge by decimal revision, and live
  records/cursors commit together. Empty newer aggregates clear older content.
- `Worker.zig` negotiates `identity-v1` only when status advertises the capability
  and extension. The C bridge exposes `Zimbr-Event-Extensions`; a missing or
  mismatched echo blocks the stream before any event is applied. Bootstrap captures
  H, fetches all conversation and identity pages, then replays after H. Restart,
  same-epoch upgrade, downgrade/re-upgrade, and expired H cannot reuse an incomplete
  directory. Permission denial gates cached presentation through reconciliation.
- `Content.zig` prepares text, attachment, card, reaction, and overflow controls.
  Verified text ranges and part IDs preserve source placement; otherwise the full
  caption precedes attachment rows. Raw resolved reactions are suppressed when the
  target is cached; unresolved/unsupported rows keep an explanatory fallback.
  Reaction changes never add unread counts or notifications.
- Overflow pages are validated against message, section, revision, and cursor.
  Expanded content has a local serial independent of the canonical revision, so
  it replaces prepared rows without accepting stale history. A newer message
  invalidates the old expansion; conflicts refresh history and allow Show more
  against the current revision.
- `Media.zig` owns a dedicated worker with two binary curl lanes, independent of
  ordinary requests and SSE. It applies the same TLS/origin/credential rules,
  uses private temporary files, verifies completion, decodes bounded PNG/JPEG,
  and atomically installs valid bytes. Only `/v1/assets` on the configured relay
  is fetched. Pending/retryable failures back off; retired versions refresh owner
  metadata; other failures offer a visible fallback and deliberate retry.
- Cache keys include relay URL, CA digest, epoch, asset, version, and variant.
  Epoch/chat/credential/availability changes cancel obsolete work and reject late
  results. Contact permission loss removes avatar cache references and bytes.
  Disk LRU is capped at 512 MiB, reserving space for two 8 MiB transfers. Abandoned
  temporary files are swept after their transfer lifetime. Files are 0600 in a
  0700 directory and are not included in diagnostics.
- `ImageCache.zig` uploads/unloads textures on the GUI thread. Textures have a
  64 MiB budget and bounded entry count. Decoding pauses while the GUI owns a
  delivered result: at most 64 MiB of decoded/transient image pixels and 64 MiB
  of textures coexist. Each image is bounded to 32 MiB decoded and 8 MiB encoded.
  Visible images plus a small viewport margin are requested; variants share one
  pipeline for attachments, cards/icons, and avatars.
- The viewer supports close/Escape, Left/Right, and retry. Captions, multiple
  images, still-preview labels, non-image rows, and full-text copy are retained.
  Cards show literal metadata and the chosen destination hostname. Activation
  accepts only HTTP(S) and opens the destination directly in the default browser
  using the desktop URI API. Plain URLs remain text links. No remote previews are
  generated.
- Prepared keys cover parts, reactions, asset versions, sender identity revision,
  width, and scale. Immutable unaffected message records and text layouts are
  reused. Message/part anchors keep the reading position when geometry changes.
  Reaction detail names and membership refresh while the detail is open.

## Verification

Automated fixtures contain generated contacts, images, addresses, and Messages
rows. The real fixture relay supplies journal, asset service, and transport
behavior; separate TLS fault fixtures inject malformed responses and negotiation
failures. No test reads a real address book or Messages database.

| Requirement | Evidence |
| --- | --- |
| Names, explicit titles, exact handles, Unicode, ambiguity, self | `IdentityDirectory` tests; GUI reaction details; notification tests |
| Rename/removal, denied/restricted/unavailable permission, same-generation recovery, offline cache, first upgrade and restart | `client_enrichment.py`, `client_enrichment_protocol.py` |
| Extension echo, legacy relay, interrupted multi-page bootstrap, expired H | `client_enrichment_protocol.py`; existing TLS suites |
| Revision merging, cursor rollback, clearing aggregates, overflow | `client_tests.zig`, Worker tests, `client_enrichment.py` |
| Real asset delivery, pending conversion, avatar clearing, offline bytes | `client_enrichment.py` through the actual fake relay/image helper |
| PNG alpha, JPEG, corruption, excessive dimensions/bytes, MIME, truncation | `Media` tests and `client_media_transport.py` |
| Two transfers, send priority, cancellation, namespace and symlink isolation | `client_media_transport.py`; existing transport tests |
| Cards and safe URL choice, custom emoji, actor counts, missing parts | `Content` / `Links` tests and GUI enrichment test |
| Captions/copy, image/card/chip hit targets, keyboard viewer, 100/125/200% | `test-gui` enrichment interaction test |
| Scroll anchoring and reuse across large histories | `test-gui`, immutable-history tests, `client-bench` |
| Existing sending, drafts, TLS renewal/revocation, offline recovery | existing client integration, transport, TLS, native TLS, and Details suites |

### Completed relay compatibility check (2026-09-24)

Compared `4e65027` with its WIP parent `78d8c9b`. Shared protocol types,
identity/SSE negotiation, asset paths and metadata paging remain compatible.
The relay now enables native names, avatars and reactions, reports the live
Contacts permission monitor's decision, and bounds inline metadata preparation
more efficiently. The client already handles these changes without a protocol or
transport adjustment. The client integration fixture now checks denied,
restricted and unavailable permissions plus same-generation recovery, preserving
identity, epoch, drafts and quiet unread behavior.

The updated configured hostname resolved through `tailscale0`. A read-only live
check used a disposable client cache and verified mutual TLS, all six advertised
capabilities/readiness states, complete negotiated identity bootstrap, and a
bounded sample of histories containing attachments, stored cards and reactions.
The production media worker decoded sample avatar, inline and viewer variants.
Lazy media conversion can initially return pending; visible requests continue
through the existing retry path. No messages were sent, and the disposable cache
was removed afterward. This check does not add native source-format acceptance
beyond the Mac record.

Rebuilt the client/probe and fixture relay; `zig build test`,
`client_enrichment.py`, `client_enrichment_protocol.py` and
`client_media_transport.py` pass against this revision.

Commands (Zig 0.16.0):

```sh
zig build test client client-probe client-bench
zig build test-gui  # running Wayland display required
python3 tests/client_enrichment.py
python3 tests/client_enrichment_protocol.py
python3 tests/client_media_transport.py
python3 tests/client_integration.py
python3 tests/client_transport.py
python3 tests/client_tls.py
python3 tests/client_native_tls.py
python3 tests/client_details.py
python3 tests/client_notifications.py
zig-out/bin/client-bench 25000 1024
zig fmt --check build.zig src
```

On systems with another OpenSSL minor version, add
`-Dopenssl-prefix=/absolute/openssl-3.5` for relay tests. Linux additionally links
libpng and libjpeg; it has no Contacts, Foundation, or ImageIO dependency.

A local Debug benchmark of 25,000 cached 1 KiB messages measured unchanged
snapshot p95 13.54 ms, one edited message p95 15.50 ms, and append p95 16.27 ms.
The initial parse was 648 ms. This measures cache publication, not frame rate or
Mac source ingestion.

Native HEIC conversion, orientation handling, Messages payload decoding, Contacts
attribution, and reaction source semantics are Mac acceptance work. Linux tests
prove presentation of their normalized contract; they do not substitute for those
installed Mac checks. Sending images/reactions, original-file export, and animated
playback remain outside the reading/presentation scope.
