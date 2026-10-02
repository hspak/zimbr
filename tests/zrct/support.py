"""Owned relay fixture, durable-effect assertions, and reading-anchor selection."""
from contextlib import closing, contextmanager
from dataclasses import replace
from pathlib import Path
import sys
import sqlite3

from zrct.errors import ExpectationFailed
from zrct.fixture import FixtureProcess
from zrct.process import until


class Relay:
    def __init__(self, context):
        self.context = context
        repo = context.suite.repository
        self.channel = FixtureProcess(context, "fixture",
                                      [sys.executable, Path(__file__).with_name("relay_worker.py"),
                                       repo, context.bundle.root], cwd=repo)
        self.process = self.channel.process
        try:
            self.ready = self.channel.wait_event("ready", timeout=15)
        except BaseException:
            self.channel.close()
            raise
        context.bundle.manifest["metadata"]["fixture"] = {"kind": "zimbr synthetic TLS relay"}
        self.paths = self.ready["paths"]

    def command(self, op, *, timeout=None, **fields):
        result = self.channel.request(op, timeout=timeout, **fields)
        if not result.get("ok"):
            raise ExpectationFailed("Fixture command failed", operation=op, observed=result)
        return result

    def fault(self, mode):
        result = self.command("fault", mode=mode)
        self.ready["args"] = result["args"]

    @property
    def data(self):
        return self.context.desktop.root / "state/client"

    def client_rows(self, sql, parameters=()):
        with closing(sqlite3.connect(f"file:{self.data / 'client.db'}?mode=ro", uri=True)) as db:
            return db.execute(sql, parameters).fetchall()

    def expect_draft(self, app, text):
        app.expect("draft committed to client database", lambda: self.client_rows(
            "SELECT text FROM drafts WHERE text=?", (text,)) == [(text,)])

    def launch(self, *, env=None):
        data = self.context.desktop.root / "state/client"
        data.mkdir(exist_ok=True, mode=0o700)
        return self.context.launch("--data-dir", data, *self.ready["args"], env=env)

    def expect_sent_once(self, text, *, files=(), chat=None):
        expected = [text] if text else []
        expected += [""] * len(files)
        def delivered():
            result = self.command("sends")
            return result if (len(result["requests"]) == 1
                              and result["requests"][0]["state"] == "delivered") else None
        with self.context.bundle.step("relay confirms exact send, route, and original bytes", expected=text):
            result = until(delivered, timeout=25, condition="delivered send", health=self.process.check)
            def exact():
                result = self.command("sends")
                if [r["text"] for r in result["rows"]] != expected or len(result["requests"]) != 1:
                    raise ExpectationFailed("Unexpected or duplicate relay sends", expected=expected, observed=result)
                if chat is not None and any(r["chat"] != chat for r in result["rows"]):
                    raise ExpectationFailed("Send reached the wrong conversation", expected=chat, observed=result)
                if files:
                    self.command("verify_files", text=text, indices=list(files))
                return True
            self.context.app.expect_always("exact send remains stable after delivery", exact,
                                           duration=.75, interval=.05)
            return result

    def expect_no_sends(self, *, duration=.5):
        self.context.app.expect_unchanged("relay receives no sends", lambda: self.command("sends"),
                                         expected=dict(ok=True, requests=[], rows=[]),
                                         duration=duration, interval=.05)

    def close(self):
        try:
            if self.process.child.poll() is None:
                self.command("close")
                self.process.wait(5)
        finally:
            self.channel.close()
            log = self.context.bundle.root / "relay.log"
            if log.exists():
                self.context.bundle.artifact(log, "log")


@contextmanager
def relay(context):
    fixture = Relay(context)
    try:
        yield fixture
    finally:
        failing = sys.exc_info()[0] is not None
        try:
            fixture.close()
        except Exception as cleanup:
            if not failing:
                raise
            context.bundle.manifest["collection_errors"].append(f"relay cleanup: {cleanup}")


def set_boundary(context, boundary):
    """Preserve this scenario's explicit input boundary through launches and restarts."""
    context.suite = replace(context.suite, boundary=boundary)
    context.bundle.manifest["boundary"] = boundary


def reading_anchor(app):
    targets = app.inspect(role="message", within="history")
    for target in targets:
        box, clip = target["bounds"], target["clip"]
        if target["visible"] and box["y"] >= clip["y"] and box["y"] + box["height"] <= clip["y"] + clip["height"]:
            return target["id"]
    raise ExpectationFailed("No fully visible message can serve as a reading anchor")
