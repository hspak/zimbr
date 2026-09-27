"""HTTP/2 transport for the existing application fault handlers.

One owner drives TLS and h2; per-stream handler threads enqueue bounded writes so
an intentionally stalled SSE/history stream cannot stall unrelated requests.
"""
from collections import deque
from email.message import Message
import io
import select
import threading

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, RequestReceived, StreamEnded, StreamReset
from h2.exceptions import H2Error


class Output:
    def __init__(self, session, stream_id):
        self.session, self.stream_id = session, stream_id

    def write(self, data):
        self.session.submit(self.stream_id, 'data', memoryview(data))
        return len(data)

    def flush(self):
        pass


class Handler:
    def send_response(self, code, message=None):
        self.output_headers = [(':status', str(code))]

    def send_header(self, name, value):
        if name.lower() not in ('connection', 'transfer-encoding', 'keep-alive'):
            self.output_headers.append((name.lower(), str(value)))

    def end_headers(self):
        self.session.submit(self.stream_id, 'headers', self.output_headers)


class Session:
    def __init__(self, server, sock, address):
        self.server, self.sock, self.address = server, sock, address
        self.h2 = H2Connection(H2Configuration(client_side=False, header_encoding='utf-8',
                                              validate_outbound_headers=False))
        self.lock = threading.Lock()
        self.commands = deque()
        self.requests = {}
        self.closed_streams = set()
        self.closed = False

    def submit(self, stream_id, kind, payload=None):
        done = threading.Event()
        command = [stream_id, kind, payload, done, None]
        with self.lock:
            if self.closed or stream_id in self.closed_streams:
                raise BrokenPipeError('HTTP/2 stream closed')
            self.commands.append(command)
        if not done.wait(15):
            raise TimeoutError('HTTP/2 peer stopped consuming the response')
        if command[4]:
            raise BrokenPipeError(command[4])

    def handle(self, stream_id, headers, body):
        cls = type('Http2Handler', (Handler, self.server.RequestHandlerClass), {})
        handler = object.__new__(cls)
        handler.session, handler.stream_id = self, stream_id
        handler.server, handler.connection = self.server, self.sock
        handler.client_address = self.address
        handler.command, handler.path = headers[':method'], headers[':path']
        handler.request_version = 'HTTP/2'
        handler.requestline = f'{handler.command} {handler.path} HTTP/2'
        handler.close_connection = False
        handler.headers = Message()
        for name, value in headers.items():
            if not name.startswith(':'):
                handler.headers[name] = value
        handler.rfile = io.BytesIO(body)
        handler.wfile = Output(self, stream_id)
        try:
            getattr(handler, 'do_' + handler.command)()
            self.submit(stream_id, 'end')
        except (OSError, H2Error):
            pass

    def flush(self):
        data = self.h2.data_to_send()
        if data:
            self.sock.sendall(data)

    def output(self):
        with self.lock:
            pending = self.commands
            self.commands = deque()
        while pending:
            command = pending.popleft()
            stream_id, kind, payload, done, _ = command
            try:
                if stream_id in self.closed_streams:
                    raise BrokenPipeError('Stream reset')
                if kind == 'headers':
                    self.h2.send_headers(stream_id, payload)
                elif kind == 'end':
                    self.h2.end_stream(stream_id)
                else:
                    budget = 256 * 1024
                    while payload and budget:
                        size = min(len(payload), self.h2.local_flow_control_window(stream_id),
                                   self.h2.max_outbound_frame_size, budget)
                        if not size:
                            break
                        self.h2.send_data(stream_id, bytes(payload[:size]))
                        payload = payload[size:]
                        budget -= size
                    command[2] = payload
                    if payload:
                        with self.lock:
                            self.commands.append(command)
                        continue
                self.flush()
            except (H2Error, OSError) as exc:
                command[4] = str(exc)
            done.set()
        self.flush()

    def run(self):
        self.h2.initiate_connection()
        self.flush()
        try:
            while True:
                self.output()
                if not self.sock.pending() and not select.select([self.sock], [], [], .01)[0]:
                    continue
                data = self.sock.recv(65536)
                if not data:
                    return
                for event in self.h2.receive_data(data):
                    if isinstance(event, RequestReceived):
                        self.requests[event.stream_id] = (dict(event.headers), bytearray())
                    elif isinstance(event, DataReceived):
                        self.requests[event.stream_id][1].extend(event.data)
                        self.h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, StreamEnded):
                        headers, body = self.requests.pop(event.stream_id)
                        threading.Thread(target=self.handle, args=(event.stream_id, headers, body), daemon=True).start()
                    elif isinstance(event, StreamReset):
                        self.closed_streams.add(event.stream_id)
                        self.requests.pop(event.stream_id, None)
                self.flush()
        finally:
            with self.lock:
                self.closed = True
                for command in self.commands:
                    command[4] = 'Connection closed'
                    command[3].set()
                self.commands.clear()
