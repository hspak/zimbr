"""Build once, supervise isolated scenario workers, preserve the original failure."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shlex
import signal
import shutil
import subprocess
import sys
import time
import unittest
import uuid

from .artifacts import Bundle, atomic_json, render_report
from .environment import Desktop, doctor
from .errors import DeadlineExceeded, ZrctError, Unsupported
from .process import Process
from .suite import Session, load_suite
from .provenance import executable_identity, verify_executable


class Result(unittest.TestResult):
    def __init__(self):
        super().__init__()
        self.error = None
    def addError(self, test, err):
        self.error = self.error or err[1]
        super().addError(test, err)
    def addFailure(self, test, err):
        self.error = self.error or err[1]
        super().addFailure(test, err)
    def addSkip(self, test, reason):
        from .errors import Unsupported
        self.error = self.error or Unsupported(reason)
        super().addSkip(test, reason)
    def addSubTest(self, test, subtest, err):
        if err is not None:
            self.error = self.error or err[1]
        super().addSubTest(test, subtest, err)
    def addUnexpectedSuccess(self, test):
        self.error = self.error or AssertionError(f"Unexpected success: {test.id()}")
        super().addUnexpectedSuccess(test)
    def addExpectedFailure(self, test, err):
        from .errors import Unsupported
        self.error = self.error or Unsupported(f"Expected failure: {test.id()}: {err[1]}")
        super().addExpectedFailure(test, err)


def metadata(suite):
    def git(*args):
        result = subprocess.run(["git", "-C", str(suite.repository), *args], capture_output=True,
                                text=True, timeout=5)
        return result.stdout.strip()[:4096]
    manifest = suite.repository / "build.zig.zon"
    tools = doctor()
    if suite.benchmark is not None:
        from .benchmark import fingerprint
        for check in tools["checks"]:
            check["sha256"] = fingerprint(check["path"]) if check.get("path") else None
    return dict(repository=str(suite.repository), revision=git("rev-parse", "HEAD"),
                changes=git("status", "--short"),
                dependencies=manifest.read_text() if manifest.exists() else None,
                system=os.uname()._asdict() if hasattr(os.uname(), "_asdict") else list(os.uname()),
                python=sys.version, tools=tools)


def worker(suite_path, name, root, record=False, pause=0, *, repository=None, executable=None, metadata_path=None, benchmark=False):
    suite, tests = load_suite(suite_path, repository=repository, executable=executable)
    test = next(t for t in tests if t.id().split(".", 1)[-1] == name)
    environment = ["env", f"PYTHONPATH={Path(__file__).resolve().parents[1]}"]
    for key in ("ZRCT_PLATFORM_DIR", "ZRCT_UV", "ZRCT_WESTON", "ZRCT_WESTON_PREFIX",
                "ZRCT_FFMPEG", "ZRCT_FFPROBE", "ZRCT_MAGICK", "ZRCT_MANAGED_TOOLS",
                "LD_LIBRARY_PATH", "MAGICK_CONFIGURE_PATH", "MAGICK_CODER_MODULE_PATH",
                "MAGICK_FILTER_MODULE_PATH"):
        if key in os.environ:
            environment.append(f"{key}={os.environ[key]}")
    reproduction = shlex.join([*environment,
                               sys.executable, "-m", "zrct", "bench" if benchmark else "run", str(Path(suite_path).resolve()),
                               "--case", name, "--no-build", "--repository", str(suite.repository),
                               "--executable", str(suite.repository / suite.executable)])
    if benchmark:
        reproduction += " --warmup 0 --repeat 1"
    bundle = Bundle(root, name, reproduction, suite.boundary)
    bundle.manifest["metadata"].update(json.loads(Path(metadata_path).read_text()) if metadata_path else metadata(suite))
    bundle.input_contract(suite.boundary, suite.input_boundaries)
    bundle.manifest["required_capabilities"] = sorted(suite.requirements)
    bundle.save()
    error = None
    context = None
    def timeout(signum, frame):
        raise DeadlineExceeded(f"Scenario exceeded {suite.timeout + pause:g}s", scenario=name)
    previous = signal.signal(signal.SIGALRM, timeout)
    signal.setitimer(signal.ITIMER_REAL, suite.timeout + pause)
    try:
        identity = bundle.manifest["metadata"].get("executable")
        if identity is None:
            identity = executable_identity(suite.repository / suite.executable)
            bundle.manifest["metadata"]["executable"] = identity
        bundle.manifest["reproduction"] += " --executable-sha256 " + identity["sha256"]
        if record:
            bundle.manifest["reproduction"] += " --record"
        if pause:
            bundle.manifest["reproduction"] += f" --pause {pause:g}"
        bundle.save()
        verify_executable(suite.repository / suite.executable, identity["sha256"])
        suite.validate_environment()
        with ExitStack() as stack:
            desktop = stack.enter_context(Desktop(bundle, width=suite.width, height=suite.height, scale=suite.scale, input=suite.needs_desktop_input, display=suite.display, sdl_renderer=suite.sdl_renderer))
            context = Session(suite, desktop, bundle, record=record, pause=pause, benchmark=benchmark)
            try:
                if suite.setup:
                    with bundle.step("fixture startup"):
                        context.fixture = stack.enter_context(suite.setup(context))
                test.context = context
                result = Result()
                test.run(result)
                error = result.error
                if error is None and not result.wasSuccessful():
                    error = ZrctError("Scenario did not complete successfully")
                if error is None and benchmark and not bundle.manifest.get("measurements"):
                    error = ZrctError("Benchmark scenario produced no measurements")
                if error is None:
                    bundle.validate_boundaries()
                    if suite.requirements - {"compositor_input"} and context.app is None:
                        raise Unsupported("Application capability requirements were not checked: no instrumented app was launched")
                if error is not None and context.app:
                    bundle.manifest.setdefault("first_failed_step", name)
                    context.app.capture_failure()
                    desktop.capture_failure()
                if error is None and context.app and not benchmark:
                    context.app.screenshot(bundle.root / "final.png")
                context.finish_recording()
                if context.app and context.app.process.child.poll() is None:
                    context.app.close()
                    context.app.process.wait(3)
            except BaseException as caught:
                error = error or caught
                bundle.manifest.setdefault("first_failed_step", name)
                if context.app:
                    context.app.capture_failure()
                desktop.capture_failure()
                try:
                    context.finish_recording()
                except Exception as collection:
                    bundle.manifest["collection_errors"].append(f"recording: {collection}")
        verify_executable(suite.repository / suite.executable, identity["sha256"])
    except BaseException as caught:
        error = error or caught
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    bundle.finish(error)
    return 0 if error is None else 1


def reclaim(root):
    """Last-resort process cleanup if a scenario worker was killed before finally blocks."""
    journal = Path(root) / "events.jsonl"
    if not journal.exists():
        return
    processes = {}
    runtimes = []
    for line in journal.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event["kind"] == "process_started":
            processes[event["name"]] = event
        elif event["kind"] == "process_stopped":
            processes.pop(event["name"], None)
        elif event["kind"] == "runtime_created":
            runtimes.append(Path(event["runtime"]))
    for entry in processes.values():
        try:
            if Process.owns_group(entry):
                os.killpg(entry["pid"], signal.SIGKILL)
        except (OSError, KeyError, ValueError):
            pass
    for runtime in runtimes:
        try:
            if runtime.name.startswith("zrct-") and (runtime / ".zrct-owner").read_text() == str(Path(root).resolve()):
                shutil.rmtree(runtime)
        except OSError:
            pass


def select(tests, *, filter="", cases=(), rerun_failed=None):
    names = [t.id().split(".", 1)[-1] for t in tests]
    if sum(bool(v) for v in (filter, cases, rerun_failed)) > 1:
        raise ValueError("Use only one of filter, cases or rerun_failed")
    if rerun_failed:
        path = Path(rerun_failed)
        previous = json.loads((path / "result.json" if path.is_dir() else path).read_text())
        cases = {row["scenario"] for row in previous["results"] if row["status"] != "passed"}
        if not cases:
            raise ZrctError("Previous run has no failed scenarios")
    missing = set(cases) - set(names)
    if missing:
        raise ZrctError(f"Unknown scenarios: {', '.join(sorted(missing))}")
    selected = [name for name in names if name in cases] if cases else [name for name in names if filter in name]
    if not selected:
        raise ZrctError(f"No scenarios match {filter!r}")
    return selected


def run(suite_path, *, filter="", cases=(), rerun_failed=None, output="artifacts", repeat=1, no_build=False,
        record=False, pause=0, repository=None, executable=None, jobs=None, benchmark=False, warmup=0,
        executable_sha256=None):
    if executable_sha256 is not None:
        if not no_build:
            raise ValueError("--executable-sha256 requires --no-build")
        if len(executable_sha256) != 64 or any(c not in "0123456789abcdef" for c in executable_sha256):
            raise ValueError("--executable-sha256 must be a lowercase SHA-256 hex string")
    if benchmark:
        if record or pause or jobs not in (None, 1):
            raise ValueError("Benchmarks require one worker, no recording and no pause")
        if not 0 <= warmup <= 100 or repeat + warmup > 1000:
            raise ValueError("warmup must be 0..100 and total iterations at most 1000")
        jobs = 1
    elif warmup:
        raise ValueError("Warmup is only supported by bench")
    if jobs is None:
        jobs = 1 if pause else min(4, getattr(os, "process_cpu_count", os.cpu_count)() or 1)
    if not 1 <= jobs <= 64 or not 1 <= repeat <= 1000:
        raise ValueError("jobs must be between 1 and 64; repeat must be between 1 and 1000")
    suite_path = Path(suite_path).resolve()
    suite, tests = load_suite(suite_path, repository=repository, executable=executable)
    if benchmark:
        from .benchmark import Benchmark
        if not isinstance(suite.benchmark, Benchmark):
            raise ValueError("Benchmark suites must declare Suite(benchmark=Benchmark(...))")
    elif suite.benchmark is not None:
        raise ValueError("Use zrct bench for a benchmark suite")
    selected = select(tests, filter=filter, cases=cases, rerun_failed=rerun_failed)
    root = Path(output).resolve() / (time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
    root.mkdir(parents=True, mode=0o700)
    results = []
    build = Bundle(root / "build", f"build {suite.name}", shlex.join(suite.build), "build")
    metadata_path = root / "metadata.json"
    try:
        suite.validate_environment()
        if not no_build and suite.build:
            with build.step("build"):
                process = Process("build", suite.build, cwd=suite.repository, env=os.environ.copy(), bundle=build)
                try:
                    process.wait(300)
                finally:
                    process.stop()
        with build.step("verify prepared executable"):
            identity = executable_identity(suite.repository / suite.executable)
            if executable_sha256 is not None:
                verify_executable(suite.repository / suite.executable, executable_sha256)
            build.manifest["metadata"]["executable"] = identity
        run_metadata = metadata(suite)
        run_metadata["executable"] = identity
        if benchmark:
            from .benchmark import metadata as benchmark_metadata
            run_metadata["benchmark"] = benchmark_metadata(suite, suite_path)
            if run_metadata["benchmark"]["executable_sha256"] != identity["sha256"]:
                raise ZrctError("Executable changed while collecting benchmark metadata")
        atomic_json(metadata_path, run_metadata)
        build.finish()
    except BaseException as error:
        results.append(build.finish(error))
    else:
        # Versions/repository state are constant for this run; avoid probing every
        # executable again in every worker. Desktop/rendering metadata stays local.
        for iteration in range(repeat + warmup):
            def start(index):
                name = selected[index]
                directory = root / f"{iteration + 1:02}-{index + 1:02}-{name}"
                print(f"Running {name} ({iteration + 1}/{repeat + warmup})" + (" [warmup]" if iteration < warmup else ""), file=sys.stderr, flush=True)
                argv = [sys.executable, "-m", "zrct", "_worker", str(suite_path), name, str(directory)]
                argv.extend(["--repository", str(suite.repository), "--executable",
                             str(suite.repository / suite.executable), "--metadata", str(metadata_path)])
                if record:
                    argv.append("--record")
                if benchmark:
                    argv.append("--benchmark")
                if pause:
                    argv.extend(["--pause", str(pause)])
                env = os.environ.copy()
                source = str(Path(__file__).resolve().parents[1])
                env["PYTHONPATH"] = source + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
                directory.mkdir(mode=0o700)
                worker_log = (directory / "worker.stdout.log").open("wb")
                try:
                    child = subprocess.Popen(argv, env=env, start_new_session=True, stdout=worker_log)
                except BaseException:
                    worker_log.close()
                    raise
                return child, worker_log, argv, directory, time.monotonic() + suite.timeout + pause + 30

            def finish(index, entry):
                child, worker_log, argv, directory, _ = entry
                worker_log.close()
                reclaim(directory)
                path = directory / "manifest.json"
                if not path.exists():
                    bundle = Bundle(directory, selected[index], shlex.join(argv), suite.boundary)
                    bundle.finish(ZrctError(f"Scenario worker exited {child.returncode} without a result"))
                result = json.loads(path.read_text())
                if result["status"] == "running":
                    result.update(status="infrastructure_failure", error="Scenario worker died or exceeded watchdog deadline")
                    atomic_json(path, result)
                    render_report(directory)
                result["manifest"] = str(path)
                result["report"] = str(directory / "report.html")
                summary = {key: result[key] for key in ("scenario", "status", "boundary", "reproduction",
                           "observed_boundaries", "required_boundaries", "required_capabilities",
                           "first_failed_step", "error", "manifest", "report") if key in result}
                summary["artifacts"] = [dict(path=str(directory / item["path"]), kind=item["kind"])
                                        for item in result["artifacts"] if item["kind"] in ("screenshot", "diff", "crop")][:12]
                summary["iteration"] = iteration + 1
                summary["details"] = result.get("details", {})
                if "observed" in summary["details"]:
                    summary["details"] = {**summary["details"], "observed": str(summary["details"]["observed"])[:2048]}
                return summary

            active, completed = {}, {}
            next_index = 0
            try:
                while next_index < len(selected) or active:
                    while next_index < len(selected) and len(active) < jobs:
                        active[next_index] = start(next_index)
                        next_index += 1
                    for index, entry in list(active.items()):
                        child, _, _, _, deadline = entry
                        if child.poll() is None and time.monotonic() >= deadline:
                            stop_worker(child)
                        if child.poll() is not None:
                            completed[index] = finish(index, entry)
                            del active[index]
                    if active:
                        time.sleep(.01)
            finally:
                # Interrupts and startup failures must reclaim all concurrent
                # desktops, including descendants in their own process groups.
                for child, worker_log, _, directory, _ in active.values():
                    try:
                        stop_worker(child)
                    finally:
                        worker_log.close()
                        reclaim(directory)
            results.extend(completed[index] for index in range(len(selected)))
        try:
            verify_executable(suite.repository / suite.executable, identity["sha256"])
        except ZrctError as error:
            integrity = Bundle(root / "integrity", "executable integrity", "", "none")
            integrity.manifest["metadata"]["executable"] = identity
            results.append(integrity.finish(error))
    result = dict(schema_version=1, status="passed" if all(r["status"] == "passed" for r in results) else "failed",
                  run=str(root), results=results)
    if benchmark:
        from .benchmark import aggregate
        report = aggregate(result, warmup, repeat)
        result["benchmark"] = str(root / "benchmark.json")
        if report["status"] != "valid":
            result["status"] = "failed"
    from .artifacts import write_junit
    result["junit"] = str(write_junit(result, root / "junit.xml"))
    atomic_json(root / "result.json", result)
    return result


def stop_worker(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
