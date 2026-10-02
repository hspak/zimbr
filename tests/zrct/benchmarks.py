"""Serial production-loop latency measurements with independent effect checks."""
from dataclasses import replace

from zrct import Benchmark, TestCase

import scenarios

SUITE = replace(scenarios.SUITE, name="zimbr-benchmarks", desktop_input=False,
                build=(*scenarios.SUITE.build, "-Doptimize=ReleaseSafe"),
                benchmark=Benchmark(
                    optimization="ReleaseSafe",
                    fixture={"kind": "indexed-synthetic-relay", "extra_messages": 10000,
                             "initial_conversation": "Fixture group"},
                    cache="fresh-process-and-private-app-state; OS-page-cache-uncontrolled; cached-switch-preopened",
                    fixture_files=(
                        "tests/zrct/support.py", "tests/zrct/relay_worker.py", "tests/zrct/relay_faults.py",
                        "tests/fixture.py", "tests/attachment_sends.py", "tests/attachment_uploads.py",
                        "tests/relay_tls.py", "tests/relay_fixture.py", "tools/tls_admin.py",
                        "tools/tls_support.py", "tools/http2.py", "tests/tls_fixture.py", "tests/http2_server.py",
                        "tests/client_media_transport.py", "zig-out/bin/fake-relay")))


class Workflows(TestCase):
    def setUp(self):
        self.relay = self.context.fixture
        seeded = self.relay.command("benchmark_history", count=10000, timeout=60)
        self.assertEqual(seeded["source_messages"], seeded["indexed_messages"])

    def launch(self):
        app = self.relay.launch()
        app.target(role="row", text="Fixture group").expect(selected=True, timeout=30)
        app.target(role="message", text="Benchmark initial conversation").expect_visible(timeout=30)
        return app

    def test_startup(self):
        app = self.context.benchmark.startup("startup_to_conversations", self.relay.launch,
                    ready=dict(role="row", text="alice", enabled=True), timeout=30)
        app.target(role="row", text="Fixture group").expect_visible()
        app.target(role="row", text="alice").expect_interactable()

    def test_first_open_large_history(self):
        app = self.launch()
        alice = app.target(role="row", text="alice")
        self.context.benchmark.action("first_open_large_history", alice.click,
                    ready=dict(role="message", text="Reading anchor 9999"), timeout=30)
        alice.expect(selected=True)
        app.target("composer").expect_interactable()
        self.assertGreater(int(app.target("history").resolve()["value"]), 0)

    def test_cached_conversation_switch(self):
        app = self.launch()
        alice = app.target(role="row", text="alice")
        alice.click()
        app.target(role="message", text="Reading anchor 9999").expect_visible(timeout=30)
        app.target("composer").type_text("Retained cached draft 👋")
        self.relay.expect_draft(app, "Retained cached draft 👋")
        app.target(role="row", text="Fixture group").click()
        app.target(role="message", text="Benchmark initial conversation").expect_visible()
        self.context.benchmark.action("cached_conversation_switch", alice.click,
                    ready=dict(role="message", text="Reading anchor 9999"))
        alice.expect(selected=True)
        app.target("composer").expect(value="Retained cached draft 👋")

    def test_search(self):
        app = self.launch()
        search = app.target("search")
        search.type_text("no matching conversation")
        app.target(role="row", text="Fixture group").expect_absent()
        app.press("left_control+a")
        self.context.benchmark.action("search_to_matching_row", lambda: app.type_text("Fixture group"),
                    ready=dict(role="row", text="Fixture group", enabled=True))
        search.expect(value="Fixture group")
        app.target(role="row", text="alice").expect_absent()

    def test_send_to_delivered(self):
        app = self.launch()
        app.target(role="row", text="alice").click()
        app.target(role="message", text="Reading anchor 9999").expect_visible(timeout=30)
        text = "Measured send 👩‍💻"
        app.target("composer").type_text(text)
        app.target("send-button").expect(enabled=True)
        self.context.benchmark.action("send_to_delivered", app.target("send-button").click,
                    ready=dict(role="message", text=text, status="delivered"), timeout=30)
        app.target("composer").expect(value="")
        self.relay.expect_sent_once(text, chat=1)
