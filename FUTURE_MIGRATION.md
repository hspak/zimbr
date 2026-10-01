# SDL3 and OpenGL migration

Raylib has been removed. The client now owns its SDL3 window/context and event
consumer, with a small OpenGL 3.3 renderer. Clay, Pango/Cairo, the editor,
application model, media workers, and raw Wayland desktop services remain.

## Current boundaries

- `src/client/desktop.c` creates the system SDL3 window with four-sample rendering,
  polls each SDL event once, and maintains pressed/released/repeat edges per batch.
  Fast press/release pairs remain observable, fractional wheel movement accumulates,
  and focus loss releases held input. `desktop.zig` exposes logical and framebuffer
  dimensions, timing, cursors, clipboard, text commits, activation, and bounded waits.
- `src/client/geometry.zig` defines application-owned points, rectangles, and RGBA
  colors. `graphics.zig` owns shaders, a fixed 12,288-vertex staging buffer, textures,
  clipping, framebuffer capture, PNG output, and offscreen rendering tests.
  Batches flush on texture/clip/target changes and before deletion or capture.
- `Text.zig` still rasterizes with Pango/Cairo at physical resolution, snaps text to
  physical pixels, and uploads nearest-filtered tiles. `ImageCache.zig` retains its
  texture and metadata budgets, linear image filtering, and center-cropped circular
  avatars. Its transparent fringe and four-sample framebuffer preserve smooth edges.
- SDL owns the Wayland connection and dispatch. `desktop/wayland.c` retains raw
  URI negotiation, complete clipboard exchange, and activation tokens. Drop offers
  retain all-or-none rejection, 16 files, 4096 bytes per path, a 256 KiB payload
  budget, and a two-second read deadline.
- Native GUI tests now push SDL input events through the production poller and
  read application renderer captures. Assertions and existing image baselines were
  retained. The obsolete image-format assertion disappeared because captures are
  typed RGBA buffers; the same pixel assertions still inspect their contents.
- Zrct's declared dependency now supports native SDL3 without a raylib module.
  The application supplies flush and overlay hooks. Mouse/key/wheel/text playback
  enters SDL's queue; acknowledgments wait for the consumer frame. Existing
  raylib-based consumers of Zrct retain their original adapter.

`build/raylib_sdl.zig`, the raylib package, and every raylib/rlgl source import are
gone. Production builds omit Zrct instrumentation and link system SDL3 and OpenGL.

## Removal validation (2026-10-01)

- Debug and ReleaseSafe client builds pass. Symbol checks find no raylib, rlgl,
  or GLFW symbols; the executable links system SDL3 and OpenGL.
- The full non-GUI test command passes 225 tests, with one platform skip; all 146
  headless client tests pass.
- All 13 existing application-owned Zrct scenarios pass, including Unicode
  editing/undo, persisted drafts, reviewed original attachment bytes, clipboard,
  history anchors, and live output-scale changes. Run: `20261001-132014-a77eca`.
- All three uninstrumented compositor diagnostics pass: raw URI delivery and
  whole-offer rejection, long clipboard exchange, native keys, resizing, four
  samples, and 1× → 2× → 1× framebuffer changes. Run: `20261001-130706-98de47`.
- The expanded native GUI suite passes 116 of 118 tests. New contracts cover
  short clicks, held/repeated keys, focus release, fractional wheel batches,
  staging-buffer overflow, queued texture deletion/uploads, circular cropping,
  and clipping at 1×, 1.25×, and 2×. Final native acceptance run: `20261001-132055-901869`.
- The two remaining failures are the unchanged date-alignment and rounded-edge
  assertions documented below. Both reproduce in the saved raylib executable
  with the same compositor, Mesa, fonts, and fixture environment; that baseline
  passes 113 of 115 tests (`20261001-131017-3dceea`). No expectation was weakened.
- Before/after full-window settings PNGs have zero differing pixels at scale 1
  (`20261001-130940-d06a2b`) and scale 2 (`20261001-131025-508427`). All 20 native
  message-header framebuffer captures are byte-identical across 1×, 1.25×, 1.5×,
  and 2×. These fractional checks exercise renderer transforms, not fractional
  compositor negotiation or mixed-DPI monitor moves.

The exact `test-gui-attachments` command and standalone
`tests/client_desktop.py` check pass in the final native acceptance run. Zrct's
five Zig and 20 Python tests pass, including disabled native SDL instrumentation
and existing raylib/GLFW consumers. `zig fmt --check build.zig build src` and
`git diff --check` pass. Raw before/after frame pairs and hashes are retained in
`artifacts/renderer-removal-comparison/`.

## Remaining platform work

Use the system SDL3 library. SDL 3.4.16 does not refresh an already mapped window's
scale when an older compositor changes only `wl_output.scale`; it updates when
the window re-enters the output. This was reproduced on unextended Weston 15,
which advertises `wl_compositor` version 5 and no fractional-scale protocol.
SDL's output-scale listener updates the display, but the legacy window-scale
recalculation runs on surface enter/leave. The project still uses unmodified
system SDL; it does not compensate with artificial viewport math.

Zrct's single-output headless Weston profile now supplies `wp_fractional_scale_v1`
and sends the output's actual integer scale through that standard protocol.
Weston's existing viewport support handles the resulting buffers. The unchanged
live scale/draft scenario now passes with SDL 3.4.16. The uninstrumented desktop
probe independently verifies that a 780×560 window changes its framebuffer from
780×560 to 1560×1120 and back, without restarting. Both regressions failed without
the extension and passed with it. This exercises SDL's modern surface-scale path;
it does not fix SDL on unextended legacy compositors.

The extension covers one headless output and integer 1×/2× settings. It does not
establish fractional scaling, monitor hotplug, or mixed-DPI coverage. A Sway/wlroots
profile is a reasonable next test environment for those cases; KWin and Mutter
would add desktop-specific acceptance. Those alternatives have not been validated
by this change.

Korean IME support now includes inline preedit, focused-editor lifecycle,
candidate-window positioning, selection replacement, and composition-aware editing
keys. Two-set Korean is exercised through real IBus/Hangul keystrokes by
`test-ime -Dautomation=true`, including confirmation, sending, and focus changes.
Unconfirmed preedit stays separate from committed text and undo history. Pointer
actions confirm it before moving focus, and a matching late IBus reset commit is
discarded before new typing begins. Chinese/Japanese conversion, surrounding-text
reconversion, and other input-method engines remain outside this acceptance
coverage. Accessibility also remains application work.

`test-zrct -Dautomation=true` uses the native SDL3 backend.
Text playback queues SDL input events, rendering metadata uses
SDL's GL loader, and attachment playback calls `zc_drop_paths`, the ordinary
native delivery boundary. Frame acknowledgements wait for the application's
existing event poll and consumer frame. The GLFW backend remains available for
other consumers; the SDL3 application does not link GLFW compatibility symbols.
All 13 application-owned scenarios pass on the extended Weston profile; the
original live-scale assertion was not weakened or skipped.

`tests/zrct/desktop_native.py` and `tests/client_desktop_probe.c` retain optional
compositor diagnostics for raw URI drops, long clipboard exchange, native keys,
resizing, live output scale/framebuffer changes, and multisampling. They use the
production SDL services without application instrumentation. Enable them with
`zig build test-sdl-desktop -Ddesktop-tests=true`; they are not a prerequisite for
normal builds or native tests.

For future renderer changes, run `zig build test-client`, the native `test-gui` and
`test-gui-attachments` suites, and `tests/client_desktop.py`. Validate real clipboard
exchange, raw file drops (including malformed, oversized and stalled offers),
notification activation tokens, idle/minimized wakeups, output scale changes,
Unicode commits, per-conversation drafts, attachment bytes at the relay, text
alignment, clipped/circular images, and bounded texture lifetimes. Compare scale
1, scale 2, and fractional-scale captures on the same rendering profile.

The initial native GUI comparison produced the same two failures with both the
preserved GLFW executable and SDL3 on the same Weston/Mesa/font profile: message
date alignment at fractional row positions and rounded-outline antialiasing.
Their assertions and image expectations are unchanged. These are existing
rendering issues to investigate separately, not evidence that either suite is
fully passing.

## SDL migration validation (2026-10-01)

Tested with Zig 0.16.0, system SDL 3.4.16, and isolated Weston 15/Mesa software
rendering:

- Debug and ReleaseSafe client builds passed. The executable links SDL3 and has
  no GLFW symbols. The Wayland application ID remains `zimbr`.
- `zig build test` passed 225 tests with one platform skip, including all 146
  headless client tests. Relay fixture builds used an OpenSSL 3.5 prefix.
- The full native GUI executable passed 113 of 115 tests. The two failures above
  reproduce with the preserved GLFW build. Existing expectations were retained.
  The native file-drop/attachment integration delivered reviewed original bytes
  to the synthetic relay.
- The SDL input regression passed complete Unicode commit delivery, one-step
  undo for a commit, clipboard content beyond 1 KiB, composition-aware Enter,
  and coalesced worker wakeups. SDL integration did not exist before this
  migration, so this test specifies the new boundary through the real editor
  consumer rather than claiming a before-fix run against GLFW.
- Real Wayland URI-drop delivery and whole-offer rejection passed three runs.
  Native keyboard input, resizing, four-sample rendering, and long clipboard
  exchange in both directions also passed the optional compositor diagnostics.
- A window opened at scale 2 reported logical dimensions 780×560 and framebuffer
  dimensions 1560×1120. Unextended legacy compositors have the live-scale
  limitation described above; Zrct's extended profile passes live transitions.
- `zig fmt --check build.zig build src` and `git diff --check` passed.

Native drop tests now inject at the application-owned delivery boundary because
GLFW's private URI parser and callbacks no longer exist in the executable. Their
original path, rejection, attachment-review, and relay-byte assertions remain;
the separate compositor diagnostics cover actual Wayland negotiation.

## Zrct SDL3 driver validation (2026-10-01)

The restored `test-zrct -Dautomation=true` suite passes all 13 scenarios in run
`20261001-124458-6ed5c9`. The earlier driver port passed 12/13; the remaining
live-scale failure was reproduced unchanged in `20261001-124008-cb0a9f` and fixed
by Zrct's Weston surface-scale extension. The same scenario also passed three
consecutive repetitions (`20261001-124630-cf3de0`). Text/editing, persistence,
settings, reviewed attachment bytes, history recording, desktop identity, native
clipboard/log actions, and real Wayland attachment sends pass. The two desktop
click scenarios passed three further repetitions each after Zrct synchronized
activation before clicking. No existing behavioral assertions or baselines were
weakened to restore the driver.

All three uninstrumented SDL desktop diagnostics passed in
`20261001-124434-92f07b`. The added framebuffer regression failed before enabling
the surface-scale extension (`20261001-124354-ae041a`) and passed afterward,
verifying live 1× → 2× → 1× rendering dimensions independently of automation.

All 146 headless client tests and the normal client build passed. Zrct's five Zig
and 20 Python tests passed, including disabled-instrumentation builds for both
backends. These checks supplement the earlier native rendering results; they do
not resolve the two existing rendering failures or establish full IME support.
