# Messaging performance

The September 24 pass below uses the current native mTLS fake relay with temporary
enrolled credentials. The older September 22 tables describe the pre-mTLS release;
the old plaintext adapter has been removed. Current Mac
transport/deployment checks are in [macOS TLS operation](macos-tls.md).

The critical path is the whole system: observing Apple's database, committing
the relay journal, transporting changes, committing the client cache, publishing
the view, and drawing it. Both endpoints and the wire protocol are ours to change.
Apple's service and automation behavior remain external boundaries.

## September 24 performance pass

The client now waits for Wayland socket readiness and a nonblocking worker wake
pipe in place of its fixed 25 ms idle sleep. Background views and decoded media
wake rendering, including when the view generation has not changed. Input
callbacks still run through raylib's normal input reset/dispatch sequence. The
25 ms timeout remains for notification/timer maintenance, and active rendering
still targets 120 FPS.

Settled histories reuse row positions and heights; finding the reading anchor is
a binary search. Content, width, and display-scale changes invalidate geometry,
while changing the composer height still clamps the viewport and preserves
follow mode. The frame scratch arena retains at most 1 MiB between frames.
Opaque Pango/Cairo surfaces need only a channel swap before upload; skipping
unpremultiplication removes three integer divisions per pixel. Transparent text
keeps its existing conversion and antialiasing behavior.

The subsequent [client SIMD trials](client-simd.md) retained vectorized opaque
pixel conversion and direct JPEG RGBA output after three comparisons each. An
ASCII layout fast path was measured and removed for insufficient gains.

Both owned databases and the read-only Messages reader reuse compiled SQL in a
connection-owned cache of at most 256 idle statements. Checked-out statements are
exclusive, nested identical queries get independent cursors, and close resets
the statement and clears borrowed bindings. Failed statements are finalized;
schema changes retain SQLite's automatic reprepare behavior. DDL and PRAGMAs are
not cached. Ingestion also reuses decoder scratch pages across rows, retaining
at most 256 KiB after each row instead of repeatedly mapping/freeing pages.
WAL, `synchronous=FULL`, source read-only access, and commit-before-publication
remain intact. See SQLite's [persistent preparation hint](https://www.sqlite.org/c3ref/c_prepare_dont_log.html),
[reset behavior](https://www.sqlite.org/c3ref/reset.html), and
[binding lifetime](https://www.sqlite.org/c3ref/clear_bindings.html).

JSON bounds checking skips ordinary quoted content in 128-bit blocks, retaining
the scalar escape/delimiter state machine and separate UTF-8 validation. Tests
compare it with the scalar path over generated inputs, vector alignments, escapes,
UTF-8 truncations, and structural/token limits.

### M1 and macOS

Build with `-Doptimize=ReleaseFast -Dtarget=aarch64-macos -Dcpu=apple_m1` and matching
arm64 OpenSSL archives. M1-targeted assembly was checked for NEON byte comparisons
in the JSON scanner and `sha256h`/`sha256su` instructions in Zig's existing SHA-256
implementation, used for asset hashing. TLS continues to use OpenSSL's existing
crypto implementation.

The launch agent now uses `ProcessType=Standard`. HTTPS requests do not receive
the XPC boosts that make Adaptive suitable for XPC services. Connection handling
and send dispatch request user-initiated QoS; ingestion, Contacts, and asset work
request utility QoS. This follows Apple's guidance to describe the urgency of
work and let macOS place it on performance/efficiency cores. No core affinity or
realtime priority is imposed. Reinstall the launch agent to apply its ProcessType
change. See [Apple's launchd definitions](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5),
[QoS guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/PrioritizeWorkWithQoS.html),
and [Apple silicon tuning](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon).

macOS UUID generation uses `arc4random_buf`, avoiding a `/dev/urandom` open/read/close
sequence for every UUID. This is also the native primitive used by Apple's
[system random generator](https://developer.apple.com/documentation/swift/systemrandomnumbergenerator).

These changes have Linux runtime coverage and M1 code-generation checks. The
macOS C boundary and complete app still need a native build and runtime profiling;
the numbers below are **not M1 measurements**. Profile real ingestion, foreground
requests during backfill, media conversion, and idle wakeups on the Mac before
drawing conclusions about its throughput or power use.

### Measurements and reproduction

Use the same Zig 0.16.0 release configuration for both revisions and run them
sequentially without concurrent builds or tests. The synthetic Linux host is an
AMD Ryzen AI Max+ 395. The end-to-end fixture has 10,004 messages with 1,024-byte
historical text; the client probe samples every 20 ms and excludes GPU presentation.
The CPU microbenchmark uses in-memory SQL, a 65,536-byte JSON string, and an opaque
Unicode text layout at 125% scale. Raster timings exclude GPU upload and drawing.

Three before/after pairs ran sequentially, alternating which version ran first.
Each row below is the median of that statistic across the three runs; each
end-to-end run contains eight incoming samples and four sends.

| Measurement | Before | After |
| --- | ---: | ---: |
| Initial ingestion, 10,004 messages | 5.23 s | 3.72 s |
| Incoming visibility, median | 55.0 ms | 41.5 ms |
| Incoming visibility, per-run p95 | 85.0 ms | 61.7 ms |
| Local outbox acknowledgement, median | 35.0 ms | 39.9 ms |
| Send dispatch, median | 38.6 ms | 42.6 ms |
| Outgoing echo visibility, median | 72.2 ms | 55.2 ms |
| 500-message live burst | 200 ms | 118 ms |
| SQL prepare/bind/read/close, median | 0.891 µs | 0.162 µs |
| 64 KiB JSON bounds check, median | 23.1 µs | 2.31 µs |
| Opaque text rasterization, median | 203 µs | 53.8 µs |
| Cold publication of 25,000 messages | 132 ms | 142 ms |
| Publish 25,000 unchanged messages, median | 13.9 ms | 13.9 ms |
| Publish one edit in 25,000 messages, median | 15.4 ms | 15.7 ms |
| Publish one append to 25,000 messages, median | 15.7 ms | 15.5 ms |

Ingestion time fell 29%, burst visibility time fell 41%, and the isolated opaque
text raster path was 3.8× faster. Warm snapshot publication was essentially unchanged;
cold publication was about 9 ms slower in this three-run sample.
The acknowledgement/dispatch samples were slightly slower; their small sample
count and the probe's 20 ms cadence do not establish a send-latency improvement.
Microbenchmark speedups describe these specific hot paths, not whole-app speed.

Validation passed in ReleaseFast and ReleaseSafe (79 tests, one native Contacts
test skipped on Linux), the isolated Wayland suite (38 tests), and 12 integration
suites covering persistence, replay, send priority, lazy history, enrichment,
assets, links, reactions, TLS, and hostile-message bounds. New regressions cover
statement reuse and binding lifetime, SIMD boundary behavior, coalesced UI wakeups,
and history geometry after content and composer changes.

```sh
zig build fake-relay client-probe client-bench hotpath-bench -Doptimize=ReleaseFast \
  -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/performance.py --history 10000 --text-bytes 1024 --samples 8 --burst 500
zig-out/bin/client-bench 25000 1024
zig-out/bin/hotpath-bench
```

`hotpath-bench` discards a warmup batch and reports 15 batches of each hot path,
with timer overhead amortized over repeated operations. It opens no network,
display, account, or persistent cache. Use `--bin-dir` with `tests/performance.py`
for saved before/after binaries. Raw results and comparison tables are recorded
in [the September 24 measurements](performance-2026-09-24.json).

## Implemented architecture

```mermaid
flowchart LR
    Apple[Messages database / WAL] -->|file notification| Ingest[Bounded ingestion batch]
    Ingest -->|durable commit| Journal[Relay journal]
    Journal -->|wake subscribers| SSE[Event stream]
    SSE -->|socket readiness| Cache[Atomic client batch]
    Cache --> View[Immutable shared view]
    UI[User send] -->|wake worker / preempt GET| Outbox[Durable local outbox]
    Outbox -->|reused HTTP connection| Accept[Durable relay acceptance]
    Accept -->|wake dispatcher| Automation[Messages automation]
    Automation --> Apple
```

- **Source observation:** kqueue on macOS and inotify on Linux watch the source
  database, WAL, rollback journal, and file replacement. Reader SHM traffic is
  excluded. Notifications trigger SQLite reads, never inferred message data.
  A settling scan covers notifications preceding a commit; periodic reconciliation
  remains the recovery path for coalesced or missed notifications.
- **Ingestion throughput:** drain bounded live/backfill pages without a one-second
  pause between pages. A read transaction gives each source batch a consistent
  snapshot. Deduplicate repeated rows and cache conversation metadata within that
  batch, while preserving live versus historical origins. Resolve and journal a
  conversation once per batch, including the conversation scan, and avoid SQL
  updates when canonical content and source mappings are unchanged.
- **Dispatch and streaming:** generation-based notifications wake the sender on
  acceptance and stream subscribers after successful journal commits. Capturing
  the generation before checking work prevents a lost wakeup. Idle subscribers
  still run bounded maintenance and token checks. Flush event pages together.
- **Transport:** reuse HTTP connections, authenticate every request, reset request
  deadlines, cap requests per connection, and disable server-side Nagle delay.
  Stream and connection limits remain enforced.
- **Client scheduling:** wait on network readiness and a command pipe instead of
  sleeping after every polling iteration. Coalesce publication for at most 16 ms.
  A send preempts an idempotent background GET; it never cancels an active POST.
- **Cache writes:** commit complete SSE frames from one network delivery in one
  transaction. Any invalid frame or persistence failure rolls back that batch's
  records, unread markers, and cursor together. Replay starts at the durable cursor.
- **UI publication:** immutable shared snapshots let drafts and
  connection status update without reparsing or copying the entire history. The
  renderer retains prepared rows while the content generation is unchanged.
  Content updates compare ordered message IDs and revisions, reusing independently
  owned immutable records. Only changed messages are parsed and their display
  previews prepared. An unchanged history shares its entire message set; edited
  histories share individual records without retaining obsolete snapshot arenas.
  Epoch changes invalidate reuse even when IDs and revisions happen to match.
  Pending-send merging uses indexed message lookups instead of scanning all
  messages for each historical send.
- **Sidebar protocol:** `GET /v1/conversations?previews=1` returns small latest-message
  projections with the conversation page. Each projection has its own message ID,
  revision, timestamp, kind, and at most 256 text characters. Projections live in a
  separate cache table and cannot overwrite canonical message text. Older relays
  omit the field; the client then uses the original per-conversation fallback.
- **Text-first history:** relays advertising `text_first_history_v1` accept
  `content=text` on history requests. Responses retain full text, message IDs,
  revisions, timestamps, and reaction-row visibility, while deferring attachment,
  link-preview, reaction, and part arrays. The GUI requests canonical metadata
  through `GET /v1/messages/{id}` for visible messages; image downloads and decoding
  remain on the separate media worker. Selection, older history, and sends preempt
  metadata GETs. Metadata failures leave text usable and retry with a delay.
  Contact-directory bootstrap also yields to history. A same-revision metadata
  response upgrades the cached text projection without erasing newer text or
  metadata already received through the event stream. Older relays keep the
  original history behavior.

## Reliability constraints

`synchronous=FULL` and WAL remain enabled on both owned databases. Local outbox
persistence precedes POST, and relay acceptance precedes dispatch. An event or
acknowledgement never claims an uncommitted write. Request IDs, conflict detection,
uncertain outcomes, source epochs, cursor expiry, and replay deduplication retain
their existing meanings. The Apple database is opened read-only.

These measurements used a 30-second outgoing-message correlation window. The
current window is 10 seconds; a unique provisional echo replaces the pending
bubble during that window without confirming the request's identity.
The current AppleScript boundary returns an invocation outcome rather than an
authoritative message ID. An earlier unique text match is not enough to rule out
a second matching message or a delayed join. Making confirmation immediate requires
a separately validated adapter that returns an authoritative identity. The shorter
window reduces the time available to discover competing matches; ambiguous
requests remain uncertain and are never automatically resent.

## Reproducing the measurements

Measured on 2026-09-22 with Zig 0.16.0, ReleaseFast builds, and identical synthetic
fixtures on the same Linux host. [Aggregate results](performance-results.json)
retain the sample counts and tail latencies.

| Measurement | Before | After |
| --- | ---: | ---: |
| Incoming visibility, median | 885 ms | 19 ms |
| Incoming visibility, p95 | 1,210 ms | 26 ms |
| Local outbox acknowledgement, median | 102 ms | 26 ms |
| Send dispatch, median | 170 ms | 27 ms |
| Outgoing echo visibility, median | 883 ms | 26 ms |
| Connect | 267 ms | 26 ms |
| Open selected history | 113 ms | 40 ms |
| 500-message live burst | 4,034 ms | 60 ms |
| Sidebar ready, 200 conversations | 20,734 ms | 26 ms |

The small fixture uses 12 incoming and 6 send samples. The 200-conversation
scenario separately measures sidebar completion. These are illustrative runs,
not statistically stable hardware-independent bounds.

```sh
zig build fake-relay client-probe -Doptimize=ReleaseFast
python3 tests/performance.py
python3 tests/performance.py --chats 200 --samples 3 --burst 100
```

Use `--bin-dir` to compare saved release builds. Run comparisons sequentially on
the same machine without competing tests. All data and recipients are synthetic;
the benchmark creates temporary databases and only connects over localhost.
It measures incoming visibility, local outbox acknowledgement, dispatch, outgoing
echo visibility, connection/history opening, complete sidebar readiness, and a
live burst. Counts and timings are the only output.

The client probe samples views every 20 ms. Reported latencies therefore include
that observation interval and exclude GPU presentation, SSH/WAN latency, native
Mac storage, Messages automation startup, and Apple's delivery network. The small
fixture has 244 source messages and four conversations. The sidebar fixture has
200 conversations. These measurements establish software-path improvements, not
an Apple delivery SLA.

`send_ack` measures the UI seeing that its command has been durably saved to the
local outbox and scheduled for transmission. It does not measure remote acceptance
or Apple's delivery confirmation. `send_dispatch` observes the synthetic adapter's
database write, after durable relay acceptance.

### Large histories

A separate scenario loads all 25,001 messages in the selected conversation from
a 50,004-message source, with 1,024-byte historical text. Its baseline already
includes the first round of notification, transport, and sidebar improvements.
The final version additionally shares individual message records and previews,
avoids repeated conversation scans within ingestion batches, and skips unchanged
source-mapping writes. Source joins have indexes in both benchmark versions;
the minimal correctness fixture otherwise makes these joins full-table scans.

| Measurement | First performance pass | Final |
| --- | ---: | ---: |
| Incoming visibility, median / p95 | 121 / 165 ms | 81 / 135 ms |
| Local outbox acknowledgement, median | 85 ms | 35 ms |
| Send dispatch, median | 95 ms | 45 ms |
| Outgoing echo visibility, median | 165 ms | 85 ms |
| 500-message live burst | 340 ms | 200 ms |
| Initial relay ingestion | 24.4 s | 18.3 s |
| Load every selected history page | 23.2 s | 14.8 s |

```sh
python3 tests/performance.py --history 50000 --load-history --text-bytes 1024
zig build client-bench -Doptimize=ReleaseFast
zig-out/bin/client-bench 25000 1024
```

`client-bench` isolates cache publication in an in-memory synthetic database. It
runs 15 unchanged-history, edit, and append samples each. At 25,000 messages,
median edit/append publication fell from 45 ms to 6–7 ms; unchanged-history
publication fell from 45 ms to 5 ms. Whole-process peak RSS, including fixture
construction, fell from approximately 242 MiB to 177 MiB on this run. Both current
and previous immutable snapshots coexist during updates in this benchmark.

The worker's cold snapshot construction increased from 46 ms to 77 ms. The new
path also prepares display previews and hashes that previously ran on the UI
thread; the old cold timing excludes that rendering preparation. These numbers
do not measure first-frame presentation. Ordinary ASCII preview scanning uses
blocks, with the same scalar UTF-8, line-limit, and invalid-text handling at
special characters. Edits reuse the unaffected previews and full message text.

## Verification

The relay/client unit and integration suites cover atomic commits, failed cursor
writes, batch rollback, replay, delayed joins, live bursts, source replacement,
send idempotency, uncertain dispatch, process restart, token rotation, partial
responses, and recovery without duplicate sends. Additional checks exercise
reauthentication on a reused socket, sending while a history response is blocked,
shared snapshot lifetime, and full-text preservation with truncated projections.
Incremental-history checks include prepends, same-count edits, reordering, linked
echoes, failed snapshot construction, epoch replacement, and selection changes.
The testing allocator verifies that record references and failed builds are freed.
The isolated Wayland checks exercise the dark palette and large-history rendering.

The production relay's Zig code and the C platform boundary compile for Apple
Silicon. Native macOS runtime verification of the new kqueue path is still needed;
the existing native acceptance evidence predates these performance changes.

## Further architectural opportunities

The next measurements should use the real Mac, realistic conversation counts,
reconnect backlogs, and an SSH tunnel with controlled RTT. Profile each stage
before choosing the next change.

1. **Authoritative send receipts:** investigate a persistent native automation
   helper and whether an available adapter can return a real message identity.
   Separate invocation, observation, and delivery; do not synthesize guarantees.
2. **Bounded history windows:** parsing and preview preparation now reuse immutable
   records, but checking ordered revisions and rebuilding changed message arrays
   still scales with loaded history. A windowed index or chunked arrays could
   reduce that cost further while preserving scroll anchors and exact copy behavior.
3. **Ingestion isolation:** source reading and decoding still hold the relay's
   journal lock for one bounded batch. If real large-message batches cause tail
   latency, prepare them outside the writer lock and revalidate source epoch and
   progress before an atomic commit.
4. **Resume/bootstrap protocol:** combined status, cursor, first conversation page,
   and selected history can remove additional RTTs on cold starts. Stream replay
   and snapshot revisions must still close every synchronization race.
5. **Idle maintenance:** Wayland and worker results now wake the GUI directly.
   Integrating the remaining notification/timer polling with that wait could
   further reduce idle wakeups while preserving cursor blinking and retries.

Design references: [SQLite WAL durability](https://www.sqlite.org/wal.html),
[SQLite synchronous modes](https://www.sqlite.org/pragma.html#pragma_synchronous),
[libcurl readiness polling](https://curl.se/libcurl/c/curl_multi_poll.html), and
[Apple kernel file notifications](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html).
