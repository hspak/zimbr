# Mac enrichment implementation and acceptance

Implementation is in progress against [message-enrichment.md](message-enrichment.md).
This record keeps the entire relay/shared-protocol scope visible. Linux client
storage, networking, rendering, notification changes, and Linux UI acceptance are
excluded from this task. Native compilation and synthetic tests do not establish
installed-app permission attribution or the semantics of a real Messages payload.

## Current evidence (2026-09-23)

| Work item | Implemented | Remaining evidence/work |
| --- | --- | --- |
| 1. Fixtures and contract | Additive types; independent optional-column probes; pinned phone parser; generated Contacts, image, plist and Foundation fixtures; aggregate probes; installed Contacts attribution and observed URL archive layouts | Observed Mac reaction operation precedence and deletion semantics |
| 2. Identity directory | Observed addresses only; native Contacts bridge; background matching; durable jobs; rename/removal/denial/stale handling; keyset/negotiated streams; migration/backfill; installed grant, relaunch, signed upgrade and locked-session reads | Runtime contact edits/removal and independent Contacts/FDA permission changes |
| 3. Image pipeline | Protected source opens; bounded ImageIO helper; immutable versions/ETags; mTLS delivery; arrival/change retries; eviction/regeneration; GC; bounded overflow; slow-reader capacity; epoch invalidation; installed JPEG/PNG/HEIC and locked-session delivery | Verified for the documented formats and bounds |
| 4. Contact avatars | Lazy thumbnail jobs; shared per-contact assets; photo-only invalidation; requested-photo refresh; denial/removal clearing; actual installed thumbnail conversion/delivery | Native photo change/removal and permission revocation acceptance |
| 5. Stored link cards | Bounded binary/XML/keyed reader; standard/partial cards; delayed payloads; embedded/local artwork; observed RichLink wrappers; exact joined attachment GUID mapping; installed metadata and image delivery | Unknown archive classes or attachment naming layouts retain fallback |
| 6. Reactions | Standard/custom/removal mappings; Foundation range/transfer-GUID parts; durable source ledger and target work; deletion tombstones; ordinary continuity anchors; target upserts and sidebar selection | Confirm source operation precedence and custom/removal behavior on the recorded Mac |
| 7. Integration/rollout | Journal/mTLS fixture suites; migration/backfill; legacy/negotiated events; signed helper; aggregate tooling; native images/attachments/stored-card capabilities enabled independently | Remaining Contacts/avatar/reaction acceptance before enabling those capabilities |

Native `image_assets_v1`, `image_attachments_v1`, `stored_link_previews_v1` and
legacy `attachments` are enabled following installed verification. The other
three native capabilities remain disabled for their outstanding acceptance cases;
they do not hold back the verified features. The fake relay advertises all six.
Permission or missing source columns affect readiness, not protocol-support
flags. `event_extensions: ["identity-v1"]` advertises negotiation on both binaries,
including read-only native acceptance while Contacts rollout remains pending.

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
uses those layouts. Native rollout stays gated accordingly.

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
with native source acceptance still pending.

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
The native build completed all 21 build steps: 20 fake-relay unit tests
passed with the native-only case skipped, and all 21 native unit tests passed.
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

Remaining installed acceptance covers live contact rename/photo/removal,
independent Contacts/FDA permission changes, and controlled reaction
add/change/remove/deleted-source behavior. These require deliberate Mac UI or
account mutations, which have not been performed. Use generated/synthetic contacts
and a deliberately selected test conversation. Names, avatars and reactions remain
gated until those cases are established. Keep private evidence outside the public repository and publish only sanitized
functional results.
