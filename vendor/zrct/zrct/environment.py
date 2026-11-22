"""The single supported headless profile: Weston GL and Mesa llvmpipe."""
import hashlib
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

from .errors import ZrctError, Unsupported
from .process import Process, until

PROFILE = "weston-gl-llvmpipe"


def platform_directory():
    return Path(os.environ.get("ZRCT_PLATFORM_DIR", Path(__file__).resolve().parents[1] / "zig-out/lib"))


def executable(name):
    configured = os.environ.get("ZRCT_" + name.upper().replace("-", "_"), name)
    return shutil.which(configured)


def doctor():
    managed = os.environ.get("ZRCT_MANAGED_TOOLS") == "1"
    checks = [dict(name="python", required=True, ok=sys.version_info >= (3, 11),
                   path=sys.executable, version=sys.version.split()[0],
                   remedy=None if sys.version_info >= (3, 11) else "Run with zig build zrct -- doctor")]
    for name, required in (("uv", True), ("zig", True), ("weston", True),
                           ("dbus-daemon", True), ("wayland-info", True),
                           ("fc-match", True), ("magick", False), ("ffmpeg", False), ("ffprobe", False),
                           ("wl-copy", False), ("wl-paste", False)):
        path = executable(name)
        version = None
        runnable = True
        if managed and name in ("magick", "ffmpeg", "ffprobe"):
            required = True
        if path:
            try:
                flags = ["version"] if name == "zig" else ["-version"] if name in ("ffmpeg", "ffprobe") else ["--version"]
                result = subprocess.run([path, *flags], capture_output=True, text=True,
                                        timeout=3, env=tool_environment())
                version = (result.stdout or result.stderr).splitlines()[0][:300]
                if name in ("uv", "weston", "magick", "ffmpeg", "ffprobe"):
                    runnable = result.returncode == 0
            except (OSError, subprocess.TimeoutExpired, IndexError):
                version = "version unavailable"
                runnable = False
        ok = bool(path) and runnable and (name != "zig" or version == "0.17.1") and (name != "weston" or (version or "").startswith("weston 15."))
        checks.append(dict(name=name, required=required, ok=ok, path=path, version=version,
                           remedy=None if ok else f"Unable to run {name}; check host shared libraries." if path and not runnable
                           else "Install Zig 0.17.1" if name == "zig" else "Run zig build zrct -- doctor to use managed Weston 15" if name == "weston"
                           else f"Install {name} or set ZRCT_{name.upper().replace('-', '_')}."))
    return dict(ok=all(c["ok"] for c in checks if c["required"]), profile=PROFILE, checks=checks)


def tool_environment():
    env = os.environ.copy()
    # Also supports an unpacked Weston for development without system installation.
    prefix = os.environ.get("ZRCT_WESTON_PREFIX")
    if prefix:
        lib = Path(prefix).resolve() / "lib"
        env["LD_LIBRARY_PATH"] = f"{lib}:{lib / 'weston'}" + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        modules = list(lib.glob("libweston-*/*.so")) + list((lib / "weston").glob("*.so"))
        env["WESTON_MODULE_MAP"] = ";".join(f"{p.name}={p}" for p in modules)
    return env


class Desktop:
    def __init__(self, bundle, *, width=1280, height=800, scale=1, input=False, display=False, sdl_renderer=None):
        self.bundle, self.width, self.height, self.scale = bundle, width, height, scale
        self.processes = []
        self.temp = None
        self.input = input
        self.display = display
        self.sdl_renderer = sdl_renderer or (None if display else "opengl")

    def __enter__(self):
        try:
            self.start()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def start(self):
        parent_display = None
        if self.display:
            if os.environ.get("ZRCT_DISPLAY_SMOKE") != "1":
                raise Unsupported("Display smoke requires ZRCT_DISPLAY_SMOKE=1 and a GPU Wayland session")
            name = os.environ.get("WAYLAND_DISPLAY")
            runtime = os.environ.get("XDG_RUNTIME_DIR")
            if not name or (not Path(name).is_absolute() and not runtime):
                raise Unsupported("Display smoke requires WAYLAND_DISPLAY and XDG_RUNTIME_DIR")
            parent_display = str(Path(name) if Path(name).is_absolute() else Path(runtime) / name)
            if not Path(parent_display).is_socket():
                raise Unsupported(f"Parent Wayland socket is unavailable: {parent_display}")
        self.temp = tempfile.TemporaryDirectory(prefix="zrct-")
        self.root = Path(self.temp.name)
        (self.root / ".zrct-owner").write_text(str(self.bundle.root))
        self.bundle.event("runtime_created", runtime=str(self.root))
        self.env = tool_environment()
        for key in list(self.env):
            if key.startswith(("DBUS_", "WAYLAND_", "XDG_")) or key in (
                    "DISPLAY", "SESSION_MANAGER", "DESKTOP_STARTUP_ID", "XAUTHORITY"):
                self.env.pop(key, None)
        for key in ("ZRCT_SOCKET", "ZRCT_RECORD_DIR", "ZRCT_BENCHMARK_START", "ZRCT_BENCHMARK_LAUNCH_NS", "FLAMEZ_SCREENSHOT", "ZIMBR_GUI_SCREENSHOT",
                    "ZIMBR_GUI_ATTACHMENT_SCREENSHOT", "ZIMBR_GUI_DROP_SCREENSHOT"):
            self.env.pop(key, None)
        # HOME is an environment entry for child processes, never a shell variable.
        for key, directory in (("HOME", "home"), ("XDG_RUNTIME_DIR", "runtime"),
                               ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                               ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                               ("TMPDIR", "tmp")):
            path = self.root / directory
            path.mkdir(mode=0o700)
            self.env[key] = str(path)
        self.env.update(XDG_SESSION_TYPE="wayland", XDG_CONFIG_DIRS=str(self.root / "config"),
                        XDG_DATA_DIRS="/usr/local/share:/usr/share", WAYLAND_DISPLAY="zrct",
                        LIBGL_ALWAYS_SOFTWARE="1", GALLIUM_DRIVER="llvmpipe", TZ="UTC",
                        LC_ALL="C.UTF-8", LANG="C.UTF-8", PYTHONUNBUFFERED="1")
        # Match the declared headless GL/llvmpipe profile. SDL's automatic renderer
        # selection may choose Vulkan, which LIBGL_ALWAYS_SOFTWARE does not govern.
        self.env["SDL_VIDEO_DRIVER"] = "wayland"
        self.env.pop("SDL_VIDEODRIVER", None)
        self.env.pop("SDL_RENDER_DRIVER", None)
        if self.sdl_renderer:
            self.env["SDL_RENDER_DRIVER"] = self.sdl_renderer
        if self.display:
            self.env.pop("LIBGL_ALWAYS_SOFTWARE", None)
            self.env.pop("GALLIUM_DRIVER", None)
        self.pin_fonts()
        self.bundle.manifest["metadata"]["rendering_profile"] = dict(name="weston-wayland-gpu" if self.display else PROFILE, width=self.width,
                                                                    height=self.height, scale=self.scale,
                                                                    sdl_renderer=self.sdl_renderer)
        # No standard service directories: host services cannot be activated on this bus.
        address = f"unix:path={self.root}/runtime/bus"
        config = self.root / "dbus.conf"
        config.write_text(f'<busconfig><type>session</type><listen>{escape(address)}</listen>'
                          '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
                          '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        self.env["DBUS_SESSION_BUS_ADDRESS"] = address
        bus = self.launch("dbus", [executable("dbus-daemon") or "dbus-daemon", "--nofork",
                                   f"--config-file={config}"], cwd=self.root)
        until(lambda: (self.root / "runtime/bus").exists(), timeout=5,
              condition="private D-Bus listener", health=bus.check)
        weston = executable("weston")
        if not weston:
            raise ZrctError("Weston is missing; run zrct doctor for prerequisites")
        # Desktop shell supports ordinary resizable windows; kiosk would force fullscreen.
        shell = "desktop-shell.so"
        prefix = os.environ.get("ZRCT_WESTON_PREFIX")
        config = self.root / "weston.ini"
        client = str(Path(prefix) / "lib/weston/weston-desktop-shell") if prefix else "/usr/lib/weston/weston-desktop-shell"
        config.write_text("[core]\n[shell]\npanel-position=none\nbackground-color=0xff202020\n"
                          "locking=false\nstartup-animation=none\n"
                          f"client={client}\n[keyboard]\nkeymap_layout=us\n[input-method]\npath=\n")
        extra = [] if self.display else ["--fake-seat"]
        if self.input:
            module = platform_directory() / "zrct-weston-input.so"
            if not module.exists():
                raise Unsupported("Build the Weston 15 input module with zig build desktop or enable addRun(.desktop = true)")
            self.env["ZRCT_DESKTOP_SOCKET"] = str(self.root / "runtime/desktop.sock")
            extra = [f"--modules={module}"]
        compositor = self.launch("weston", [weston, "--backend=wayland" if self.display else "--backend=headless", "--renderer=gl",
                                            f"--shell={shell}", f"--config={config}",
                                            "--socket=zrct", "--idle-time=0", "--debug", *extra,
                                            f"--width={self.width}", f"--height={self.height}",
                                            f"--scale={self.scale}"], cwd=self.root,
                                 env={"WAYLAND_DISPLAY": parent_display} if self.display else None)
        until(self._roundtrip, timeout=10, condition="Wayland roundtrip", health=compositor.check)
        info = self.launch("wayland-info", [executable("wayland-info") or "wayland-info"], cwd=self.root)
        info.wait(5)
        protocols = info.stdout_path.read_text(errors="replace")
        for required in ("wl_compositor", "wl_shm", "xdg_wm_base"):
            if required not in protocols:
                raise Unsupported(f"Compositor does not advertise {required}")
        self.bundle.event("desktop_ready", runtime=str(self.root), display="zrct")

    def pin_fonts(self):
        directory = self.root / "fonts"
        directory.mkdir()
        fingerprints = {}
        for query in ("DejaVu Sans", "DejaVu Sans:style=Bold", "DejaVu Sans Mono", "Noto Color Emoji"):
            match = subprocess.run(["fc-match", "-f", "%{file}", query], capture_output=True,
                                   text=True, timeout=3, env=tool_environment())
            source = Path(match.stdout)
            if match.returncode or not source.is_file():
                raise ZrctError(f"Required rendering font is unavailable: {query}")
            target = directory / source.name
            shutil.copyfile(source, target)
            fingerprints[source.name] = hashlib.sha256(target.read_bytes()).hexdigest()
        config = self.root / "fonts.conf"
        config.write_text('<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
                          f'<fontconfig><dir>{escape(str(directory))}</dir>'
                          f'<cachedir>{escape(str(self.root / "cache/fonts"))}</cachedir>'
                          '<alias><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>'
                          '<alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family></prefer></alias>'
                          # Color bitmap fonts need the same strike scaling as ordinary
                          # Fontconfig configurations; otherwise emoji render at 109 px.
                          '<match target="font"><test name="outline"><bool>false</bool></test>'
                          '<edit name="pixelsizefixupfactor" mode="assign"><divide>'
                          '<name target="pattern">pixelsize</name><name target="font">pixelsize</name>'
                          '</divide></edit></match>'
                          '<match target="font"><test name="outline"><bool>false</bool></test>'
                          '<test name="pixelsizefixupfactor" compare="not_eq"><double>1.0</double></test>'
                          '<edit name="matrix" mode="assign"><times><name>matrix</name><matrix>'
                          '<name>pixelsizefixupfactor</name><double>0</double><double>0</double>'
                          '<name>pixelsizefixupfactor</name></matrix></times></edit>'
                          '<edit name="size" mode="assign"><divide><name>size</name>'
                          '<name>pixelsizefixupfactor</name></divide></edit></match>'
                          '</fontconfig>')
        self.env["FONTCONFIG_FILE"] = str(config)
        self.bundle.manifest["metadata"]["fonts"] = fingerprints

    def _roundtrip(self):
        # wayland-info itself performs the protocol handshake, with a bounded process below.
        path = self.root / "runtime/zrct"
        if not path.exists():
            return False
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(.1)
            try:
                connection.connect(str(path))
                return True
            except OSError:
                return False

    def launch(self, name, argv, *, cwd=None, env=None, category="infrastructure", stdin=None):
        process = Process(name, argv, cwd=cwd or self.root, env={**self.env, **(env or {})},
                          bundle=self.bundle, category=category, stdin=stdin)
        self.processes.append(process)
        return process

    def health(self):
        for process in self.processes:
            if not process.closed and (process.name in ("weston", "dbus") or process.category == "fixture"):
                process.check()

    def capture_failure(self):
        prefix = os.environ.get("ZRCT_WESTON_PREFIX")
        helper = str(Path(prefix) / "bin/weston-screenshooter") if prefix else executable("weston-screenshooter")
        if not helper or not Path(helper).exists():
            self.bundle.manifest["collection_errors"].append("External capture: weston-screenshooter is unavailable")
            return
        before = set(self.bundle.root.glob("*.png"))
        process = None
        try:
            process = self.launch("external-capture", [helper], cwd=self.bundle.root)
            process.wait(2)
            for path in set(self.bundle.root.glob("*.png")) - before:
                self.bundle.artifact(path, "screenshot", boundary="compositor_output")
        except Exception as error:
            self.bundle.manifest["collection_errors"].append(f"External capture: {error}")
        finally:
            if process:
                process.stop()

    def __exit__(self, *exc):
        for process in reversed(self.processes):
            try:
                process.stop()
            except Exception as error:
                self.bundle.manifest["collection_errors"].append(f"cleanup {process.name}: {error}")
        if self.temp:
            self.temp.cleanup()
        self.bundle.save()
