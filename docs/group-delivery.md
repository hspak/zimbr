# Group delivery status

Zimbr supports two solid checkmarks for a group message when the source database
confirms delivery. Messages without delivery confirmation remain **sent**.

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
