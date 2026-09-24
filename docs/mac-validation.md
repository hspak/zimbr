# macOS validation guide

Validate the relay under its installed app identity. A development executable or
terminal permission grant does not establish LaunchAgent access.

The source schema is documented in [macos-27-schema.json](macos-27-schema.json).
Keep account data and deployment records outside public documentation.

## Automated checks

Build the native relay, fake relay, and unit tests, then run the integration and
acceptance-helper suites. Use synthetic databases for fault injection, source
replacement, Unicode decoding, routing, cursor replay, and send recovery.
Never mutate the real Messages database to exercise a failure.

Check the app signature and LaunchAgent property list. Cross compilation is
supplementary; it does not establish native permissions or recipient delivery.

## Installed acceptance

1. Verify Full Disk Access and Messages Automation under the installed identity.
   Check history, participants, plain text, attributed text, and degraded status.
2. With an explicitly authorized recipient, check direct sends and replies,
   recipient-side delivery, Unicode, and durable request IDs. Confirm existing
   group routing separately from a direct conversation.
3. Check live receipt from another device, restart recovery, missed-event replay,
   and preservation of epoch, message IDs, and send associations across upgrades.
4. Check operation while the active login session stays locked for the entire
   observation interval. A locked session differs from a logged-out session.
5. Revoke and restore permissions, then check actionable status and recovery.
   Recheck permissions when changing the app's code-signing identity.

Preserve acceptance evidence privately, including request IDs needed to resolve
possibly completed sends. Do not repeat an uncertain send with a new request ID.
Record observed results separately from unverified cases; synthetic tests alone
do not establish installed-app acceptance.

## Real-account validation

Run the helper from the repository root.

After permissions are granted, use only a deliberately selected recipient:

```sh
python3 tools/mac_acceptance.py --recipient 'YOUR_TEST_ADDRESS' --confirm-send --restart
```

This sends two clearly labeled Unicode/multiline messages, reuses their request
IDs to check idempotency, observes the resulting history and SSE records, replies
to the identified existing conversation, and optionally verifies IDs and event
replay after restarting the LaunchAgent. Use `--conversation OPAQUE_ID` instead
of `--recipient` to test one explicitly selected existing conversation or group.
Add `--wait-for-lock 300` with `--conversation` to wait up to five minutes for the
user to lock the screen before sending that one message.

The helper saves test IDs/statuses under ignored `.local/` before submitting each
message, preserving them on failure. It refuses to overwrite an existing evidence
file; inspect that run's request IDs before authorizing another run with a new
`--output` path. Recipient-side delivery and receipt initiated from another Apple
device require separate confirmation. Locked operation is recorded only when the
helper observes the current user's locked console session throughout its send check.

## Regression coverage

Reconciliation must classify rows beyond live progress as live even if another
scan discovers them first. Include a burst larger than one ingestion batch and
rows whose bodies or joins arrive later. Check the UTF-8 byte limit after UTF-16
conversion, since conversion can expand the encoded text.

The source is read-only, including normal live WAL handling. Unknown attributed
body layouts remain unsupported placeholders; decoding must not instantiate
arbitrary archived classes or extract arbitrary printable bytes.
