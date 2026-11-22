"""Supervised JSON-line fixtures with correlated replies, events and bounded I/O."""
from collections import deque
import json
import math
import os
import select
import subprocess
import time

from .errors import DeadlineExceeded, ProtocolError, ZrctError


class FixtureProcess:
    """Sequential requests; unsolicited events are retained until wait_event consumes them.

    Requests: {id, op, ...fields}. Replies: {id, result} or {id, error}.
    Events: {event, data}. Helpers must flush each UTF-8 JSON line to stdout;
    diagnostics belong on stderr. Desktop supervision owns the process group.
    """
    message_limit = 65536
    event_limit = 1024
    transcript_limit = 8 * 1024 * 1024

    def __init__(self, context, name, argv, *, cwd=None, env=None, timeout=5):
        self.context, self.timeout = context, timeout
        self.process = context.desktop.launch(name, argv, cwd=cwd, env=env,
                                              category="fixture", stdin=subprocess.PIPE)
        self.reader = self.process.stdout_path.open("rb")
        self.buffer = bytearray()
        self.events = deque()
        self.serial = 0
        self.closed = False
        self.transcript = context.bundle.root / f"{name}.transcript.jsonl"
        self.transcript.touch()
        self.transcript_bytes = 0
        context.bundle.artifact(self.transcript, "fixture_transcript")
        os.set_blocking(self.process.child.stdin.fileno(), False)

    def _deadline(self, timeout):
        timeout = self.timeout if timeout is None else timeout
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("fixture timeout must be finite and positive")
        return time.monotonic() + timeout

    def _remaining(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DeadlineExceeded("Fixture channel deadline", fixture=self.process.name,
                                   transcript=str(self.transcript))
        return remaining

    def _record(self, direction, message):
        line = (json.dumps(dict(time_ns=time.monotonic_ns(), direction=direction, message=message),
                           ensure_ascii=False) + "\n").encode()
        if self.transcript_bytes + len(line) > self.transcript_limit:
            raise ProtocolError("Fixture transcript exceeds 8 MiB", transcript=str(self.transcript))
        with self.transcript.open("ab") as stream:
            stream.write(line)
        self.transcript_bytes += len(line)

    def _read(self, deadline):
        while True:
            self._remaining(deadline)
            # Drain a complete final reply before reporting an exited helper.
            if self.process.child.poll() is not None:
                self.process.drain()
                self._remaining(deadline)
            raw = self.reader.readline(self.message_limit + 1 - len(self.buffer))
            self.buffer.extend(raw)
            if len(self.buffer) > self.message_limit or self.process.truncated[0]:
                raise ProtocolError("Fixture response or stdout exceeds its bound")
            if self.buffer.endswith(b"\n"):
                try:
                    message = json.loads(self.buffer)
                except (ValueError, UnicodeError) as error:
                    raise ProtocolError(f"Malformed fixture JSON: {error}") from error
                self.buffer.clear()
                if not isinstance(message, dict):
                    raise ProtocolError("Fixture message must be an object")
                self._record("received", message)
                return message
            self.process.check()
            time.sleep(min(.01, self._remaining(deadline)))

    def _event(self, message):
        if "event" not in message:
            return False
        if "id" in message or not isinstance(message["event"], str):
            raise ProtocolError("Malformed fixture event", observed=message)
        if len(self.events) == self.event_limit:
            raise ProtocolError("Fixture event queue exceeds 1024 events")
        self.events.append(message)
        return True

    def request(self, operation, *, timeout=None, **fields):
        if self.closed:
            raise ZrctError("Fixture channel is closed")
        if "id" in fields or "op" in fields:
            raise ValueError("id and op are reserved fixture fields")
        deadline = self._deadline(timeout)
        self.process.check()
        self.serial += 1
        message = dict(id=self.serial, op=operation, **fields)
        raw = (json.dumps(message, ensure_ascii=False) + "\n").encode()
        if len(raw) > self.message_limit:
            raise ProtocolError("Fixture request exceeds 64 KiB")
        self._record("sent", message)
        offset = 0
        fd = self.process.child.stdin.fileno()
        while offset < len(raw):
            self.process.check()
            if not select.select([], [fd], [], min(.02, self._remaining(deadline)))[1]:
                continue
            try:
                offset += os.write(fd, raw[offset:])
            except BlockingIOError:
                continue
            except BrokenPipeError:
                self.process.check()
                raise ProtocolError("Fixture closed its request stream") from None
        while True:
            message = self._read(deadline)
            if self._event(message):
                continue
            if (type(message.get("id")) is not int or message["id"] != self.serial
                    or ("result" in message) == ("error" in message)):
                raise ProtocolError("Fixture reply ID or structure mismatch", observed=message)
            if "error" in message:
                raise ZrctError("Fixture command failed", operation=operation, error=message["error"])
            return message["result"]

    def wait_event(self, name, *, timeout=None):
        deadline = self._deadline(timeout)
        while True:
            for message in self.events:
                if message["event"] == name:
                    self.events.remove(message)
                    return message.get("data")
            message = self._read(deadline)
            if not self._event(message):
                raise ProtocolError("Unexpected fixture reply while waiting for an event", observed=message)

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.process.stop()
        finally:
            self.reader.close()
            self.process.child.stdin.close()

    def __enter__(self):
        return self

    def __exit__(self, kind, error, traceback):
        try:
            self.close()
        except Exception as cleanup:
            if error is None:
                raise
            self.context.bundle.manifest["collection_errors"].append(f"fixture cleanup: {cleanup}")
            self.context.bundle.save()
