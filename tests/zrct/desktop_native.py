"""SDL/Wayland contracts using Zrct's compositor, without application instrumentation."""
import json
import socket
import subprocess

from zrct import Suite, TestCase
from zrct.environment import executable, platform_directory
from zrct.process import until

SUITE = Suite("zimbr-sdl-desktop", timeout=90, desktop_input=True, boundary="compositor_input")


class NativeDesktop(TestCase):
    def command(self, command):
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as client:
            client.settimeout(3)
            client.connect(self.context.desktop.env["ZRCT_DESKTOP_SOCKET"])
            client.sendall(command.encode())
            result = json.loads(client.recv(4096))
        self.assertNotIn("error", result, (command, result))
        return result

    def launch_probe(self):
        probe = self.context.desktop.launch(
            "desktop-probe", [self.context.suite.executable],
            stdin=subprocess.PIPE, category="application")
        self.expect_line(probe, "ready")
        until(lambda: self.surface_exists(), timeout=5, condition="probe window", health=probe.check)
        self.command("activate zimbr")
        return probe

    def surface_exists(self):
        try:
            self.command("geometry zimbr")
            return True
        except AssertionError:
            return False

    def expect_line(self, process, line, occurrences=1):
        until(lambda: process.stdout_path.read_text().splitlines().count(line) >= occurrences, timeout=5,
              condition=line, health=process.check)

    def tell(self, process, command):
        process.child.stdin.write((command + "\n").encode())
        process.child.stdin.flush()

    def test_live_output_scale_updates_framebuffer(self):
        probe = self.launch_probe()
        self.tell(probe, "size")
        original = "size 780 560 780 560 1.000"
        self.expect_line(probe, original)
        count = probe.stdout_path.read_text().splitlines().count(original)
        self.command("scale 2")
        self.expect_line(probe, "size 780 560 1560 1120 2.000")
        self.command("scale 1")
        self.expect_line(probe, original, occurrences=count + 1)
        self.tell(probe, "quit")
        probe.wait(5)

    def test_clipboard_keys_and_resize(self):
        probe = self.launch_probe()
        self.tell(probe, "pixels")
        self.expect_line(probe, "pixels 17 93 201 255")
        self.tell(probe, "size")
        self.expect_line(probe, "size 780 560 780 560 1.000")
        self.tell(probe, "resize")
        self.expect_line(probe, "size 920 640 920 640 1.000")
        self.command("key 30 1")
        self.expect_line(probe, "key a")
        self.command("key 30 0")
        self.expect_line(probe, "text 61")

        copied = "Wayland clipboard 👋\n" * 300
        owner = self.context.desktop.launch("clipboard-owner", [executable("wl-copy"), "--foreground",
            "--type", "text/plain;charset=utf-8"], stdin=subprocess.PIPE)
        owner.child.stdin.write(copied.encode())
        owner.child.stdin.close()
        def read_external():
            result = subprocess.run([executable("wl-paste"), "--no-newline"],
                env=self.context.desktop.env, capture_output=True, timeout=3)
            return result.stdout.decode() if result.returncode == 0 else None
        until(lambda: read_external() == copied, timeout=5, condition="clipboard owner ready", health=owner.check)
        self.tell(probe, "clipboard")
        self.expect_line(probe, "clipboard " + copied.encode().hex())
        # wl-paste's fallback creates a focused surface on this compositor.
        # Restore the application's keyboard focus before requesting a copy.
        self.command("activate zimbr")
        self.command("key 30 1")
        self.expect_line(probe, "key a", occurrences=2)
        self.command("key 30 0")
        self.tell(probe, "copy")
        self.expect_line(probe, "copied")
        until(lambda: read_external() == "Z" * 8192, timeout=5, condition="application clipboard exported", health=probe.check)
        self.tell(probe, "quit")
        probe.wait(5)

    def test_raw_file_drop_preserves_unicode_and_rejects_malformed_offer(self):
        probe = self.launch_probe()
        helper = str(platform_directory() / "zrct-drop-client")
        for index, uris in enumerate((
            "file:///tmp/photo%20%F0%9F%91%8B.png\r\nfile://localhost/tmp/a%23b.txt\r\n",
            "file:///tmp/good\r\nfile:///tmp/bad%0G\r\n",
        )):
            source = self.context.desktop.launch(f"drop-source-{index}", [helper, uris])
            self.expect_line(source, "ready")
            self.command("activate zrct-dnd")
            self.command("move zrct-dnd 120 50")
            self.command("button 272 1")
            self.expect_line(source, "dragging")
            self.command("move zimbr 300 250")
            self.expect_line(probe, "hover 1", occurrences=index + 1)
            self.command("button 272 0")
            source.wait(5)
            self.assertIn("finished", source.stdout_path.read_text())
            if index == 0:
                self.expect_line(probe, "drop 2")
                self.expect_line(probe, "path " + "/tmp/photo 👋.png".encode().hex())
                self.expect_line(probe, "path " + b"/tmp/a#b.txt".hex())
            else:
                self.expect_line(probe, "rejected")
                self.assertEqual(1, probe.stdout_path.read_text().count("drop "))
        self.tell(probe, "quit")
        probe.wait(5)

    def start_held_drop(self, probe):
        source = self.context.desktop.launch("held-drop", [
            str(platform_directory() / "zrct-drop-client"), "file:///tmp/held.png\r\n", "--hold"],
            stdin=subprocess.PIPE)
        self.expect_line(source, "ready")
        self.command("activate zrct-dnd")
        self.command("move zrct-dnd 120 50")
        self.command("button 272 1")
        self.expect_line(source, "dragging")
        self.command("move zimbr 300 250")
        self.expect_line(probe, "hover 1")
        self.command("button 272 0")
        self.expect_line(source, "sending")
        return source

    def test_partial_drop_keeps_rendering_and_completes_after_release(self):
        probe = self.launch_probe()
        source = self.start_held_drop(probe)
        self.tell(probe, "pixels")
        until(lambda: "pixels 17 93 201 255" in probe.stdout_path.read_text(), timeout=1,
              condition="render during a partial drop", health=probe.check)
        self.assertNotIn("drop ", probe.stdout_path.read_text())
        self.tell(source, "release")
        self.expect_line(probe, "drop 1")
        self.expect_line(probe, "path " + b"/tmp/held.png".hex())
        source.wait(5)
        self.tell(probe, "quit")
        probe.wait(5)

    def test_stalled_drop_times_out_without_accepting_partial_paths(self):
        probe = self.launch_probe()
        source = self.start_held_drop(probe)
        self.expect_line(probe, "rejected")
        self.assertNotIn("drop ", probe.stdout_path.read_text())
        self.tell(source, "release")
        source.wait(5)
        self.tell(probe, "quit")
        probe.wait(5)

    def test_shutdown_closes_an_unfinished_drop(self):
        probe = self.launch_probe()
        source = self.start_held_drop(probe)
        self.tell(probe, "quit")
        probe.wait(1)
        self.tell(source, "release")
        source.wait(5)
