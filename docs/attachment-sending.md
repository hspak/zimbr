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
2. **Pending: relay upload storage and transport.** Persist upload reservations,
   stream authenticated bytes into private files, verify length and SHA-256,
   and implement retry, cancellation, quotas, and orphan cleanup.
3. **Pending: relay dispatch and observation.** Pass staged files to Messages,
   retain per-part outcomes, correlate observed attachments conservatively, and
   preserve uncertainty through crashes and source resets.
4. **Pending: client attachment drafts and upload worker.** Snapshot local files,
   persist drafts and outbox ownership, upload with progress, and recover without
   duplicating sends.
5. **Pending: composer integration.** Accept Wayland file drops, show removable
   attachments and thumbnails, allow attachment-only sends, and surface errors
   and cancellation.
6. **Pending: end-to-end validation and documentation.** Exercise the actual
   client and synthetic relay together, then record outstanding Mac acceptance
   checks separately.

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

Text and files may become separate Messages records. The dispatch implementation
must track each operation durably and represent partial or uncertain outcomes;
retrying an uncertain operation must never automatically dispatch it again.
The source Messages database remains read-only.

Local drafts own private copies so a moved, changed, or deleted source file does
not alter an already staged attachment. Draft removal, outbox transfer, restart,
reset, and eventual cleanup must explicitly transfer or release file ownership.
Disk and network work must remain bounded and allow the GUI and live events to
continue making progress.

Browser image offers and clipboard image bytes require additional input support;
the first input path handles local file-manager drops. Upload and dispatch are
generic across regular files and do not depend on preview support.

Relay-specific checks and their evidence are maintained in
[attachment relay validation](attachment-relay-validation.md).
