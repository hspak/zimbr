# macOS message enrichment

The native and fake relays advertise `identity_directory_v1`, `contact_avatars_v1`,
`image_assets_v1`, `image_attachments_v1`, `stored_link_previews_v1`, and
`reactions_v1`. Permission and source availability affect readiness separately.
Linux behavior is documented in [client enrichment](linux-message-enrichment.md).

Validate the installed build using the verification procedures below. Native
compilation and synthetic fixtures do not establish installed permissions or every
source layout. Keep account-specific acceptance records outside the repository.

## Directory and transport contract

`Identity.id` is an opaque UUID encoded as 22 unpadded Base64url characters,
unique by service plus the exact observed address within one relay epoch.
Revisions are decimal strings from the global journal
sequence. `display_name` and `avatar` are nullable. Match states are `pending`,
`matched`, `unmatched`, `ambiguous`, and `unavailable`; freshness is `fresh` or
`stale`. Unmatched/ambiguous/unavailable upserts clear presentation values. Source
contact IDs are confined to `contact_mappings`, never identities or events.

`GET /v1/identities?before=ID&limit=N` returns `identities` and `next`, with
descending immutable-ID keysets, at most 200 records, and a 32 KiB record budget.
Capture `/v1/sync` before the bootstrap pages, then replay after that cursor.
`GET /v1/events?...&extensions=identity-v1` includes identity events and returns
`Zimbr-Event-Extensions: identity-v1`. Unknown/duplicate requested extensions fail
with HTTP 400. Streams without the extension return an empty extension header and
omit identity events; skipped identity sequences still advance the internal scan.
Names update through identity events without rewriting messages or changing chat
participants, titles, routing, or message timestamps.

The journal stores directory/private mappings/work, canonical enrichment items,
asset sources/owners/representations/work/private blobs, reaction observations/work,
and independent ordinary-message anchors. A resumable `identity_backfill_v1`
keyset pass observes historical incoming senders, and
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
on a worker, allowing Contacts notifications to arrive during normal operation.
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

The Contacts framework caches process-level permission and query results. A
permission monitor therefore invokes the same signed executable in a private
status-only mode once per second. Probes have a two-second deadline; failed or
older-than-five-second observations make contact presentation unavailable.
Enumeration and thumbnail reads run in fresh signed child processes with private
pipes, empty environments and no inherited relay descriptors. Reads have a
15-second deadline and 512 MiB resident-memory bound; responses are capped at
32 MiB for the index and 8 MiB for a thumbnail. Parent-side permission/generation
checks reject obsolete results. Ordinary invocation without the dedicated pipe
handles is refused. Permission restoration reconciles before reporting readiness.

## Phone normalization dependency

The native relay statically compiles the core Objective-C sources of
[libPhoneNumber-iOS 1.7.8](https://github.com/iziz/libPhoneNumber-iOS/releases/tag/1.7.8),
a libphonenumber port supporting macOS. `build.zig.zon` pins
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
uses those layouts.

## Image and overflow contract

`GET /v1/assets/:id/:version/:variant` uses the existing mTLS/device authorization.
Asset IDs and versions are relay-generated UUIDs encoded as 22 unpadded
Base64url characters. Attachment metadata IDs encode the full SHA-256 of
Apple's source GUID as 43 unpadded Base64url characters. These public IDs are
case-sensitive; Apple's source GUID spelling remains unchanged.
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

## Supported source formats

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
independently with Python `plistlib`. The linked
[reference parser](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/message_types/url.rs)
provides format leads, not Mac acceptance evidence.

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
The [reference mapping](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/tables/messages/message.rs)
provides format leads; verify reaction codes and removal/deletion semantics
against the installed source.

A self-conversation can place the reaction and target in different source chats
without a shared link. Such a reaction remains an unresolved placeholder; the
adapter does not infer account ownership or merge routes from this observation.

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

Build with Zig 0.16.0, Apple's Command Line Tools, OpenSSL 3.5 static archives,
and the Python dependencies from [setup](setup.md):

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

The suites cover synthetic phone/email normalization, ambiguity, permission
changes, identity replay/bootstrap, overflow, source replacement, reaction
ordering/tombstones, asset ownership, helper isolation, and failed publication.
Native image fixtures exercise ImageIO conversion, orientation, metadata
stripping, animation still frames, corrupt inputs and bounds. HEIC fixture
encoding requires the Mac codec service. Packaging checks stage disposable apps;
they do not grant permissions to or replace the installed app.

For an installed read-only aggregate check:

```sh
python3 tools/mac_acceptance.py --profile dev --enrichment --output /private/evidence/enrichment.json
```

Create the private output directory first. The helper refuses to overwrite an
existing report or combine enrichment mode with send/restart options. It omits
names, handles, message content, paths and URLs; aggregate API counts cannot
establish all native acceptance gates. `doctor --enrichment` separately samples
at most 100 stored URL payloads and 100 reaction rows, with bounded diagnostics.

On the installed app, verify Contacts grant/denial/regrant, live name/photo
changes and removal, images while the screen is locked, stored artwork without
remote fetches, and each reaction operation you rely on. Full Disk Access and
Contacts grants are independent. Preserve epoch, IDs and clearing behavior
through upgrades; distinguish synthetic coverage from native observations.
