"""Version 1: newline-delimited JSON, one bounded request per connection."""
import json
import socket
import time

from .errors import ProtocolError, Unsupported, DeadlineExceeded

VERSION = 1
MAX_MESSAGE = 1024 * 1024


class Connection:
    def __init__(self, path, timeout=5):
        self.path, self.timeout = str(path), timeout
        self.serial = 0

    def request(self, operation, *, timeout=None, **params):
        self.serial += 1
        request = dict(version=VERSION, id=self.serial, op=operation, **params)
        raw = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        if len(raw) > 65536:
            raise ProtocolError("Request exceeds 64 KiB")
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            def remaining():
                value = deadline - time.monotonic()
                if value <= 0:
                    raise DeadlineExceeded(f"Protocol deadline: {operation}", socket=self.path)
                sock.settimeout(value)
            try:
                remaining()
                sock.connect(self.path)
                remaining()
                sock.sendall(raw)
                result = bytearray()
                while b"\n" not in result:
                    remaining()
                    chunk = sock.recv(min(65536, MAX_MESSAGE + 1 - len(result)))
                    if not chunk:
                        raise ProtocolError("Application closed an incomplete response")
                    result.extend(chunk)
                    if len(result) > MAX_MESSAGE:
                        raise ProtocolError("Response exceeds 1 MiB")
            except TimeoutError:
                raise DeadlineExceeded(f"Protocol deadline: {operation}", socket=self.path) from None
        try:
            response = json.loads(result)
            if not isinstance(response, dict) or response.get("id") != self.serial or response.get("version") != VERSION:
                raise ProtocolError("Response ID or protocol version mismatch")
            if response.get("error"):
                error = response["error"]
                cls = Unsupported if error["code"] == "unsupported" else ProtocolError
                raise cls(error["message"], code=error["code"], operation=operation,
                          frame_id=response.get("frame_id"))
            return response["result"]
        except (ValueError, KeyError, TypeError) as error:
            raise ProtocolError(f"Malformed response: {error}") from error
