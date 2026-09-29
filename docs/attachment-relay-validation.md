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
| Multipart correlation and safe reclamation | `python3 tests/attachment_observation.py -v` | Passed: 17 production HTTP/2 cases covering byte identity, ambiguity, source changes, partial outcomes, late receipts, restart, atomic cleanup, and handoff preview retention |
| Undecodable outgoing records block uniqueness | `python3 tests/attachment_observation.py AttachmentObservation.test_malformed_outgoing_records_cannot_disappear_from_the_uniqueness_check` | Same regression failed before the guard and passed after; a malformed possible echo cannot disappear from correlation |
| Observed failure reports a failed request while retaining the original | `python3 tests/attachment_observation.py AttachmentObservation.test_observed_failure_is_reported_without_releasing_or_resending_the_file` | Same regression failed before aggregate outcome handling and passed after |
| A staged original cannot prove an independent Messages copy | `python3 tests/attachment_observation.py AttachmentObservation.test_source_path_to_the_staged_original_is_not_an_independent_copy` | Same regression failed before file-identity checking and passed after, including relay storage nested under the Messages attachment root |
| Multipart acceptance and recovery journal | `zig build test -Doptimize=ReleaseSafe` | Passed: atomic pinning, incomplete and foreign uploads, injected part-write rollback, ordered caption/file parts, exact retries, partial outcomes, restart between/during operations, and source-reset holds |
| Existing text sends, idempotency, recovery, and source resets | `python3 tests/integration.py` | Passed after multipart observation and safe reclamation |
| HTTP/2 stream isolation | `python3 tests/relay_http2.py` | Passed: all seven existing transport regressions |
| GUI-reviewed originals through the production worker and relay | `zig build test-gui-attachments -Doptimize=ReleaseSafe` | Passed: native callback drops, background thumbnail, source deletion/replacement, caption/PNG/empty/binary dispatch exactly once in order, byte identity, individual delivery, and confirmed client history |
| Native AppleScript payload binding under the installed Messages dictionary | `python3 tests/mac_send_script.py -v` on macOS | Passed: four tests covering compilation, literal Unicode text, file aliases, and missing-file rejection. The same text/file operand regression failed before the fix in all four direct/chat modes and passed unchanged afterward. No Messages sends or account/chat queries execute. |
| Messages-readable handoff and preview after upload cleanup | `python3 tests/attachment_observation.py AttachmentObservation.test_handoff_is_readable_by_messages_and_preview_survives_upload_cleanup -v` | The same regression failed before production handoff staging and passed unchanged afterward. Covers separate original bytes, delivery, preview generation, cleanup, restart, and exact retry without replay. |
| Handoff integrity and ownership | `zig build test -Doptimize=ReleaseSafe` | Passed: independent inode, unchanged original offset, retained bytes after original deletion, unstarted cleanup, wrong hash, symlink rejection, and no replacement of an existing copy. |

Use Zig from `.zigversion`. Build `fake-relay` before the Python suites. Supply
`-Dopenssl-prefix=/absolute/openssl-3.5` when the system OpenSSL is not 3.5.
Build caches can be redirected with `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` when the normal cache is unavailable.
The GUI attachment check builds its synthetic relay automatically and additionally
requires a Wayland display and Python `cryptography` and `h2`. Its native callback
injection does not test compositor drag negotiation or Messages Automation.

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

The native script passes the handoff's absolute filename as a literal argument,
coerces it to an alias before setting its dispatch flag, and uses the same
account and chat checks as text sending. Apple's
[file-reference guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/ReferenceFilesandFolders.html)
documents POSIX-file-to-alias conversion. Native compilation and payload operand
binding now have a separate macOS regression check. File acceptance, copy timing,
and delivery still require the real Messages acceptance checks below. Synthetic
copies exercise the journal boundary, not Apple's implementation.

The first native send exposed a terminology collision: the script's variable
`outgoing` was interpreted inside the Messages block as the application's `FTog`
enumeration. This substituted an enum for both captions and file aliases, producing
unexpected text while the intended request remained unconfirmed. The payload now
uses `messagePayload`. The installed dictionary confirmed the conflicting term;
the unchanged regression reproduced the wrong argument before the rename and
the correct text/alias afterward. It retains production preparation and send
operands but substitutes local capture for sending and synthetic account/chat
lookup, so it never sends a real message. The original script also compiled
before the fix: compilation alone did not catch this issue, and the synthetic
adapter did not exercise AppleScript terminology.

The subsequent native attempt exposed a separate sandbox failure. Read-only Mac
diagnostics showed Messages' background processes failing to open the relay's
application-support upload with `Operation not permitted`. Messages recorded a
failed attachment referencing that external file; the relay correctly refused
to generate its preview with `unsafe_source`. Relaxing preview path validation
would not fix delivery.

The relay now creates a separate, length- and hash-verified handoff copy inside
Messages' attachment storage before invoking file automation. The synthetic
adapter rejects paths outside that root, reproducing the observed native access
boundary; it no longer silently copies an arbitrary relay descriptor. The new
regression first failed against the original production dispatch path using this
fixture, then passed unchanged with production staging. The handoff copy survives
uncertain automation, relay restart/reset, and private-upload retirement because
Messages may keep referencing that exact filename. Definite unstarted operations
remove their copies. Retained history files are outside the upload quota and
are not swept by upload recovery. Delivery still requires an observed matching
message and receipt; preparing the copy alone proves neither.

Handoff validation passed 212 Zig tests with one unavailable-platform skip, plus
all 49 integration cases across `attachment_uploads.py`, `attachment_sends.py`,
`attachment_observation.py`, and `client_attachments.py`. Formatting and diff
checks passed. A further native check could not run because the Mac connection
timed out; the corrected handoff still needs actual Messages acceptance below.
No real messages were sent during this validation.

An affected relay must be rebuilt and restarted because it embeds the script.
Previously attempted requests remain uncertain and are not automatically replayed
or declared delivered. Preserve their originals and review actual message history
before deliberately creating another send.

## Remaining real Messages acceptance

Validate under the installed relay app identity, with a deliberately selected
recipient and separate authorization for actual sends. Follow the existing
[Mac validation guide](mac-validation.md). Never write to the real Messages
database to manufacture test cases.

1. After the dictionary and operand checks above, verify actual file sending to a
   direct recipient, an existing direct chat, and an existing group.
2. Send a PNG, JPEG, PDF, and an ordinary binary file. Check recipient-side bytes,
   filename, presentation, and observed attachment metadata. Check empty files
   and the configured size boundary; document any Messages-specific restriction.
3. Send text with one file and with several files. Record how many Messages rows
   appear, their ordering, attachment joins, and whether captions are preserved.
4. Establish which source metadata safely identifies our uploads. Include two
   different files with the same name/size, repeated identical files, and an
   unrelated simultaneous send to the same conversation. Ambiguity must remain
   uncertain rather than confirming the wrong request.
5. Observe the handoff filename and any copy Messages creates, including a slow
   transfer. Verify image viewing after private-upload retirement and relay
   restart. Do not treat AppleScript returning successfully as proof of delivery.
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
