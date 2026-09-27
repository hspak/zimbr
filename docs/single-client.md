# Work enabled by one client owner

This is a historical implementation/measurement report. Benchmark results and
suite counts below describe that revision; use [setup](setup.md) for current
installation and rerun the listed checks for a new build.

The client already holds an exclusive lock for its data directory from startup
through worker shutdown. This provides one writer for the media cache. Separate
test instances with independent directories remain independent owners. Startup
logging now follows lock acquisition, preserving the existing duplicate-launch
test's exact error output before any display initialization.

## Media cache maintenance

Previously every successful download enumerated and inspected the entire cache,
grew a temporary entry list once per file, and sorted it for eviction. The worker
now scans at startup and maintains conservative byte and entry counters between
scans. A completed download adds its verified encoded length, or the transport's
8 MiB bound when the asset did not advertise a length. This also accounts for
an installation whose final directory fsync failed after the rename.

The disk limit remains 512 MiB. Maintenance starts above 496 MiB or 8,192 entries,
leaving 16 MiB for the two active download lanes. A scan trims to 448 MiB and
7,680 entries, providing room for subsequent downloads. This trades some retained
cache capacity for far fewer directory scans. The temporary scan array grows
geometrically and remains capped at 8,192 entries; sorting happens only when
eviction is needed.

Counters deliberately overcount replacements and files removed as corrupt,
retired, or private avatars. Active temporary files counted by a scan may also
be counted again upon installation. Overcounting can trigger an earlier scan;
it cannot falsely create spare capacity. Failed or incomplete scans invalidate
the counters and are retried after the next completed download. Filesystem
failures still make eviction best effort, as before.

At startup, no download can be active, so owned temporary files left by a crash
are removed immediately. Later scans preserve temporary files regardless of age
and include their current sizes in usage. File ownership, permissions, link and
format checks, bounded decoding, fsync, and atomic rename remain in place.
Successful reads still update file modification times for least-recently-used
eviction. There is no persistent in-memory index of individual files.

## SQLite connection ownership

Each client database connection is used by one thread at a time: synchronization
owns its worker connection, startup configuration opens a temporary connection,
and the settings pane uses a separate connection. These connections now use
`SQLITE_OPEN_NOMUTEX`. This is SQLite's per-connection multi-thread mode, which
allows concurrent independent connections while requiring exclusive use of each
connection and its statements. [SQLite's threading contract](https://www.sqlite.org/threadsafe.html)
describes that distinction.

The relay retains its serialized connections. The existing statement-cache lock
calls remain; a confined connection returns a null database mutex, for which
SQLite's mutex operations are no-ops. [SQLite mutex API](https://www.sqlite.org/c3ref/mutex_alloc.html)
documents this behavior. An additional experiment caching that mutex pointer
regressed batch benchmarks and was removed.

WAL, FULL synchronous durability, busy handling, and file locking remain. The UI
can save settings while synchronization uses another connection, so exclusive
database locking would be incorrect. Worker/UI queues and immutable snapshot
reference counts also still cross thread boundaries and retain synchronization.
The one-time process lock enforces ownership and is not a recurring hot-path
cost.

## Measurements

Zig 0.16.0, ReleaseFast, Linux x86_64. The baseline is a saved worktree immediately
after the serialization pass, including its uncommitted changes. Both versions
use the same expanded benchmark source. Three sequential pairs alternate order,
with no concurrent builds or tests. The table reports medians across those runs.

| Measurement | Before | After |
| --- | ---: | ---: |
| Maintenance per download, cache below its limit | 1,705 µs | <0.1 µs |
| Maintenance per download, cache near its limit | 2,994 µs | 3.97 µs |
| Cached client SQL lookup | 0.180 µs | 0.138 µs |

Cache maintenance fell by over 99.8% in the eviction-pressure fixture. Each cache
run starts with 4,096 or 7,936 sparse files of 64 KiB each, discards 64 warmup
downloads, then measures maintenance across 960 new files. File creation,
payload writes, decoding and fsync are outside the timed interval. The near-limit
mean includes batched eviction; the below-limit path only updates counters and
its measured duration is close to timer overhead. Startup scanning is recorded
separately. These are metadata-maintenance measurements, not complete download
latencies or cold-disk measurements.

SQL samples average 10,000 prepared, bound, stepped and reset lookups; each run
discards a warmup and takes 15 samples. The dedicated client query improves about
23% in this run. Whole-event ingestion varied across measurement rounds, as did
unchanged relay controls, so this does not establish a comparable end-to-end
speedup. The [raw results](performance-single-client.json) include all controls,
source hashes, and the diagnostic rounds used to reject the shared statement-cache
experiment. That rejected candidate is absent from the final implementation.

Build each revision separately with the same benchmark source, then run three
alternating pairs. The fixture selects the older per-installation pruning call
when the baseline lacks `Media.DiskCache`.

```sh
zig build hotpath-bench -Doptimize=ReleaseFast
zig-out/bin/hotpath-bench
```

## Verification

Debug and ReleaseSafe suites passed 148 tests with one expected native Contacts
skip on Linux. New coverage exercises concurrent client connections while a WAL
reader retains its snapshot, byte and entry eviction thresholds, LRU ordering,
replacement overcounting, failed-scan retries, fresh crash leftovers, active
temporaries, and directories exceeding the scan's 8,192-entry storage bound.
The original media eviction test retains its behavior and now checks the scan's
success result through the expanded C interface.

Client integration, media transport, settings, and single-instance suites passed.
The existing duplicate-launch test failed before moving the startup log and
passed afterwards without changing its assertions. A Debug Wayland smoke run
started and exited successfully; the platform's window-position warnings remain.
Native macOS runtime checks were not available.

ASan/UBSan pixel checks match the parent revision `efb5e6e`. The comparison harness
now compiles each revision with its own header so C interface changes do not mix
declarations from different revisions. The script's much older default baseline
predates intentional text-selection rendering changes and produces a different
pixel checksum even though decoding/rejection counts agree; the explicit parent
revision has the same checksum as this change.

```sh
zig build test client client-probe -Dopenssl-prefix=/absolute/openssl-3.5
zig build test fake-relay client-probe client -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/client_integration.py
python3 tests/client_media_transport.py
python3 tests/client_settings.py
python3 tests/client_single_instance.py
python3 tests/client_pixel_safety.py --baseline efb5e6e
```
