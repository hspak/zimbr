# Native SDL3 client

The client uses SDL3 for its window, ordered input events, renderer, textures,
render targets, surfaces, and clipboard. Raylib, GLFW, the custom OpenGL renderer,
and Clay are no longer dependencies. Pango/Cairo still provides text shaping and
rasterization; the application owns its pane geometry and editing semantics.

## Ownership and event flow

- `desktop.c` owns the SDL window and platform services. `desktop.zig` drains
  individual SDL events in order, retaining each key's translated keycode,
  modifiers and repeat flag, and each pointer event's coordinates. A single
  logical/physical size snapshot serves each update. Focus loss clears held input.
- `App.processEvents` performs editing and control actions. Drawing records owned,
  clipped hit regions for the displayed controls. It does not consume clicks or
  keystrokes. Asynchronous conversation selection remains unavailable until its
  worker publishes the selected history and draft.
- The main loop owns monotonic frame deadlines, the 120 FPS interaction cadence,
  30 FPS sync animation, and idle waits. Presentation only presents. Worker
  wakeups, notifications, draft persistence and active drop transfers continue
  to run while drawing is idle.
- Korean composition keeps uncommitted text separate from editor history. Pointer
  focus changes confirm it, composition owns its confirmation key, and one
  matching late reset echo is suppressed without swallowing fresh input.

## Rendering and storage

`graphics.zig` owns an `SDL_Renderer`; SDL owns batching and texture lifetime
synchronization. Capture and test readback use `SDL_RenderReadPixels`. Resources
are native SDL textures and surfaces, without duplicate dimensions, IDs, GL
bindings, framebuffers, shaders or staging arrays.

Text tiles upload native premultiplied Cairo ARGB with the actual row pitch and
SDL's premultiplied blend mode. Raster placement remains one physical pixel per
source pixel. Logical clip edges are rounded once at the framebuffer boundary.
Shapes share indexed contour geometry with explicit alpha coverage; corner radii
are logical pixels. Smooth edges do not require a multisampled window. Circular
avatars use shared indexed vertices and preserve center cropping.

Image entries have one tagged lifecycle. An upload failure remains retryable and
does not report a ready texture or consume the resident-byte budget. Existing
image/entry budgets and eviction remain enforced. Media and notification queues
use 32-byte identities, encoding the existing 64-character cache filenames only
at filesystem boundaries. Existing cache names and trust isolation are unchanged.

Raw Wayland URI negotiation retains all-or-none validation, 16 files, 4096 bytes
per path, a 256 KiB payload cap, and a two-second deadline. Reads are nonblocking;
the transfer owns its offer until completion, rejection, timeout or shutdown.
SDL owns the Wayland connection and event dispatch.

## Validation and test API changes

Run the commands in [development setup](docs/development.md#gui-scenarios-with-zrct).
`test-gui-isolated` runs the native suite in a private Wayland desktop with its
Python fixture dependencies. Production builds omit automation instrumentation.

Validated with Zig 0.16.0, SDL 3.4.16, and isolated Weston/Mesa:

- Debug and ReleaseSafe builds; 230 unit tests pass with one platform skip,
  including 151 headless client tests in both build modes.
- All 130 native GUI tests, including queued key/text/pointer ordering, semantic
  shortcuts, repeated keys, read-only transitions, upload failure/retry, Cairo
  pitch/blending, text alignment, fractional clipping, and attachment delivery.
- All 13 application scenarios, four real IBus/Hangul scenarios, and six native
  compositor diagnostics pass. The latter include a source held mid-transfer,
  timeout without partial acceptance, and shutdown while the source is stalled.
- The same partial-drop responsiveness scenario fails with the old blocking
  Wayland reader and passes with the nonblocking implementation.
- ASan/UBSan pixel checks match the pre-refactor renderer baseline after converting
  native Cairo tiles to comparable straight RGBA outside production code. That
  baseline replaces the older security snapshot, whose text rendering predates
  intervening text-engine changes; JPEG rejection and pixel assertions remain.
- Three alternating raster benchmark pairs retain identical output. Transparent
  rasterization drops from 86.9 to 34.7 microseconds (60%); long HiDPI tiles improve
  5%. Unicode tiles are unchanged; tiny labels are 2.5% slower (0.07 microseconds).
  These measure CPU rasterization, not end-to-end application frame rate.
- The release executable links SDL3 directly, without direct GL, GLFW, raylib or
  rlgl rendering symbols.

The old four-sample-window assertion is now a native SDL pixel readback assertion;
shape coverage is checked by the retained edge tests. Native fixture tests publish
changed capabilities before clicking their retained controls. Scenario selection
waits for explicit readiness before typing, preserving delivery and draft checks.
The private font profile now scales bitmap emoji strikes, fixing oversized emoji
without changing text-alignment expectations. A sufficiently large compositor
output keeps pointer targets reachable throughout the 1×/2× scale scenario.

Companion changes to the declared Zrct dependency are applied locally and preserved
in [the dependency patch](tests/zrct/sdl-native.patch), including SDL_Renderer
capture, event modifiers, the font profile and desktop/drop fixture options.

## Platform coverage

SDL 3.4.16 does not refresh an already mapped window when an older compositor
changes only `wl_output.scale`; re-entering the output updates it. The client uses
unmodified system SDL. Zrct's Weston profile supplies `wp_fractional_scale_v1` and
passes live 1× → 2× → 1× changes. Fractional renderer tests cover 1.25× and 1.5×
transforms, but do not establish fractional compositor negotiation, monitor
hotplug, or mixed-DPI behavior.

Real Korean input is covered through IBus/Hangul. Chinese/Japanese conversion,
surrounding-text reconversion, other engines, and accessibility remain outside
this acceptance coverage.
