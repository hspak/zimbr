# API v1

The relay exposes HTTPS and server-sent events (SSE) over TLS 1.3 and HTTP/2.
ALPN must select `h2`; HTTP/1 and connections without ALPN are rejected.
SSE uses HTTP/2 DATA frames and can share a connection with commands and queries.
Upgrade the client, relay, and administrative tools together.
Every route requires a clientAuth certificate from the dedicated CA and an enabled
SHA-256 leaf fingerprint. See
[certificate management](certificate-management.md) and [relay operation](macos-relay.md#operation)
for enrollment and an authenticated status example.

## Routes

| Method | Path | Response |
| --- | --- | --- |
| GET | `/v1/status` | Epoch, readiness, capabilities, sync activity, degraded reasons |
| GET | `/v1/sync` | Epoch and durable event cursor |
| GET | `/v1/conversations?before=...&limit=50` | `conversations`, `next` |
| GET | `/v1/conversations/:id/messages?before=...&limit=50` | `messages`, `next` |
| GET | `/v1/identities?before=...&limit=50` | Observed-address `identities`, `next` |
| GET | `/v1/assets/:id/:version/:variant` | Approved immutable JPEG/PNG bytes or availability/retry response |
| GET | `/v1/messages/:id/enrichment?section=...&revision=...&after=...` | Bounded overflow metadata and revision-bound `next` |
| GET | `/v1/messages/:id` | Canonical message including inline enrichment |
| POST | `/v1/messages` | Durable send request; 202 new, 200 retry |
| POST | `/v1/uploads` | Reserve an outgoing file's metadata and bytes; 200 on exact retry |
| PUT | `/v1/uploads/:id` | Stream and verify original bytes; 200 when complete |
| GET | `/v1/uploads/:id` | This device's upload metadata and phase |
| DELETE | `/v1/uploads/:id` | Retire an unused upload for cleanup; 204 |
| GET | `/v1/send-requests/:id` | Current send request |
| GET | `/v1/events?after=...` | SSE replay followed by live events |

## Sending messages

Send bodies follow the [design specification](../DESIGN.md): Base64url UUID `request_id`,
expected `server_epoch`, `text`, and exactly one target: `conversation_id` or
`recipient: {address, service: "imessage"}`. Use an international phone number or
unambiguous email. The adapter requires one enabled iMessage account and checks
existing chats against that account. It never chooses SMS/RCS or creates a group.
Unknown optional JSON fields are accepted. IDs are case-sensitive and must use
canonical unpadded Base64url; hyphenated UUIDs and nonzero pad bits are rejected.

## Outgoing file uploads

`attachment_uploads_v1` advertises upload storage. Sending those files is a
separate capability, `send_attachments_v1`, which remains false until attachment
dispatch is implemented. The current send endpoint rejects nonempty attachment
arrays; it never sends just their caption.

Reserve with `POST /v1/uploads`, `Content-Type: application/json`, and:

```json
{
  "server_epoch": "<current epoch>",
  "file": {
    "id": "<client-generated Base64url UUID>",
    "name": "photo.png",
    "mime_type": "image/png",
    "bytes": "<canonical decimal byte count>",
    "sha256": "<64 lowercase hexadecimal characters>"
  }
}
```

The response contains `server_epoch`, `file`, and `phase` (`reserved`,
`receiving`, `ready`, or `pinned`). Upload IDs belong to the authenticated client
certificate. Another enrolled device cannot inspect, overwrite, or cancel them.
Reusing an ID with different metadata returns 409.

PUT, GET, and DELETE require `Zimbr-Server-Epoch: <current epoch>`. PUT also
requires `Content-Type: application/octet-stream` and an exact `Content-Length`,
including `0` for empty files. Send raw original bytes, without JSON or Base64.
The relay writes bounded chunks to private files and verifies both length and
SHA-256 before publishing `ready`. Interrupted uploads return to `reserved`;
restart discards their partial files. Retry from the beginning with the same ID.
A PUT for an already completed upload returns its metadata without rewriting
its bytes. GET resolves a lost upload response.

DELETE is idempotent for absent/retired IDs. Active transfers return 409: cancel
the HTTP stream first, then retry DELETE. Files pinned by a send cannot be
cancelled. Cleanup removes retired files before releasing quota. Unused uploads
expire after 24 hours or an epoch change. Pinned files remain protected across
resets and uncertain send outcomes.

Limits are 100 MiB per file, 256 reservations, 2 GiB reserved storage, and four
active PUT requests. Uploads have a 30-second idle timeout and a 15-minute total
deadline. Other command bodies retain their 64 KiB limit. These are application
resource bounds, not a guarantee about files Messages can deliver.

## Pagination and synchronization

Public IDs are opaque. Generated UUIDs (including request IDs, epochs, identity
IDs, asset IDs, and asset versions) encode their 16 bytes as 22 Base64url
characters. Attachment IDs encode the full SHA-256 of the private source GUID
as 43 Base64url characters. Both encodings omit `=` padding and preserve case.
Revisions and event sequences are decimal strings.
Timestamps are UTC with source nanosecond precision. Conversation pages descend
by immutable relay ID; history pages descend by `(source timestamp, relay ID)`.
Treat `next` and event cursors as opaque strings and URL-encode them. Fetch a sync
cursor **before** fetching snapshots, then replay after it; merge by ID/revision.
History queries also enqueue bounded source reconciliation.

## Conversations and routing

Conversation records may include `is_self` (default `false`) and `thread_id`
(default `null`). A verified reciprocal pair of local addresses on one Messages
account shares the older source chat's relay ID as its thread ID. Clients group
those records for presentation; each conversation retains its own ID and source
route. The Linux client uses a verified self address for new sends from **You**.
History requested through either member includes both histories, with
original message IDs and `conversation_id` values and one shared pagination order.
On a grouping change, clients restart history pagination. Matching contact names
alone never combines conversations.

For Messages' transport-neutral `any;…` routes, the latest ordinary message
determines the service, falling back to the chat label when no such message exists.
Reactions and system events do not change that classification. Dispatch rechecks
the same source rule and retains the existing enabled-iMessage-account checks.

## Enrichment

Enrichment fields are additive. Complete empty arrays clear older aggregates;
`null` means unsupplied. Inline metadata has a combined 32 KiB budget and exposes
totals/completion flags; overflow pages never silently drop attachments, captions,
previews, parts, or reactions. A changed revision requires restarting those pages.
Identity events require `extensions=identity-v1` and an echoed
`Zimbr-Event-Extensions` response header. Streams without that extension skip
identity events. Bootstrap identities after capturing a sync cursor, then replay
and merge by revision. Capability support and readiness are
separate, so permission loss can still synchronize clearing records.

The relay updates observed identities automatically when Contacts changes on the
Mac and through periodic scans. Clients receive those updates through negotiated
identity events. `enrichment_readiness.identity_directory_v1` in `/v1/status`
reports `ready`, `stale`, `permission`, `reason`, `refreshing`, and `last_refresh_ms`.

`/v1/status` also reports `sync_activity`, with boolean `messages`, `contacts`,
`images`, and `media` fields. Multiple fields can be true during overlapping
backfills. They cover historical message import/reconciliation, contact lookup
and identity backfill, runnable image preparation, and metadata backfill,
respectively. Blocked work and delayed image retries are excluded. Clients may
poll more frequently while work is active and combine this with their own
download queues; missing fields on older relays default to false.

## Events

SSE uses `id`, `event`, and JSON `data`, with 15-second comment heartbeats. Each
event contains its cursor, sequence, full record, type, and origin (`live`,
`historical_import`, or `reconciliation`). Replays are at least once. Notify only
for newly committed incoming live events. Conflicting `Last-Event-ID` and `after`
values are rejected. Epoch mismatch returns 409; expired event cursors return
410 with `resync_required`. A connected stream closes on a reset/expired cursor.
Reconnect using the last applied cursor to receive the explicit error.

## Send outcomes and recovery

Errors use `error_info: {code, message, outcome}`. `outcome` is `unstarted` or
`uncertain`. HTTP acceptance means persistence succeeded, not delivery. A success
from AppleScript remains uncertain until a unique outgoing database record is
observed in the actual route within the dispatch window. Correlation waits 10
seconds to expose competing candidates. Multiple candidates remain unknown.
Interrupted dispatches are never automatically resent. If saving a dispatch
result fails, the worker recovers it as unknown when persistence is available,
without requiring a restart or invoking the send again. Queued requests can resume
only after route/epoch revalidation. Query by the original request ID after a
network failure. Idempotency identities are never automatically pruned.

## Source resets

`POST /v1/reset` accepts JSON `{"server_epoch":"<epoch from /v1/status>"}`
from an enrolled mTLS client. Status advertises `state_reset_v1`. When the supplied
epoch matches, the relay transactionally creates a fresh epoch, clears generated
history, identity and media records, and restarts ingestion. Existing streams
must resync. Unreferenced media files are reclaimed in the background; source
Messages and Contacts, TLS configuration and credentials are untouched.

The response is HTTP 200 with `server_epoch` and `cursor`, like `/v1/sync`. If the
epoch already changed, it returns the current snapshot without another reset,
making a retry of the same request safe after a lost response. Keep the original
epoch until a complete, valid response arrives. The reset affects every connected
client. Pending sends are held as `unknown`; idempotency records are retained and
never automatically resent. Old-format send identities remain private in the
journal rather than being emitted as invalid events.

A relay with an incompatible stored epoch accepts only `/v1/status` and this
reset operation; other requests return HTTP 409 `relay_cache_reset_required`.
The reset's expected epoch is opaque so the same operation can recover old IDs.
Invalid bodies return 400; failed transactions roll back and return 503.

On macOS, the source identity uses a persistent volume UUID, inode, and birth
time, so reboot-time device renumbering preserves the journal. Source identity
changes or unexplained high-water/anchor mismatches rebuild normalized
source state under a new epoch. Old queued/in-flight requests become
held `unknown` requests with `source_reset`, retaining their request IDs. Clients
must explicitly synchronize again. Conservative invalidation may also occur for
a benign database replacement or deletion of an ordinary anchor. A tracked
reaction deletion preserves the epoch only with the same source identity and
independent matching ordinary anchors; the scan rebases with GUID deduplication.

## Limits

Limits: 64 KiB request bodies, 16 KiB outgoing UTF-8 text, 1 MiB decoder inputs,
64 KiB decoded incoming text, 200 records/page, 32 connections, 8 event streams,
10-second socket timeouts, and 15-second automation runtime with 128 bytes of
retained status output. Over-limit content becomes a classified placeholder.
Events are pruned every minute to seven days and at most 100,000 records by
default. Pruning does not delete normalized history or request identities.

Message handling also bounds JSON nesting/complexity, shared plist expansion,
attachment enumeration, and client metadata accumulation. Malformed text and
oversized source metadata use classified fallbacks. See the
[message security boundaries and regression tests](message-security.md).

## Decoding and supported content

The attributed decoder recognizes the observed immutable/mutable typed-stream
root NSString layouts and validates their length, encoding, and string terminator.
It does not instantiate archived classes or scrape printable bytes. A restricted
Foundation attribute grammar also maps verified text/image parts using source
indices and file-transfer GUIDs; unknown layouts retain full text and attachment
fallbacks. Stored URL payloads use a bounded primitive plist/archive reader.
Reactions retain their source rows and publish complete target aggregates using
durable source ordering/removal state. Resolved reaction rows are skipped by the
relay sidebar projection. General message deletion, reaction/attachment sending,
group administration, read receipts, video/audio playback, and animated stickers
remain outside this reading extension.
