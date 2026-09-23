# Messaging performance

The measurements below describe the pre-mTLS release. The Linux performance harness now connects
directly to the native mTLS fake relay with temporary enrolled credentials;
the old plaintext adapter has been removed. Current Mac
transport/deployment checks are in [macOS TLS operation](macos-tls.md).

The critical path is the whole system: observing Apple's database, committing
the relay journal, transporting changes, committing the client cache, publishing
the view, and drawing it. Both endpoints and the wire protocol are ours to change.
Apple's service and automation behavior remain external boundaries.

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
- **UI publication:** immutable shared snapshots let drafts, appearance, and
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

## Reliability constraints

`synchronous=FULL` and WAL remain enabled on both owned databases. Local outbox
persistence precedes POST, and relay acceptance precedes dispatch. An event or
acknowledgement never claims an uncommitted write. Request IDs, conflict detection,
uncertain outcomes, source epochs, cursor expiry, and replay deduplication retain
their existing meanings. The Apple database is opened read-only.

The 30-second outgoing-message correlation window is deliberately unchanged.
The current AppleScript boundary returns an invocation outcome rather than an
authoritative message ID. An earlier unique text match is not enough to rule out
a second matching message or a delayed join. Making confirmation immediate requires
a separately validated adapter that returns an authoritative identity; shortening
the window or silently resending would change reliability, not just performance.

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
The isolated Wayland checks exercise both themes and large-history rendering.

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
5. **Native UI wakeup:** replace the remaining GUI input polling with a display
   event wait that the worker can wake. Keep cursor blinking, resizing, scrolling,
   and deferred layout responsive without raising idle CPU use.

Design references: [SQLite WAL durability](https://www.sqlite.org/wal.html),
[SQLite synchronous modes](https://www.sqlite.org/pragma.html#pragma_synchronous),
[libcurl readiness polling](https://curl.se/libcurl/c/curl_multi_poll.html), and
[Apple kernel file notifications](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html).
