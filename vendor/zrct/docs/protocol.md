# Driver and protocol contract

The automation build listens only when `ZRCT_SOCKET` is set. The runner creates a
private 0700 runtime directory; the application socket is 0600. Production builds
omit the module. The default driver shares the application's SDL3 library and
window, with optional drawing hooks. Register semantic targets beside ClayUI's
final layout geometry. There is no business-action API.

Version 1 uses one newline-terminated JSON request/response per Unix stream
connection. A request contains `version: 1`, a numeric `id`, `op`, and operation
arguments. A response repeats the version and ID and contains `result` or
`error: {code, message}`. Error responses carry the last completed `frame_id`.
The UI thread polls nonblocking I/O in the actual application loop, including its
idle path. The server handles eight clients, one active action, 64 KiB requests,
1 MiB responses, and ten-second connection deadlines. Python enforces one absolute
deadline across connect/send/receive, including partial responses.

`hello` reports identity, operations, canonical keys/scancodes/evdev codes, backend,
input and drop boundaries, monotonic time, and limits. `renderer` describes the
SDL renderer or OpenGL device. Native SDL `rendering` reports SDL version, video
driver, renderer backend, logical/pixel dimensions, window pixel format, and GL
channel sizes/multisampling when available. Unknown GL properties are null, not
assumed capabilities. The `rendering` operation refreshes this information after
resize or scale changes. Font selection remains a runner/application observation. The default headless
profile requests SDL OpenGL under llvmpipe and forces Wayland; `Suite.sdl_renderer`
can explicitly select another renderer. A display suite leaves renderer selection
to SDL unless configured. The requested profile is recorded alongside actual
application capabilities; selecting a profile is not proof that the app honors it.

`inspect` returns an immutable completed-frame snapshot with ID/time and up to
2,048 targets. Targets own valid UTF-8 strings, logical bounds, effective ancestor
clip, parent, and semantic properties. Identity fields (`id`, `role`, `parent`)
longer than 4096 bytes or invalid UTF-8 registration make the snapshot incomplete;
actions and the Python inspector refuse incomplete registries.

Drivers advertising `query` also accept `query: {id, role, text, within}` and return
the same snapshot envelope with only matching targets, in registration order.
ID and role are exact matches; text is a label substring; within includes
descendants through all parents before applying the other filters. Duplicate
identities remain visible, and the full registry's `truncated` flag is preserved.
Python uses this capability for filtered inspection and falls back to `inspect`
for older drivers. An unfiltered inspection still returns the complete snapshot.
The Python API exposes exact complete-label matching as `text=` and preview
substring matching as `text_contains=`. It uses the wire substring query to obtain
candidates, then validates exact labels or full-label digests in that same snapshot.
Both selectors together are invalid. Singular assertions reject ambiguous matches;
explicit `app.targets(...)` collection assertions can accept multiple matches.

`label`, `status` and `value` are UTF-8 previews of at most 4096 bytes. Their
`strings` metadata reports `bytes`, `truncated` and a full SHA-256 when truncated.
The `content` operation takes `target`, `field`, and `max_bytes` (at most 65536),
returning complete text and the current frame ID or an explicit error. Full text
above the preview size has a 512 KiB per-frame retention budget. Digests remain
available when full content exceeds that budget. Snapshot property assertions
never silently accept truncated prefixes. A content read refers to its returned
frame, which can be newer than the preceding inspection.

`resolve` returns a current completed-frame hit point for a semantic target.
`resolve_scroll` uses the same wheel-specific hit test as `scroll`, allowing
descendant controls inside a scroll container.
Application and desktop input share this resolver: it intersects bounds with the
window/scroll clip and checks later interactive targets in painter order. Missing,
ambiguous, disabled, offscreen and obscured targets produce named errors. Scroll
containers allow descendant controls at the wheel point. The candidate grid can
conservatively reject very small exposed slivers. It never claims unregistered
native windows or system overlays are part of Clay's hit map.

SDL input operations are `click`, `double_click`, `press`, `key_down`, `key_up`,
`key_repeat`, `type_text`, `text_editing`, `drag`, `scroll`, `resize`, `drop`, and
`close`. Mouse operations require semantic targets; `drag` optionally accepts a
`to_target` resolved in the same snapshot. Action frame IDs from the future or
more than 120 completed frames old are stale. Inspect immediately before acting.
Python target actions first wait for unique, enabled, interactable targets within
a readiness deadline. The appropriate resolver is checked for each drag endpoint
and for wheel input. Missing, disabled, offscreen and obscured states can be polled;
ambiguity, incomplete snapshots and unrelated protocol errors fail immediately.
The action is then sent once, with no retry after transmission. `click_now()` and
`action_now(...)` provide immediate execution with the same server validation.
Scrolling into view is always explicit. Readiness polling bounds protocol requests
to its remaining deadline; it does not shorten the subsequent input acknowledgement.
Chords use the shared vocabulary, such as `left_control+s`; duplicate keys fail.
Explicit key holds persist across successful actions until key-up or cleanup.
Repeat requires a held key. Motion includes held-button state and relative deltas;
clicks carry SDL click counts. Fractional wheel input is preserved.

Text requests allow 32768 UTF-8 bytes (also subject to the 64 KiB JSON request
bound), queued in complete UTF-8 chunks of at most 4096 bytes per frame. Text is
never pasted through the clipboard or written into application state. Preedit
accepts up to 4096 bytes with character-based `start`/`length`; empty text cancels.
Committing uses `type_text`. Embedded NUL is rejected. This is SDL text-event
coverage, not a system IME or Wayland text-input implementation. Drag duration is
1–120 frames; resize dimensions are 100–4096.

SDL events remain queued for the application's single event consumer. The driver
never independently drains SDL's queue. Each pending action advances at most once
per completed frame and acknowledges only after the consumer's following draw;
repeated idle polling cannot collapse press/release into one update. Applications
must continue normal SDL polling after drawing and in the idle path. SDL text/drop
buffers remain borrowed across that poll. SDL rejects filtered or unqueueable events
as action errors. Synthetic events do not alter `SDL_GetKeyboardState` or physical
mouse state: use compositor input for those consumers. Disconnect, failure,
timeout and shutdown release injected keys/buttons. Successful explicit holds
remain active; ordinary click/chord actions release their own inputs.

Drops use the registered application delivery handler when present (reported as
`application_drop_handler`), otherwise SDL begin/file/complete events with the
resolved position (`sdl3_drop_events`). Paths must be NUL-free, with at most 16
files and 4095 bytes per path for SDL playback. These cover delivery; actual drag
negotiation and URI validation require compositor input.

The optional raylib/GLFW adapter retains its existing snapshots and callbacks.
Its capability list excludes SDL-only operations and still rejects fractional
wheel input. It is compatibility code, outside the current SDL acceptance scope.

Input is applied before the app's ordinary consumers. Acknowledgements include
`injected_ns`, `consumed_ns`, `frame_id`, and `drawn: true`; completion follows a
relevant draw. Async business effects still require an observable condition or an
independent fixture assertion. `screenshot` flushes pending draw batches and
captures before buffer swap; target captures report the bounds and window from
that same completed frame. `overlay` is diagnostic and should be off in visual
assertions. `record_start`, `record_stop`, and `record_status` implement bounded
per-app-frame capture; `ZRCT_RECORD_DIR` starts capture before the first frame.
PNGs retain the exact top-to-bottom RGBA8 framebuffer bytes and use fast lossless
zlib compression. Compression speed does not change frame coverage or pixel values.

Desktop suites use a separate private Weston 15 seat module. It injects normal
seat pointer/keyboard events, activates real surfaces, and changes the real output
scale. Clipboard clients and an xdg-shell drag-source helper negotiate Wayland
protocols. The Weston module flushes client events before acknowledging input.
The `frame` operation waits for the application to dispatch queued native events
and acknowledges their completed frame, without injecting input or encoding a PNG.
Desktop actions hold buttons/keys through this barrier before releasing them.
Activation also waits through a frame; clicks activate the application first so
clipboard helper or drag-source focus cannot turn the click into activation only.
Semantic observations still locate controls, but these tests' input
boundary is `compositor_input`. The plugin uses version-specific Weston backend
entry points, so other Weston majors are unsupported until explicitly ported.

`Suite.requires` declares operation/capability availability; the reserved
`compositor_input` requirement enables desktop input. `Suite.required_boundaries`
also requires successful input through each named boundary. Missing helpers fail
preflight; application capabilities are checked at launch, including compositor
frame synchronization. The legacy `boundary="compositor_input"` declaration is
an enforced required boundary. Other legacy annotations remain `declared_boundary`.
Reports derive `observed_boundaries` and `boundary` from acknowledged application
input and successful native desktop commands, including mixed input. Inspection,
frame barriers, screenshots and cleanup do not claim input coverage. An unused
required boundary is non-passing, even if the test's other assertions pass.

Each process has its own process group and bounded stdout/stderr (8 MiB each,
then draining/discarding with a truncation marker). Cleanup terminates descendants
also when their original parent has exited. An outer watchdog reclaims only
journaled process identities and marked private runtime directories. Artifact
collection has separate deadlines and cannot replace the original failure.
The parent supervises up to four isolated workers concurrently by default, with
`--jobs 1` selecting serial execution. Each repetition completes before the next
begins. Interrupting the parent reclaims all active workers and their journaled
descendants; a scenario failure does not cancel its peers.

All runs fingerprint the prepared executable with SHA-256 after building, before
workers and each session launch, after scenarios and at run completion. Missing or
changed artifacts fail. Reproduction commands include `--no-build` and
`--executable-sha256` to refuse a different binary, and retain recording/pause
options. This is artifact identity, not proof of source freshness; source and
fixtures still need to stay fixed throughout a repetition batch.

## Benchmark observation

The handshake reports `benchmark_version: 2`, `clock: "CLOCK_MONOTONIC"`, and the
instrumentation module's optimization mode. `measure_start` takes a `measurement`
object containing `name`, an `id`/`role` query with optional exact `text` or explicit
substring `text_contains`, optional exact
`value`/`status`/`selected`/`enabled` requirements, and optional `frames` (default
true). It arms an action observer without forcing a frame. The endpoint must be
currently false; the first ordinary input starts timing, and the first matching
completed frame stops it. Multiple input stages retain the initial timestamp.
Version 2 makes label matching explicit; the Python benchmark API rejects older
observers so an exact selector cannot silently become a substring selector.

Launch observations instead use `ZRCT_BENCHMARK_START` with the same JSON object
and `start: "launch"`. The launcher supplies `ZRCT_BENCHMARK_LAUNCH_NS` immediately
before process creation. Both processes must share Linux CLOCK_MONOTONIC.
`measure_status` reports armed/running/complete/invalid, failure reason, identity,
start/end timestamps, action/frame IDs, and up to 2,048 frame samples after
completion. Running status excludes the frame array. `measure_cancel` releases
the observer. Overflow, incomplete/ambiguous snapshots, and truncated required
properties invalidate measurement; recording and overlays cannot overlap it.
See [benchmarking](benchmarking.md) for runner policy and interpretation limits.

## Fixture channel and observation windows

`FixtureProcess` uses the runner's existing supervised process groups, stdout/stderr
logs and watchdog cleanup. Requests have increasing `id` and an `op`; replies must
match that ID and contain exactly one of `result` or `error`. `{event, data}` messages
may interleave with replies. Stdout lines are bounded to 64 KiB; request writes and
response/event waits use monotonic deadlines, including a full stdin pipe. A final
complete response is consumed before reporting helper exit. Unrequested IDs,
malformed JSON and overflow are failures. Events are retained in a bounded queue;
all traffic goes to a bounded transcript artifact. Application health checks also
check live fixture processes. The context manager preserves the original failure
if cleanup itself fails.

`expect_always` checks a predicate throughout a duration; `expect_unchanged` compares
observations to an owned initial value; `expect_count` waits for a cumulative count
and then verifies that it stays exact throughout a post-arrival window. Sampling
includes the final boundary and process health. Reports distinguish these invariant
windows from eventual expectations and record the first violation. Observers must
bound their own blocking calls. Sampling cannot detect a transient that occurs and
reverts between samples; cumulative event counters can detect such events.
