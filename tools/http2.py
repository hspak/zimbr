"""Small synchronous HTTP/2 client for authenticated administration and wire tests.

The caller owns the TLS context. A connection can carry multiple response streams;
flow-control credit is returned when response bytes are consumed.
"""
from collections import deque
import http.client
import socket
import ssl

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset
from h2.exceptions import H2Error, StreamClosedError
from hyperframe.frame import Frame, GoAwayFrame
from hyperframe.exceptions import HyperframeError


class Response:
    def __init__(self, connection, stream_id):
        self.connection = connection
        self.stream_id = stream_id
        self.status = None
        self.headers = []
        self.buffer = bytearray()
        self.ended = False
        self.error = None
        self.received = 0
        self.fp = self

    def getheader(self, name, default=None):
        values = [v for k, v in self.headers if k == name.lower()]
        return ', '.join(values) if values else default

    def getheaders(self):
        return self.headers.copy()

    def _take(self, count):
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        if self.connection.sock is not None:
            self.connection.h2.acknowledge_received_data(len(result), self.stream_id)
            self.connection._flush()
        if self.ended and not self.buffer:
            self.connection.responses.pop(self.stream_id, None)
        return result

    def read(self, amount=None):
        if amount is not None and amount < 0:
            amount = None
        result = bytearray()
        while amount is None or len(result) < amount:
            if self.buffer:
                result += self._take(len(self.buffer) if amount is None else min(len(self.buffer), amount-len(result)))
            elif self.error:
                raise http.client.HTTPException(self.error)
            elif self.ended:
                self.connection.responses.pop(self.stream_id, None)
                break
            else:
                self.connection._receive()
        return bytes(result)

    def readline(self, limit=-1):
        result = bytearray()
        while limit < 0 or len(result) < limit:
            if self.buffer:
                end = self.buffer.find(b'\n')
                count = len(self.buffer) if end < 0 else end+1
                if limit >= 0:
                    count = min(count, limit-len(result))
                result += self._take(count)
                if result.endswith(b'\n'):
                    break
            elif self.error:
                raise http.client.HTTPException(self.error)
            elif self.ended:
                break
            else:
                self.connection._receive()
        return bytes(result)

    def close(self):
        if not self.ended and self.connection.sock is not None:
            try:
                self.connection.h2.reset_stream(self.stream_id)
                self.connection._flush()
            except (OSError, H2Error):
                pass
        self.ended = True
        self.buffer.clear()
        self.connection.responses.pop(self.stream_id, None)


class Connection:
    # Use HTTPS's default port and a 20-second bound for administrative network operations.
    def __init__(self, host, port=443, *, context, timeout=20):
        self.host, self.port = host, port
        self.context, self.timeout = context, timeout
        self.sock = None
        self.h2 = None
        self.responses = {}
        self.pending = deque()
        self.draining = False
        self.incoming = bytearray()

    def connect(self):
        if self.sock is not None:
            return
        raw = socket.create_connection((self.host, self.port), self.timeout)
        try:
            self.sock = self.context.wrap_socket(raw, server_hostname=self.host)
            if self.sock.selected_alpn_protocol() != 'h2':
                raise ssl.SSLError('The relay must negotiate HTTP/2 (h2)')
            self.h2 = H2Connection(H2Configuration(header_encoding='utf-8'))
            self.h2.initiate_connection()
            self.draining = False
            self.incoming.clear()
            self._flush()
        except BaseException:
            raw.close()
            self.close()
            raise

    def _flush(self):
        data = self.h2.data_to_send()
        if data:
            self.sock.sendall(data)

    def _receive(self):
        # Receive in 64 KiB batches to amortize TLS reads without retaining an unlimited chunk.
        data = self.sock.recv(65536)
        if not data:
            for response in self.responses.values():
                length = response.getheader("content-length")
                if length is not None and response.received != int(length):
                    response.error = "Connection closed before the complete response body"
                response.ended = True
            self.sock.close()
            self.sock = None
            return
        self.incoming.extend(data)
        events = []
        try:
            while len(self.incoming) >= 9:
                frame, length = Frame.parse_frame_header(memoryview(bytes(self.incoming[:9])))
                if length > self.h2.max_inbound_frame_size:
                    raise http.client.HTTPException('HTTP/2 frame exceeds the negotiated limit')
                if len(self.incoming) < 9+length:
                    break
                packet = bytes(self.incoming[:9+length])
                del self.incoming[:9+length]
                if isinstance(frame, GoAwayFrame):
                    frame.parse_body(memoryview(packet[9:]))
                    if frame.error_code:
                        raise http.client.HTTPException(f'HTTP/2 GOAWAY: {frame.error_code}')
                    # hyper-h2 closes its state machine immediately on GOAWAY.
                    # Drain accepted streams before closing the TLS connection.
                    self.draining = True
                    for response in self.responses.values():
                        if response.stream_id > frame.last_stream_id:
                            response.error = 'HTTP/2 request was not accepted before GOAWAY'
                            response.ended = True
                else:
                    events.extend(self.h2.receive_data(packet))
        except (H2Error, HyperframeError) as exc:
            raise http.client.HTTPException(str(exc)) from exc
        for event in events:
            response = self.responses.get(getattr(event, 'stream_id', None))
            if response is not None:
                if isinstance(event, ResponseReceived):
                    response.headers = [(k, v) for k, v in event.headers if not k.startswith(':')]
                    response.status = int(dict(event.headers)[':status'])
                elif isinstance(event, DataReceived):
                    response.buffer.extend(event.data)
                    response.received += len(event.data)
                    padding = event.flow_controlled_length-len(event.data)
                    if padding:
                        self.h2.acknowledge_received_data(padding, event.stream_id)
                elif isinstance(event, StreamEnded):
                    response.ended = True
                elif isinstance(event, StreamReset):
                    response.ended = True
                    if event.error_code:
                        response.error = f'HTTP/2 stream reset: {event.error_code}'
        self._flush()

    def request(self, method, path, body=None, headers=None):
        if self.draining:
            if self.responses:
                raise http.client.HTTPException('Connection is draining; active streams must finish')
            self.close()
        self.connect()
        body = body.encode() if isinstance(body, str) else body or b''
        fields = [(k.lower(), str(v)) for k, v in (headers or {}).items()]
        if body and not any(k == 'content-length' for k, _ in fields):
            fields.append(('content-length', str(len(body))))
        authority = f'[{self.host}]:{self.port}' if ':' in self.host else f'{self.host}:{self.port}'
        fields = [(':method', method), (':scheme', 'https'), (':authority', authority), (':path', path)] + fields
        stream_id = self.h2.get_next_available_stream_id()
        response = Response(self, stream_id)
        self.responses[stream_id] = response
        self.pending.append(response)
        self.h2.send_headers(stream_id, fields, end_stream=not body)
        self._flush()
        offset = 0
        while offset < len(body) and not response.ended:
            window = self.h2.local_flow_control_window(stream_id)
            count = min(window, self.h2.max_outbound_frame_size, len(body)-offset)
            if not count:
                self._receive()
                continue
            try:
                self.h2.send_data(stream_id, body[offset:offset+count], end_stream=offset+count == len(body))
            except StreamClosedError:
                break
            offset += count
            self._flush()

    def getresponse(self):
        response = self.pending.popleft()
        while response.status is None:
            if response.ended or self.sock is None:
                raise http.client.HTTPException(response.error or 'Connection closed before response headers')
            self._receive()
        return response

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        for response in self.responses.values():
            response.ended = True
        self.responses.clear()
        self.pending.clear()
