---
name: zrct
description: Integrate zrct into Zig GUI projects, write semantic GUI scenarios, run focused tests, and investigate zrct failures or visual regressions.
---

# Zrct GUI testing

Exercise the application's real input consumers and verify observable effects in
an isolated desktop. Keep application instrumentation opt-in.

This file lives at the zrct package root. Resolve symlinks before following its
relative links. When working in a consuming project, inspect its `build.zig.zon`
and `build.zig` to locate the declared zrct dependency, suite, fixture builds,
and test step; do not infer a sibling checkout or installed executable.
Zimbr is the current SDL3/ClayUI integration; prefer its application-owned suite.
Bundled raylib patches, visual baselines and Flamez examples are historical and
are not SDL acceptance evidence. External checkouts may be unavailable; use the
current consuming project for execution and validation.

## Run a focused scenario

Use the consuming project's Zig step so it builds the exact instrumented binary
and provisions pinned uv, managed Python, Weston, FFmpeg, and ImageMagick. Reuse
the project's required build options. From an integrated application's root,
adapt the step name and scenario filter to its build:

```sh
zig build test-zrct -Dautomation=true -- --filter scenario_name --json
```

`--filter` is a substring of the unittest scenario ID, not a regular expression.
Use `--list` to inspect selection, `--case Class.test_name` for an exact case, or
`--rerun-failed artifacts/RUN` to select previous failures. Every run writes
`junit.xml` alongside `result.json`. Build options precede `--`; runner
options follow it. Other consumers can choose a different step name.

From the zrct root, you can also run an explicitly selected suite against a
prepared instrumented executable and its fixtures:

```sh
zig build zrct -- run /path/to/app/tests/gui.py --repository /path/to/app --executable /path/to/instrumented-app --no-build --filter scenario_name --json
zig build zrct -- doctor --json
```

Keep warm caches. A separate `zig build tools` or desktop build is unnecessary
for an integrated `addRun` step with the appropriate options. Use `zig build
python -- ...` for Python helpers. Missing host shared libraries/utilities are
environment failures; consult [setup prerequisites](../../docs/development.md#gui-scenarios-with-zrct). The current
managed binary profile requires Linux x86-64 with compatible Arch Linux ABIs.

Start with the affected scenario. The runner normally executes up to four
isolated scenarios concurrently; use `--jobs 1` when investigating ordering or
resource contention. Add `--record` for temporal assertions or frame evidence,
and `--repeat N` when checking repeatability. Broaden to affected suites and native
tests once the focused case passes. Keep source/builds fixed during repetitions.

`addRun` builds first and supplies `--no-build` itself. For manual CLI reuse,
provide `--executable /absolute/path/to/instrumented-app --no-build` only after
preparing that artifact and its fixtures. A normal build can overwrite
`zig-out/bin`; its presence does not establish that it supports automation.
Runs record the executable's SHA-256 and reject changes before workers/launches
and after scenarios. Generated reproduction commands pin that identity with
`--executable-sha256`; rebuild through the consumer step after source changes.
The hash establishes artifact identity, not source freshness.

## Author or extend a scenario

Read the relevant existing suite and [driver](zrct/driver.py). Python suites export
`SUITE = Suite(...)` and use `zrct.TestCase`. Launch through `self.context.launch()`
or the existing fixture's launcher. Fixture context managers receive the session
and are entered as `Suite.setup`; `self.context.fixture` holds their result. See
[suite/session APIs](zrct/suite.py) and [Zimbr scenarios](../../tests/zrct/scenarios.py).

- Locate controls with registered IDs or role/text/container queries. `text=`
  matches the complete label; use `text_contains=` explicitly for a substring of
  its preview. Migrate older substring selectors to `text_contains=`. Add missing
  targets alongside real layout geometry, using domain identity for repeated
  items. Singular assertions and actions reject multiple matches. Use
  `app.targets(...).expect_count(n)` or `.expect_any_visible()` for collections.
  `Target.expect` rejects unknown properties and empty property sets.
- Ordinary target actions wait within a deadline for unique, enabled, interactable
  targets, then send input once. Action errors and lost acknowledgements are never
  retried. Use `scroll_into_view` explicitly for clipped or virtualized controls.
  `expect_fully_visible` additionally requires the complete bounds inside the clip.
  Actions and expectations accept `timeout=` for readiness. For timing-sensitive
  work, `click_now()` and `action_now(...)` resolve and send once while retaining
  server validation; `app.act` remains the low-level API.
- Establish readiness with `expect_visible`, property expectations, `app.expect`,
  or fixture events. Input acknowledgement means a frame consumed the action;
  asynchronous delivery or persistence still needs its own assertion.
- Use `expect_always`, `expect_unchanged`, or `expect_count` for bounded observation
  windows, including duplicate detection after initial delivery. Cumulative fixture
  counters preserve events between samples.
- Inspect `strings` truncation metadata for long values; use `read_text` or
  `expect_digest` for full-value assertions. A snapshot preview is not complete text.
- `FixtureProcess` provides supervised JSON requests/events and transcripts; keep
  application SQL, bytes and protocol-specific fault logic in the fixture.
- Assert independent effects where relevant: relay delivery counts, attachment
  bytes, exported contents, or persistence after restart. Preserve observation
  windows that detect duplicates or late effects when optimizing test runtime.
- `expect_absent_from_snapshot()` establishes no matching registered target; it
  does not establish deletion from application data. An invisible registered target
  is still present. Scroll explicitly or assert through the fixture as appropriate.
  `expect_drawing_idle()` observes drawing inactivity, not network readiness.
  The old `expect_absent` and `expect_idle` names are deprecated aliases.
- Let each scenario own its fresh desktop, HOME/XDG state, fixtures, and processes.
  Use `app.restart()` for persistence within that scenario. Register fixture
  processes through the runner's desktop so cleanup can reclaim them.

Choose the input boundary that covers the behavior. Ordinary `app.target(...)`
actions queue SDL3 events for the application's normal consumer; `Target.drop`
uses SDL drop events or the registered native drop-delivery handler. Inspect the
handshake's `boundary` and `drop_boundary` instead of assuming GLFW callbacks.
Clipboard, activation, or actual Wayland drag negotiation needs `DesktopInput`,
`Suite(..., required_boundaries=("compositor_input",))`, and `.desktop = true`
on `addRun`. The requirement enables desktop input and fails if a scenario never
exercises it. For suites whose scenarios only sometimes use the compositor,
`requires=("compositor_input",)` requires availability without requiring usage in
every scenario. Application operation requirements, such as `requires=("drop",)`,
are checked at launch. Follow [desktop examples](../../tests/zrct/desktop_native.py).
Reports list actual `observed_boundaries`, including mixed input routes; a suite
label cannot establish compositor coverage. These helpers use the same
clipped/obscured hit test as application input and synchronize native events with
completed frames; adding sleeps or screenshots as barriers hides readiness bugs
and adds overhead.

SDL `text_editing` simulates preedit/cancel at the event boundary; it does not
exercise a real IME. Use the consuming app's IME suite for that boundary. Shared
key names are available in `app.keys`; native SDL supports holds/repeat, double
click, semantic-endpoint drags and fractional wheel input. Applications reading
physical SDL device state require compositor input.

For a GUI regression, establish that the same scenario fails before the fix and
passes after it when practical. Retain meaningful assertions and the application's
native tests; GUI coverage supplements them.

## Investigate failures and visual changes

Read `artifacts/RUN/result.json`, then the failing scenario's `manifest.json`,
`events.jsonl`, and `report.html`. Inspect the first failed step, expected/observed
values, snapshot, and relevant application/fixture/Weston logs. Distinguish the
original failure from `collection_errors`; a missing screenshot can be a secondary
failure. Unsupported capabilities are non-passing. Preserve failing evidence
when rerunning and report the tested scope and artifact path.

Use the manifest's reproduction command to reuse its verified executable identity;
a different executable is rejected. Rerun through the consuming Zig step after
source changes. Rebuild instrumentation when upgrading zrct: ordinary scrolling
now requires `resolve_scroll`, and benchmarks require observer version 2.
For interactive inspection, add `--pause 60` to a focused run, then use the printed session handle
from the zrct root:

```sh
zig build zrct -- inspect --session /path/session.json --full --json
zig build zrct -- act --session /path/session.json overlay on
```

Turn the overlay off before visual assertions. The pause occurs after launch;
fixture/test actions may still be pending. Touch the printed `resume` path to
continue. `zig build zrct -- skeleton artifacts/RUN/SCENARIO --output /tmp/draft.py`
recovers actions only: supply fixture setup and meaningful assertions yourself.

Visual checks default to zero changed pixels and require a matching rendering
profile. Inspect expected/actual/difference images and `.profile.json` before
changing expectations. Update baselines only for an intended, reviewed visual
change; do not loosen masks/tolerance or accept new images just to clear a failure.
See [baseline and recording procedures](../../docs/development.md#gui-scenarios-with-zrct).
PNG checkpoints are authoritative; MP4 is for navigation. Frame recording has
capture overhead and does not measure application latency or FPS.

## Benchmark a GUI workflow

For performance work, follow [benchmarking](docs/benchmarking.md). Use an explicit
`Benchmark` suite and `zrct bench`; retain fixture setup and correctness assertions
outside measured intervals. Build with production optimization and a matching
zrct module mode. Benchmarks run serially, without recording or passing screenshots.
Use the application-side startup/action observer, not elapsed correctness-test
steps or legacy acknowledgement timestamps. Completion means a matching frame
before presentation. Benchmark `ready` selectors also use exact `text=` and
explicit `text_contains=`. Keep source/builds fixed during repetitions, declare cache
policy and fixture fingerprints, and compare only compatible runs. Validate
unchanged-build variability and observer cost before proposing CI gates.

## Build integration

Zimbr's build passes its translated SDL bindings and project-patched library to
`createModule` with `.link_system_sdl = false`. Its suite definitions live in
[tests/zrct](../../tests/zrct). Keep the Python environment and build outputs
in the consumer's cache so the package itself can be read-only.
