"""Explicit Python suites, standard unittest discovery, and isolated app sessions."""
from dataclasses import dataclass, replace
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import time
import unittest

from .artifacts import atomic_json
from .driver import App
from .errors import ZrctError, Unsupported
from .process import until
from .provenance import verify_executable


@dataclass
class Suite:
    name: str
    repository: Path | None = None
    build: tuple[str, ...] = ()
    executable: str | None = None
    setup: object = None
    boundary: str = "application_input"
    timeout: float = 45
    scale: int = 1
    desktop_input: bool = False
    display: bool = False
    width: int = 1280
    height: int = 800
    # None selects OpenGL for headless llvmpipe; display suites keep SDL's default.
    sdl_renderer: str | None = None
    benchmark: object = None
    # Application operation names (e.g. "drop") or "compositor_input" availability.
    requires: tuple[str, ...] = ()
    # These input boundaries must also be exercised by successful scenario actions.
    required_boundaries: tuple[str, ...] = ()

    def __post_init__(self):
        for name in ("requires", "required_boundaries"):
            values = getattr(self, name)
            if isinstance(values, str) or any(not isinstance(v, str) or not v for v in values):
                raise ValueError(f"Suite.{name} must be a sequence of nonempty names")
            setattr(self, name, tuple(values))

    @property
    def input_boundaries(self):
        # Preserve the established compositor declaration as an enforced contract.
        return set(self.required_boundaries) | ({"compositor_input"} if self.boundary == "compositor_input" else set())

    @property
    def needs_desktop_input(self):
        return self.desktop_input or "compositor_input" in self.requirements

    @property
    def requirements(self):
        return set(self.requires) | self.input_boundaries

    def validate_environment(self):
        if self.needs_desktop_input:
            from .environment import platform_directory
            if not (platform_directory() / "zrct-weston-input.so").is_file():
                raise Unsupported("Compositor input requires addRun(.desktop = true), or zig build desktop for manual runs")

    def validate_application(self, app):
        available = set(app.capabilities) | {app.handshake.get("boundary"), app.handshake.get("drop_boundary")}
        if self.needs_desktop_input:
            # The native frame barrier is required by every compositor action.
            if "frame" not in app.capabilities:
                raise Unsupported("Compositor input requires the application's frame operation")
            available.add("compositor_input")
        missing = self.requirements - available
        if missing:
            raise Unsupported(f"Application lacks required capabilities: {', '.join(sorted(missing))}")


class TestCase(unittest.TestCase):
    """The runner assigns context before unittest executes setUp/test/tearDown."""
    context: "Session"


class Session:
    def __init__(self, suite, desktop, bundle, *, record=False, pause=0, benchmark=False):
        self.suite, self.desktop, self.bundle = suite, desktop, bundle
        self.app = None
        self.fixture = None
        self.launch_count = 0
        self.record, self.pause = record, pause
        self.recorder = None
        self.startup_measurement = None
        from .benchmark import Measurements
        self.benchmark = Measurements(self) if benchmark else None

    def launch(self, *args, env=None):
        identity = self.bundle.manifest["metadata"].get("executable")
        if identity:
            verify_executable(self.suite.repository / self.suite.executable, identity["sha256"])
        self.launch_count += 1
        sock = self.desktop.root / "runtime" / f"app-{self.launch_count}.sock"
        arguments = [str(self.suite.repository / self.suite.executable), *map(str, args)]
        extra = {**(env or {}), "ZRCT_SOCKET": str(sock)}
        if self.startup_measurement:
            import json
            extra["ZRCT_BENCHMARK_START"] = json.dumps(self.startup_measurement)
            self.startup_measurement = None
        recording_dir = None
        if self.record:
            recording_dir = self.bundle.root / f"app-{self.launch_count}-frames"
            recording_dir.mkdir()
            extra["ZRCT_RECORD_DIR"] = str(recording_dir)
        with self.bundle.step("launch application"):
            process = self.desktop.launch(f"app-{self.launch_count}", arguments,
                                          cwd=self.desktop.root / "data",
                                          env=extra, category="application")
            until(sock.exists, timeout=10, condition="application control socket", health=process.check)
            self.app = App(sock, bundle=self.bundle, process=process,
                           relaunch=lambda: self.launch(*args, env=env),
                           before_close=self.finish_recording, health=self.desktop.health)
            self.suite.validate_application(self.app)
            if self.record:
                from .recording import Recording
                self.recorder = Recording(self.app, recording_dir.name)
                self.recorder.active = True
                self.app.recording = self.recorder
                self.recorder.started_ns = self.app.hello_before
                self.recorder.offset_ns = (self.app.hello_before + self.app.hello_after) // 2 - self.app.handshake["time_ns"]
                self.recorder.uncertainty_ns = (self.app.hello_after - self.app.hello_before) // 2
            self.app.expect("first completed application frame", lambda: self.app.inspect() or
                            (self.app.last and self.app.last["frame_id"] > 0))
        if self.benchmark is None:
            atomic_json(self.bundle.root / "session.json", dict(socket=str(sock), pid=process.child.pid,
                                                              bundle=str(self.bundle.root)))
            print(f"Session: {self.bundle.root / 'session.json'}", file=sys.stderr, flush=True)
        if self.pause:
            print(f"Paused for up to {self.pause:g}s; touch {self.bundle.root / 'resume'} to continue", file=sys.stderr, flush=True)
            deadline = time.monotonic() + self.pause
            while time.monotonic() < deadline and not (self.bundle.root / "resume").exists():
                self.app.health()
                time.sleep(.1)
        return self.app

    def finish_recording(self):
        if self.recorder:
            self.recorder.stop()
            self.recorder = None


def example_repository(name):
    """Built-in app examples require an explicit checkout, never a sibling guess."""
    value = os.environ.get("ZRCT_REPOSITORY") or os.environ.get(f"ZRCT_{name.upper()}_ROOT")
    if not value:
        raise ZrctError(f"Specify --repository /path/to/{name} or set ZRCT_{name.upper()}_ROOT")
    return Path(value).resolve()


def load_suite(path, *, repository=None, executable=None):
    path = Path(path).resolve()
    name = "zrct_suite_" + hashlib.sha256(str(path).encode()).hexdigest()[:12]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    sys.path.insert(0, str(path.parent))
    previous_repository = os.environ.get("ZRCT_REPOSITORY")
    if repository is not None:
        os.environ["ZRCT_REPOSITORY"] = str(Path(repository).resolve())
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
        if repository is not None:
            if previous_repository is None:
                os.environ.pop("ZRCT_REPOSITORY", None)
            else:
                os.environ["ZRCT_REPOSITORY"] = previous_repository
    suite = replace(module.SUITE,
                    repository=Path(repository or module.SUITE.repository or path.parent).resolve(),
                    executable=str(Path(executable).resolve()) if executable is not None else module.SUITE.executable)
    if not suite.executable:
        raise ZrctError("Supply --executable or set Suite.executable (Zig addRun supplies the built artifact)")
    discovered = unittest.defaultTestLoader.loadTestsFromModule(module)
    def flatten(items):
        for item in items:
            if isinstance(item, unittest.TestSuite):
                yield from flatten(item)
            else:
                yield item
    return suite, list(flatten(discovered))
