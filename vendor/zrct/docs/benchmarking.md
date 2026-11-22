# GUI benchmark pilot

Zrct measures startup and input-to-state latency in native SDL applications. It
reuses semantic actions and fixtures, with a separate execution policy and an
application-side completion observer. Comparisons are diagnostic; there is no CI
performance threshold.

## Run and compare

Build an instrumented application with the optimization used for production.
For the Zimbr pilot, build `client` and `fake-relay` with `-Dautomation=true` and
`-Doptimize=fast`, retaining the application's required OpenSSL option.

```sh
zig build zrct -- bench suites/benchmark_zimbr.py \
  --repository /path/to/zimbr --executable /path/to/zimbr/zig-out/bin/zimbr \
  --no-build --warmup 3 --repeat 20
zig build zrct -- compare artifacts/BASELINE artifacts/CANDIDATE \
  --output artifacts/comparison.json
```

The pilot reuses the current consumer's fixture implementation, seeds 10,000 old
messages with stable content/dates/GUIDs, and waits for the relay to index all
source messages. A newer group message makes the initial selection deterministic.
Startup ends when Alice's conversation row is visible and enabled. Opening Alice
ends when `Reading anchor 9999` appears in the visible history. The application
loads its ordinary recent page; this does not measure drawing all 10,000 messages.
Fixtures, private state, processes, and desktop are fresh for each repetition.
OS page caches remain shared and uncontrolled; this is not a cold-disk benchmark.

`bench` runs one scenario at a time and accepts no recording, pause, or concurrency
option. `--repeat` counts measured iterations. `--warmup` adds discarded complete
scenario iterations whose samples remain available. Warmups do not preserve
application processes or private state. In-process warmups belong in scenario
setup and must be described in its cache policy.

Each run writes:

- `benchmark.json`: raw samples, warmups, compatibility metadata, medians,
  median absolute deviation (MAD), and ranges. P95 appears only at 100+ samples.
- `benchmark.html`: readable metric summary and links to raw evidence.
- `benchmark.trace.json`: Chrome JSON duration/frame events for Perfetto.
- Normal scenario manifests, logs, correctness assertions, and failure evidence.

`compare --output comparison.json` also creates `comparison.html`. Comparison
requires matching metric sets, endpoints, workload/cache declarations, suite and
fixture hashes, zrct implementation, machine/affinity/governor, tools, fonts,
rendering profile, and optimization. Application executable hashes may differ
between revisions and are retained per sample. Changed fixture binaries require
a new baseline. CPU load is recorded but not used as a compatibility key. A
private desktop does not reserve host CPUs or GPU.

With at least ten samples per side, comparisons include a deterministic
independent-sample bootstrap interval for the median change. An interval above
zero is labelled `slower`, below zero `faster`, otherwise `inconclusive`. Labels
do not change exit status. Fewer samples give `insufficient_samples`. Invalid or
incompatible runs fail the command. A narrow unchanged-build interval around zero
is stronger evidence of repeatability than an inconclusive result alone. Thermal
drift and correlated noise can invalidate the statistical interpretation.

## Author a benchmark

```python
from zrct import Benchmark, Suite, TestCase

SUITE = Suite("my-app-bench", executable="zig-out/bin/my-app", setup=my_fixture,
    benchmark=Benchmark(
        fixture={"dataset": "large-history-v1", "messages": 10000},
        cache="fresh private app state; shared OS cache uncontrolled",
        fixture_files=("tests/fixture.py", "tests/data/history.json"),
        optimization="fast"))

class Workflows(TestCase):
    def test_startup(self):
        app = self.context.benchmark.startup("ready", self.context.fixture.launch,
            ready={"id": "conversation-list", "enabled": True})
        app.target("conversation-list").expect_interactable()

    def test_open(self):
        app = self.context.fixture.launch()
        app.target("open").expect_interactable()
        self.context.benchmark.action("open", app.target("open").click,
            ready={"id": "document", "status": "ready"})
        self.context.fixture.verify_document()
```

Keep dataset setup, preload/warmup, and unrelated observation windows outside
measurements. Retain independent correctness checks afterward: a failed scenario
invalidates the run even if it recorded a fast sample. Every scenario must produce
measurements, and each metric must appear in every repetition. Fingerprint all
fixture inputs and helper implementations, including transitive dependencies.
Describe services and cache preparation in `fixture` and `cache`; zrct cannot
infer them from a Python callback.

`ready` selects exactly one target using `id`, `role`, and optional complete-label
`text` or explicit preview substring `text_contains`, optionally requiring exact
`value`, `status`, `selected`, or `enabled`. The two text selectors are mutually
exclusive. This requires benchmark observer version 2; rebuild instrumentation
when upgrading and change older substring selectors to `text_contains`.
The target must be visible and unobscured. Semantic visibility does not establish
pixel correctness or compositor presentation. Ambiguous/incomplete snapshots and
truncated required properties fail explicitly. Action measurements reject an
already-true condition. Names must be unique within a scenario.

Use a single ordinary SDL action as the trigger. `Target.type_text` includes its
focus click; focus beforehand and use `App.type_text` to measure only text input.
Compositor input is outside the pilot's timestamp boundary. Input remains paced
by completed frames; this is not a fixed-rate scrolling or saturation benchmark.

`addRun(..., .benchmark = true)` runs a benchmark suite with the exact built
executable and normal fixture dependencies. Pass the same optimization to the
application and zrct module. Debug instrumentation is rejected. Normal `run`
refuses benchmark suites to prevent concurrent execution under correctness policy.

## Measurement contract and overhead

Startup starts immediately before `Popen` creates the application, using Linux
`CLOCK_MONOTONIC`. Launch environment variables arm the observer at `zrct.init`,
so the first matching frame can be recorded before Python connects. Startup
includes process creation and application initialization, but excludes desktop
and fixture setup. A fresh process does not imply cold OS caches.

Actions start immediately before the next ordinary action queues its first input.
Subsequent press/release/text stages do not reset the start. Both measurements end
at `endFrame` for the first matching completed snapshot, before swap/presentation
and potentially before deferred GPU work completes. They do not measure GPU
execution or physical-device-to-display latency.

The observer owns a preallocated buffer for 2,048 frame timestamps and elapsed
`beginFrame`/`endFrame` spans. These spans are named `hooks_ns`: they are neither
CPU time nor necessarily complete application update times. The observer performs
no per-frame allocations or disk writes. Status polls return the frame array only
after completion. Overflow invalidates evidence. `frames=False` omits the array
while retaining exact endpoint timestamps. Matching scans the semantic registry.

Recording, screenshots, and overlays are rejected during active measurements.
The runner defers journal/manifest writes during measurement and skips passing
final screenshots. Deferred journals are bounded to 8,192 events; abrupt worker
termination may lose that interval's journal. Subprocess log supervision continues.
Registration, event injection, polling, and matching still cost time. Results
describe an instrumented release build, not an uninstrumented production binary.
