# Cache continuity and reset triggers

Clients keep independent SQLite caches and event cursors. The relay keeps one
durable epoch and an event journal shared by all subscribers. Reading a snapshot,
opening another client, reconnecting, or rotating an HTTP/2 connection does not
change that epoch or consume another subscriber's events.

## Synchronization and history

| Trigger | Effect |
| --- | --- |
| Ordinary reconnect or certificate renewal | Resume the saved cursor; keep cached records and media keys. |
| Replay cursor expires | Fetch a new snapshot and cursor in the same epoch; retain history, contacts, avatar references, unread counts, and event deduplication. Refresh paging and preview coverage. |
| Interrupted initial synchronization | Retry the snapshot; retain records already cached in the same epoch. |
| Contact extension becomes available or its initial snapshot is incomplete | Fetch the directory independently, then attach events from the saved cursor. |
| API `resync_required` error | Obtain a new snapshot. Other HTTP 409/410 errors do not invalidate the entire cache. |
| Relay epoch changes | Clear replicated records, contact identities, history coverage, and unread state. Preserve drafts and original send-request identities; never resend automatically. Media keys use the new epoch. |
| Explicit local cache reset | Replace the client database and remove media and outgoing files, preserving connection settings. |
| Explicit client-and-relay reset | Reset the shared relay epoch conditionally, then clear the requesting client's local data after confirmation. Other clients observe the new epoch. |
| First upgrade to lazy history caching | One-time migration trims previously copied background history. The persisted migration marker prevents repetition. |

The relay retains at most 100,000 replay events by default and at most seven days
of events, pruning once per minute. A client offline beyond either limit needs a
snapshot. This used to delete contacts and history even with an unchanged epoch,
which could make names and photos disappear and reload after an idle reconnect.
Same-epoch refreshes now merge records by revision and retain existing content
while the snapshot arrives. Older retained history is refreshed when requested
or reconciled; a snapshot does not eagerly download the whole archive.

## Relay source checks

The relay resets its epoch when the Messages database file identity changes, a
surviving saved row has a different GUID, or insufficient source anchors remain
to establish continuity. macOS file identity uses the volume UUID, inode, and
birth time; ordinary filesystem device renumbering at reboot is not replacement.

Deleting an ordinary saved anchor previously caused a shared reset. Missing rows
now retire from the anchor set when at least two independent saved rows still
match. A deleted ingestion cursor can rebase to a surviving anchor. Reuse of an
ordinary anchor's row by a different GUID remains a reset; the existing exception
for deleted tracked reaction rows remains supported. Actual file replacement
still resets even when its contents were copied from the old database.

## Contact names and photos

Contacts refresh automatically on source changes and periodically every fifteen
minutes. An unchanged contact/photo refresh preserves public IDs and photo
versions. A failed contact query retains stale presentation. Permission loss or
unavailability hides contact presentation and evicts private avatar files and
textures; recovery waits for successful reconciliation.

On macOS, the authorization monitor uses a fresh status subprocess. A failed
probe or a permission check older than five seconds reports unavailable. This is
a separate possible cause of disappearing names/photos around wake or reconnect,
even when the epoch and message cache remain unchanged. The permission gate is
preserved; a confirmed grant is required before contact presentation resumes.

Media cache keys include the relay endpoint, CA digest, epoch, asset ID, version,
and variant. Ordinary reconnects retain these keys. Image storage has separate
bounded disk and texture caches; budget eviction, changed/retired assets, invalid
files, and explicit reset can require another download. Changing conversation or
connection cancels pending image work while retaining usable textures and files.

## Diagnosis and regression checks

Client logs distinguish `Live sync cursor expired`, `Relay requested sync`,
`Status requested bootstrap`, and `Contact bootstrap started`. `Cache sync started`
reports whether the epoch changed and records were retained. `Contact presentation
changed` reports the permission and reason for gating names/photos. Relay source
reset logs identify `file_identity`, `ordinary_anchor`, or `live_anchor`.

Build with the pinned toolchain and run the synthetic tests:

```sh
zig build test client-probe fake-relay -Dopenssl-prefix=/path/to/openssl-3.5
python3 tests/client_cache.py
python3 tests/client_integration.py
python3 tests/client_enrichment.py
python3 tests/client_media_transport.py
python3 tests/contact_refresh.py
python3 tests/reactions.py
```

The cache regressions exercise two independently authenticated clients, one
client falling behind the replay window, preservation of contact rows and avatar
files, conflict responses, enabling Contacts, deleted source anchors, and actual
source discontinuity. They use temporary databases and synthetic contacts.
