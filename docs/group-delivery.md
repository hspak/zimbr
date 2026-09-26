# Group delivery status

Zimbr supports two solid checkmarks for a group message when the source database
confirms delivery. The reviewed macOS 27 data does not provide that confirmation
for ordinary outgoing group iMessages, including hours-old messages. Keep those
messages at **sent** until receipt evidence exists.
There is no verified additional group-delivery signal to implement at present.

The client distinguishes sent group messages with a solid first check and a
dotted second check, appearing together as soon as the message is sent. Hovering
the checks shows “Sent · group delivery receipts unavailable.” An observed
delivery confirmation makes the second check solid. This is presentation only;
the source status, relay journal and protocol record remain `sent` until then.

## Existing implementation

The database adapter uses the same rules for direct and group messages, in order:

| Source condition | Observed status |
| --- | --- |
| `error != 0` | `failed` |
| Incoming message without an error | `received` |
| Outgoing, `is_delivered != 0` or `date_delivered > 0` | `delivered` |
| Outgoing, `is_sent != 0` | `sent` |
| Otherwise | `unknown` |

See [MessagesDb](../src/relay/adapter/MessagesDb.zig). The Linux
[presentation mapping](../src/client/display.zig) shows one solid check for
`sent`, with a dotted second check in groups, and two solid checks for `delivered`.
It does not suppress delivery confirmations in groups.
The protocol has a message-level status, without per-recipient receipt counts.
Two checks therefore do not establish that every participant received or read
the message.

[Core](../src/relay/Core.zig) refreshes the latest 100 source rows, performs
rolling reconciliation over older rows, and revisits outstanding send requests.
Changed delivery status participates in the
[journal fingerprint](../src/relay/Journal.zig), produces a new message revision,
and reaches the client through SSE. Age alone never promotes a sent message to
delivered, and does not stop reconciliation.

## Available data and APIs

A read-only review on macOS 27.0 (26A428) compared outgoing group-message flags
with the installed relay journal. The reviewed group rows had `is_sent=1` and
`is_finished=1`, but zero delivery flags and timestamps. The relay correctly
stored `sent`. Direct-message records in the same database did contain delivery
confirmations, including flags without timestamps.

| Source | Finding |
| --- | --- |
| `is_delivered`, `date_delivered` | Already consumed; absent in the reviewed outgoing group records |
| `is_finished`, `is_sent`, `error` | Describe send progress/failure; no verified basis for inferring recipient delivery |
| `is_read`, `date_read` | No additional group receipt established; some historical outgoing group rows had `is_read=1` with no read or delivery timestamp |
| Quiet-delivery, notification and preview flags | Unset in the sampled recent group messages; no demonstrated replacement for message delivery confirmation |
| `message_summary_info`, `payload_data` | Recent sampled summaries contained `amc` and `ust`; payloads were absent. No verified receipt metadata |
| `chat.properties` | Sampled keys describe chat configuration and local activity; no per-message recipient acknowledgements identified |
| Source schema | No dedicated per-recipient receipt table identified in the inspected database |
| Installed Messages scripting dictionary | Exposes accounts, chats, participants and file transfers, but no message-delivery query; `send` has no receipt result |

These observations establish the behavior of the inspected source. They do not
prove that all macOS versions or Apple's internal services lack group receipts.
Seeing a message in Messages, or obtaining a successful AppleScript result, does
not supply a recipient acknowledgement to the relay.

Other implementations reinforce the distinction:

- [imsg's status mapping][imsg-status] uses the same error, delivery-field and
  sent-field ordering. It does not promote `is_finished` to delivered.
- [BlueBubbles' changelist][bluebubbles-groups] records removing group status
  indicators because they remained sent. This is historical supporting evidence,
  not a guarantee about later macOS behavior.
- [mautrix-imessage][mautrix-status] explicitly labels one group status path
  `fake group delivered status`. Such a synthesized status would change the
  meaning of Zimbr's second checkmark.
- [imsg's private-framework documentation][imsg-private] describes process
  injection and SIP requirements. It does not establish a reliable additional
  group-delivery source for Zimbr's current database/Automation adapter.

## Verification and future support

Run the existing suites with the pinned toolchain:

```sh
# Add -Dopenssl-prefix=/absolute/openssl-3.5 if system OpenSSL is another minor version.
zig build test fake-relay client-probe
python3 tests/conversations.py
```

The conversation suite exercises hours-old group messages outside the recent-row
window through the production database reader, relay journal, SSE stream and
Linux worker. Either a late delivery flag or a late timestamp updates the cached
message to `delivered`, preserving its ID and advancing its revision. Sent-only,
finished-only, incoming and failed messages retain their distinct statuses.
The client unit suite covers direct and group checkmark presentation, immediate
dotted checks for sent groups, and their transition to confirmed delivery.
This characterizes existing behavior; it does not reproduce a missing receipt
that Apple has not written.

Before expanding the mapping, obtain a message-specific signal with established
semantics: distinguish transport acceptance, delivery to one recipient and
delivery to every participant. Preserve failure precedence and add a fixture
that reproduces the source format. Do not infer delivery from elapsed time,
`is_finished`, an error-free send, or unrelated later activity in the chat.

[imsg-status]: https://github.com/openclaw/imsg/blob/1aca78d212c888ef8b09d2abc2f3ca0b6d1f776c/Sources/IMsgCore/MessageSendStatus.swift
[bluebubbles-groups]: https://github.com/BlueBubblesApp/bluebubbles-app/issues/1764
[mautrix-status]: https://github.com/mautrix/imessage/blob/master/portal.go
[imsg-private]: https://github.com/openclaw/imsg/blob/1aca78d212c888ef8b09d2abc2f3ca0b6d1f776c/docs/advanced-imcore.md
