"""Rich content controls, asynchronous image recovery, and composer focus."""
from dataclasses import replace

from zrct import TestCase

import scenarios

SUITE = replace(scenarios.SUITE, name="zimbr-content", desktop_input=False)


class Content(TestCase):
    def launch(self, fault="none"):
        self.relay = self.context.fixture
        self.relay.command("rich_content")
        self.relay.fault(fault)
        self.app = self.relay.launch()
        self.app.resize(1120, 1200)
        self.app.target(role="row", text="alice").expect_visible(timeout=15)
        self.app.target(role="row", text="alice").click()
        message = self.app.target(role="message", text="Photos and reactions 👋")
        message.expect_visible(timeout=20)
        self.message = message.resolve()["id"]
        self.draft = "Keep this draft while inspecting content 👩‍💻"
        self.app.target("composer").type_text(self.draft)
        self.relay.expect_draft(self.app, self.draft)
        return self.app

    def images(self):
        return [t for t in self.app.inspect(role="button", within=self.message)
                if "/attachment/" in t["id"]]

    def test_viewer_navigation_and_keyboard_focus_preserve_draft(self):
        app = self.launch()
        app.expect("both image controls are available", lambda: len(self.images()) == 2, timeout=20)
        first = sorted(self.images(), key=lambda t: t["bounds"]["y"])[0]
        app.target(first["id"]).scroll_into_view("history", direction=1).click()
        viewer = app.target("viewer-image")
        viewer.expect(label="photo-0.heic", status="ready", timeout=20)
        first_id = viewer.resolve()["value"]
        app.type_text("Must not edit the hidden composer")
        app.target("viewer-next").click()
        viewer.expect(label="photo-1.heic", status="ready", timeout=20)
        self.assertNotEqual(viewer.resolve()["value"], first_id)
        app.press("left")
        viewer.expect(label="photo-0.heic", value=first_id, status="ready")
        app.press("escape")
        viewer.expect_absent()
        app.target("composer").expect(value=self.draft)
        self.relay.expect_draft(app, self.draft)
        self.relay.expect_no_sends()

    def test_viewer_retry_recovers_failed_asset_without_mutating_draft(self):
        app = self.launch("fail_viewer")
        app.expect("image controls are available", lambda: len(self.images()) == 2, timeout=20)
        image = sorted(self.images(), key=lambda t: t["bounds"]["y"])[0]
        app.target(image["id"]).scroll_into_view("history", direction=1).click()
        app.target("viewer-image").expect(status="unavailable", timeout=15)
        app.target("viewer-retry").expect_interactable()
        before = self.relay.command("faults")["calls"]
        viewer_requests = sum(count for path, count in before.items() if path.endswith("/viewer"))
        self.assertGreaterEqual(viewer_requests, 1)
        self.relay.fault("none")
        app.target("viewer-retry").click()
        app.target("viewer-image").expect(status="ready", timeout=15)
        after = self.relay.command("faults")["calls"]
        self.assertGreater(sum(count for path, count in after.items() if path.endswith("/viewer")),
                           viewer_requests)
        app.target("viewer-close").click()
        app.target("composer").expect(value=self.draft)
        self.relay.expect_no_sends()

    def test_idle_viewer_retries_failed_asset_without_input(self):
        app = self.launch("fail_viewer")
        app.expect("image controls are available", lambda: len(self.images()) == 2, timeout=20)
        image = sorted(self.images(), key=lambda t: t["bounds"]["y"])[0]
        app.target(image["id"]).scroll_into_view("history", direction=1).click()
        app.target("viewer-image").expect(status="unavailable", timeout=15)
        app.expect_idle(quiet=.75)
        self.relay.fault("none")
        app.target("viewer-image").expect(status="ready", timeout=15)
        app.target("viewer-close").click()
        app.target("composer").expect(value=self.draft)
        self.relay.expect_no_sends()

    def test_reaction_details_update_and_preserve_composer_focus(self):
        app = self.launch()
        def reactions():
            return [t for t in app.inspect(role="button", within=self.message) if "/reaction/" in t["id"]]
        app.expect("reaction details are enriched", reactions, timeout=20)
        app.target(reactions()[0]["id"]).scroll_into_view("history").click()
        detail = app.target("content-detail")
        app.expect("reaction detail identifies peer and self", lambda:
                   "alice@example.invalid" in detail.read_text() and "You (your reaction)" in detail.read_text())
        app.type_text("Must not edit the hidden composer")
        self.relay.command("remove_self_reaction")
        app.expect("open details follow reaction removal", lambda:
                   "alice@example.invalid" in detail.read_text() and "You (your reaction)" not in detail.read_text(),
                   timeout=20)
        app.target("content-close").click()
        detail.expect_absent()
        app.target("composer").expect(value=self.draft)
        self.relay.expect_draft(app, self.draft)
        self.relay.expect_no_sends()
