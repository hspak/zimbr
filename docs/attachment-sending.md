# Outgoing attachments implementation

The intended flow is to drop local files into a conversation, review the staged
files alongside the text draft, and press Send. Images receive thumbnails when
the client can decode them; other files receive filename and size cards. File
preparation and network transfer run off the GUI thread.

## Discrete implementation steps

Each step is validated and committed before the next one. Completion below
means the implementation and its relevant automated checks have passed.

1. **Complete: protocol contract.** Define bounded upload metadata and send
   attachment references, preserve text-request idempotency, and reject
   attachment sends until the dispatch path is ready.
2. **Complete: relay upload storage and transport.** The durable reservation
   ledger now enforces device ownership, metadata identity, quotas, exclusive
   transfer leases, and pinning to send requests. Private streamed file I/O now
   verifies length and SHA-256 before atomic publication. Authenticated HTTP/2
   endpoints, restart recovery, failed-lease recovery, physical cleanup, and
   transport regression checks are complete.
3. **Complete: relay dispatch and observation.** Atomic acceptance now pins
   every completed upload and journals ordered caption/file operations. Exact
   retries retain their outcomes. Recovery holds an interrupted operation and
   skips its unstarted successors. Authenticated HTTP acceptance and sequential
   text/file dispatch now run through the sender; synthetic tests verify original
   bytes, ordering, partial failure, interruption, and exact retries. Correlation
   verifies independent original bytes, checks uniqueness and competing sends,
   and follows receipt changes. Safe reclamation releases unstarted parts and
   independently observed deliveries. Automated checks pass; native file sending
   still requires Mac acceptance.
4. **Complete: client attachment drafts and upload worker.** Private local
   snapshots and transactional draft/outbox ownership pass automated storage
   validation. A separate preparation worker and outgoing HTTP/2 lane now stage
   files, report progress, and recover original request IDs without replaying
   submissions. Automated worker and transport checks pass; these operations
   are ready for composer integration.
5. **Complete: composer integration.** Local file drops populate removable
   attachment cards with background thumbnails. The composer supports
   attachment-only sends, preparation and upload cancellation, progress, and
   individual file outcomes. Automated input and GUI checks pass, apart from
   the separately verified baseline software-renderer antialiasing assertion.
6. **Complete: end-to-end validation and documentation.** The GUI, preparation
   worker, image worker, upload lane, and synthetic relay pass an integrated
   original-byte send check. Usage and limits are documented; outstanding native
   Mac acceptance is recorded separately.

## Protocol and lifetime decisions

`send_attachments_v1` is distinct from the existing attachment-reading capability.
Clients require this capability before offering attachment sends. A send contains
an ordered `attachments` array of upload metadata: opaque `id`, display `name`,
`mime_type`, decimal-string `bytes`, and lowercase hexadecimal `sha256`. The
relay verifies that references exactly match completed uploads in the current
epoch. Filesystem paths never travel in message requests.

Empty attachment arrays serialize exactly like existing text-only requests.
This preserves persisted request payloads used for idempotency. A nonempty text
body or at least one attachment is required. An upload may contain zero bytes.
Initial application limits are 16 files, 100 MiB per file, and 200 MiB combined
per send. These are relay resource limits, not a promise about iMessage limits.

Upload reservation, byte transfer, and message submission are separate steps.
Small JSON commands retain the existing 64 KiB cap; binary uploads use a separate
bounded streaming path. Upload IDs support retry without creating another file.
Incomplete uploads cannot be dispatched. Completed files remain pinned while
Messages may still need them; HTTP acceptance and AppleScript completion alone
do not prove that Messages has finished reading a file.

The relay reservation ledger allows at most 256 uploads and 2 GiB of declared
bytes, including incomplete transfers. Unused reservations expire after 24
hours or an epoch change. Retirement blocks further use immediately; quota is
released only after physical cleanup. Each transfer receives a fresh lease token
so late callbacks cannot publish or abandon a replacement transfer. Originals
for attempted parts remain protected through resets and uncertain outcomes.
Proven unstarted parts can be retired without waiting for Messages.

Binary transfer memory is independent of file size: the connection uses a
16 KiB read buffer and the existing bounded HTTP/2 session. Files stream to disk
without Base64 expansion or a whole-file allocation. Disk writes and final fsync
run outside the journal mutex; flow-control credit follows consumed bytes. Four
active uploads and separate idle/total deadlines bound resource use. A 9 MiB
binary transfer and commands/SSE alongside an unfinished upload are exercised by
the transport suite.

Text and files may become separate Messages records. The dispatch implementation
must track each operation durably and represent partial or uncertain outcomes;
retrying an uncertain operation must never automatically dispatch it again.
The source Messages database remains read-only.

Before file automation, the relay streams a separate, hash-verified copy into a
private subdirectory of Messages' attachment storage. Messages' background
processes can be denied access to the relay's application-support directory even
when AppleScript accepts the file alias. The private upload remains unchanged.
Copying uses a 64 KiB buffer and costs one additional full-file read and write.
A definite unstarted failure removes the handoff copy. Once automation succeeds
or may have started, the copy remains available for Messages history and retries;
relay reset and upload cleanup never delete it. These retained history files are
outside the upload reservation quota and can grow with sent attachment history.

Multipart requests carry an ordered `parts` array: a text operation when the
caption is nonempty, followed by one operation per file. Each part retains its
own status, message association, and safe error. `invoked` means automation
returned, not that a message was observed or delivered. A confirmed unstarted
failure or uncertain operation skips the remaining parts. A crash between
durable successful invocations can resume at the next queued part; a crash
during invocation makes that part uncertain and holds its successors. Exact
request retries never replay attempted parts. Aggregate delivery requires every
part to be delivered; partial requests expose the individual outcomes.

Observation runs on a separate worker. It compares stable source snapshots,
checks filename and actual file length, and hashes source bytes in 64 KiB chunks
outside the journal mutex. Messages' reported attachment size can differ from
the file on disk and cannot exclude a possible match or duplicate. The source
file must be inside Messages' attachment root and have a different file identity
from the staged original. A bounded cache of 512 file fingerprints avoids
rehashing unchanged bytes; each observation pass hashes at most 200 MiB.
Missing, changed, unsafe, or undecodable source
records prevent confirmation. Duplicate content and overlapping requests cannot
claim the same echo. Source transformations can therefore leave sends uncertain.
Incoming copies in self conversations do not compete with outgoing records;
the outgoing record still requires byte verification and the normal receipt checks.

Discovery examines at most 4,096 source rows after the dispatch boundary and
64 scoped outgoing records. Exceeding either bound keeps the outcome uncertain,
and old unconfirmed parts retry every 30 seconds. A confirmed association follows
its source message identity for later receipts even after newer history exceeds
the discovery budget or Messages evicts its local copy. Discovery alone retains
the private upload; a delivery receipt retires it in the same transaction as the
send update. Failed transactions preserve both the previous outcome and the original.
Existing cleanup removes retired files before releasing quota, while durable
request identities continue to answer retries after the files are gone.

Local drafts own private copies so a moved, changed, or deleted source file does
not alter an already staged attachment. Draft removal, outbox transfer, restart,
reset, and eventual cleanup must explicitly transfer or release file ownership.
Disk and network work must remain bounded and allow the GUI and live events to
continue making progress.

The client stores originals as private files and streams snapshot copies in
64 KiB chunks, hashing while copying. It rejects changed sources, symlinks, and
nonregular files. Its persistent ledger bounds all owned and retired originals
to 256 files and 2 GiB, in addition to the per-draft protocol limits. A single
copy may temporarily use another 100 MiB before its ledger commit. Startup
collection removes interrupted orphan copies; routine collection removes only
retired entries and releases quota after deleting their files.

Send must contain exactly the saved draft's ordered attachments. The outbox
insert, attachment ownership transfer, and draft clearing commit together.
Attachment-only drafts remain discoverable after relay resets. Failed and
uncertain attachment sends retain their local originals and review history;
the text-only five-minute unknown-send expiry does not apply to them. Confirmed
delivery retires local originals atomically with the matching request update.
An explicit local cache reset also removes the private outgoing directory.

Storage validation passed `zig build test-client client-probe client
-Doptimize=ReleaseSafe` (138 client tests and both executable builds),
`python3 tests/client_integration.py`, and `python3 tests/client_reset.py`.
The new cases exercise original-byte preservation, cancellation, unsafe sources,
crash orphans, quotas, merged drafts, empty files, transaction rollback, invalid
delivery updates, and retention across relay resets. Existing text-send and
unknown-send expiry checks remain intact.

The worker exposes preparation, draft removal, preparation cancellation, and
pre-submission upload cancellation. File work uses a separate cache connection;
the outgoing request slot keeps live events, commands, history, and incoming
images responsive. Upload reads use at most 64 KiB per callback and responses
have a 512 KiB cap. Cancellation retains the local outbox originals for review;
unused relay reservations follow their normal 24-hour expiry.

Each upload attempt first looks up the immutable request ID. Before submission,
it may retry reservations and transfers with the same upload IDs, reusing bytes
the relay already verified. Submission intent is persisted before starting the
POST. A lost response or restart from that point permits only request lookup;
a missing request becomes unconfirmed and is not automatically submitted again.
Epoch changes hold old requests and preserve their originals.

`python3 tests/client_attachments.py -v` passed nine production-worker cases,
including 9 MiB and empty files, corrupted originals, offline removal, live
events during a held upload, cancellation, lost upload responses, lost accepted
and unaccepted send responses, restart after relay cleanup, and epoch changes.
The private-storage readiness case failed before the send-gate fix and passed
unchanged afterward. Existing client integration, transport fault, and media
transport suites also passed.
The final worker build passed 139 client tests, including completion of queued
preparations when the file worker cannot open its cache connection. Both the
desktop client and headless client executable built successfully.

Composer integration also requires multipart history to remain reviewable. A
matching caption cannot hide its attachment request; partial and uncertain
requests keep their summary. A delivered summary disappears only after every
part's message has loaded. History queries, missing-message hydration, and new
conversation selection now follow individual part links. The unchanged
regression test failed before this fix and passed afterward; 140 client tests
and both client builds passed. The production-worker suite verifies all three
caption/file echoes and redirection to the resulting conversation; all nine
attachment cases and the existing text-send integration suite passed.

The Wayland backend now validates local file URIs before converting them to
paths. It accepts escaped Unicode names and local authorities, rejects remote
authorities, malformed escapes, embedded NULs and oversized paths, and bounds
offers to 16 paths, 4096 bytes per path, and 256 KiB total. Reads are nonblocking;
a stalled offer has a two-second deadline. The transfer owns its offer until
completion, rejection, timeout, or shutdown, and paths are accepted as a complete
batch. The application-owned delivery handler copies complete paths without
truncation. SDL owns the Wayland connection and dispatch; a native data device
retains the raw URI validation boundary.

Native GUI tests inject complete batches through the delivery handler, verify
remote URI and long-path rejection, and send reviewed original bytes to the
synthetic relay. Zrct compositor scenarios separately exercise actual Wayland
drag negotiation and attachment-only sends. Native compositor diagnostics cover
partial-transfer responsiveness, stalled-drop timeouts, and shutdown during a
transfer. See the [GUI development notes](development.md#gui-scenarios-with-zrct)
for test commands and software/hardware rendering profiles.

Local originals can now use the existing background image worker and bounded
texture cache, including with no relay epoch or connection. PNG/JPEG decoding
keeps its 8 MiB encoded, 2,560-pixel dimension and 32 MiB decoded limits. Preview
failure leaves the attachment available for sending. The decoder borrows the
original descriptor without changing its offset or modification timestamps;
preview pixels do not replace uploaded bytes.

The preview chunk passed 141 client tests, both client builds, an offline
production-worker case covering deleted sources, PNG/JPEG, unsupported files,
oversized dimensions and symlink rejection, and the existing authenticated
media transport suite. The GUI texture handoff check passed; 106 of 107 GUI
checks passed with the same baseline software-renderer antialiasing failure.

The composer now consumes the native dropped-file list and queues private
preparation. A fixed-height card with previous/next controls keeps all 16 files
reviewable without growing the composer over the history. Removal and drop
commands carry an acknowledgment token; Send stays disabled until the displayed
draft reflects them and preparation finishes. Offline files remain drafts, and
attachment sends require the relay capability and local storage readiness.

Pending history shows filename/size cards, upload progress and cancellation,
and each file's observed status. Copying an earlier multipart send is explicitly
**Copy caption**: it preserves the earlier files and does not silently queue
another upload. Files for a new send must be dropped into its draft. Caption
recovery warns when an earlier text operation may have reached Messages; a
cancelled pre-submission upload does not trigger that warning.

Composer validation passed 142 client tests, both client builds and all ten
production-worker attachment cases. The native callback GUI scenario exercises
Unicode drops, attachment paging/removal, capability and preparation gates,
attachment-only Enter, upload cancellation, and caption copying. The minimum-size
layout was captured and reviewed. The GUI suite passed 108 of 109 checks with
the previously documented baseline antialiasing failure remaining.

Browser image offers and clipboard image bytes require additional input support;
the first input path handles local file-manager drops. Upload and dispatch are
generic across regular files and do not depend on preview support.

The final `zig build test-gui-attachments -Doptimize=ReleaseSafe` check drives a
real App, Worker, and Media instance through the native file-drop callback on
Wayland. It stages a Unicode-named PNG, an empty file, and a 256 KiB binary file,
checks the decoded thumbnail, and verifies that no send occurs before review.
After deleting or modifying every source, Enter submits the reviewed caption and
private originals. The synthetic relay receives the original bytes exactly once
in order, every part reaches delivered, and the client shows confirmed history
in the resulting conversation with an empty draft. The minimum-size screenshot
was reviewed, including the transparent preview's fallback-label correction.

Final core validation passed 142 client tests and 69 relay/protocol tests, with
one unavailable-platform skip, and both client executables built successfully.
The dedicated GUI integration passed; the full GUI suite passed 109 of 110 tests,
with only the previously verified baseline software-renderer antialiasing failure.
Native file-manager drag negotiation across a compositor and actual Messages file
acceptance remain manual checks; callback injection does not establish either.

Relay-specific checks and their evidence are maintained in
[attachment relay validation](attachment-relay-validation.md).
