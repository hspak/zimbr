"""Operation-specific faults in front of the real, private synthetic TLS relay."""
from collections import Counter
from contextlib import closing
import http.client
import http.server
import threading

from tls_fixture import TLSServer


class Faults:
    modes = {"none", "reset_unsupported", "reset_lost_response", "hold_upload",
             "hold_history", "lost_unaccepted_send", "lost_accepted_send", "fail_viewer"}

    def __init__(self, fixture, publish):
        self.fixture, self.publish = fixture, publish
        self.mode = "none"
        self.release = threading.Event()
        self.lock = threading.Lock()
        self.calls = Counter()
        self.epochs = []
        self.held = 0
        owner = self

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self): self.forward()
            def do_POST(self): self.forward()
            def do_PUT(self): self.forward()

            def reply(self, status, raw, *, content_type="application/json", incomplete=False):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(raw) + int(incomplete)))
                self.end_headers()
                self.wfile.write(raw)
                self.close_connection = True

            def forward(self):
                with owner.lock:
                    mode = owner.mode
                    owner.calls[self.command + " " + self.path.split("?", 1)[0]] += 1
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                reset = self.command == "POST" and self.path == "/v1/reset"
                send = self.command == "POST" and self.path == "/v1/messages"
                if reset:
                    import json
                    with owner.lock:
                        owner.epochs.append(json.loads(body)["server_epoch"])
                    if mode == "reset_unsupported":
                        return self.reply(404, b"{}")
                if send and mode == "lost_unaccepted_send":
                    return self.reply(202, b"{", incomplete=True)
                if mode == "fail_viewer" and self.path.startswith("/v1/assets/") and self.path.endswith("/viewer"):
                    return self.reply(503, b"{}")
                with closing(fixture.tls.connection(timeout=30)) as connection:
                    headers = {name: self.headers[name] for name in ("Content-Type", "Zimbr-Server-Epoch")
                               if name in self.headers}
                    connection.request(self.command, self.path,
                                       body if self.command in ("POST", "PUT") else None, headers)
                    response = connection.getresponse()
                    if self.path.startswith("/v1/events") and response.status == 200:
                        self.send_response(200)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Zimbr-Event-Extensions", response.getheader("Zimbr-Event-Extensions", ""))
                        self.end_headers()
                        frame = bytearray()
                        try:
                            while line := response.readline():
                                frame.extend(line)
                                if line.strip():
                                    continue
                                if mode != "lost_accepted_send" or b"event: send_request.updated" not in frame:
                                    self.wfile.write(frame)
                                frame.clear()
                        except (OSError, http.client.HTTPException):
                            pass
                        return
                    raw = response.read()
                    if ((mode == "hold_upload" and self.command == "PUT") or
                            (mode == "hold_history" and self.command == "GET" and
                             self.path.startswith("/v1/conversations/") and "/messages" in self.path)):
                        with owner.lock:
                            owner.held += 1
                        owner.publish("held", dict(method=self.command, path=self.path))
                        if not owner.release.wait(timeout=30):
                            return self.reply(504, b"{}")
                    self.reply(response.status, raw,
                               content_type=response.getheader("Content-Type", "application/json"),
                               incomplete=(reset and mode == "reset_lost_response") or
                                          (send and mode == "lost_accepted_send"))

        self.server = TLSServer(Proxy, fixture.tls.server_context())

    def set(self, mode):
        if mode not in self.modes:
            raise ValueError(f"Unknown relay fault: {mode}")
        with self.lock:
            self.mode = mode
            if mode.startswith("hold_"):
                self.release.clear()
            else:
                self.release.set()

    def snapshot(self):
        with self.lock:
            return dict(ok=True, calls=dict(self.calls), epochs=list(self.epochs), held=self.held)

    def close(self):
        self.release.set()
        self.server.close()
