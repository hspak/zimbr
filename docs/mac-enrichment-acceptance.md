# Mac enrichment implementation and acceptance

The relay/shared-protocol implementation of
[message-enrichment.md](message-enrichment.md) is complete, with the verification
limits recorded below. Native reaction verification covers
heart-to-thumbs-up replacement; extended cases remain unverified.
This record keeps the entire relay/shared-protocol scope visible. Linux client
storage, networking, rendering, notification changes, and Linux UI acceptance are
excluded from this task. Native compilation and synthetic tests do not establish
installed-app permission attribution or the semantics of a real Messages payload.

## Current evidence (2026-09-24)

| Work item | Implemented | Remaining evidence/work |
| --- | --- | --- |
| 1. Fixtures and contract | Additive types; independent optional-column probes; pinned phone parser; generated Contacts, image, plist and Foundation fixtures; aggregate probes; installed Contacts attribution, URL archive layouts and reaction add/replacement | Extended native reaction cases deferred |
| 2. Identity directory | Observed addresses only; native Contacts bridge; background matching; durable jobs; rename/removal/denial/stale handling; keyset/negotiated streams; migration/backfill; installed grant, relaunch, signed upgrade, locked-session reads, live rename/removal, permission recovery and independent Contacts/FDA changes | Verified for the documented installed cases |
| 3. Image pipeline | Protected source opens; bounded ImageIO helper; immutable versions/ETags; mTLS delivery; arrival/change retries; eviction/regeneration; GC; bounded overflow; slow-reader capacity; epoch invalidation; installed JPEG/PNG/HEIC and locked-session delivery | Verified for the documented formats and bounds |
| 4. Contact avatars | Lazy thumbnail jobs; shared per-contact assets; photo-only invalidation; requested-photo refresh; denial/removal clearing; installed thumbnail conversion/delivery, photo addition, photo-only replacement, photo removal, live revocation and recovery from denied startup | Verified for the documented installed cases |
| 5. Stored link cards | Bounded binary/XML/keyed reader; standard/partial cards; delayed payloads; embedded/local artwork; observed RichLink wrappers; exact joined attachment GUID mapping; installed metadata and image delivery | Unknown archive classes or attachment naming layouts retain fallback |
| 6. Reactions | Standard/custom/removal mappings; Foundation range/transfer-GUID parts; durable source ledger and target work; deletion tombstones; ordinary continuity anchors; target upserts and sidebar selection; installed heart add, thumbs-up replacement and persistence across upgrade/restart | Remaining standard values, custom/removal/deletion and removal across restart have synthetic coverage; extended native checks deferred |
| 7. Integration/rollout | Journal/mTLS fixture suites; migration/backfill; legacy/negotiated events; signed helper; aggregate tooling; all six native capabilities enabled | Native verification limits below |

Native `identity_directory_v1`, `contact_avatars_v1`, `image_assets_v1`,
`image_attachments_v1`, `stored_link_previews_v1`, `reactions_v1` and legacy
`attachments` are enabled. Contacts and images passed the installed cases below;
reaction rollout uses the installed add/replacement checks and automated coverage,
with the native verification limits recorded below. The fake relay also
advertises all six.
Permission or missing source columns affect readiness, not protocol-support
flags. `event_extensions: ["identity-v1"]` advertises negotiation on both binaries,
including read-only native acceptance.

## Directory and transport contract

`Identity.id` is an opaque UUID, unique by service plus the exact observed address
within one relay epoch. Revisions are decimal strings from the global journal
sequence. `display_name` and `avatar` are nullable. Match states are `pending`,
`matched`, `unmatched`, `ambiguous`, and `unavailable`; freshness is `fresh` or
`stale`. Unmatched/ambiguous/unavailable upserts clear presentation values. Source
contact IDs are confined to `contact_mappings`, never identities or events.

`GET /v1/identities?before=UUID&limit=N` returns `identities` and `next`, with
descending immutable-ID keysets, at most 200 records, and a 32 KiB record budget.
Capture `/v1/sync` before the bootstrap pages, then replay after that cursor.
`GET /v1/events?...&extensions=identity-v1` includes identity events and returns
`Zimbr-Event-Extensions: identity-v1`. Unknown/duplicate requested extensions fail
with HTTP 400. Legacy streams return an empty extension header and only the
existing event types; skipped identity sequences still advance the internal scan.
Names update through identity events without rewriting messages or changing chat
participants, titles, routing, or message timestamps.

Schema version 6 adds directory/private mapping/work, canonical enrichment items,
asset sources/owners/representations/work/private blobs, reaction observations/work,
and independent ordinary-message anchors in an atomic migration.
It preserves epoch, messages, requests, and cursor sequence. A resumable
`identity_backfill_v1` keyset pass observes historical incoming senders, and
`enrichment_backfill_v1` drains a bounded, resumable source pass. Chat scans
observe participants, and message ingestion observes senders/reaction actors.
Worker completions check epoch and job generation inside their commit transaction.
Source reset clears directory records and pending work with the rest of the epoch.

The Contacts worker reads unified contacts through `CNContactStore`, requesting the
formatter's name keys, organization, phone/email values, and image availability.
Thumbnails are fetched only for requested, matched, observed contacts, through
`thumbnailImageData`; aliases share their contact's avatar. Reads, matching,
thumbnail fetches, and conversion run outside the Core mutex.
The native main thread services the macOS run loop while the HTTPS listener runs
on a worker. The installed rename check initially exposed missing notification
delivery when the main thread blocked in network accept; after this fix a second
rename arrived live, advancing the identity revision and preserving its ID.
Adding a photo and then changing only that photo produced valid JPEG avatars with
new versions and different ETags while preserving the identity and name.
Removing only the photo after recovery from denied startup cleared the avatar
live and made the previously cached image return HTTP 404. The name, identity,
relay epoch and history availability were preserved, and the revision advanced.
Deleting the contact then cleared its name live, advanced the identity revision,
and preserved its identity, relay epoch and history availability.
Startup/change notification/permission grant/15-minute refreshes replace the index;
new handles use that index. Failed queries mark existing matches stale and retry
after 30 seconds; a new source generation permits earlier recovery. Successful
removal or denied/restricted permission clears live matches. Store generations
also invalidate private source mappings for future photo jobs.

The bridge checks authorization before any enumeration. Normal startup never
calls the request API. `relay doctor --request-contacts` is the explicit interactive
action and refuses an executable without the installed bundle identifier.
`CNAuthorizationStatusLimited` is annotated for iOS in the inspected Mac SDK;
unknown status values are reported as unsupported until verified on macOS.

Installed revocation testing found that the long-running process retained an old
authorization result. A permission monitor now invokes the same signed executable
in a private status-only mode once per second. The child uses the public Contacts
authorization API, an empty environment, null standard streams and no inherited
descriptors. Each probe has a two-second deadline; failure or an observation older
than five seconds makes contact presentation unavailable. This runs outside the
Core mutex. Installed live revocation cleared names/photos and rejected the exact
avatar fetched successfully just before revocation with HTTP 409, without a relay
restart; history remained ready. Startup with access denied also clears names and
photos. Status responses use the monitor's latest decision even while the directory
worker is busy; a restored grant stays unready until reconciliation finishes.

Recovery testing found a second process-level cache: a new `CNContactStore` object
in a relay started while denied still failed enumeration after regrant. Enumeration
and thumbnail reads now run in fresh instances of the same signed executable,
using dedicated request/response pipes, empty environments and no inherited relay
descriptors. Reads have a 15-second deadline and 512 MiB resident-memory bound;
responses are capped at 32 MiB for the index and 8 MiB for a thumbnail. The parent
checks permission around each result and generation around each thumbnail. Normal
invocation without the dedicated pipe handles is refused. Installed authorized
startup, thumbnail delivery and live revocation pass with this reader. A relay
started while denied then restored the fixture name and avatar after regrant,
without another restart. The recovered avatar returned HTTP 200 with valid JPEG
markers, and the identity and history availability were preserved.
Independent permission checks also pass: installed doctor can read Messages while
Contacts is denied, and reports `DatabaseUnavailable` with Contacts still
authorized when Full Disk Access is disabled. After Full Disk Access was restored,
installed doctor again reported readable Messages and authorized Contacts. The
subsequently installed signed build advertises the directory and avatar
capabilities and reports both ready through mTLS; its app/helper signatures pass
strict verification.

## Phone normalization dependency

The native relay statically compiles the core Objective-C sources of
[libPhoneNumber-iOS 1.7.8](https://github.com/iziz/libPhoneNumber-iOS/releases/tag/1.7.8),
an actively maintained libphonenumber port supporting macOS. `build.zig.zon` pins
the release archive and Zig content hash. The core needs Foundation and zlib, with
no Homebrew runtime dependency. Its Apache license is installed under
`zig-out/share/zimbr/licenses/` and copied into the signed relay app. Fake/Linux
builds do not import the dependency or Mac frameworks.

Lookup normalization version is 1. An explicit `contacts_phone_region` in
`relay.json` supplies national-number context (for example `US` or `GB`); the
default is empty. Doctor reports the Mac region as a suggestion only. The parser
produces E.164 keys for valid numbers. Short codes, unparseable input, and numbers
with extensions keep exact trimmed keys. Suffix matching is never used. Email
matching trims whitespace, lowercases the domain with Foundation on macOS, prefers the exact local
part, and accepts a case-insensitive fallback only for a unique unified
contact. Plus tags and dots retain their meaning. Multiple contacts at a lookup
key are ambiguous, independently of enumeration order.

## Source query probes

`MessagesDb.open` validates the existing required history queries, then separately
prepares each of these optional queries. A missing optional input cannot disable
ordinary history. Doctor and status expose only the following booleans:

| Probe | Query |
| --- | --- |
| `attachment_filename` | `SELECT filename FROM attachment LIMIT 0` |
| `attachment_uti` | `SELECT uti FROM attachment LIMIT 0` |
| `attachment_transfer_state` | `SELECT transfer_state FROM attachment LIMIT 0` |
| `link_payload` | `SELECT payload_data FROM message LIMIT 0` |
| `reaction_target` | `SELECT associated_message_guid FROM message LIMIT 0` |
| `reaction_emoji` | `SELECT associated_message_emoji FROM message LIMIT 0` |
| `reaction_range` | `SELECT associated_message_range_location,associated_message_range_length FROM message LIMIT 0` |

These prove query availability only. The parsers accept the explicitly bounded
layouts below; fixture acceptance does not establish that a particular Messages version
uses those layouts. Source-format evidence and its limits are recorded below.

## Image and overflow contract

`GET /v1/assets/:id/:version/:variant` uses the existing mTLS/device authorization.
Unknown IDs return 404, retired versions 410, unavailable/pending images structured
409, and a saturated worker/response lane 503 with a retry hint. Ready responses
carry actual JPEG/PNG MIME/length, a quoted SHA-256 ETag, private immutable caching,
and `nosniff`; conditional requests return 304. There are four asset response
slots, bounded write time, and remaining connection capacity for commands and SSE.
No API accepts a source path or fetch URL.

Attachment filenames are privately resolved under the Messages attachment root
with descriptor-relative opens. Traversal, symlinks, hard links, wrong ownership,
and nonregular files are rejected. Each inspection reopens the approved root,
so renaming/replacing it cannot retain access through an obsolete descriptor.
Missing files retry independently of message
insertion, with visible-chat prioritization. Stat identity is checked around
conversion and source/version/epoch are checked before publication. Photos and
payload bytes go through private temporary descriptors in the same pipeline.

The separately signed helper receives only input/output/metadata descriptors,
with no shell, source paths, relay credentials, or inherited user environment.
ImageIO reads pixels with orientation correction, preserves alpha, emits the
first animation frame, and writes fresh JPEG/PNG without source metadata. Bounds:
100 MiB source, 100 megapixels, 15-second conversion, 512 MiB resident helper,
32 MiB decoded output, 8 MiB encoded output; avatar/inline/viewer long edges are
128/1024/2560. Jobs are deduplicated and capped at 128. The private derivative
cache is capped at 2 GiB, with atomic installation, LRU eviction, regeneration,
and temporary/orphan cleanup. Regeneration may reuse a version only for identical
bytes/ETag. Contact changes rotate generations even for photo-only edits; permission
loss clears references and blocks cached avatar reads.

Full attachment/preview/reaction/part metadata is retained in canonical journal
items. History and events inline at most 32 attachments, four previews, 128
reactions, and 128 parts within a combined 32 KiB metadata budget. Totals and
completion flags expose overflow. `GET /v1/messages/:id/enrichment` accepts
`section`, `revision`, `after`, and `limit`; tokens bind to message/section/revision,
and a changed revision returns 409 `enrichment_restart_required`. Pages have a
32 KiB byte bound. Captions remain in the original `text`; parts use UTF-8 ranges
instead of duplicating long text. History assembly also observes its 8 MiB bound.
Inline budgeting reuses canonical item lengths and measures the envelope once;
it does not repeatedly allocate encodings of shrinking prefixes. A regression
with large escaped strings, 32 attachments, four cards, 128 reactions and 128
parts preserves every canonical item within an 8 MiB preparation arena.

## Accepted source-format candidates

`adapter/plist.zig` handles primitive binary/XML property lists with a 1 MiB input,
8,192-object and depth-32 limits. UID resolution has independent visit/depth/cycle
checks; invalid indices, duplicate keys, unknown classes and XML internal entities
fail safely. It never instantiates archived classes or resolves external entities.
The URL adapter accepts `richLinkMetadata`/`metadata`, directly or through known
NSKeyedArchiver dictionary/array/string/URL/data, LP metadata, `RichLink`, and
`LPSharingMetadataWrapper` containers. It
retains original/final HTTP(S) URLs, bounded title/summary/site text and placeholder
state. Unsupported app/music/map shapes keep message text and an explicit fallback.
Original/final mismatch is retained. Ordinary links do not acquire invented cards.

Artwork is accepted as known embedded data or an explicit transfer GUID
matching an attachment already joined to that message. An observed
`RichLinkImageAttachmentSubstitute` index can identify the exact
`at_<index>_<message GUID>` attachment, but only if that GUID is actually joined
to the same message. SQL position and body-part indices never establish this
association; unmatched naming layouts retain an empty artwork reference.
Joined artwork is marked
to avoid duplicate attachment presentation. Remote URLs never enqueue fetches;
there is no HTTP client or `LPMetadataProvider` in this path. Tests generate XML,
binary, keyed, partial, multiple, delayed, cyclic, invalid and oversized inputs
independently with Python `plistlib`. The design's linked
[reference parser](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/message_types/url.rs)
provides format leads, not Mac acceptance evidence.

Native source-format checks observed binary plists containing `RichLink`,
`LPLinkMetadata`, `NSURL`, arrays, image/icon metadata and
`RichLinkImageAttachmentSubstitute` objects. Exact joined attachment GUIDs can
resolve indexed artwork; unsupported layouts retain fallback. Synthetic fixtures
independently reproduce wrappers, outer placeholder fields, null artwork and
deliberately misleading attachment order without copying account payloads.

`body_parts.zig` accepts a restricted primitive Foundation typedstream grammar.
`tools/generate-decoder-fixtures.m` generates its synthetic archive using Apple's
encoder, including Unicode text and `__kIMMessagePartAttributeName` /
`__kIMFileTransferGUIDAttributeName` attributes. UTF-16 boundaries are validated and
converted to UTF-8 byte ranges. Image placement comes from joined GUIDs, independently
of SQL order. Unknown/partial layouts use the full-text-then-attachments fallback
with unresolved part mapping. Stable mapped IDs are `source:<index>`; fallback IDs
remain independent of layout.

Reaction candidates map 2000–2005 to heart/like/dislike/laugh/emphasize/question,
2006 to the complete custom emoji sequence, and 3000–3006 to matching removals.
1000, 2007/3007 and unknown values remain unsupported placeholders. Accepted target
forms are an exact UUID, `p:<decimal index>/<UUID>`, or `bp:<UUID>`; malformed or
cross-chat targets never project a chip. Ordinary replies are excluded by type.
Native samples confirm standard/custom codes and `p:`/`bp:` target forms, but
do not establish removal/deletion precedence or every standard value.
These are candidates derived from the
[reference mapping](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/tables/messages/message.rs),
with the controlled native evidence and deferred cases described below.

A controlled heart Tapback in a self-conversation exposed an explicit fallback
case: the native source marks both reaction and target incoming and joins them to
two different chats, with one chat link each and no shared link. The relay retains
the unresolved reaction placeholder rather than projecting across conversations.
This self-conversation case does not establish ordinary add/change/remove
acceptance and does not justify merging routes or inferring account ownership.

Native verification in a regular conversation covered a standard heart followed
by a standard thumbs-up. Both resolved to the selected target and the source marked
the actor as self. Authenticated enrichment reads published one current value,
and each target change emitted a reconciliation upsert. The target timestamp,
delivery status and relay epoch stayed unchanged. Messages retained both source
add operations; the later thumbs-up replaced the earlier heart in the aggregate.
Other standard values, complete custom sequences, matching/mismatched removal, deleted-source
reconciliation, cursor continuity and removal across restart retain their automated
coverage; this run does not claim installed acceptance for those cases. The
verified thumbs-up aggregate also survived the final signed upgrade and relay
restart with the same epoch, target timestamp and delivery status.

The private ledger folds by target/source-part/actor in `(source timestamp, source
row, source GUID)` order. Adds replace that actor's value; removes clear only the
matching value. Complete tracked-source absence leaves a durable ordering barrier,
so earlier adds cannot reappear after restart/backfill. A removed operation keeps
its effect. Retired GUIDs cannot move their tombstone on stale reimport. Pending
target work survives restart, performs bounded same-chat source lookup and retries
on target import. Source observations, raw-row resolution and full target upserts
commit together, including complete empty aggregates. Changes preserve timestamp
and delivery status and use reconciliation origin.

Tracked rows have their own fair bounded reconciliation, independent of the recent
window; requested histories prioritize their chat. Deleting a tracked reaction at
the high-water/cursor can preserve the epoch only with unchanged file identity,
absence of that GUID, and at least two matching ordinary-message anchors. The
affected scan rebases with GUID deduplication and handles row reuse. Source identity
replacement, mismatching ordinary anchors or insufficient continuity still reset.
Sidebar projection skips resolved reaction rows and preserves conversation ordering.

## Verification

Native fixtures ran on macOS 27.0 / build 26A428. Apple Silicon builds use
Zig 0.16.0, the installed Command Line
Tools SDK, and the repository's OpenSSL 3.5 static archives. Commands:

```sh
zig build relay fake-relay test test-macos-enrichment -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/enrichment.py
python3 tests/assets.py
python3 tests/links.py
python3 tests/reactions.py
python3 tests/native_images.py
python3 tests/integration.py
python3 tests/mac_acceptance_test.py
python3 tests/mac_enrichment_packaging.py
python3 tests/enrichment_probe.py
python3 tests/contacts_permission.py
python3 tests/media_boundary.py
zig fmt --check build.zig build.zig.zon src
```

The new tests cover exact/folded email selection, plus tags, shared contact aliases,
duplicate unified IDs, conflicting contacts, Unicode display names, international
numbers, US/GB national numbers, missing region, short codes, extensions, directory
rollback, epoch/generation rejection, private-ID exclusion, and tombstones. The
transport suite covers snapshot/replay overlap, immutable identity IDs after
rename, stale query failure, ambiguity, denial, permission-only regrant without a
generation notification, removal, restart, observed-only
export, a historical sender, migration/backfill, and legacy/negotiated streams.
The pre-existing protocol/send recovery suite still passes with the Contacts worker.
The full native/fake build completed all 21 build steps. The latest unit targets
passed 23 fake-relay tests with the native-only case skipped, and all 24 native
tests. A frozen pre-enrichment v1 message schema verifies every existing closed
enum value and ignores the new fields using the old client's parsing policy;
old messages also decode with absent enrichment under the new schema.
Five acceptance-helper tests pass. A disposable staged app passes strict signature
verification and contains both permission descriptions and both dependency licenses;
this stages under `zig-out/` and does not replace or run the installed app.
The final staged app and helper are also signed with the existing persistent local
identity; strict verification passes and their designated requirements match the
installed app. Installation and the approved Contacts request succeeded, with
the installed results recorded above. The TLS boundary suite passes all 11 tests, and the five
acceptance-tool tests pass.

The asset service tests cover captions/multiple images/overflow, authenticated
bytes and 304, immutable versions, eviction/regeneration, delayed arrival, unsafe
paths/FIFO/symlinks, replaced/symlinked attachment roots, corrupt/oversized sources,
orphan cleanup, restart and source
reset during an in-flight conversion. The old completion cannot publish into the
new epoch. Four
stalled 8 MiB transfers saturate only the asset lane; send/history/SSE remain
responsive and the write deadline releases those slots. The native fixture harness
verifies actual JPEG/PNG/HEIC decoding, EXIF orientation, alpha, animation first
frame, metadata stripping, output variants, corrupt/hostile dimensions, source
mutation and helper timeout. ImageIO HEIC fixture encoding needs macOS codec service
access outside the development sandbox.
The process-boundary harness also checks inherited-descriptor and environment
isolation, failed launch, malformed metadata, helper crash, and a descendant that
retains the metadata pipe after the helper exits. Metadata reads are nonblocking,
and an already-reaped child PID is never killed on a wait error.

Reaction tests cover source-order folding, whole custom emoji, self/multiple actors,
replacement/mismatched and matching removals, old tracked deletion, highest/cursor
deletion with row reuse, target-before-import, Foundation text/image parts, URL
bubbles, malformed/cross-chat/unknown cases, empty clearing aggregates, stable
restart and real file replacement. Existing send/idempotency/recovery tests pass.

`tools/mac_acceptance.py --enrichment --output /private/evidence/enrichment.json`
is a read-only aggregate probe. An optional `--conversation ID` includes message
kind/attachment/preview/reaction counts. It stores no names, handles, IDs, text,
paths, or URLs. It leaves `complete` and installed Contacts attribution false:
read-only API counts cannot establish those gates. It refuses to overwrite prior
evidence or combine this mode with send/restart options.

The installed `doctor --enrichment` mode independently samples at most 100 URL
payloads and 100 reaction rows through the read-only adapter. It reports parser
outcomes, known archive vocabulary, exact local artwork join counts and reaction
type/target-shape counts. It never emits source strings, identifiers or bytes;
`tests/enrichment_probe.py` checks those disclosure and sample bounds.
It also compares source/target chat links, reporting only fixed state labels and
counts, plus the newest sample's direction flags. Fixtures distinguish a shared
selected chat, shared links with different selected chats, disjoint chats and a
malformed target, without exposing GUIDs or participant values.
Its independent diagnostic tree walk has an 8,192-visit budget; shared binary
plist references cannot expand into an unbounded traversal. Truncated diagnostic
counts are marked by `shape_limit_reached`. The shared-reference regression timed
out before this bound and now completes with the expected limit indication.
`tests/contacts_permission.py` runs the permission-only child with an empty
environment and verifies its bounded exit-status contract and absence of output;
it neither requests access nor reads contacts. It also verifies that the private
reader refuses ordinary invocation without its dedicated pipe handles.
The synthetic Contacts transport suite now exercises restricted, unavailable and
denied states against an avatar fetched successfully immediately before each
change. Every state clears live presentation, refuses that cached version, keeps
history and protocol support available, and recovers on a same-generation grant.

Native verification covers heart addition and thumbs-up replacement. Remaining
standard values, custom reactions, removal/deletion and removal across restart
remain unverified natively, despite passing synthetic coverage. Keep private
acceptance records outside the public repository.
