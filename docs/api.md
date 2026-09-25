# API v1

The relay exposes HTTPS and server-sent events (SSE) over TLS 1.3 and HTTP/1.1.
Every route requires a clientAuth certificate from the dedicated CA and an enabled
SHA-256 leaf fingerprint; bearer tokens grant no access. See
[certificate management](certificate-management.md) and [relay operation](macos-relay.md#operation)
for enrollment and an authenticated status example.

## Routes

| Method | Path | Response |
| --- | --- | --- |
| GET | `/v1/status` | Epoch, readiness, capabilities, degraded reasons |
| GET | `/v1/sync` | Epoch and durable event cursor |
| GET | `/v1/conversations?before=...&limit=50` | `conversations`, `next` |
| GET | `/v1/conversations/:id/messages?before=...&limit=50` | `messages`, `next` |
| GET | `/v1/identities?before=...&limit=50` | Observed-address `identities`, `next` |
| GET | `/v1/assets/:id/:version/:variant` | Approved immutable JPEG/PNG bytes or availability/retry response |
| GET | `/v1/messages/:id/enrichment?section=...&revision=...&after=...` | Bounded overflow metadata and revision-bound `next` |
| POST | `/v1/messages` | Durable send request; 202 new, 200 retry |
| POST | `/v1/contacts/refresh` | Force a Contacts scan; empty body, 202 with `refresh_id` |
| GET | `/v1/send-requests/:id` | Current send request |
| GET | `/v1/events?after=...` | SSE replay followed by live events |

## Sending messages

Send bodies follow the [design specification](../DESIGN.md): UUID `request_id`,
expected `server_epoch`, `text`, and exactly one target: `conversation_id` or
`recipient: {address, service: "imessage"}`. Use an international phone number or
unambiguous email. The adapter requires one enabled iMessage account and checks
existing chats against that account. It never chooses SMS/RCS or creates a group.
Unknown optional JSON fields are accepted. UUID casing is normalized.

## Pagination and synchronization

Public IDs are opaque; revisions and event sequences are decimal strings.
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
`Zimbr-Event-Extensions` response header. Legacy streams keep their existing event
types and skip identity sequences. Bootstrap identities after capturing a sync
cursor, then replay and merge by revision. Capability support and readiness are
separate, so permission loss can still synchronize clearing records.

Relays advertising `refresh_contacts_v1` accept an authenticated, empty-body
`POST /v1/contacts/refresh`. It schedules a fresh Contacts snapshot and rematches
all observed identities, bypassing the periodic scan and cached index. Contact
photos receive fresh asset versions. The response is `202 {"refresh_id": N}`.
Poll `enrichment_readiness.identity_directory_v1` in `/v1/status`: its
`refresh_requested` and `refresh_completed` identify the latest requested scan
and the last scan whose identity work has finished. Completion is successful
only when `ready` is true and `stale` is false; permission and persistence failures
remain visible in `reason`. Refresh IDs are process-local; if a restarted relay
reports `refresh_requested` below the accepted ID, request another refresh.
After success, clients can replace their identity cache from `/v1/identities`,
merging live identity events by revision while preserving their saved event cursor.

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
observed in the actual route within the dispatch window. Correlation waits 30
seconds to expose competing candidates. Multiple candidates remain unknown.
Interrupted dispatches are never automatically resent. If saving a dispatch
result fails, the worker recovers it as unknown when persistence is available,
without requiring a restart or invoking the send again. Queued requests can resume
only after route/epoch revalidation. Query by the original request ID after a
network failure. Idempotency identities are never automatically pruned.

## Source resets

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
Reactions retain legacy source rows and publish complete target aggregates using
durable source ordering/removal state. Resolved reaction rows are skipped by the
relay sidebar projection. General message deletion, reaction/attachment sending,
group administration, read receipts, video/audio playback, and animated stickers
remain outside this reading extension.
