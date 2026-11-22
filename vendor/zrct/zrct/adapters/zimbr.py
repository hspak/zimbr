from contextlib import contextmanager
from pathlib import Path
import sys

from ..errors import ExpectationFailed
from ..process import until
from ..fixture import FixtureProcess


class Relay:
    def __init__(self, context):
        self.context = context
        repo = context.suite.repository
        self.channel = FixtureProcess(context, "fixture", [sys.executable, Path(__file__).with_name("relay_helper.py"),
                                                           repo, context.bundle.root], cwd=repo)
        self.process = self.channel.process
        self.ready = self.channel.wait_event("ready", timeout=15)
        context.bundle.manifest["metadata"]["fixture"] = {"kind": "zimbr synthetic TLS relay"}
        self.paths = self.ready["paths"]

    def command(self, op, **fields):
        return self.channel.request(op, **fields)

    def launch(self):
        data = self.context.desktop.root / "state/client"
        data.mkdir(exist_ok=True, mode=0o700)
        return self.context.launch("--data-dir", data, *self.ready["args"])

    def expect_sent_once(self, text):
        last = None
        def verified():
            nonlocal last
            last = self.command("sent_once", text=text)
            return last.get("ok")
        with self.context.bundle.step("relay independently confirms one delivered send", expected=text):
            until(verified, timeout=25, condition="one delivered send", health=self.process.check)
            self.context.app.expect_always("relay retains exactly one delivered send", verified,
                                           duration=.75, interval=.05)

    def verify_files(self, text):
        result = self.command("verify_files", text=text)
        if not result.get("ok"):
            raise ExpectationFailed("Attachment bytes differ from reviewed originals", observed=result)

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
    except BaseException:
        try:
            fixture.close()
        except Exception as cleanup:
            context.bundle.manifest["collection_errors"].append(f"fixture cleanup: {cleanup}")
        raise
    else:
        fixture.close()


def reading_anchor(app):
    targets = app.inspect(role="message", within="history")
    for target in targets:
        box, clip = target["bounds"], target["clip"]
        if target["visible"] and box["y"] >= clip["y"] and box["y"] + box["height"] <= clip["y"] + clip["height"]:
            return target["id"]
    raise ExpectationFailed("No fully visible message can serve as a reading anchor")
