# Decode once and retain wire records

This is a historical implementation/measurement report. Benchmark results and
suite counts below describe that revision; use [setup](setup.md) for current
installation and rerun the listed checks for a new build.

This pass follows the [bounded storage work](bounded-data.md). The shared v1
types already describe both endpoints' payloads, so the client can decode those
types directly and keep the original JSON bytes for persistence. A generic JSON
tree is unnecessary when the code only needs to forward or store a record.

## Removed conversions

| Path | Previous work | Current work |
| --- | --- | --- |
| Client history, conversation and identity pages | Parse an envelope into generic JSON trees, serialize each record, then parse it into a shared type. | Decode each shared type once while recording its input span. Validate the record and copy its original bytes into SQLite. |
| Sidebar previews and metadata hydration | Reparse a record already decoded by the response handler. | Pass the decoded record to the cache writer. Conversation IDs also come from the already decoded conversation. |
| Client live messages | Decode a generic event record, serialize it, parse the message for notifications, then parse it again for the cache. | Keep the event record's bytes, decode the message once, and reuse it for cache and notification work. |
| Generated previews and send acknowledgements | Serialize a locally constructed preview and immediately parse it; reparse a send record to update the outbox. | Use the existing typed preview or send record when updating the cache. A stale send response still reads the authoritative newer stored record. |
| Relay event and enrichment responses | Parse stored JSON into a tree solely to embed it in a response. | Validate the stored JSON and write its bytes into the response envelope. |
| Client enrichment continuation | Parse generic item trees, combine and serialize them, then parse the combined JSON into typed items. | Select the requested section's type once, decode items directly, and merge typed items while retaining their original bytes for continuation storage. |

`protocol.json.Decoded(T)` wraps Zig's existing typed parser and records the
consumed input span. The default parsing mode borrows that span and any unescaped
strings; escaped strings belong to the caller's arena. `alloc_always` copies both
the raw record and its parsed strings. Cache writers copy bytes into SQLite
before returning, and their API documents that the typed record and raw bytes
must come from the same parser result.

`protocol.Json` handles opaque values whose envelope needs decoding or encoding.
It validates JSON grammar and UTF-8 without constructing a tree or interpreting
numbers. Serialization removes literal CR/LF formatting bytes, which valid JSON
cannot contain inside strings. Escaped newlines remain intact, so pretty-printed
stored records cannot split an SSE data line. This type moved from the relay into
the shared protocol module because both endpoints use it.

The previous generic conversion rounded the unknown numeric field
`1.234567890123456789` to `1.2345678901234567`. A worker-level regression copied
unchanged into the saved pre-change source fails there and passes with the new
path. The cache now preserves those original numeric tokens and unknown fields.

## Conversions retained

- Byte, depth and token checks remain before decoding network input. Shared
  types still validate field types, required fields and duplicate known fields;
  cache writes retain their semantic validation and revision rules. Unknown
  fields are checked for valid JSON and preserved as opaque bytes.
- SSE envelope decoding and record interpretation remain separate. Cursor,
  event type, origin and extension negotiation determine how the record is
  consumed. No generic tree or intermediate JSON serialization is involved.
- Each process still decodes network input and reads its durable cache after a
  restart. Immutable message snapshots already avoid reparsing unchanged rows.
- Canonical records whose contents change still need serialization. Enrichment
  merging changes a message; relay normalization and revision assignment also
  change records. Status persistence deliberately projects documented fields for
  offline diagnostics, so arbitrary response fields are not stored.
- v1 decimal-string revisions and cursors remain compatible with existing
  clients. Integer conversion is still needed for ordering and validation in
  SQLite. Removing these small conversions would require a wire/schema change;
  the expensive tree/text round trips can be removed without one.

## Measurements

Zig 0.16.0, ReleaseFast, Linux x86_64. The baseline is a saved source snapshot
immediately after the bounded storage pass, including its uncommitted changes.
Both versions use the same expanded `hotpath-bench` source. Three sequential pairs
alternate execution order with no concurrent builds or tests; each run discards
a warmup and measures 15 batches. The table gives the median of per-run medians.
[Raw results and baseline source hashes](performance-serialization.json) retain
all runs and the existing control measurements.

| Measurement | Before | After | Time reduction |
| --- | ---: | ---: | ---: |
| Relay event batch construction | 938 µs | 258 µs | 72.5% |
| Client event batch ingestion | 2,972 µs | 1,640 µs | 44.8% |

The fixture contains 1 KiB message text. Each batch scans 100 journal entries:
one conversation, 98 messages and one identity event omitted from a legacy
stream. Relay samples average 20 batch constructions. Client samples average
10 deliveries through the SSE parser and production cache writer, including
record, preview, unread and cursor writes in one transaction. Resetting the
in-memory client cache happens outside the timed interval. Each delivery checks
the resulting message count.

These CPU measurements exclude TLS, disk durability latency, display rendering
and native macOS runtime behavior. Build each revision separately with the same
benchmark source, then run three alternating pairs:

```sh
zig build hotpath-bench -Doptimize=ReleaseFast
zig-out/bin/hotpath-bench
```

## Verification

Debug and ReleaseSafe suites passed 143 tests with one expected native Contacts
skip on Linux. Added tests cover borrowed and owned parser lifetimes, exact raw
records after caller-buffer reuse, unknown numeric fields, duplicate known
fields, malformed escapes, fragmented SSE with multiline stored JSON, enrichment
continuation and transactional rollback of invalid history batches. The existing
relay enrichment test now decodes each serialized item before asserting its ID;
its pagination and ordering coverage is unchanged.

Integration, client integration, client transport, client enrichment, enrichment
protocol and hostile-message suites passed. Client integration was repeated after
the final sidebar preview change. The default desktop build also passed. Native
macOS build/runtime checks were not available in this environment.

```sh
zig build test fake-relay client-probe client -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=/absolute/openssl-3.5
zig build test client -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/integration.py
python3 tests/client_integration.py
python3 tests/client_transport.py
python3 tests/client_enrichment.py
python3 tests/client_enrichment_protocol.py
python3 tests/message_security.py
```
