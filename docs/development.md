# Development setup: build a Mac relay and Linux client

For normal installation, use the [two-step package setup](setup.md).
This guide is for working on Zimbr itself.

Run commands from a checkout of the same revision on both computers. The Mac
must be signed into Messages in its graphical login session; Linux needs a
Wayland desktop. Install the Zig version in [`.zigversion`](../.zigversion)
(currently **0.16.0**) from [Zig's downloads](https://ziglang.org/download/).
Run setup as your ordinary user.

These steps use the source build's **dev** profile: port **8732**, **Zimbr Relay
Dev.app**, and separate `zimbr-dev` client state. For packaged releases, use
`release` consistently in build and administration commands, port **8731**, and
the paths in [profiles](macos-profiles.md). Optimization does not select a profile.

## Frame scheduling

Interactive rendering uses VSync plus a deadline at the current display's refresh
rate (120 Hz when unavailable). The deadline also applies during resize, when
recreating Vulkan swapchains can let VSync return before a refresh. Drawing and
presentation count toward that deadline, so an already blocked frame adds no
extra wait. The final fraction of a millisecond uses a precise wait instead of
rounding every frame up to the next millisecond. Held keys and mouse buttons keep
rendering active; other input extends a 120 ms burst, and visible sync animation
runs at the same cadence. Idle screens skip drawing and
presentation until input, a worker update, or a visible timer needs a frame.
Caret blinking, notice expiry, send recovery, and image retries retain their
own deadlines; background services are still polled at least every 25 ms while
idle. With `-Dfps-counter=true`, the counter shows `Idle` for idle refreshes and
excludes idle waiting from the next active FPS sample.

## Rendering benchmarks

Linux GUI builds fetch [pinned SDL 3.4.16 sources](../vendor/sdl/README.zimbr),
compile them directly with [Zig](../build/sdl.zig), and link them statically.
The client, rendering benchmark, native tests, and Zrct hooks all use that library.
GNU `patch` applies the checked-in [Vulkan changes](../build/sdl/vulkan.patch)
to a generated renderer file in the build cache. The downloaded sources remain
unchanged; Zig reruns patch preparation when either input changes. No manual patch
command, Python, CMake, Ninja, or host SDL installation is required. Zig owns
compilation, configuration headers, caching, and linking, using the selected
optimization mode and CPU target. The first build needs network access to fetch
dependencies; subsequent builds can reuse the cached packages.
`pkg-config` locates native development headers, and `wayland-scanner` generates
bindings from SDL's pinned protocol XML as Zig build steps. D-Bus and libdecor
development files are required. IBus support is enabled when `pkg-config` finds
`ibus-1.0`; missing development files omit SDL's direct IBus backend. Fcitx and
compositor-provided Wayland text input remain available. Use `-Dibus=false` to
disable IBus explicitly or `-Dibus=true` to require it and fail if it is unavailable.
Use `PKG_CONFIG_PATH` for development libraries outside the system prefix.
Optional audio/device drivers are enabled when their development files are present.
The patched library reuses completed upload buffers, retaining at most 8 MiB of
buffer capacity per command buffer, and raises the upload batch limit from 32 to
128. Driver allocation alignment and metadata are additional. Recycling waits
for the associated completion fence or queue idle. Both swapchain recreation and
renderer shutdown release every retained buffer.
Geometry preserves shared vertices and normalizes indices to 32 bits, retaining
SDL's draw batching. Vertex and index bytes share the existing GPU buffer lifetime.
Shader constants and matching descriptor bindings are reused only within the
current command list; an entry never mutates a descriptor used by pending draws.
The SDL revision reported by the benchmark includes a digest of the upstream
package hash and Vulkan patch, identifying both the release contents and local changes.

Text shaping shares two immutable Pango contexts per thread, one for each
antialiasing mode. Scale or font-map changes replace the cached context while
existing layouts retain their original context. Cold-text benchmarks still
rebuild every application layout and raster.

Build the synthetic benchmark with the pinned toolchain, then run it on the
Wayland desktop whose GPU and compositor you want to measure:

```sh
zig build render-bench -Doptimize=ReleaseFast
python3 tests/rendering.py --output artifacts/rendering-before \
  --drivers opengl --runs 5 --frames 1200
# After a renderer change, repeat backends with alternating run order.
python3 tests/rendering.py --output artifacts/rendering-after \
  --drivers opengl vulkan gpu --runs 5 --frames 1200
# Isolate the cost of avatars sharing a letter in different participant colors.
python3 tests/rendering.py --output artifacts/rendering-distinct \
  --drivers opengl vulkan --avatars distinct --runs 5 --frames 1200
# Isolate cache rebuilding or image uploads for profiling.
python3 tests/rendering.py --output artifacts/rendering-cold-text \
  --drivers opengl vulkan --workload cold_text --runs 5 --frames 1200
SDL_RENDER_DRIVER=vulkan perf record -g --call-graph dwarf \
  -o artifacts/rendering-image-upload.perf \
  -- zig-out/bin/render-bench 3000 shared image_upload
```

Each output directory must be new. It retains per-frame JSONL samples, summaries,
stderr logs, the executable hash, source revision, SDL build revision, and system/driver information.
`--workload` selects `cached`, `scroll`, `cold_text`, `image_upload`, `rich_anchor`,
`caret`, `reflow`, `resize_width`, or `resize_height`; the default is `all`.
`--pacing` selects `unpaced` (default), `vsync`, `timer`, or `capped_vsync`.
The executable accepts the workload and pacing as its optional third and fourth
arguments, after frame count and avatar mode. Keep profiling
runs separate from timing runs.
Use `--drivers default` to inspect and measure the application's default choice.
The `vulkan` backend is SDL's direct Vulkan renderer; `gpu` selects SDL's GPU
renderer with `SDL_GPU_DRIVER=vulkan` and verifies the underlying GPU driver.
No relay, credentials, database, or real messages are used. A temporary benchmark
window draws 32 conversations and 1,000 synthetic messages through the production
chat renderer. Keep the window on the same display at the same scale, with other
GPU workloads quiet. Compare matching window dimensions and optimization modes.
The default `--avatars shared` gives conversations the same initial in different
participant colors, exposing raster-cache contention. `--avatars distinct` gives
visible conversations different initials. Compare backends within each fixture;
the shared-initial case is a stress case, not an estimate of every user's chat list.
The `cached` workload means a settled scene after warm-up; it does not guarantee
zero texture uploads if cached raster variants replace one another.

The original four workloads are settled redraws, a deterministic scrolling sweep, clearing
the text cache each frame, and uploading/drawing/destroying a 512×512 RGBA image
over the cached chat. Layout settles before measurement; each workload gets 120
warm-up frames. The default `unpaced` mode disables VSync and bypasses the frame
timer. It records draw and presentation wall time plus process CPU time, reporting
p50/p95/p99 and the fraction of work intervals exceeding the 8.33 ms budget for
120 Hz. These are CPU-side throughput measurements through `SDL_RenderPresent`,
not GPU timestamps, displayed FPS, input latency, or proof of missed display
deadlines. Event polling is outside the measured interval. Texture retirement is
included in the upload workload. The cold-text workload measures cache rebuilding,
not whole-application startup. No screenshot capture runs during measurement.

`rich_anchor` keeps a long message containing links partly above the viewport,
exercising block measurements and reading-anchor maintenance on every frame.
`caret` moves a collapsed selection through 64 positions in an unchanged long
draft. `reflow` invalidates all 1,000 history heights at a fixed width, then lets
the production layout finish before invalidating again. This isolates deferred
height measurement from compositor resize timing and cold visible-text caches.
Its summaries include completed cycles, frames to settle, and total CPU-side
wall work per cycle; partial cycles at sample boundaries are excluded. Frame
counts describe unpaced work, not elapsed convergence under the application's
frame timer. Compare these alongside per-frame latency when changing the layout
budget, since smaller batches may take more frames to finish.

The resize workloads grow and shrink one window dimension by two logical pixels
per frame over a 200-pixel range. They exercise real SDL window and swapchain
resizing; width changes also reflow history. They do not simulate a compositor's
interactive border drag. Frame-start intervals include pacing and event handling,
while `draw_ms` and `present_ms` separate application work from presentation waits.
`timer` and `capped_vsync` share the application's display interval and wait helper;
the latter keeps VSync enabled. Use these modes to check regularity separately
from unpaced rendering capacity, retaining each run's raw samples:

```sh
zig build render-bench -Doptimize=ReleaseSafe
python3 tests/rendering.py --output artifacts/resize-vsync --drivers vulkan \
  --workload resize_height --pacing vsync --runs 3 --frames 360
python3 tests/rendering.py --output artifacts/resize-paced --drivers vulkan \
  --workload resize_height --pacing capped_vsync --runs 3 --frames 360
# Repeat with resize_width, scroll, and caret to check the other active paths.
```

Preserve the baseline binary before rebuilding if a later direct comparison is
needed. CPU sampling with `perf record` should use a separate run so profiling
overhead does not contaminate the timing samples. The isolated zrct headless
profile uses software OpenGL, so use a GPU-backed desktop for hardware comparisons.

Shared shaped text retains up to 16 raster appearances per layout, within the
32 MiB live text-texture limit. This avoids replacing a glyph texture whenever
the same avatar initial appears in a different participant color. Retired static
textures reuse matching size/format allocations in a FIFO bounded by 128 textures
and 8 MiB of pixel storage, additional to the live caches. SDL/driver allocation
overhead is outside those byte counts. Render targets and oversized textures are
released immediately. Reusing storage avoids repeated creation and synchronous
destruction in SDL's direct Vulkan renderer; uploads still use SDL's transfer path.

## 1. Build on the Mac

Install Apple's Command Line Tools (`xcode-select --install` if absent), then:

```sh
brew install mkcert python@3.14 cryptography openssl@3.5
mkdir -p .tools
"$(brew --prefix python@3.14)/bin/python3.14" -m venv .tools/python
.tools/python/bin/python3 -m pip install -r tools/requirements-tls.txt
. .tools/python/bin/activate
export ZIMBR_PYTHON="$PWD/.tools/python/bin/python3"
export ZIMBR_ZIG="$(command -v zig)"
export ZIMBR_OPENSSL_PREFIX="$(brew --prefix openssl@3.5)"
export ZIMBR_OPENSSL_LICENSE="$ZIMBR_OPENSSL_PREFIX/LICENSE.txt"
test "$(zig version)" = "$(cat .zigversion)"
test -f "$ZIMBR_OPENSSL_PREFIX/lib/libssl.a"
test -f "$ZIMBR_OPENSSL_PREFIX/lib/libcrypto.a"
test -f "$ZIMBR_OPENSSL_LICENSE"
zig build relay test test-macos-enrichment -Dprofile=dev -Doptimize=ReleaseSafe \
  -Dopenssl-prefix="$ZIMBR_OPENSSL_PREFIX"
```

Use the versioned [OpenSSL 3.5 formula](https://formulae.brew.sh/formula/openssl@3.5);
the relay requires 3.5 headers and static archives. For a custom toolchain, see
[TLS build details](macos-tls.md#build). Keep these environment overrides for
future [updates](macos-relay.md#update-the-running-relay). In a new Mac shell,
activate the environment with `. .tools/python/bin/activate` before using guides
that invoke `python3`.

## 2. Generate credentials and install on the Mac

Choose a DNS name or IP that Linux can reach **directly**, and a local Mac IP to
listen on. Replace the documentation placeholders below. The server name must
resolve to the Mac from both computers; SSH aliases do not provide that routing.
Allow the selected TCP port through the Mac/network firewall when needed.

```sh
.tools/python/bin/python3 tools/tls_admin.py setup --profile dev \
  --server-name relay.example --listen-address 192.0.2.10
.tools/python/bin/python3 packaging/macos/signing.py setup
.tools/python/bin/python3 packaging/macos/install.py --profile dev --install --start \
  --tls-config "$HOME/.config/zimbr-dev-setup/relay.json" \
  --admin-config "$HOME/.config/zimbr-dev-setup/admin.json" \
  --openssl-license "$ZIMBR_OPENSSL_LICENSE"
```

`setup` uses **mkcert** to create a dedicated CA and sign server and Mac
administrative CSRs, writes the allowlist and both configurations, and validates
them with the built relay. No JSON editing is needed. Add `--name OTHER_NAME`
for additional server identities, or `--port NUMBER` to override the profile port.
It refuses to replace existing staging credentials. After an interrupted run,
use `--directory` with a new private directory and pass its configurations to
the installer. Keep the existing CA for retries and renewal.

The issuer lives at `~/Library/Application Support/Zimbr Dev/ca/`;
**keep `rootCA-key.pem` on the Mac**. Setup migrates the former default
`~/.config/zimbr-dev-ca` without changing its certificate or key.
mkcert's [`CAROOT` and CSR options](https://github.com/FiloSottile/mkcert#advanced-topics)
provide issuance. Zimbr uses explicit trust, so do not run `mkcert -install` or
reuse your general development CA. Code signing is a separate identity; approve
its one-time prompt locally on the Mac. Back up both identities privately.

The installer copies runtime credentials outside the app and starts a login
LaunchAgent. Complete the macOS permission steps:

1. Add `~/Applications/Zimbr Relay Dev.app` to **System Settings → Privacy &
   Security → Full Disk Access**.
2. Run this from the Mac's Terminal and approve Messages Automation:

   ```sh
   open -n -W -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --check-automation
   ```

3. Choose **Restart Relay** from its menu after granting access. For optional
   contact names/photos, run:

   ```sh
   open -n -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --request-contacts --read-only
   ```

Use the menu's **Check Permissions** and **Open Logs** to verify readiness.
The relay needs this user's graphical login after reboot; locking the screen
does not log the user out. Permission grants cannot be automated by the installer.

## 3. Build and connect on Linux

Install Zig 0.16.0 and the [Linux build dependencies](linux-client.md#build-and-install),
including OpenSSH, Python cryptography, and OpenSSL. Then:

```sh
zig build client -Dprofile=dev -Doptimize=ReleaseSafe
packaging/linux/install.sh
zimbr-provision setup user@mac.example --profile dev --launch "$HOME/.local/bin/zimbr"
```

The dev app includes the same SSH enrollment helper as the release app. Its
helper uses the Homebrew Python and mkcert installed above. Alternatively, set
`ZIMBR_PYTHON` in the Mac's SSH environment to the Python environment prepared
above. No source checkout is used during enrollment.

Setup generates the Linux key, sends its CSR over SSH, enrolls the returned
certificate, saves the connection, and opens the client. It targets only the dev
profile (port 8732). The default credentials are under
`$XDG_CONFIG_HOME/zimbr-dev/tls` or `~/.config/zimbr-dev/tls`.

Open **Details** (Ctrl+D) to check authentication and sync. Setup sends no messages.
See [TLS operation](linux-mtls.md) for renewal and [Mac validation](mac-validation.md)
for permissions, restart, and deliberate send checks.

## GUI scenarios with Zrct

Zrct instrumentation uses native SDL3 input and application renderer hooks. The build
selects `.backend = .sdl3` and passes the SDL window to the driver, which uses
`SDL_RenderReadPixels` for capture. Attachment playback uses the native drop-delivery handler.
Text enters through SDL's event queue; compositor scenarios use real Wayland input.
The native `test-gui` and `test-gui-attachments` suites remain available on Wayland.
`test-gui-isolated` runs the same native GUI regressions in a fresh desktop with
the managed Python fixture dependencies; it does not require instrumentation.

The single-output Weston test profile provides standard surface-scale
notifications, so SDL3 observes live 1× → 2× → 1× changes without restarting the
window. The original scale/draft scenario passes unchanged. The native desktop
probe also checks logical and framebuffer dimensions independently of Zrct
instrumentation. See [the migration notes](../FUTURE_MIGRATION.md) for the remaining
limitation on compositors that only send legacy output-scale notifications.

Text and geometry use SDL's reported display scale on both axes. Rounded
framebuffer-to-window size ratios are not font scales: at 125%, those ratios
change as either window dimension crosses a pixel boundary. The native resize
regressions compare fixed text and geometry pixel-for-pixel while growing and
shrinking each axis, and check that text caches survive. Run them on a Wayland
display configured to 125% to exercise fractional rounding; the default isolated
desktop exercises integer scaling:

```sh
zig build test-gui -Dgui-test-filter='resizing preserves fixed' \
  -Dopenssl-prefix=.tools/openssl-3.5
```

History has an additional fractional-pixel boundary: following messages are
anchored to the viewport's bottom edge. Round that edge and each row's distance
from it separately, then use the resulting pixel-aligned row origin for its
header and body. Rounding their absolute positions independently changes their
relative spacing as the window height changes. The history resize regressions
compare text pixels after accounting for the expected bottom-edge translation,
and verify that a scrolled reading position stays fixed:

```sh
zig build test-gui -Dgui-test-filter='vertical resizing' \
  -Dopenssl-prefix=.tools/openssl-3.5
```

Optional SDL compositor diagnostics run without application instrumentation:
`zig build test-sdl-desktop -Ddesktop-tests=true`. These are independent of the
normal client build and native test steps.

Resolve Zrct from the dependency declared in `build.zig.zon`. For a local
checkout, set that dependency's `.path` to its location relative to the manifest.
From the Zimbr checkout, run:

```sh
zig build test-gui-isolated -Dopenssl-prefix=.tools/openssl-3.5
zig build test-zrct-all -Dautomation=true -Dopenssl-prefix=.tools/openssl-3.5
zig build test-zrct -Dautomation=true -Dopenssl-prefix=.tools/openssl-3.5
zig build test-zrct-recovery -Dautomation=true -Dopenssl-prefix=.tools/openssl-3.5
zig build test-zrct-content -Dautomation=true -Dopenssl-prefix=.tools/openssl-3.5
# Select a scenario and retain a recording:
zig build test-zrct -Dautomation=true -Dopenssl-prefix=.tools/openssl-3.5 -- --filter send_unicode --record
# On a GPU Wayland desktop, run the isolated suite in a nested GPU compositor:
ZRCT_DISPLAY_SMOKE=1 SDL_RENDER_DRIVER=vulkan zig build test-gui-isolated \
  -Doptimize=ReleaseSafe -Dopenssl-prefix=.tools/openssl-3.5
ZRCT_DISPLAY_SMOKE=1 SDL_RENDER_DRIVER=vulkan zig build test-zrct \
  -Dautomation=true -Doptimize=ReleaseSafe -Dopenssl-prefix=.tools/openssl-3.5 \
  -- --filter Messages
```

The default headless suites select software OpenGL unless `SDL_RENDER_DRIVER`
is explicitly set. The suites pass this selection through Zrct's renderer option,
which records the requested renderer in each report's rendering profile.
`ZRCT_DISPLAY_SMOKE=1` uses the existing GPU Wayland session
for a visible nested compositor while keeping client data and fixtures isolated;
it tests the application's normal renderer preference unless overridden. Hardware
and software rendering profiles have different visual baselines. The nested profile
does not support all compositor-control fixtures: run the `Desktop` scale, clipboard,
and drag-and-drop scenarios in their default headless profile. Use the separate
benchmark above for timings; scenario capture and instrumentation add overhead.

`-Dopenssl-prefix` selects the OpenSSL 3.5 LTS static libraries for the synthetic
relay; replace the example prefix with your installation. Zrct's Zig build
integration builds the instrumented client and fixture relay, provisions pinned
uv, Weston, FFmpeg, and ImageMagick, and runs with uv-managed Python 3.14 and
locked relay dependencies. The native tool packages currently require Linux
x86-64 with compatible Arch Linux shared libraries. Keep the application's native
build dependencies, zlib, `dbus-daemon`, `wayland-info`, `fc-match`, and fonts on the host.

Zimbr owns its scenarios and fixture under [`tests/zrct/`](../tests/zrct/README.md).
They cover Unicode editing and sends, independent conversation drafts, hiding and
restoring conversations, offline restart/reconnect, settings validation and
persistence, attachment review/removal and original bytes, and the reading
position while history and incoming messages load. Desktop scenarios also exercise
real Wayland clipboard exchange, file-drop negotiation, window resizing and output
scale changes. The application-ID check verifies the installed desktop identity.

`test-zrct-recovery` covers confirmed reset, lost reset replies and retry, held-upload
cancellation, uncertain send responses across restart, and superseded history
responses. `test-zrct-content` covers image viewer navigation, failed-image retry,
live reaction details, and preservation of the composer draft while overlays own
keyboard input. These suites use application input and need no Weston input helpers.
The relay owns operation-specific faults and records cumulative request counts;
the tests independently inspect committed client state and relay effects.
`test-zrct-all` combines the application, recovery, and content cases in one run,
with one worker limit and one JUnit report. Keep the individual steps for focused
work; the optional IME suite remains separate.

Each scenario uses a private headless Wayland desktop and synthetic TLS relay; it
does not need a Mac or account credentials. Desktop input additionally requires
`wl-clipboard`, a C compiler, pkg-config, and Wayland development files/protocols,
xkbcommon, libdrm, and Pixman; the build provisions Zrct's Weston helpers.
The build supplies the repository and executable paths. Up to four scenarios run
concurrently in separate desktops; `--jobs 1` runs serially. Arguments after `--`
go to the runner, including
`--filter`, `--case Class.test_name`, `--list`, `--rerun-failed artifacts/RUN`,
`--repeat`, `--record`, `--json`, and `--output`. Selection applies to the chosen
suite's build step. Repetitions complete one batch before starting the next.

Reports, logs, screenshots, and requested recordings appear under `artifacts/`.
Each run also writes `junit.xml` for CI and `result.json` with evidence links.
The Python environment and managed tools use build caches. Automation remains
opt-in through `-Dautomation=true`; normal client builds omit the Zrct driver.
Existing native and protocol suites remain useful for fault injection, allocation
failures, and precise rendering checks; GUI scenarios supplement those contracts.

### GUI workflow benchmarks

`bench-zrct` measures startup, first opening of a 10,000-message conversation,
switching back to a cached conversation, search results, and send-to-delivered
latency. It uses ReleaseSafe, matching the packaged Linux client. The fixture is
fully indexed before measurement. Each scenario owns fresh application storage;
the cached-switch case explicitly visits both conversations before timing the
return. The OS page cache is uncontrolled and recorded as such.

```sh
zig build bench-zrct -Dautomation=true -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=.tools/openssl-3.5 -- --warmup 3 --repeat 20 --json
# A short check that all measurements and effect assertions work:
zig build bench-zrct -Dautomation=true -Doptimize=ReleaseSafe \
  -Dopenssl-prefix=.tools/openssl-3.5 -- --warmup 1 --repeat 3
```

Measurements run serially without video capture. Native timestamps end at the
first completed application frame containing the specified semantic result,
before presentation; they do not measure physical display latency. Relay delivery,
routing, draft persistence, and duplicate-send assertions run outside timed
intervals. Avoid other builds or test runs while collecting samples.

Each run writes `benchmark.json`, `benchmark.html`, and `benchmark.trace.json`
alongside its correctness reports. Use the declared Zrct dependency's CLI:
`zig build zrct -- compare /path/to/baseline /path/to/candidate` from that package's
root. The comparator checks workload, fixture, tool content, renderer, optimization,
and machine compatibility. Tool cache relocation alone does not invalidate a run.
Comparisons are diagnostic: no timing threshold fails CI until repeatability and
budgets have been established. The existing renderer and worker benchmarks retain
their more specific performance coverage.

### Korean input-method scenarios

Install IBus, ibus-hangul, their GLib schemas/configuration helper, and a Hangul
font. The optional suite starts a private IBus daemon, Hangul engine, Wayland
desktop, and synthetic relay. It does not use the desktop's running input method
or change the user's input-method settings.

```sh
zig build test-ime -Dautomation=true -Dibus=true -Dopenssl-prefix=/path/to/openssl-3.5
zig build test-ime -Dautomation=true -Dibus=true -Dopenssl-prefix=/path/to/openssl-3.5 -- --repeat 3
```

For an extracted IBus installation, `ZIMBR_IBUS_PREFIX` selects its prefix
(containing `bin`, `lib`, and `share`); the default is `/usr`. The suite adds a
Korean font to its private rendering profile and records the font fingerprint.
It exercises real two-set keystrokes, jamo deletion, inline preedit, confirmation
without sending, paste during composition, exact relay delivery, and field changes
without duplicate text.
Native `test-gui -Dgui-test-filter=Korean` tests also cover selection replacement,
cancellation, wrapping, scrolling, and the SDL candidate area. Headless editor
tests cover UTF-8 offsets, size limits, undo/redo, and allocation failures.
