"""GUI latency measurements, compatible-run summaries and diagnostic comparisons.

No performance pass/fail thresholds: establish repeatability before gating CI.
"""
from dataclasses import asdict, dataclass
import html
import json
import math
import os
from pathlib import Path
import random
import statistics
import sys
import time

from .artifacts import atomic_json
from .errors import ExpectationFailed, ZrctError
from .provenance import fingerprint


@dataclass(frozen=True)
class Benchmark:
    """Fixture files are project-relative paths or (stable name, installed path) pairs."""
    fixture: dict
    cache: str
    fixture_files: tuple[str | tuple[str, Path], ...] = ()
    optimization: str = "fast"

    def __post_init__(self):
        if not self.fixture or not self.cache:
            raise ValueError("Benchmarks require a fixture identity and explicit cache policy")
        if self.optimization not in ("fast", "safe", "small"):
            raise ValueError("Benchmarks require a release optimization mode")


def machine():
    def read(path):
        try:
            return Path(path).read_text().strip()
        except OSError:
            return None
    cpu = read("/proc/cpuinfo") or ""
    models = sorted({line.split(":", 1)[1].strip() for line in cpu.splitlines()
                     if line.startswith(("model name", "microcode"))})
    governors = sorted({p.read_text().strip() for p in Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_governor")})
    return dict(host=os.uname().nodename, kernel=os.uname().release, architecture=os.uname().machine,
                cpus=models, affinity=sorted(os.sched_getaffinity(0)), governors=governors,
                boot_id=read("/proc/sys/kernel/random/boot_id"))


def metadata(suite, suite_path):
    config = suite.benchmark
    if not isinstance(config, Benchmark):
        raise ValueError("A benchmark suite must declare Suite(benchmark=Benchmark(...))")
    files = dict((entry, entry) if isinstance(entry, str) else entry for entry in config.fixture_files)
    if len(files) != len(config.fixture_files):
        raise ValueError("Benchmark fixture names must be unique")
    configuration = asdict(config)
    configuration["fixture_files"] = list(files)
    return dict(schema_version=1, configuration=configuration, machine=machine(),
                executable_sha256=fingerprint(suite.repository / suite.executable),
                suite_sha256=fingerprint(suite_path),
                fixture_sha256={name: fingerprint(suite.repository / path) for name, path in files.items()},
                zrct_sha256={str(p.relative_to(Path(__file__).parent.parent)): fingerprint(p)
                             for directory, suffix in (("zrct", ".py"), ("src", ".zig"))
                             for p in sorted((Path(__file__).parent.parent / directory).rglob("*" + suffix))})


class Measurements:
    def __init__(self, session):
        self.session = session
        self.names = set()

    def _spec(self, name, ready, start, frames):
        if name in self.names:
            raise ValueError(f"Measurement name must be unique within a scenario: {name}")
        allowed = {"id", "role", "text", "text_contains", "value", "status", "selected", "enabled"}
        if set(ready) - allowed or not (ready.get("id") or ready.get("role")):
            raise ValueError("ready requires an id or role and supported semantic properties")
        if "text" in ready and "text_contains" in ready:
            raise ValueError("Use either text (exact label) or text_contains (substring)")
        self.names.add(name)
        return dict(name=name, start=start, frames=frames, **ready)

    def _validate_app(self, app):
        config = self.session.suite.benchmark
        if app.handshake.get("optimization") != config.optimization:
            raise ZrctError("Application optimization differs from benchmark configuration",
                            expected=config.optimization, observed=app.handshake.get("optimization"))
        if app.handshake.get("benchmark_version") != 2 or app.handshake.get("clock") != "CLOCK_MONOTONIC":
            raise ZrctError("Application lacks the benchmark timing contract")
        if app.handshake.get("boundary") != "sdl3_events":
            raise ZrctError("The benchmark pilot requires native SDL event instrumentation")

    def _collect(self, app, spec, timeout):
        self._validate_app(app)
        deadline = time.monotonic() + timeout
        while True:
            result = app.request("measure_status")
            if result["state"] == "invalid":
                raise ZrctError("Invalid benchmark measurement", observed=result)
            if result["state"] == "complete":
                break
            if time.monotonic() >= deadline:
                raise ExpectationFailed("Benchmark completion condition was not reached", observed=result)
            time.sleep(.05)
        if result["name"] != spec["name"] or result["completed_ns"] <= result["started_ns"]:
            raise ZrctError("Invalid benchmark timestamps or identity", observed=result)
        result.update(specification=spec, duration_ns=result["completed_ns"] - result["started_ns"],
                      boundary="process_launch_to_completed_state" if spec["start"] == "launch" else "first_input_queued_to_completed_state",
                      unit="ns", load_average=list(os.getloadavg()))
        self.session.bundle.manifest.setdefault("measurements", []).append(result)
        return result

    def _cancel(self, app):
        if app is None:
            return
        failing = sys.exc_info()[0] is not None
        try:
            app.request("measure_cancel")
        except Exception as error:
            if not failing:
                raise
            self.session.bundle.manifest["collection_errors"].append(f"measurement cleanup: {error}")

    def startup(self, name, launch, *, ready, timeout=15, frames=True):
        """Launch a fresh process; stop at the first matching completed frame."""
        spec = self._spec(name, ready, "launch", frames)
        self.session.startup_measurement = spec
        app = None
        try:
            with self.session.bundle.defer_writes():
                app = launch()
                if self.session.startup_measurement is not None:
                    raise ZrctError("Startup launcher must use context.launch()")
                self._collect(app, spec, timeout)
            return app
        finally:
            self.session.startup_measurement = None
            self._cancel(app or self.session.app)

    def action(self, name, action, *, ready, timeout=15, frames=True):
        """Arm before an ordinary input action; timestamps come from the UI thread."""
        app = self.session.app
        self._validate_app(app)
        spec = self._spec(name, ready, "action", frames)
        app.request("measure_start", measurement=spec)
        try:
            with self.session.bundle.defer_writes():
                action()
                return self._collect(app, spec, timeout)
        finally:
            self._cancel(app)


def summarize(values):
    if not values or any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Measurements must be finite positive durations")
    median = statistics.median(values)
    result = dict(n=len(values), median_ns=median, min_ns=min(values), max_ns=max(values),
                  mad_ns=statistics.median(abs(v - median) for v in values))
    result["relative_mad"] = result["mad_ns"] / median
    # Small pilot samples cannot estimate tail latency reliably.
    if len(values) >= 100:
        result["p95_ns"] = sorted(values)[math.ceil(len(values) * .95) - 1]
    return result


def compatibility(manifest, sample):
    meta = manifest["metadata"]
    bench = meta["benchmark"]
    app = meta["application"]
    host = {k: v for k, v in bench["machine"].items() if k != "boot_id"}
    tools = meta["tools"]
    if isinstance(tools, dict) and all("sha256" in c for c in tools["checks"]):
        tools = {**tools, "checks": [{k: v for k, v in c.items() if k not in ("path", "remedy")}
                                    for c in tools["checks"]]}
    return dict(schema_version=1, configuration=bench["configuration"], machine=host,
                suite_sha256=bench["suite_sha256"], fixture_sha256=bench["fixture_sha256"],
                zrct_sha256=bench["zrct_sha256"], tools=tools, fonts=meta.get("fonts"),
                rendering_profile=meta["rendering_profile"], renderer=app["renderer"],
                rendering=app.get("rendering"), optimization=app["optimization"],
                specification=sample["specification"], boundary=sample["boundary"])


def aggregate(result, warmup, repeats=None):
    root = Path(result["run"])
    groups = {}
    failures = []
    for row in result["results"]:
        if "manifest" not in row:
            failures.append(dict(reason=row.get("error", "Build failed")))
            continue
        manifest = json.loads(Path(row["manifest"]).read_text())
        samples = manifest.get("measurements", [])
        if row["status"] != "passed" or not samples:
            failures.append(dict(scenario=row["scenario"], manifest=row["manifest"], reason=row.get("error", "No completed measurements")))
            continue
        for sample in samples:
            key = row["scenario"] + "/" + sample["name"]
            compatible = compatibility(manifest, sample)
            group = groups.setdefault(key, dict(compatibility=compatible, samples=[], warmup_samples=[]))
            if compatible != group["compatibility"]:
                failures.append(dict(scenario=key, reason="Environment changed between iterations"))
                continue
            item = dict(**sample, manifest=row["manifest"],
                        executable_sha256=manifest["metadata"]["benchmark"]["executable_sha256"])
            group["warmup_samples" if row["iteration"] <= warmup else "samples"].append(item)
    for group in groups.values():
        if repeats is not None and (len(group["samples"]) != repeats or len(group["warmup_samples"]) != warmup):
            failures.append(dict(reason="A metric is missing from one or more iterations"))
        if group["samples"]:
            group["summary"] = summarize([v["duration_ns"] for v in group["samples"]])
        else:
            failures.append(dict(reason="No measured samples after warmup"))
    report = dict(schema_version=1, status="valid" if groups and not failures else "invalid",
                  run=str(root), warmup=warmup, metrics=groups, failures=failures,
                  limitations=["Completed-frame latency precedes GPU/display presentation.",
                               "Instrumented release build; cache policy is declared by the suite.",
                               "Comparisons are diagnostic; no CI performance gate."])
    atomic_json(root / "benchmark.json", report)
    render(report, root / "benchmark.html")
    trace = []
    for index, (name, group) in enumerate(groups.items()):
        for sample in group["samples"]:
            trace.append(dict(name=name, ph="X", pid=index + 1, tid=1, ts=sample["started_ns"] / 1000,
                              dur=sample["duration_ns"] / 1000, args=dict(manifest=sample["manifest"])))
            for frame in sample["frames"]:
                trace.append(dict(name="completed frame (before presentation)", ph="i", s="t", pid=index + 1,
                                  tid=1, ts=frame["completed_ns"] / 1000, args=frame))
    atomic_json(root / "benchmark.trace.json", dict(traceEvents=trace, displayTimeUnit="ms"))
    return report


def compare(baseline, candidate):
    def read(path):
        path = Path(path)
        return json.loads((path / "benchmark.json" if path.is_dir() else path).read_text())
    before, after = read(baseline), read(candidate)
    if before["status"] != "valid" or after["status"] != "valid":
        raise ValueError("Cannot compare invalid benchmark runs")
    if before["metrics"].keys() != after["metrics"].keys():
        raise ValueError("Benchmark metric sets differ")
    rows = {}
    for name, group in after["metrics"].items():
        previous = before["metrics"][name]
        if group["compatibility"] != previous["compatibility"]:
            fields = [k for k in group["compatibility"] if group["compatibility"][k] != previous["compatibility"].get(k)]
            raise ValueError(f"Incompatible benchmark {name}: {', '.join(fields)}")
        a = [s["duration_ns"] for s in previous["samples"]]
        b = [s["duration_ns"] for s in group["samples"]]
        rows[name] = compare_samples(a, b)
    return dict(schema_version=1, baseline=str(baseline), candidate=str(candidate), metrics=rows,
                note="Diagnostic independent-sample bootstrap; thermal drift and correlated noise can invalidate inference. No CI gate.")


def compare_samples(a, b):
    row = dict(baseline=summarize(a), candidate=summarize(b),
               change=statistics.median(b) / statistics.median(a) - 1, assessment="insufficient_samples")
    if min(len(a), len(b)) >= 10:
        rng = random.Random(0)
        draws = sorted(statistics.median(rng.choices(b, k=len(b))) /
                       statistics.median(rng.choices(a, k=len(a))) - 1 for _ in range(2000))
        row["median_change_ci95"] = [draws[49], draws[1949]]
        row["assessment"] = "slower" if draws[49] > 0 else "faster" if draws[1949] < 0 else "inconclusive"
    return row


def render(report, path):
    esc = html.escape
    rows = []
    for name, group in report["metrics"].items():
        summary = group.get("summary")
        if summary:
            rows.append(f"<tr><td>{esc(name)}</td><td>{summary['n']}</td><td>{summary['median_ns']/1e6:.3f}</td>"
                        f"<td>{summary['relative_mad']:.1%}</td><td>{summary['min_ns']/1e6:.3f}–{summary['max_ns']/1e6:.3f}</td></tr>")
    Path(path).write_text("<!doctype html><meta charset=utf-8><title>Zrct benchmarks</title>"
                         "<style>body{font:16px system-ui;margin:3em;max-width:1100px}td,th{padding:.6em;text-align:left}"
                         "pre{white-space:pre-wrap}</style><h1>GUI benchmark measurements</h1>"
                         f"<p>{esc(report['status'])}</p><p>Latency ends at a completed application frame, before presentation.</p>"
                         "<table><tr><th>Metric</th><th>Samples</th><th>Median ms</th><th>Relative MAD</th><th>Range ms</th></tr>"
                         + "".join(rows) + "</table><p><a href=benchmark.json>Raw samples and metadata</a> · "
                         "<a href=benchmark.trace.json>Perfetto-compatible trace</a></p>"
                         f"<pre>{esc(json.dumps(report['failures'], indent=2)) if report['failures'] else ''}</pre>")


def render_comparison(report, path):
    rows = []
    for name, row in report["metrics"].items():
        interval = row.get("median_change_ci95")
        ci = f"{interval[0]:+.1%} to {interval[1]:+.1%}" if interval else "Insufficient samples"
        rows.append(f"<tr><td>{html.escape(name)}</td><td>{row['baseline']['median_ns']/1e6:.3f}</td>"
                    f"<td>{row['candidate']['median_ns']/1e6:.3f}</td><td>{row['change']:+.1%}</td>"
                    f"<td>{ci}</td><td>{html.escape(row['assessment'])}</td></tr>")
    Path(path).write_text("<!doctype html><meta charset=utf-8><title>Zrct comparison</title>"
                         "<style>body{font:16px system-ui;margin:3em}td,th{padding:.6em;text-align:left}</style>"
                         "<h1>GUI benchmark comparison</h1><table><tr><th>Metric</th><th>Baseline ms</th>"
                         "<th>Candidate ms</th><th>Median change</th><th>95% interval</th><th>Assessment</th></tr>"
                         + "".join(rows) + f"</table><p>{html.escape(report['note'])}</p>")
