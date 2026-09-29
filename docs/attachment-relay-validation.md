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
| Upload streaming, integrity, quotas, and cleanup | To be added with upload implementation | Pending |
| Attachment dispatch, correlation, partial failure, and restart | To be added with dispatch implementation | Pending |
| Existing text sends, idempotency, recovery, and source resets | `python3 tests/integration.py` | Passed after protocol changes |
| HTTP/2 stream isolation | `python3 tests/relay_http2.py` | Pending upload transport changes |

Use Zig from `.zigversion`. Build `fake-relay` before the Python suites. Supply
`-Dopenssl-prefix=/absolute/openssl-3.5` when the system OpenSSL is not 3.5.
Build caches can be redirected with `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` when the normal cache is unavailable.

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
