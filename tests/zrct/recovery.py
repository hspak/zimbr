"""GUI recovery over real TLS, with faults and effects owned by the relay fixture."""
from dataclasses import replace

from zrct import TestCase

import scenarios
from support import set_boundary

SUITE = replace(scenarios.SUITE, name="zimbr-recovery", desktop_input=False)


class Recovery(TestCase):
    def launch(self, fault="none"):
        self.relay = self.context.fixture
        self.relay.fault(fault)
        self.app = self.relay.launch()
        self.app.target(role="row", text="alice@example.invalid").expect_visible(timeout=15)
        self.app.target(role="row", text="alice@example.invalid").click()
        self.app.target("composer").expect_interactable()
        return self.app

    def posts(self):
        return self.relay.command("faults")["calls"].get("POST /v1/messages", 0)

    def test_reset_failure_lost_response_and_retry_preserve_then_clear_local_data(self):
        app = self.launch("reset_unsupported")
        draft = "Keep until the relay confirms reset 👋"
        app.target("composer").type_text(draft)
        self.relay.expect_draft(app, draft)
        media = self.relay.data / "media"
        media.mkdir(exist_ok=True)
        sentinel = media / ("a" * 64)
        sentinel.write_bytes(b"cached local media before reset")
        original = self.relay.command("status")["server_epoch"]
        app.target("settings").click()
        reset = app.target("settings-reset")
        reset.scroll_into_view("settings-form").click()
        reset.expect(label="Reset and resync")
        reset.click()
        app.expect("unsupported reset reports failure", lambda:
                   "Update the relay" in app.target("settings-form").resolve()["status"], timeout=15)
        self.assertEqual(self.relay.command("status")["server_epoch"], original)
        self.relay.expect_draft(app, draft)
        self.assertTrue(sentinel.is_file())

        self.relay.fault("reset_lost_response")
        reset.scroll_into_view("settings-form").click()
        app.expect("lost reset response preserves local state", lambda:
                   bool(app.target("settings-form").resolve()["status"]), timeout=15)
        changed = self.relay.command("status")["server_epoch"]
        self.assertNotEqual(changed, original)
        self.relay.expect_draft(app, draft)
        self.assertTrue(sentinel.is_file())

        self.relay.fault("none")
        reset.scroll_into_view("settings-form").click()
        app.target("settings-form").expect_absent(timeout=20)
        app.target(role="row", text="alice@example.invalid").expect_visible(timeout=20)
        app.target(role="row", text="alice@example.invalid").click()
        app.target("composer").expect(value="")
        self.assertEqual(self.relay.client_rows("SELECT count(*) FROM drafts"), [(0,)])
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.relay.command("status")["server_epoch"], changed)
        self.assertEqual(self.relay.command("faults")["epochs"], [original] * 3)
        self.relay.expect_no_sends()

    def test_held_upload_allows_draft_and_incoming_then_cancel_survives_restart(self):
        app = self.launch("hold_upload")
        set_boundary(self.context, "application_input+native_drop_handler")
        app.target("composer").drop([self.relay.paths[2]])
        caption = "Cancel this upload"
        app.target("composer").type_text(caption)
        app.target("send-button").expect(enabled=True)
        app.target("send-button").click()
        self.relay.channel.wait_event("held", timeout=15)
        pending = app.target(role="message", text=caption)
        pending.expect(status="uploading")
        next_draft = "Next draft while uploading 👋"
        app.target("composer").type_text(next_draft)
        self.relay.expect_draft(app, next_draft)
        incoming = "Live during attachment upload"
        self.relay.command("receive", text=incoming)
        app.target(role="message", text=incoming).expect_visible(timeout=10)
        request_id = pending.resolve()["id"].removeprefix("message/")
        app.target(pending.resolve()["id"] + "/recover").click()
        app.expect("cancelled upload committed", lambda: self.relay.client_rows(
            "SELECT state FROM outbox WHERE id=?", (request_id,)) == [("cancelled",)])
        self.relay.fault("none")
        app.restart()
        app.target(role="row", text="alice@example.invalid").expect_visible()
        app.target(role="row", text="alice@example.invalid").click()
        app.target("composer").expect(value=next_draft)
        app.expect_count("cancelled upload never submits a message", self.posts, 0, duration=.75)
        self.assertEqual(self.relay.client_rows(
            "SELECT count(*) FROM outgoing_files WHERE request_id=?", (request_id,)), [(1,)])
        self.relay.expect_no_sends()

    def test_unaccepted_send_is_not_replayed_on_restart(self):
        app = self.launch("lost_unaccepted_send")
        text = "No automatic resend after an uncertain response"
        app.target("composer").type_text(text)
        app.target("send-button").expect(enabled=True)
        app.target("send-button").click()
        app.expect("uncertain send is durable", lambda:
                   self.relay.client_rows("SELECT state FROM outbox") == [("unknown",)], timeout=15)
        app.restart()
        app.target(role="row", text="alice@example.invalid").expect_visible()
        app.target(role="row", text="alice@example.invalid").click()
        app.target("composer").expect(value="")
        app.expect_count("restart does not replay uncertain submission", self.posts, 1, duration=.75)
        self.relay.expect_no_sends()

    def test_accepted_send_with_lost_reply_is_delivered_once_across_restart(self):
        app = self.launch("lost_accepted_send")
        text = "Relay accepted this despite the lost reply 👋"
        app.target("composer").type_text(text)
        app.target("send-button").expect(enabled=True)
        app.target("send-button").click()
        self.relay.expect_sent_once(text, chat=1)
        app.restart()
        app.target(role="row", text="alice@example.invalid").expect_visible()
        app.target(role="row", text="alice@example.invalid").click()
        app.target(role="message", text=text).expect(status="delivered", timeout=20)
        app.expect_count("accepted send has one submission", self.posts, 1, duration=.75)
        self.relay.expect_sent_once(text, chat=1)

    def test_superseded_history_response_cannot_change_draft_or_send_route(self):
        app = self.launch()
        draft = "Alice draft must stay with Alice 👩‍💻"
        app.target("composer").type_text(draft)
        self.relay.expect_draft(app, draft)
        self.relay.fault("hold_history")
        group = app.target(role="row", text="Fixture group")
        group_id = group.resolve()["id"].removeprefix("conversation/")
        group.click()
        held = self.relay.channel.wait_event("held", timeout=15)
        self.assertEqual(held["method"], "GET")
        self.assertTrue(held["path"].startswith(f"/v1/conversations/{group_id}/messages?"))
        app.target(role="row", text="alice@example.invalid").click()
        self.relay.fault("none")
        app.target(role="row", text="alice@example.invalid").expect(selected=True)
        app.target("composer").expect(value=draft)
        app.expect_unchanged("late history cannot replace the selected draft",
                             lambda: app.target("composer").read_text(), expected=draft, duration=.5)
        app.target("send-button").expect(enabled=True)
        app.target("send-button").click()
        self.relay.expect_sent_once(draft, chat=1)
