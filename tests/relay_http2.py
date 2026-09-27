#!/usr/bin/env python3
"""HTTP/2 negotiation, multiplexing, stream isolation, and flow-control boundaries."""
import json
import sqlite3
import time
import unittest
from contextlib import closing

from h2.events import ResponseReceived, StreamReset
from h2.settings import SettingCodes
from fixture import new_id
from relay_tls import RelayTls


class Http2(RelayTls):
    # Reuse the native relay setup without rerunning the inherited TLS test cases.
    def test_requires_h2_alpn(self):
        for protocols in ([], ['http/1.1'], ['http/1.0']):
            context = self.tls.context()
            context.set_alpn_protocols(protocols)
            self.reject(context)
        connection = self.tls.connection()
        try:
            connection.request('GET', '/v1/status')
            self.assertEqual(connection.sock.selected_alpn_protocol(), 'h2')
            self.assertEqual(connection.getresponse().status, 200)
        finally:
            connection.close()

    def test_sse_and_commands_share_one_connection(self):
        baseline = self.get('/v1/sync')
        with closing(self.tls.connection()) as connection:
            connection.request('GET', '/v1/events?after='+baseline['cursor'])
            events = connection.getresponse()
            self.assertEqual(events.readline(), b': connected\n')
            self.assertEqual(events.readline(), b'\n')
            sock = connection.sock
            outgoing = dict(request_id=new_id(), server_epoch=baseline['server_epoch'],
                            target={'recipient': {'address': 'alice@example.invalid', 'service': 'imessage'}},
                            text='Multiplexed send while SSE remains open')
            connection.request('POST', '/v1/messages', json.dumps(outgoing), {'content-type': 'application/json'})
            reply = connection.getresponse()
            self.assertEqual(reply.status, 202)
            self.assertEqual(json.loads(reply.read())['request_id'], outgoing['request_id'])
            self.assertIs(sock, connection.sock)
            while True:
                line = events.readline()
                self.assertTrue(line)
                if line.startswith(b'data: ') and outgoing['request_id'].encode() in line:
                    break
            events.close()
            connection.request('GET', '/v1/status')
            self.assertEqual(connection.getresponse().status, 200)
            self.assertIs(sock, connection.sock)

    def test_stalled_stream_window_does_not_block_other_streams(self):
        connection = self.tls.connection()
        try:
            connection.connect()
            connection.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 0})
            connection._flush()
            connection.request('GET', '/v1/status')
            stalled = connection.getresponse()
            self.assertEqual(stalled.status, 200)
            self.assertFalse(stalled.buffer)
            connection.request('GET', '/v1/sync')
            ready = connection.getresponse()
            connection.h2.increment_flow_control_window(65535, ready.stream_id)
            connection._flush()
            self.assertIn('cursor', json.loads(ready.read()))
            self.assertFalse(stalled.buffer)
            stalled.close()
            connection.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 65535})
            connection._flush()
            connection.request('GET', '/v1/status')
            self.assertTrue(json.loads(connection.getresponse().read())['adapter_ready'])
        finally:
            connection.close()

    def test_bad_headers_reset_only_the_affected_stream(self):
        with closing(self.tls.connection()) as connection:
            connection.connect()
            connection.h2.send_headers(1, [(':method', 'GET'), (':scheme', 'https'),
                (':authority', 'localhost'), (':path', '/v1/status'), ('x-large', 'x'*20000)], end_stream=True)
            connection._flush()
            # Keep the malformed stream outside the convenience client's response map.
            reset = False
            deadline = time.monotonic()+3
            while not reset:
                self.assertLess(time.monotonic(), deadline)
                for event in connection.h2.receive_data(connection.sock.recv(65536)):
                    if isinstance(event, StreamReset) and event.stream_id == 1:
                        reset = True
            connection.request('GET', '/v1/status')
            reply = connection.getresponse()
            self.assertEqual(reply.status, 200)
            self.assertTrue(json.loads(reply.read())['adapter_ready'])

    def test_unfinished_body_expires_without_dispatch(self):
        baseline = self.get('/v1/sync')
        outgoing = dict(request_id=new_id(), server_epoch=baseline['server_epoch'],
                        target={'recipient': {'address': 'alice@example.invalid', 'service': 'imessage'}},
                        text='Expired incomplete request must never dispatch')
        body = json.dumps(outgoing).encode()
        with closing(self.tls.connection(timeout=12)) as connection:
            connection.connect()
            connection.h2.send_headers(1, [(':method', 'POST'), (':scheme', 'https'),
                (':authority', 'localhost'), (':path', '/v1/messages'),
                ('content-type', 'application/json'), ('content-length', str(len(body)))])
            connection.h2.send_data(1, body[:1])
            connection._flush()
            start = time.monotonic()
            reset = False
            while not reset:
                for event in connection.h2.receive_data(connection.sock.recv(65536)):
                    self.assertNotIsInstance(event, ResponseReceived)
                    if isinstance(event, StreamReset) and event.stream_id == 1:
                        reset = True
            self.assertLess(time.monotonic()-start, 11)
            connection.request('GET', '/v1/status')
            self.assertEqual(connection.getresponse().status, 200)
            with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)

    def test_goaway_preserves_the_final_response_and_reconnects(self):
        with closing(self.tls.connection()) as connection:
            original = None
            for index in range(65):
                connection.request('GET', '/v1/status')
                reply = connection.getresponse()
                self.assertEqual(reply.status, 200)
                self.assertTrue(json.loads(reply.read())['adapter_ready'])
                if index == 0:
                    original = connection.sock
                elif index < 64:
                    self.assertIs(original, connection.sock)
            self.assertIsNot(original, connection.sock)

    def test_body_without_content_length_is_bounded(self):
        with closing(self.tls.connection()) as connection:
            connection.connect()
            connection.h2.send_headers(1, [(':method', 'POST'), (':scheme', 'https'),
                (':authority', 'localhost'), (':path', '/v1/messages'), ('content-type', 'application/json')])
            for _ in range(4):
                connection.h2.send_data(1, b'x'*16000)
            connection._flush()
            while connection.h2.local_flow_control_window(1) < 2000:
                connection.h2.receive_data(connection.sock.recv(65536))
            connection.h2.send_data(1, b'x'*2000, end_stream=True)
            connection._flush()
            status = None
            while status is None:
                for event in connection.h2.receive_data(connection.sock.recv(65536)):
                    if isinstance(event, ResponseReceived) and event.stream_id == 1:
                        status = int(dict(event.headers)[':status'])
            self.assertEqual(status, 413)
            connection.request('GET', '/v1/status')
            self.assertEqual(connection.getresponse().status, 200)
            with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)


if __name__ == '__main__':
    names = [name for name in Http2.__dict__ if name.startswith('test_')]
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Http2(name) for name in names))
    raise SystemExit(not result.wasSuccessful())
