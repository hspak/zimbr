"""Production-loop workflows with independent synthetic-relay effect checks."""
import configparser
import os
from pathlib import Path
import re

from zrct import Suite, TestCase
from zrct.desktop import DesktopInput

from support import relay, reading_anchor

REPOSITORY = Path(__file__).resolve().parents[2]
PREFIX = os.environ.get("ZRCT_OPENSSL_PREFIX", str(REPOSITORY / ".tools/openssl-3.5"))
SUITE = Suite("zimbr", REPOSITORY,
              ("zig", "build", "client", "fake-relay", "-Dautomation=true", f"-Dopenssl-prefix={PREFIX}"),
              "zig-out/bin/zimbr", setup=relay, timeout=90, desktop_input=True,
              width=2560, height=1600)


class Messages(TestCase):
    def setUp(self):
        self.relay = self.context.fixture
        self.app = self.relay.launch()
        self.app.target(role="row", text="alice").expect_visible(timeout=15)
        self.app.target(role="row", text="alice").click()
        self.app.target("composer").expect(visible=True, obscured=False)

    def test_send_unicode_and_persist(self):
        text = "Hello 👋 👩‍💻 é — a character queue longer than sixteen characters."
        self.app.target("composer").type_text(text)
        self.app.target("composer").expect(value=text)
        self.app.target("send-button").expect(enabled=True)
        self.app.target("send-button").click()
        self.app.target(role="message", text=text).expect(status="delivered")
        self.relay.expect_sent_once(text)
        self.app.restart()
        self.app.target(role="row", text="alice").expect_visible()
        self.app.target(role="row", text="alice").click()
        self.app.target(role="message", text=text).expect_visible()
        self.relay.expect_sent_once(text)

    def test_reviewed_attachments(self):
        self.context.bundle.manifest["boundary"] = "application_input+native_drop_handler"
        self.app.press("left_control+n")
        self.app.type_text("peer@example.invalid")
        self.app.press("enter")
        self.app.target("composer").expect(visible=True, obscured=False)
        text = "Reviewed caption 👋"
        self.app.target("composer").drop(self.relay.paths)
        self.app.target("send-button").expect(enabled=True)
        self.relay.command("stage")
        self.app.target("composer").type_text(text)
        self.app.target("send-button").click()
        self.relay.expect_sent_once(text, files=(0, 1, 2))

    def test_unicode_editing_undo_and_keyboard_send(self):
        composer = self.app.target("composer")
        composer.type_text("Keep 👩‍💻 é")
        self.app.press("backspace")
        composer.expect(value="Keep 👩‍💻 ")
        self.app.press("backspace")
        self.app.press("backspace")
        composer.expect(value="Keep ")
        self.app.press("left_control+z")
        composer.expect(value="Keep 👩‍💻")
        self.app.press("left_control+left_shift+z")
        composer.expect(value="Keep ")
        self.app.type_text("한글")
        self.app.press("left_shift+enter")
        self.app.type_text("Second line 👋")
        text = "Keep 한글\nSecond line 👋"
        composer.expect(value=text)
        self.relay.expect_no_sends()
        self.app.press("left_control+enter")
        composer.expect(value="")
        self.app.target(role="message", text=text).expect(status="delivered")
        self.relay.expect_sent_once(text, chat=1)

    def test_drafts_survive_switch_hide_incoming_and_restart(self):
        alice = self.app.target(role="row", text="alice")
        group = self.app.target(role="row", text="Fixture group")
        first, second = "Alice draft 👩‍💻", "Group draft é"
        self.app.target("composer").type_text(first)
        group.click()
        group.expect(selected=True)
        self.app.target("composer").expect(value="")
        self.app.target("composer").type_text(second)
        alice.click()
        self.app.target("composer").expect(value=first)
        self.relay.expect_draft(self.app, first)
        self.relay.expect_draft(self.app, second)
        self.app.target("conversation-visibility").click()
        alice.expect_absent()
        self.app.target("search").type_text("alice")
        alice.expect_absent()
        self.app.target("hidden").click()
        alice.expect_visible()
        alice.click()
        self.app.target("composer").expect(value=first)
        incoming = "Arrives while this conversation is hidden"
        self.relay.command("receive", text=incoming)
        self.app.target(role="message", text=incoming).expect_visible(timeout=15)
        self.app.restart()
        alice.expect_absent()
        self.app.target("hidden").click()
        alice.expect_visible()
        alice.click()
        self.app.target("composer").expect(value=first)
        self.app.target(role="message", text=incoming).expect_visible()
        self.app.target("conversation-visibility").expect(label="Unhide")
        self.app.target("conversation-visibility").click()
        self.app.target("messages").click()
        alice.expect_visible()
        group.click()
        self.app.target("composer").expect(value=second)
        self.relay.expect_no_sends()

    def test_review_remove_attachment_and_restart_before_sending(self):
        self.context.bundle.manifest["boundary"] = "application_input+native_drop_handler"
        self.app.target("composer").drop(self.relay.paths)
        self.app.target("draft-attachments").expect(value="3", label="photo 👋.png")
        self.app.target("send-button").expect(enabled=True)
        self.relay.command("stage")
        self.app.target("attachment-next").click()
        self.app.target("draft-attachments").expect(label="empty.txt")
        self.app.target("attachment-remove").click()
        self.app.target("draft-attachments").expect(value="2")
        text = "Only the reviewed remaining files 👋"
        self.app.target("composer").type_text(text)
        self.relay.expect_draft(self.app, text)
        self.relay.expect_no_sends()
        self.app.restart()
        self.app.target(role="row", text="alice").expect_visible()
        self.app.target(role="row", text="alice").click()
        self.app.target("composer").expect(value=text)
        self.app.target("draft-attachments").expect(value="2", label="photo 👋.png")
        self.app.target("send-button").expect(enabled=True)
        self.app.target("send-button").click()
        self.app.target("draft-attachments").expect_absent()
        self.relay.expect_sent_once(text, files=(0, 2), chat=1)

    def test_offline_restart_keeps_draft_until_explicit_send_after_reconnect(self):
        text = "Draft before the connection disappears 👋"
        self.app.target("composer").type_text(text)
        self.relay.expect_draft(self.app, text)
        self.relay.command("pause")
        self.app.restart()
        self.app.target(role="row", text="alice").expect_visible()
        self.app.target(role="row", text="alice").click()
        self.app.target("composer").expect(value=text)
        self.app.target("send-button").expect(enabled=False)
        self.app.press("left_control+end")
        self.app.type_text(" — edited offline")
        text += " — edited offline"
        self.app.target("composer").expect(value=text)
        self.relay.expect_draft(self.app, text)
        self.app.press("enter")
        self.app.target("composer").expect(value=text)
        self.relay.expect_no_sends()
        self.relay.command("resume")
        self.app.expect("relay reconnects and enables the retained draft", lambda:
                        self.app.target("send-button").resolve()["enabled"], timeout=20)
        self.relay.expect_no_sends()
        self.app.target("send-button").click()
        self.relay.expect_sent_once(text, chat=1)


class Settings(TestCase):
    def test_first_launch_validation_save_and_enter_preference(self):
        relay = self.context.fixture
        app = self.context.launch("--data-dir", relay.data)
        app.target("settings_relay").expect_visible()
        initial_settings = relay.client_rows("SELECT * FROM settings")
        app.press("escape")
        app.press("left_control+n")
        app.press("left_control+d")
        app.target("settings_relay").expect_visible()
        app.target("recipient").expect_absent()
        app.target("composer").expect_absent()
        app.target("messages").expect(enabled=False)
        app.target("settings-save").click()
        app.expect("invalid settings report an error", lambda: bool(
            app.target("settings-form").resolve()["status"]))
        self.assertEqual(relay.client_rows("SELECT * FROM settings"), initial_settings)
        invalid_url_error = app.target("settings-form").resolve()["status"]

        # A small window forces the credential fields through the clipped form viewport.
        app.resize(780, 560)
        fields = ("settings_relay", "settings_ca", "settings_cert", "settings_key")
        values = relay.ready["args"][1::2]
        for field, value in zip(fields, values):
            app.target(field).scroll_into_view("settings-form").type_text(value)
        app.target("settings_key").click()
        app.press("left_control+a")
        app.type_text(values[-1] + ".missing")
        app.target("settings-save").click()
        app.expect("unreadable credentials report a different error", lambda:
                   app.target("settings-form").resolve()["status"] not in ("", invalid_url_error))
        self.assertEqual(relay.client_rows("SELECT * FROM settings"), initial_settings)
        app.target("settings_key").click()
        app.press("left_control+a")
        app.type_text(values[-1])
        app.target("settings-enter-to-send").scroll_into_view("settings-form", direction=1).click()
        app.target("settings-enter-to-send").expect(label="Enter to send: Off")
        app.target("settings-save").click()
        app.target(role="row", text="alice").expect_visible(timeout=15)
        self.assertEqual(relay.client_rows("SELECT relay_url,enter_to_send FROM settings"),
                         [(values[0], 0)])
        app.restart()
        app.target(role="row", text="alice").expect_visible(timeout=15)
        app.target(role="row", text="alice").click()
        app.target("composer").type_text("Saved preference")
        app.press("enter")
        app.type_text("second line")
        text = "Saved preference\nsecond line"
        app.target("composer").expect(value=text)
        relay.expect_no_sends()
        app.press("left_control+enter")
        relay.expect_sent_once(text, chat=1)

    def test_cancel_settings_and_reset_confirmation_preserve_draft(self):
        relay = self.context.fixture
        app = relay.launch()
        app.target(role="row", text="alice").expect_visible(timeout=15)
        app.target(role="row", text="alice").click()
        draft = "Keep my unsent draft 👋"
        app.target("composer").type_text(draft)
        relay.expect_draft(app, draft)
        app.target("settings").click()
        app.target("settings_relay").click()
        app.press("left_control+a")
        app.type_text("https://unsaved.invalid")
        app.target("settings-reset").scroll_into_view("settings-form").click()
        app.target("settings-keep-data").scroll_into_view("settings-form").click()
        app.target("settings-keep-data").expect_absent()
        app.target("settings-cancel").click()
        app.target("composer").expect(value=draft)
        app.target("settings").click()
        app.target("settings_relay").expect(value=relay.ready["args"][1])
        app.target("settings-cancel").click()
        app.restart()
        app.target(role="row", text="alice").expect_visible()
        app.target(role="row", text="alice").click()
        app.target("composer").expect(value=draft)
        relay.expect_no_sends()


class Desktop(TestCase):
    def setUp(self):
        self.context.bundle.manifest["boundary"] = "compositor_input"
        self.relay = self.context.fixture
        self.app = self.relay.launch()
        self.desktop = DesktopInput(self.context)
        self.app.target(role="row", text="alice").expect_visible(timeout=15)
        self.desktop.activate()
        self.desktop.click(self.app.target(role="row", text="alice").resolve()["id"])
        self.app.target("composer").expect(visible=True, obscured=False)

    def test_clipboard_round_trip_resize_and_scale_preserve_draft(self):
        text = "External clipboard 👩‍💻 é\nSecond line 한글"
        self.desktop.set_clipboard(text)
        self.desktop.click("composer")
        self.desktop.press("left_control+v")
        self.app.target("composer").expect(value=text)
        self.app.resize(780, 560)
        self.desktop.set_scale(2)
        self.app.target("composer").expect(value=text)
        self.desktop.click("composer")
        self.desktop.press("left_control+a")
        self.desktop.press("left_control+c")
        self.app.expect("external reader sees the exact multiline selection",
                        lambda: self.desktop.clipboard() == text)
        self.desktop.set_scale(1)
        self.app.resize(1120, 780)
        self.desktop.click("send-button")
        self.app.target("composer").expect(value="")
        self.relay.expect_sent_once(text, chat=1)

    def test_wayland_attachment_only_drop_sends_original_bytes(self):
        self.desktop.drop_files("composer", self.relay.paths)
        self.app.target("draft-attachments").expect(value="3")
        self.app.target("send-button").expect(enabled=True)
        self.relay.expect_no_sends()
        self.relay.command("stage")
        self.desktop.activate()
        self.desktop.click("send-button")
        self.app.target("draft-attachments").expect_absent()
        self.relay.expect_sent_once("", files=(0, 1, 2), chat=1)

    def test_details_clipboard_clear_and_focus_do_not_edit_draft(self):
        draft = "Draft kept while inspecting diagnostics"
        self.desktop.set_clipboard(draft)
        self.desktop.click("composer")
        self.desktop.press("left_control+v")
        self.app.target("composer").expect(value=draft)
        self.desktop.click("details")
        self.app.expect("session logs are available", lambda: int(
            self.app.target("logs").resolve()["value"]) > 0)
        # Paste with a hidden composer must not mutate its draft.
        self.desktop.set_clipboard("Must not enter the hidden composer")
        self.desktop.press("left_control+v")
        self.desktop.click("logs-copy")
        self.app.expect("external clipboard receives session diagnostics", lambda:
                        re.search(r"\d{4}-\d{2}-\d{2}.*\w+\(\w+\): ",
                                  self.desktop.clipboard() or ""))
        copied = self.desktop.clipboard()
        self.assertNotIn("PRIVATE KEY", copied)
        self.desktop.click("logs-clear")
        self.app.target("logs").expect(value="0")
        self.desktop.press("escape")
        self.app.target("composer").expect(value=draft)
        self.relay.expect_no_sends()


class Application(TestCase):
    def test_wayland_identity_matches_installed_desktop_entry(self):
        # Preserve the assertions from tests/client_desktop.py in an isolated desktop.
        repository = self.context.suite.repository
        path = repository / "packaging/linux/zimbr.desktop"
        entry = configparser.ConfigParser(interpolation=None)
        entry.read(path)
        icon = entry["Desktop Entry"]["Icon"]
        self.assertTrue((path.parent / (icon + ".svg")).is_file())
        app = self.context.launch("--data-dir", self.context.fixture.data,
                                  env={"WAYLAND_DEBUG": "client"})
        app.target("settings_relay").expect_visible()
        def reported_ids():
            return re.findall(r'xdg_toplevel[^\n]*\.set_app_id\("([^"\n]*)"\)',
                              app.process.stderr_path.read_text())
        app.expect("Wayland client publishes its application identity", reported_ids)
        self.assertEqual(set(reported_ids()), {path.stem})


class History(TestCase):
    def test_history_and_incoming_preserve_reading_anchor(self):
        from zrct.recording import Recording
        relay = self.context.fixture
        relay.command("history", count=400)
        app = relay.launch()
        app.target(role="row", text="alice").expect_visible(timeout=15)
        app.target(role="row", text="alice").click()
        app.target("history").scroll(100)
        app.target("load-older").expect_visible(timeout=10)
        anchor = reading_anchor(app)
        original = app.target(anchor).resolve()["bounds"]["y"]
        count = int(app.target("history").resolve()["value"])
        with Recording(app, "reading") as recording:
            app.target("load-older").click()
            app.expect("older history is loaded", lambda: int(app.target("history").resolve()["value"]) > count)
            count = int(app.target("history").resolve()["value"])
            relay.command("receive", text="Incoming while reading older history")
            app.expect("incoming message is synchronized", lambda: int(app.target("history").resolve()["value"]) > count, timeout=10)
        recording.expect_anchor(anchor, tolerance=1, expected=original, visual=True)
        app.target("new-messages").expect_visible()
        app.target("new-messages").click()
        app.target(role="message", text="Incoming while reading older history").expect_visible()
        app.target("new-messages").expect_absent()
