"""Real Wayland input via the pinned Weston backend and the application's SDL consumers."""
import json
from pathlib import Path
import socket
import subprocess

from .errors import Unsupported, ZrctError
from .process import until
from .keys import KEYS as KEY_TABLE, chord_names
from .driver import Target

KEYS = {name: key["evdev"] for name, key in KEY_TABLE.items()}


class DesktopInput:
    def __init__(self, context):
        self.context, self.app = context, context.app
        self.name = self.app.handshake["application"]
        self.socket = context.desktop.env.get("ZRCT_DESKTOP_SOCKET")
        if not self.socket:
            raise Unsupported('Suite must require "compositor_input" and build the Weston module with addRun(.desktop = true)')
        self.capabilities = self.command("hello")

    def command(self, text):
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as sock:
            sock.settimeout(2)
            sock.connect(self.socket)
            sock.sendall(text.encode())
            result = json.loads(sock.recv(4096))
        self.context.bundle.event("desktop_command", command=text, result=result)
        if "error" in result:
            raise ZrctError(result["error"], command=text)
        if text.split(" ", 1)[0] in ("activate", "move", "button", "key", "scale"):
            self.context.bundle.observe_boundary("compositor_input", operation=text.split(" ", 1)[0])
        return result

    def activate(self):
        with self.app.step("compositor activate", boundary="compositor_input"):
            def mapped():
                try:
                    return self.command(f"activate {self.name}")
                except ZrctError as error:
                    if str(error) != "application surface is not mapped":
                        raise
                    return None
            # Semantic frames are published before presentation. Weston may
            # still be mapping the first buffer when the application is ready.
            result = until(mapped, timeout=self.app.timeout,
                           condition=f"mapped compositor surface for {self.name}", health=self.app.health)
            self.app.act("frame")
            return result

    def set_scale(self, scale):
        with self.app.step(f"compositor output scale {scale}", boundary="compositor_input"):
            self.command(f"scale {int(scale)}")
            self.app.expect(f"application observes output scale {scale}", lambda: self.app.inspect() is not None
                            and self.app.last["window"]["scale"] == scale)

    def move(self, target, *, timeout=None):
        target = target if isinstance(target, Target) else self.app.target(target)
        if isinstance(target, Target) and target.app is not self.app:
            raise ValueError("Desktop target must belong to this application")

        point = target.expect_interactable(timeout=timeout)
        return self.command(f"move {self.name} {point['x']} {point['y']}")

    def click(self, target, *, timeout=None):
        with self.app.step(f"compositor click {target}", boundary="compositor_input"):
            # Clipboard helpers and drag sources can take keyboard focus. SDL
            # consumes the first click on an unfocused window for activation.
            self.activate()
            # SDL can publish a resized layout before Weston updates the input region.
            until(lambda: self.move(target, timeout=timeout)["focused"],
                  timeout=self.app.timeout if timeout is None else timeout,
                  condition="compositor pointer over the click target", health=self.app.health)
            self.command("button 272 1")
            # Dispatch the flushed Wayland events before app consumers, then wait
            # for their completed frame. No screenshot encoding or delay is needed.
            try:
                self.app.act("frame")
            finally:
                self.command("button 272 0")
            self.app.act("frame")

    def press(self, chord):
        names = chord_names(chord)
        held = []
        with self.app.step(f"compositor press {chord}", boundary="compositor_input"):
            try:
                for name in names:
                    self.command(f"key {KEYS[name]} 1")
                    held.append(KEYS[name])
                self.app.act("frame")
            finally:
                for key in reversed(held):
                    self.command(f"key {key} 0")
            self.app.act("frame")

    def set_clipboard(self, text):
        from .environment import executable
        tool = executable("wl-copy")
        if not tool:
            raise Unsupported("wl-copy is required for the desktop clipboard fixture")
        process = self.context.desktop.launch("clipboard-owner", [tool, "--foreground", "--type", "text/plain;charset=utf-8"],
                                              stdin=subprocess.PIPE)
        process.child.stdin.write(text.encode())
        process.child.stdin.close()
        until(lambda: self.clipboard() == text, timeout=5, condition="Wayland clipboard ownership", health=process.check)
        self.context.bundle.observe_boundary("compositor_input", operation="set_clipboard")
        return process

    def clipboard(self):
        from .environment import executable
        tool = executable("wl-paste")
        if not tool:
            raise Unsupported("wl-paste is required for the desktop clipboard fixture")
        result = subprocess.run([tool, "--no-newline"], env=self.context.desktop.env,
                                capture_output=True, timeout=2)
        return result.stdout.decode() if result.returncode == 0 else None

    def drop_files(self, target, paths):
        from .environment import platform_directory
        helper = platform_directory() / "zrct-drop-client"
        if not helper.exists():
            raise Unsupported("Build the Wayland drop client with zig build desktop or enable addRun(.desktop = true)")
        uris = "\r\n".join(Path(p).resolve().as_uri() for p in paths) + "\r\n"
        with self.app.step(f"Wayland file drop on {target}", boundary="compositor_input"):
            source = self.context.desktop.launch("drop-source", [helper, uris])
            until(lambda: "ready" in source.stdout_path.read_text(), timeout=5,
                  condition="drop source window", health=source.check)
            self.command("activate zrct-dnd")
            self.command("move zrct-dnd 120 50")
            self.command("button 272 1")
            try:
                until(lambda: "dragging" in source.stdout_path.read_text(), timeout=5,
                      condition="Wayland drag start with pointer serial", health=source.check)
                self.move(target)
                self.app.act("frame")
            finally:
                self.command("button 272 0")
            source.wait(5)
            if "finished" not in source.stdout_path.read_text():
                raise ZrctError("Compositor drag was cancelled; data transfer did not finish")
