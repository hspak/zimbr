"""Owned relay fixture, durable-effect assertions, and reading-anchor selection."""
from contextlib import closing, contextmanager
from dataclasses import replace
import json
from pathlib import Path
import subprocess
import sys
import sqlite3
import time

from zrct.errors import ExpectationFailed, ZrctError
from zrct.process import until


class Relay:
    def __init__(self, context):
        self.context = context
        repo = context.suite.repository
        self.process = context.desktop.launch("fixture", [sys.executable, Path(__file__).with_name("relay_worker.py"),
                                                          repo, context.bundle.root], cwd=repo, stdin=subprocess.PIPE)
        self.reader = self.process.stdout_path.open()
        self.buffer = ""
        self.ready = self._read(timeout=15)
        if not self.ready.get("ready"):
            raise ZrctError("Fixture did not publish readiness", observed=self.ready)
        context.bundle.manifest["metadata"]["fixture"] = {"kind": "zimbr synthetic TLS relay"}
        self.paths = self.ready["paths"]

    def _read(self, timeout=5):
        def line():
            if self.process.child.poll() is not None:
                self.process.drain()
            raw = self.reader.readline(65537)
            self.buffer += raw
            if len(self.buffer) > 65536:
                raise ZrctError("Fixture response exceeds 64 KiB")
            if self.buffer.endswith("\n"):
                response, self.buffer = self.buffer, ""
                return json.loads(response)
            self.process.check()
            return None
        return until(line, timeout=timeout, condition="fixture response")

    def command(self, op, **fields):
        self.process.check()
        self.process.child.stdin.write((json.dumps(dict(op=op, **fields)) + "\n").encode())
        self.process.child.stdin.flush()
        result = self._read()
        self.context.bundle.event("fixture_command", operation=op, fields=fields, result=result)
        if not result.get("ok"):
            raise ExpectationFailed("Fixture command failed", operation=op, observed=result)
        return result

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
            # Continue observing after delivery: an eventual count of one cannot catch late replay.
            deadline = time.monotonic() + .75
            while True:
                rows = result["rows"]
                if [r["text"] for r in rows] != expected or len(result["requests"]) != 1:
                    raise ExpectationFailed("Unexpected or duplicate relay sends", expected=expected, observed=result)
                if chat is not None and any(r["chat"] != chat for r in rows):
                    raise ExpectationFailed("Send reached the wrong conversation", expected=chat, observed=rows)
                if files:
                    self.command("verify_files", text=text, indices=list(files))
                if time.monotonic() >= deadline:
                    return result
                time.sleep(.05)
                result = self.command("sends")

    def expect_no_sends(self, *, duration=.5):
        with self.context.bundle.step("relay receives no sends", duration=duration):
            deadline = time.monotonic() + duration
            while True:
                result = self.command("sends")
                if result["requests"] or result["rows"]:
                    raise ExpectationFailed("Unexpected send", observed=result)
                if time.monotonic() >= deadline:
                    return
                time.sleep(.05)

    def close(self):
        try:
            if self.process.child.poll() is None:
                self.command("close")
                self.process.wait(5)
        finally:
            self.reader.close()
            self.process.stop()
            log = self.context.bundle.root / "relay.log"
            if log.exists():
                self.context.bundle.artifact(log, "log")


@contextmanager
def relay(context):
    fixture = Relay(context)
    try:
        yield fixture
    finally:
        fixture.close()


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
