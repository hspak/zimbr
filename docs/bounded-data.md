# Bounded storage and ownership

This pass uses the shared protocol's existing bounds to reduce temporary storage
and copying across the client and relay. It compares against `efb5e6e`, which
already contains the fixed request-log buffer and the startup/shutdown panic fix.

## Decisions

| Path | Known bound or lifetime | Implementation |
| --- | --- | --- |
| Client request URLs | The C bridge accepts an 8,192-byte URL buffer, including its terminator. | Format and percent-escape directly into the worker's existing buffer. SSE setup uses one local buffer of the same size. No separately allocated path or escaped components. The bridge still checks the combined origin and path. |
| Client POST bodies | JSON bytes already have a length; libcurl copies them during setup. | Pass pointer and length to the bridge, removing the temporary sentinel-terminated copy. |
| Completed HTTP responses | The bridge owns one allocation until the worker handles completion. | Transfer that allocation to the worker, acknowledge the transport slot, and free the bytes after parsing. Starting the next request cannot invalidate them. |
| Media queue | Asset IDs and versions are 36-byte UUIDs; variant and availability are enums. | Validate UUIDs and copy only download fields into each request. Remove the per-request JSON round trip and arena. Derive the path buffer size from UUID lengths and the longest variant name. |
| Unchanged message history | The previous immutable snapshot owns the matching prefix. | Borrow that prefix while comparing. Retain individual records and allocate a pointer array only after a change is found; otherwise retain the entire snapshot once. |
| Relay source scans | Each SQL query returns at most 100 row IDs. | Share the limit with the caller's 800-byte array and reuse it after each batch is consumed. Pending retries use a separate 50-row array. |
| Ingestion positions | Signed 64-bit integers need at most 20 decimal bytes. | Parse borrowed SQLite text before closing the statement; format writes into a local array. |
| Relay history and identity pages | At most 200 records; cursor IDs are UUIDs and timestamps are signed 64-bit integers. | Gather descriptors in a 3,200-byte array on 64-bit targets, copy the final descriptor slice once, and allocate only the cursor actually returned. Reject invalid page limits before indexing. |
| Stored JSON response records | The journal already stores serialized records; each query's bytes must survive statement reuse. | Copy the serialized bytes once, validate their JSON syntax, and embed them directly in the envelope. Preserve unknown fields, escapes and integer precision without constructing a JSON tree. Text-only projection still happens in SQLite. |
| Enrichment preparation | Four SHA-256 digests; each section's item count is known. | Keep binary digests inline and convert to hex at the database boundary. Allocate each descriptor array once at its exact length. |

The disk schema, media cache names, wire fields, durability boundaries, send
idempotency and replay behavior are unchanged. Dynamic storage still serves
several useful purposes:

- Message text, recipients and metadata vary in size. Per-record maximum-size
  arrays would multiply unused space across retained history.
- Media requests still have one independently owned allocation, allowing queued
  and active requests to move between threads without moving their storage.
  The queue retains its storage and accepts at most 128 pending requests.
- HTTP response bodies and incomplete SSE frames grow within existing limits.
  Reserving their full multi-megabyte maxima for every connection would raise
  idle memory use. SSE retains its multiline framing behavior.
- Editor undo records store their actual text lengths, bounded by 100 checkpoints
  and the protocol text limit. Text/image caches retain their existing entry and
  texture budgets.
- Session log appends already allocate nothing: a 200-entry ring stores up to
  768 bytes per entry. Rendering snapshots and clipboard text own separate copies
  so consumers can release the writer lock promptly.

## Measurements

Zig 0.16.0, ReleaseFast, Linux x86_64. Three sequential before/after pairs
alternated execution order, with no concurrent builds or test suites. Both
revisions used the same expanded benchmark source. Each run discarded a warmup
and collected 15 batches; these numbers are medians of the per-run medians.
[Raw measurements](performance-bounded-data.json) include all runs and control
paths.

| Measurement | Before | After |
| --- | ---: | ---: |
| Media enqueue, per request | 1.075 µs | 0.294 µs |
| Media request struct, excluding separately allocated storage | 288 bytes | 232 bytes |
| Build and serialize a 128-message relay page, 1 KiB text per message | 1,343 µs | 520 µs |
| Publish an unchanged 5,000-message snapshot | 1.463 ms | 1.420 ms |
| Publish one edit in that snapshot | 1.577 ms | 1.615 ms |
| Publish one append to that snapshot | 1.632 ms | 1.616 ms |

Media enqueue time fell 73%, including removal of its separate arena allocations.
Relay page time fell 61%. Unchanged snapshot time fell 3%; edit and append timings
were roughly unchanged. These are in-memory CPU fixtures, excluding network,
disk ingestion, GPU presentation and native macOS runtime behavior.

Build each revision separately, copying the updated `src/hotpath_bench.zig` into
the baseline checkout so both execute identical fixtures:

```sh
zig build client-bench hotpath-bench -Doptimize=ReleaseFast
zig-out/bin/client-bench 5000 1024
zig-out/bin/hotpath-bench
```

Run three pairs sequentially and alternate which revision runs first.
`hotpath-bench` measures 32 batches of 128 queued media requests per sample,
clearing the previous batch by changing the selected conversation. Each relay
page sample performs 20 queries plus envelope serializations. Neither fixture
uses an account, display, network server or persistent database.

## Validation

The complete Debug and ReleaseSafe suites each passed 123 tests, with one
expected native Contacts skip on Linux. New coverage includes escaped URL
delimiters and buffer exhaustion, media ownership after caller buffer reuse,
shortened history snapshots, integer boundaries, row ordering and pagination,
maximum page size, cursor/record lifetime across subsequent queries, and
malformed stored JSON. The existing startup/shutdown regression remains intact.
The identity tombstone test now parses the page's serialized record before
applying its existing assertions because the page representation changed.

The integration, client integration, client transport, client enrichment,
enrichment protocol, hostile-message, media transport and settings suites passed
during the pass. Integration and enrichment protocol checks were repeated after
the final pagination changes. A Wayland startup/shutdown smoke test also passed
with temporary settings and cache; GLFW's window-position warnings remain.

```sh
zig build test fake-relay client-probe client -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=/absolute/openssl-3.5
zig build test -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/integration.py
python3 tests/client_integration.py
python3 tests/client_transport.py
python3 tests/client_enrichment.py
python3 tests/client_enrichment_protocol.py
python3 tests/message_security.py
python3 tests/client_media_transport.py
python3 tests/client_settings.py
```

Shared relay code is exercised through the Linux fake adapter. Native macOS
build/runtime validation was not available in this environment.
