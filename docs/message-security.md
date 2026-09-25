# Message handling boundaries

The relay treats Messages database content and authenticated API requests as
untrusted input. Client checks provide a second boundary for a faulty or
compromised relay. This follows the [OWASP input validation guidance](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html): enforce validation on the server even when clients also validate.

## Relay

- Send bodies retain the 64 KiB limit and typed validation. Before JSON parsing,
  an allocation-free scan caps nesting at 32 containers and complexity at 8,192
  tokens, including unknown fields. The media type must be `application/json`;
  parameters such as `charset=utf-8` remain supported. Duplicate known fields
  fail typed parsing. Rejected requests do not create send records.
- Incoming text is read with a byte-bounded SQLite BLOB projection. SQLite text
  slicing must not hide a NUL and its suffix. Invalid UTF-8 or embedded NULs in
  plain/attributed text produce a malformed placeholder; more than 64 KiB of
  incoming UTF-8 produces an oversized placeholder. Normal Unicode and
  multiline content remain intact.
  Attributed-body/payload size checks and attachment filenames also use byte
  semantics, preventing embedded NULs from bypassing limits or path validation.
- Primitive plist parsing retains the 1 MiB input, 8,192-object, and 32-level
  limits. It also budgets 8 MiB of cumulative reads/key hashing, so aliased
  object offsets cannot repeatedly validate large strings without limit.
  Stored link archive resolution separately caps expanded scalar/container
  bytes at 4 MiB, including repeated references to shared artwork. Unsupported,
  malformed, and oversized link metadata retain the original caption.
- Stored link payloads are copied out of SQLite before decoding. Binary plist
  strings and artwork borrow their input, so the source buffer must outlive
  SQLite statement finalization and all uses of the decoded result.
- Attachment enumeration stops after detecting more than 1,024 joined rows or
  a GUID over 1,024 bytes. That attachment set is omitted with enrichment state
  `oversized`, preserving the caption. This is a source safety limit, separate
  from normal inline metadata and overflow pagination limits.
- Import scratch allocations are reset after each message, retaining at most
  256 KiB of reusable capacity. A batch of expensive messages cannot retain
  every parser's scratch memory until commit; the arena is freed at batch end.

## Client

- JSON response/event parsing has byte, depth, and complexity bounds before
  constructing JSON trees. Individual received records are limited to 512 KiB;
  history responses retain their 8 MiB limit and pages may contain at most 200
  records. Incoming message text independently enforces the relay's UTF-8,
  NUL, and 64 KiB requirements.
- Enrichment pages are limited to 32 KiB and 200 items. Expansion allows at most
  4,096 items per section and 8 MiB per assembled message. Totals must remain
  consistent with the message revision; duplicate item IDs and pages claiming
  continuation after reaching the total are rejected. Failed pages roll back
  without replacing the previous cache or pagination cursor. Failed message
  events leave the committed sync cursor unchanged.
- Reaction targets and actor groups are built once, avoiding repeated scans
  of all blocks at every part and repeated copying of growing actor lists.
- Stored cards and client activation share the same HTTP(S) URL policy:
  bounded valid UTF-8, no credentials, no encoded hostnames, no raw controls or
  backslashes, and no Unicode directional controls that could obscure the
  destination. Clicking a validated URL opens it directly in the default browser.
  These checks do not establish that a website is trustworthy.

These boundaries cover Zimbr's processing after Messages receives content. They
do not protect Apple's own receive path or eliminate vulnerabilities in native
image/text libraries. The existing bounded image helper, authenticated media
transport, and local-only preview artwork policy remain relevant defenses.

## Verification

```sh
zig build test fake-relay client-probe -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/message_security.py
python3 tests/links.py
python3 tests/assets.py
python3 tests/integration.py
python3 tests/client_enrichment.py
python3 tests/client_pixel_safety.py
```

The fixtures are synthetic. They exercise malformed text, byte boundaries,
attachment floods, aliased plist offsets, shared artwork expansion, deep/wide
JSON, rejected sends, valid Unicode/idempotency, client transaction rollback,
duplicate/invalid metadata pagination, and large reaction groups. Native macOS
Messages and ImageIO acceptance still require validation on a Mac.

The [performance hardening audit](performance-hardening.md) compares both
September 24 performance commits with the security-pass baseline and records
additional boundary, statement-lifetime, and sanitized pixel regressions.
