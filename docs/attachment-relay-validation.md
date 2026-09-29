# Attachment relay validation

This file tracks relay-specific validation for outgoing attachments. Synthetic
tests establish protocol and recovery behavior; they do not establish Messages
Automation behavior on a real Mac. Keep account addresses, machine names, paths,
and real-message evidence outside this document.

## Automated validation

Record the implemented boundary, command, and observed result after each chunk.

| Boundary | Command | Result |
| --- | --- | --- |
| Protocol, validation, and text idempotency | `zig build test -Doptimize=ReleaseSafe` | Passed with Zig 0.16.0 and OpenSSL 3.5 prefix |
| Unavailable attachments cannot send only their caption | `python3 tests/attachment_sends.py` | Failed before the fix (202 acceptance); passed after the fix (400, unstarted, no queued send), with the same test |
| Upload reservation ownership, quotas, leases, pinning rollback, restart, and epoch changes | `zig build test -Doptimize=ReleaseSafe` | Passed; exercises SQLite persistence and reopen, injected transaction failure, and stale transfer callbacks |
| Private file streaming and publication | `zig build test -Doptimize=ReleaseSafe` | Passed; binary chunks, short/excess bodies, wrong hashes, empty files, basename collisions, symlink rejection, and unpublished-file cleanup |
| Relative upload roots produce absolute automation paths | `zig build test -Doptimize=ReleaseSafe` | Same test failed before root resolution and passed after; the native file argument no longer depends on the caller supplying an absolute data directory |
| Upload streaming, integrity, ownership, active limits, timeout, restart, reset, cancellation, and cleanup | `python3 tests/attachment_uploads.py` | Passed: 12 production mTLS/HTTP2 cases, including a 9 MiB binary file, empty files, unsafe storage isolation, and failed publication |
| Failed disconnected-writer release recovers without restart | `python3 tests/attachment_uploads.py AttachmentUploads.test_failed_lease_release_recovers_without_restarting_the_relay` | Same regression failed before retry handling and passed after; an injected SQLite failure no longer leaves the upload permanently receiving |
| Attachment dispatch, original copies, direct/group routing, partial failure, result-commit failure, restart, and reset | `python3 tests/attachment_sends.py -v` | Passed: 10 cases through the production HTTP/2 server and synthetic Messages adapter; the original caption-loss regression remains unchanged |
| Multipart correlation and safe reclamation | `python3 tests/attachment_observation.py -v` | Passed: 16 production HTTP/2 cases covering byte identity, ambiguity, source changes, partial outcomes, late receipts, restart, and atomic cleanup |
| Undecodable outgoing records block uniqueness | `python3 tests/attachment_observation.py AttachmentObservation.test_malformed_outgoing_records_cannot_disappear_from_the_uniqueness_check` | Same regression failed before the guard and passed after; a malformed possible echo cannot disappear from correlation |
| Observed failure reports a failed request while retaining the original | `python3 tests/attachment_observation.py AttachmentObservation.test_observed_failure_is_reported_without_releasing_or_resending_the_file` | Same regression failed before aggregate outcome handling and passed after |
| A staged original cannot prove an independent Messages copy | `python3 tests/attachment_observation.py AttachmentObservation.test_source_path_to_the_staged_original_is_not_an_independent_copy` | Same regression failed before file-identity checking and passed after, including relay storage nested under the Messages attachment root |
| Multipart acceptance and recovery journal | `zig build test -Doptimize=ReleaseSafe` | Passed: atomic pinning, incomplete and foreign uploads, injected part-write rollback, ordered caption/file parts, exact retries, partial outcomes, restart between/during operations, and source-reset holds |
| Existing text sends, idempotency, recovery, and source resets | `python3 tests/integration.py` | Passed after multipart observation and safe reclamation |
| HTTP/2 stream isolation | `python3 tests/relay_http2.py` | Passed: all seven existing transport regressions |

Use Zig from `.zigversion`. Build `fake-relay` before the Python suites. Supply
`-Dopenssl-prefix=/absolute/openssl-3.5` when the system OpenSSL is not 3.5.
Build caches can be redirected with `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` when the normal cache is unavailable.

The observation chunk passed 202 Zig tests with one unavailable-platform skip.
The dispatch suite passed all 10 cases and the upload suite passed all 12 cases.
Retention assertions now expect proven unstarted successors to retire; their
coverage still requires uncertain attempted originals to remain pinned across
restart and source reset.

Observation tests include a 9 MiB original, an empty file, changed bytes after a
cached proof, missing and unsafe source paths, delayed attachment joins, and an
injected cleanup transaction failure. Discovery refuses to confirm after its
4,096-row budget is exceeded. Already confirmed submissions still follow a late
delivery receipt after that history bound and after Messages evicts its copy.

The native script passes the private absolute filename as a literal argument,
coerces it to an alias before setting its dispatch flag, and uses the same
account and chat checks as text sending. Apple's
[file-reference guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/ReferenceFilesandFolders.html)
documents POSIX-file-to-alias conversion. That does not establish current
Messages behavior: script compilation, file acceptance, copy timing, and delivery
remain native acceptance checks below. Synthetic copies exercise the journal
boundary, not Apple's implementation.

## Real Mac acceptance: not yet run

Validate under the installed relay app identity, with a deliberately selected
recipient and separate authorization for actual sends. Follow the existing
[Mac validation guide](mac-validation.md). Never write to the real Messages
database to manufacture test cases.

1. Inspect the installed Messages scripting dictionary and verify file sending
   to a direct recipient, an existing direct chat, and an existing group.
2. Send a PNG, JPEG, PDF, and an ordinary binary file. Check recipient-side bytes,
   filename, presentation, and observed attachment metadata. Check empty files
   and the configured size boundary; document any Messages-specific restriction.
3. Send text with one file and with several files. Record how many Messages rows
   appear, their ordering, attachment joins, and whether captions are preserved.
4. Establish which source metadata safely identifies our uploads. Include two
   different files with the same name/size, repeated identical files, and an
   unrelated simultaneous send to the same conversation. Ambiguity must remain
   uncertain rather than confirming the wrong request.
5. Observe when Messages copies the staged file, including a slow transfer.
   Establish safe retention/cleanup behavior without relying on AppleScript
   returning successfully as proof that copying is complete.
6. Interrupt automation before and after each text/file operation. Restart the
   relay and retry the original request ID. Confirm completed or uncertain parts
   are not resent and remaining parts have accurate outcomes.
7. Repeat direct/group sends while the active graphical session remains locked
   throughout the observation window. Test permission loss/restoration under the
   installed app identity and confirm the errors remain actionable.
8. Reset the relay or replace the source identity during an upload and during
   dispatch. Old uploads must not become new-epoch sends; uncertain files remain
   available for the documented retention period.

Record macOS version, relay revision, installed profile, test case, and observed
result in private acceptance evidence. Save request IDs before sending, preserve
them on failure, and distinguish recipient confirmation from local observation.
