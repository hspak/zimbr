"""Real two-set Korean keystrokes through Wayland, SDL, IBus, and ibus-hangul."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

from zrct import Suite, TestCase
from zrct.desktop import DesktopInput
from zrct.process import until

from support import relay

SUITE = Suite("zimbr-korean-ime", setup=relay, timeout=90,
              desktop_input=True, boundary="compositor_input+ibus-hangul")


class Korean(TestCase):
    def setUp(self):
        desktop = self.context.desktop
        prefix = Path(os.environ.get("ZIMBR_IBUS_PREFIX", "/usr")).resolve()
        schemas = desktop.root / "ime-schemas"
        schemas.mkdir()
        for name in ("org.freedesktop.ibus", "org.freedesktop.ibus.engine.hangul"):
            shutil.copyfile(prefix / "share/glib-2.0/schemas" / (name + ".gschema.xml"),
                            schemas / (name + ".gschema.xml"))
        (schemas / "korean.gschema.override").write_text(
            "[org.freedesktop.ibus.engine.hangul]\ninitial-input-mode='hangul'\n"
            "[org.freedesktop.ibus.general]\nuse-system-keyboard-layout=true\n")
        subprocess.run(["glib-compile-schemas", schemas], check=True)
        desktop.env.update(
            IBUS_ADDRESS=f"unix:path={desktop.root}/runtime/ibus",
            SDL_IM_MODULE="ibus",
            GSETTINGS_SCHEMA_DIR=str(schemas),
            GSETTINGS_BACKEND="memory",
            IBUS_USE_PORTAL="0",
            LD_LIBRARY_PATH=f"{prefix}/lib:" + desktop.env.get("LD_LIBRARY_PATH", ""),
        )
        font_path, languages = subprocess.check_output(
            ["fc-match", "-f", "%{file}\n%{lang}", "sans-serif:lang=ko"], text=True).split("\n")
        self.assertIn("ko", languages.split("|"), "Install a font with Hangul coverage")
        font = Path(font_path)
        shutil.copyfile(font, desktop.root / "fonts" / font.name)
        self.context.bundle.manifest["metadata"]["fonts"][font.name] = hashlib.sha256(font.read_bytes()).hexdigest()
        daemon = desktop.launch("ibus", [prefix / "bin/ibus-daemon", "--single", "--cache=none",
                                        "--address=" + desktop.env["IBUS_ADDRESS"]])
        until(lambda: (desktop.root / "runtime/ibus").exists(), timeout=5,
              condition="private IBus listener", health=daemon.check)
        config_path = prefix / "lib/ibus/ibus-dconf"
        if not config_path.exists():
            config_path = prefix / "libexec/ibus-dconf"
        config = desktop.launch("ibus-config", [config_path])

        def config_ready():
            result = subprocess.run([
                "gdbus", "call", "--address", desktop.env["IBUS_ADDRESS"],
                "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
                "--method", "org.freedesktop.DBus.NameHasOwner", "org.freedesktop.IBus.Config",
            ], env=desktop.env, capture_output=True, text=True, timeout=3)
            return result.returncode == 0 and "true" in result.stdout

        until(config_ready, timeout=5, condition="private IBus config", health=config.check)
        engine_path = prefix / "lib/ibus/ibus-engine-hangul"
        if not engine_path.exists():
            engine_path = prefix / "libexec/ibus-engine-hangul"
        engine = desktop.launch("hangul", [engine_path])

        def select_engine():
            result = subprocess.run([prefix / "bin/ibus", "engine", "hangul"],
                                    env=desktop.env, capture_output=True, timeout=3)
            (self.context.bundle.root / "engine-selection.log").write_bytes(result.stdout + result.stderr)
            return result.returncode == 0

        until(select_engine, timeout=10, condition="Hangul engine selected", health=engine.check)
        self.relay = self.context.fixture
        # SDL's IBus backend expects this override to name an address file;
        # libibus itself expects the address string used by the engine above.
        address_file = desktop.root / "ibus.address"
        address_file.write_text("IBUS_ADDRESS=" + desktop.env["IBUS_ADDRESS"] + "\n")
        self.app = self.relay.launch(env={"IBUS_ADDRESS": str(address_file)})
        self.app.target(role="row", text="alice").expect_visible(timeout=15)
        self.app.target(role="row", text="alice").click()
        self.desktop = DesktopInput(self.context)
        self.desktop.click("composer")

    def key(self, code):
        self.desktop.command(f"key {code} 1")
        try:
            self.app.act("frame")
        finally:
            self.desktop.command(f"key {code} 0")
        self.app.act("frame")

    def preedit(self, text, committed=""):
        self.app.target("ime-preedit").expect(value=text)
        self.app.target("composer").expect(value=committed)

    def test_two_set_composition_backspace_commit_and_send(self):
        # g k s -> 한; Backspace removes the final jamo, not committed text.
        for code, syllable in ((34, "ㅎ"), (37, "하"), (31, "한"), (14, "하"), (31, "한")):
            self.key(code)
            self.preedit(syllable)
        for code, syllable in ((19, "ㄱ"), (50, "그"), (33, "글")):
            self.key(code)
            self.preedit(syllable, "한")
        self.relay.expect_no_sends()
        self.key(28)
        self.app.target("ime-preedit").expect_absent()
        self.app.target("composer").expect(value="한글")
        self.relay.expect_no_sends()
        self.relay.expect_draft(self.app, "한글")
        self.key(28)
        self.app.target(role="message", text="한글").expect(status="delivered")
        self.relay.expect_sent_once("한글", chat=1)

    def test_send_button_confirms_the_last_syllable(self):
        for code, syllable in ((34, "ㅎ"), (37, "하"), (31, "한")):
            self.key(code)
            self.preedit(syllable)
        self.desktop.click("send-button")
        self.app.target(role="message", text="한").expect(status="delivered")
        self.relay.expect_sent_once("한", chat=1)

    def test_focus_change_confirms_korean_in_the_original_field(self):
        # dkssudgktpdy -> 안녕하세요, including resyllabification across keystrokes.
        for code in (32, 37, 31, 31, 22, 32, 34, 37, 20, 25, 32, 21):
            self.key(code)
        self.preedit("요", "안녕하세")
        self.app.screenshot(self.context.bundle.root / "korean-preedit.png")
        self.desktop.click("search")
        self.app.target("ime-preedit").expect_absent()
        self.app.target("search").expect(value="")
        self.app.target("composer").expect(value="안녕하세요")
        self.relay.expect_draft(self.app, "안녕하세요")
        self.key(19)
        self.app.target("ime-preedit").expect(value="ㄱ")
        self.key(37)
        self.app.target("ime-preedit").expect(value="가")
        self.desktop.click("composer")
        self.app.target("search").expect(value="가")
        self.app.target("composer").expect(value="안녕하세요")
        self.app.target("ime-preedit").expect_absent()
        self.relay.expect_no_sends()

    def test_paste_confirms_the_syllable_and_inserts_clipboard_text(self):
        self.desktop.set_clipboard(" 붙임")
        self.desktop.activate()
        for code, syllable in ((34, "ㅎ"), (37, "하"), (31, "한")):
            self.key(code)
            self.preedit(syllable)
        self.desktop.press("left_control+v")
        self.app.target("ime-preedit").expect_absent()
        self.app.target("composer").expect(value="한 붙임")
        self.relay.expect_no_sends()
        self.desktop.click("send-button")
        self.app.target(role="message", text="한 붙임").expect(status="delivered")
        self.relay.expect_sent_once("한 붙임", chat=1)
