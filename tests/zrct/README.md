# Zimbr GUI scenarios

These scenarios run the production SDL3 client with opt-in Zrct instrumentation.
The build selects Zrct's native SDL3 backend and supplies its SDL window and renderer flush/overlay
hooks. Mouse, key, wheel, and text playback use SDL events; reviewed attachment
playback calls the application's ordinary native drop-delivery handler. Separate
compositor scenarios cover actual Wayland file-drop negotiation.
Explicit scenario boundaries are retained across application launches and restarts.
Suites select SDL's direct Vulkan renderer by default, matching the release
client's preferred backend and using the same patched SDL library. Vulkan must
initialize; tests do not silently fall back to OpenGL. `SDL_RENDER_DRIVER`
overrides the selection for diagnostics. Reports record that selection and
instrumented applications report the actual backend in their handshake.
Headless runs select Mesa Lavapipe with `VK_LOADER_DRIVERS_SELECT=*lvp*` and record
that filter and the pinned package identity in the rendering profile. Zig's GUI
test steps download, verify, cache, and install Lavapipe from
[`build/native-tools.json`](../../build/native-tools.json), using Zrct's managed
Python provisioner. The build supplies the driver location to the suite; no
manual download, system Lavapipe installation, or `VK_DRIVER_FILES` override is
needed. Reproduction commands retain the managed driver location.
Weston still uses software OpenGL for compositing. `ZRCT_DISPLAY_SMOKE=1` leaves
Vulkan driver selection alone for hardware runs in a visible nested compositor.
The pinned native tools require Linux x86-64 and compatible Arch Linux shared
library ABIs, including the host Vulkan loader and Mesa/LLVM dependencies.

The desktop scenarios use SDL 3.4.16 and Zrct's Weston surface-scale extension,
including the live output-scale scenario. The extension reports the
headless output's actual integer scale through `wp_fractional_scale_v1`.
Optional diagnostics in `desktop_native.py` run with
`zig build test-sdl-desktop -Ddesktop-tests=true` without application
instrumentation, including a framebuffer check across live 1× → 2× → 1× changes.
The native regressions also run under `zig build test-gui-isolated -Ddesktop-tests=true`, with no
application instrumentation. Desktop diagnostics include partial transfers,
stalled-drop timeouts, and shutdown during a transfer. See
[display compatibility](../../docs/linux-client.md#display-compatibility) for the legacy-compositor
limitation and fractional/multi-output coverage limits.

`ime.py` is an optional real Korean input-method suite, run with
`zig build test-ime -Dautomation=true -Dibus=true -Dopenssl-prefix=/path/to/openssl-3.5`.
It requires IBus, ibus-hangul, their configuration helper/schemas, and a Hangul
font. `ZIMBR_IBUS_PREFIX` can select an extracted installation. Each test owns a
private IBus daemon and engine in addition to the isolated desktop and relay.
Keystrokes pass through Wayland and SDL's IBus backend, covering syllable
composition/deletion, Enter confirmation, Send-button confirmation, draft
persistence, paste during composition, and focus changes without committing text
into the wrong field.
The input method itself supplies preedit; these tests do not inject composed
SDL text events. The suite adds the selected Korean font to its recorded profile.

Run from the repository root with the pinned Zig toolchain:

```sh
zig build test-zrct-all -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5
zig build test-zrct -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5
zig build test-zrct-recovery -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5
zig build test-zrct-content -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5
zig build test-zrct -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5 -- --filter Desktop
zig build test-zrct -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5 -- --repeat 3
zig build test-zrct -Dautomation=true -Dopenssl-prefix=/path/to/openssl-3.5 -- --filter History --record
```

See [development setup](../../docs/development.md#gui-scenarios-with-zrct) for host
prerequisites and artifact locations. Resolve and read Zrct's `SKILL.md` using the
dependency in `build.zig.zon` before authoring or investigating a scenario.

`scenarios.py` owns the general application/desktop suite. `recovery.py` and
`content_scenarios.py` are independent suites for transport recovery and rich
content. `all_scenarios.py` combines them under one worker limit and report.
`benchmarks.py` owns serial ReleaseSafe GUI latency measurements; see
[benchmark commands and timing boundaries](../../docs/development.md#gui-workflow-benchmarks).
`support.py` launches `relay_worker.py` through Zrct's `FixtureProcess`, which
correlates replies, retains events and transcripts, and reports fixture failures.
The worker reuses Zimbr's synthetic TLS/attachment fixtures. Its child relay
belongs to the same process group, so Zrct can reclaim
it even if a scenario times out. The worker never opens a real Messages database.
All clients run the production application loop with opt-in instrumentation.

The scenarios wait for a conversation to become unobscured before editing it:
selection acknowledgment can precede the worker publishing its history and draft.
Native tests that replace fixture capabilities publish a new frame before
clicking the retained controls. Their behavioral assertions are unchanged.
Conversation selectors use the fixture's full `alice@example.invalid` label
because Zrct's `text=` queries require an exact match.
Attachment scenarios retain the restart boundary assertion using Zrct's current
`application_drop_handler+sdl3_events` names.

## Test review and migration choices

The repository already has substantial store, worker, protocol, transport,
security, rendering, packaging, and macOS coverage. The largest GUI testing cost
was in manually constructing `App`/`Worker.View`, invoking methods, injecting
low-level events, and assigning scroll positions in `src/client_main.zig`.
These are useful implementation checks but cannot prove a whole user workflow.

| Existing coverage | Zrct coverage added or retained | Coverage still needed at the original level |
| --- | --- | --- |
| Editor grapheme deletion and undo in `src/client_tests.zig` | Unicode keyboard editing, undo/redo, multiline insertion, and Ctrl+Enter delivery | Invalid input, allocation failure, shaping and raster boundaries |
| Hidden conversations and drafts in Store and `client_main.zig` | Two independent drafts, switching, search exclusion, hide, live incoming message, restart, restore | Atomic merges and immutable snapshots |
| Settings methods and coordinate-driven pane tests | First-launch navigation gate, invalid URL and credentials, clipped form scrolling, save, restart, Enter preference, cancellation of settings/reset | Failed database commits, reset acknowledgment ordering, credential file policy |
| Native drop-delivery and attachment pipeline tests | Reviewed bytes retained after source removal/replacement, removal of the middle file, restart, actual Wayland attachment-only drop | Upload interruption, quotas, partial dispatch, uncertain outcomes and retry idempotency |
| Worker offline persistence and reconnect tests | Cached conversation and editable draft after offline restart; no send until explicit action after reconnect | Transport fault matrix and cursor rollback |
| `client_relay_reset.py` and reset methods | GUI-confirmed reset failure, lost response, retry with the original epoch, and local draft/media removal only after success | Authentication, transaction rollback, old-ID conversion, and Contacts freshness |
| `client_attachments.py` and send recovery | Held upload with concurrent draft/incoming message, GUI cancellation and restart, accepted/unaccepted lost responses without duplicate submission | Byte corruption, storage permissions, quotas, partial dispatch, and protocol fault combinations |
| Superseded worker-view regression in `client_main.zig` | Hold the selected conversation's real history response, switch back, preserve the draft, and verify the final send's route | Exact publication ordering and allocation failures |
| Native rich-content controls | Viewer navigation, failed viewer request and Retry, live reaction-detail updates, hidden composer unchanged | Exact image pixels, decode limits, texture allocation failure, and malformed metadata |
| Native long-editor workspace tests | Large multiline Unicode Wayland clipboard round trip, full-content digest/readback, resize, and restart | Grapheme boundary matrix, shaping/raster details, and editor allocation failures |
| Native Details clipboard and hidden-editor checks | External Wayland clipboard reader, log copy/clear, hidden composer remains unchanged | Log ring capacity, scrollback anchoring and concurrent writers |
| Native layout and text scale checks | Clipboard draft survives resize and live scale changes, then sends to the correct chat | Fractional pixel alignment, texture eviction and exact raster checks |
| Wayland application ID and desktop icon | `Application.test_wayland_identity_matches_installed_desktop_entry` checks the actual Wayland ID and desktop icon | Duplicate standalone script removed; run `zig build test-zrct -Dautomation=true -- --filter Application` |
| Three scenarios formerly loaded from Zrct's example suite | Owned Unicode send/restart, reviewed attachments, and recorded history/incoming anchor checks; added navigation to the new message | Existing regression assertions are retained |

Native tests were not removed: these scenarios cover more of the application, but
do not replace their error injection and rendering contracts. macOS adapter,
permission, signing, notification-daemon, and package tests remain separate.
The synthetic relay checks dispatch and observed delivery in its fixture, not
delivery through Apple's service.

## Assertion boundaries

`Emoji` covers shortcode expansion, completion paging and keyboard/mouse
selection, cancellation, undo/redo, draft persistence, and Unicode relay delivery.
Its clipboard scenario also uses real Wayland paste/copy and pointer selection
at the minimum window size and 2× scale. The other emoji scenarios use SDL input.

- `Messages`, `Settings`, and `History` use normal application input. The two
  reviewed-attachment scenarios additionally invoke the native drop-delivery handler.
- `Desktop` uses real compositor activation, clipboard ownership, keyboard/mouse
  events, and Wayland drag-and-drop negotiation. Clicks synchronize application
  activation first, including after clipboard helper or drag-source focus. Window resize still uses the
  driver's application resize operation; output scale changes use Weston.
- `Recovery` and `Content` use application input with operation-specific relay
  faults. Fixture events establish when a request is held, and cumulative counters
  detect submissions even if replies are lost. Rich controls use message/attachment
  identity; viewer readiness observes an uploaded texture in the completed frame.
- Draft/settings persistence checks read the committed client database without
  modifying it. Sends are checked against both the relay journal and synthetic
  Messages rows, including destination, count, ordered attachment names and bytes.
- Negative-send checks observe half a second; completed sends remain under
  observation for at least three quarters of a second to catch late duplicates.
  These bounded windows do not prove absence forever. No sleep establishes UI
  readiness: target properties and committed effects supply those barriers.
- History retains the original lossless recording/visual anchor assertion through
  older-history loading and incoming messages, then checks that the new-message
  button reveals the incoming message.

Each scenario owns a fresh desktop, database, credentials and processes. Restarts
within it preserve the client directory. Role/text selectors distinguish fixture
conversations; controls use stable IDs and repeated message actions use message
identity. Attachment mutations happen only after preparation enables Send.

## Companion Zrct changes

The declared local dependency includes SDL_Renderer capture through the supplied
window, event-time modifier injection, bitmap-font scaling in the private font
profile, configurable desktop dimensions, and a controllable partial-drop source.
These changes are already included in the declared dependency; no patch
application is needed.

The dependency also preserves failed subtests, records window geometry per captured
frame, reclaims descendants after a group leader exits, and publishes cached desktop
helpers atomically. Runs support listing, exact selection, failed-case reruns, and
JUnit reports. Benchmark compatibility identifies tool content independently of
cache paths. Neither correctness scenarios nor benchmarks silently retry failures.

The scale scenario uses a 2560×1600 test output so the application remains
reachable by the compositor pointer at 2×. On a smaller output, Weston clamps
pointer movement to the screen edge, which can select history instead of the
composer. Pixel assertions and scale transitions retain their existing coverage.
