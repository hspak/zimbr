# Performance hardening audit

Reviewed the changes from security commit
`1aa4f0b621091726db1ba35e02df0fff0db0d669` through performance commits `42b6943`
and `9d9f840`. No hardening regression was found in the reviewed and tested paths.
The audit adds regression tests and documentation; it does not change production
behavior or require reverting a performance optimization.

## Boundaries reviewed

| Performance change | Preserved protection and evidence |
| --- | --- |
| JSON string SIMD | UTF-8 validation and byte limits still precede scanning; only ordinary quoted bytes are skipped. Escapes, delimiters, depth and token counts use the original state machine, followed by typed JSON parsing. Tests cover exact 32-container and 8,192-token limits after long escaped strings at 32 alignments. HTTP tests reject controls and invalid escapes in unknown fields without creating send records. |
| Cached SQLite statements | The cache remains connection-owned, bounded to 256 idle entries, and protected by SQLite's connection mutex. Checked-out statements leave the cache. Close resets unfinished cursors and clears all borrowed bindings before arenas can be reset; failed statements are finalized. Tests cover nested queries, failed writes, schema changes, collisions, bounded retention, and partial binding failures followed by freed caller memory and reuse. |
| Reused import scratch | Every entered row scope resets scratch through `defer`, including error and early-return paths. Retained capacity is limited to 256 KiB and freed at batch end. Conversation IDs and batch maps use the separate batch allocator. Stored link payloads still copy SQLite column data before decoding; the archive does not borrow a statement buffer across close/reuse. |
| Reused frame scratch and history geometry | Frame scratch resets after drawing with a 1 MiB retention limit. Persistent UI values are copied into their owning allocations. Cached history still invalidates on content, conversation, width and scale changes. Input validation, link confirmation, and URL policy were not changed. |
| Pixel SIMD and direct JPEG RGBA | Text geometry, tile and allocation limits are unchanged. JPEG input remains capped at 8 MiB, dimensions at 2,560 per side, and output at 32 MiB. Decoder errors and warnings still reject the result and clear output state. Sanitized comparisons exercise short rows, fractional scaling, RGB/grayscale/progressive JPEGs, every truncated prefix of selected fixtures, invalid dimensions and precision, and valid reads following failures. |
| Worker/UI wakeups | Publishing still happens under the existing mutex and media generation checks still precede publication. The wake pipe is bounded, nonblocking and close-on-exec. Workers are joined before the pipe is closed. Epoch, credential and media cancellation behavior passed integration tests. |
| macOS scheduling and randomness | QoS and launchd process type change scheduling; installation ownership, mode, signing entitlements and authentication policy are unchanged. `arc4random_buf` retains cryptographic random generation. Native runtime validation remains outstanding. |

The message/record validators, SQLite BLOB source projections, plist object/read
budgets, archive expansion budget, attachment limits, enrichment pagination and
rollback rules, URL policy, journal transaction/durability settings, TLS wrapper,
credential configuration and dependency lockfile are unchanged from the security
commit. The new cache does not change SQL parameters or transaction boundaries.

SQLite documents that [reset retains bindings](https://www.sqlite.org/c3ref/reset.html)
and that [clear_bindings resets them to NULL](https://www.sqlite.org/c3ref/clear_bindings.html);
both calls are present on the reuse path. Apple's
[arc4random documentation](https://raw.githubusercontent.com/apple-oss-distributions/Libc/main/gen/FreeBSD/arc4random.3)
describes its cryptographic generator and kernel reseeding, including after fork.

## Verification

The Linux audit used Zig 0.16.0. Unit tests passed in ReleaseSafe and ReleaseFast:
82 passed, with one native Contacts test skipped. ReleaseSafe fixture binaries
also passed these ten suites:

```sh
zig build test fake-relay client-probe -Doptimize=ReleaseSafe -Dopenssl-prefix=/absolute/openssl-3.5
zig build test -Doptimize=ReleaseFast -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/message_security.py
python3 tests/links.py
python3 tests/assets.py
python3 tests/integration.py
python3 tests/client_enrichment.py
python3 tests/client_enrichment_protocol.py
python3 tests/client_media_transport.py
python3 tests/relay_tls.py
python3 tests/client_tls.py
python3 tests/media_boundary.py
python3 tests/client_pixel_safety.py
```

The pixel runner compiles the security revision and current C code with Clang
22.1.8, `-O2 -march=native`, AddressSanitizer and UndefinedBehaviorSanitizer.
Both variants accepted 42 valid JPEGs, rejected 1,758 malformed JPEGs, and rendered
183 bounded text tiles with checksum `0761b1746cda975b`. It also checks rejection
of an encoded file over 8 MiB. Both variants completed without sanitizer errors.
All fixtures are synthetic; no account data, system trust-store changes or live
Messages database access are involved.

Sanitizers instrument the project's C boundary; installed Pango/Cairo/libjpeg
libraries are not rebuilt with instrumentation. Leak detection is disabled for
the font libraries' process-global caches. The comparison verifies these inputs
and the reviewed boundaries, not the absence of every possible library defect.
macOS scheduling, random generation, Messages and ImageIO still need native
runtime acceptance; this audit does not claim those Linux tests execute them.
