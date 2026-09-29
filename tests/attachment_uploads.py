#!/usr/bin/env python3
"""Production mTLS/HTTP2 upload streaming with synthetic files and restart faults."""
import hashlib
import http.client
import json
import sqlite3
import time
import unittest
from contextlib import closing

from fixture import new_id
import relay_tls
from http2 import Response


class AttachmentUploads(unittest.TestCase):
    setUp = relay_tls.RelayTls.setUp
    tearDown = relay_tls.RelayTls.tearDown
    start = relay_tls.RelayTls.start
    stop = relay_tls.RelayTls.stop
    get = relay_tls.RelayTls.get

    def request(self, method, path, body=None, *, name='client', headers=None):
        with closing(self.tls.connection(name=name)) as connection:
            connection.request(method, path, body, headers or {})
            response = connection.getresponse()
            raw = response.read()
            return response.status, json.loads(raw) if raw else None

    def reserve(self, content, name='photo.png', mime='image/png'):
        epoch = self.get('/v1/sync')['server_epoch']
        file = dict(id=new_id(), name=name, mime_type=mime, bytes=str(len(content)),
                    sha256=hashlib.sha256(content).hexdigest())
        body = dict(server_epoch=epoch, file=file)
        status, record = self.request('POST', '/v1/uploads', json.dumps(body),
                                     headers={'content-type': 'application/json'})
        self.assertEqual(status, 200, record)
        self.assertEqual(record, dict(server_epoch=epoch, file=file, phase='reserved'))
        return body

    def headers(self, upload):
        return {'zimbr-server-epoch': upload['server_epoch'], 'content-type': 'application/octet-stream'}

    def put(self, upload, content, **kwargs):
        return self.request('PUT', '/v1/uploads/'+upload['file']['id'], content,
                            headers={**self.headers(upload), 'content-length': str(len(content))}, **kwargs)

    def status(self, upload, **kwargs):
        return self.request('GET', '/v1/uploads/'+upload['file']['id'],
                            headers=self.headers(upload), **kwargs)

    def local(self, upload):
        return self.root/'data/uploads'/upload['file']['id']/upload['file']['name']

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.03)
        self.fail('Timed out waiting for upload transition')

    def partial(self, upload, content=b'x'):
        connection = self.tls.connection()
        connection.connect()
        response = Response(connection, 1)
        connection.responses[1] = response
        connection.pending.append(response)
        connection.h2.send_headers(1, [(':method', 'PUT'), (':scheme', 'https'),
            (':authority', 'localhost'), (':path', '/v1/uploads/'+upload['file']['id']),
            ('content-type', 'application/octet-stream'), ('content-length', upload['file']['bytes']),
            ('zimbr-server-epoch', upload['server_epoch'])])
        connection.h2.send_data(1, content)
        connection._flush()
        return connection

    def test_original_binary_above_image_limit_streams_and_retries_without_rewriting(self):
        content = bytes(range(256)) * (9*1024*1024//256)
        upload = self.reserve(content, 'résumé.dat', 'application/octet-stream')
        self.assertTrue(self.get('/v1/status')['capabilities']['attachment_uploads_v1'])
        status, record = self.put(upload, content)
        self.assertEqual(status, 200, record)
        self.assertEqual(record['phase'], 'ready')
        self.assertEqual(self.local(upload).read_bytes(), content)
        self.assertEqual(self.local(upload).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.local(upload).parent.stat().st_mode & 0o777, 0o700)
        inode = self.local(upload).stat().st_ino
        self.assertEqual(self.put(upload, b'z'*len(content))[0], 200)
        self.assertEqual(self.local(upload).stat().st_ino, inode)
        self.assertEqual(self.local(upload).read_bytes(), content)
        self.assertEqual(self.status(upload)[1]['file'], upload['file'])
        changed = {**upload, 'file': {**upload['file'], 'name': 'changed.dat'}}
        self.assertEqual(self.request('POST', '/v1/uploads', json.dumps(changed),
                                     headers={'content-type': 'application/json'})[0], 409)
        self.stop(); self.start()
        self.assertEqual(self.status(upload)[1]['phase'], 'ready')
        self.assertEqual(self.local(upload).read_bytes(), content)

    def test_integrity_failures_empty_files_and_cancellation(self):
        upload = self.reserve(b'right')
        for wrong in (b'bad', b'wrong'):
            status, record = self.put(upload, wrong)
            self.assertEqual(status, 400, record)
            self.assertEqual(record['error_info']['code'], 'upload_integrity')
            self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
            self.assertFalse(self.local(upload).exists())
        self.assertEqual(self.put(upload, b'right')[0], 200)
        empty = self.reserve(b'', 'empty.txt', 'text/plain')
        self.assertEqual(self.request('PUT', '/v1/uploads/'+empty['file']['id'], b'',
                                     headers=self.headers(empty))[0], 400)
        self.assertEqual(self.put(empty, b'')[0], 200)
        self.assertEqual(self.local(empty).read_bytes(), b'')
        path = '/v1/uploads/'+upload['file']['id']
        self.assertEqual(self.request('DELETE', path, headers=self.headers(upload))[0], 204)
        self.wait(lambda: self.status(upload)[0] == 404)
        self.assertFalse(self.local(upload).parent.exists())
        self.assertEqual(self.request('DELETE', path, headers=self.headers(upload))[0], 204)

    def test_peer_identity_prevents_read_write_and_cancel_of_another_devices_upload(self):
        self.tls.issue('other'); self.tls.enroll('other')
        self.stop(); self.start()
        upload = self.reserve(b'private')
        self.assertEqual(self.status(upload, name='other')[0], 404)
        self.assertEqual(self.put(upload, b'private', name='other')[0], 404)
        self.assertEqual(self.request('POST', '/v1/uploads', json.dumps(upload), name='other',
                                     headers={'content-type': 'application/json'})[0], 404)
        self.assertEqual(self.request('DELETE', '/v1/uploads/'+upload['file']['id'], name='other',
                                     headers=self.headers(upload))[0], 204)
        self.assertEqual(self.status(upload)[1]['phase'], 'reserved')
        self.assertEqual(self.put(upload, b'private')[0], 200)

    def test_interrupted_upload_releases_lease_and_crash_discards_partial_bytes(self):
        upload = self.reserve(b'x'*1000)
        with closing(self.partial(upload)):
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            self.assertEqual(self.put(upload, b'x'*1000)[0], 409)
            self.assertEqual(self.request('DELETE', '/v1/uploads/'+upload['file']['id'],
                                         headers=self.headers(upload))[0], 409)
        self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
        with closing(self.partial(upload)):
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            self.stop()
        self.start()
        self.assertEqual(self.status(upload)[1]['phase'], 'reserved')
        self.assertFalse(self.local(upload).parent.exists())
        self.assertEqual(self.put(upload, b'x'*1000)[0], 200)

    def test_reset_during_stream_cannot_publish_an_old_epoch_upload(self):
        upload = self.reserve(b'xy')
        with closing(self.partial(upload)) as connection:
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            self.assertEqual(self.request('POST', '/v1/reset', json.dumps({'server_epoch': upload['server_epoch']}),
                                         headers={'content-type': 'application/json'})[0], 200)
            connection.h2.send_data(1, b'y', end_stream=True); connection._flush()
            response = connection.getresponse()
            self.assertEqual(response.status, 409)
            self.assertEqual(json.loads(response.read())['error_info']['code'], 'resync_required')
        self.wait(lambda: not self.local(upload).parent.exists())
        self.assertEqual(self.status(upload)[0], 409)

    def test_incomplete_upload_and_sse_leave_commands_usable_on_same_connection(self):
        upload = self.reserve(b'x'*1000)
        with closing(self.partial(upload)) as connection:
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            # The upload response remains pending; read later command responses directly.
            connection.pending.popleft()
            socket = connection.sock
            connection.request('GET', '/v1/events?after='+self.get('/v1/sync')['cursor'])
            events = connection.getresponse()
            self.assertEqual(events.readline(), b': connected\n')
            self.assertEqual(events.readline(), b'\n')
            connection.request('GET', '/v1/status')
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertTrue(json.loads(response.read())['adapter_ready'])
            self.assertIs(connection.sock, socket)
            connection.h2.reset_stream(1); connection._flush()
            events.close()
        self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')

    def test_active_upload_limit_and_expiry_release_storage(self):
        uploads = [self.reserve(b'xy') for _ in range(5)]
        active = []
        try:
            for upload in uploads[:4]:
                active.append(self.partial(upload))
                self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            self.assertEqual(self.put(uploads[4], b'xy')[0], 409)
            self.assertEqual(self.status(uploads[4])[1]['phase'], 'reserved')
            self.assertTrue(self.get('/v1/status')['adapter_ready'])
        finally:
            for connection in active: connection.close()
        for upload in uploads[:4]:
            self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
        self.assertEqual(self.put(uploads[4], b'xy')[0], 200)
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            with db: db.execute('UPDATE uploads SET created_ms=0')
        self.wait(lambda: all(self.status(upload)[0] == 404 for upload in uploads))
        self.assertFalse(any((self.root/'data/uploads').iterdir()))

    def test_failed_journal_publication_removes_verified_file_and_allows_retry(self):
        upload = self.reserve(b'original')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            with db:
                db.execute("CREATE TRIGGER reject_ready BEFORE UPDATE ON uploads WHEN NEW.state='ready' BEGIN SELECT RAISE(ABORT,'injected publication failure'); END")
        self.assertEqual(self.put(upload, b'original')[0], 503)
        self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
        self.assertFalse(self.local(upload).exists())
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            with db: db.execute('DROP TRIGGER reject_ready')
        self.assertEqual(self.put(upload, b'original')[0], 200)
        self.assertEqual(self.local(upload).read_bytes(), b'original')

    def test_failed_lease_release_recovers_without_restarting_the_relay(self):
        upload = self.reserve(b'xy')
        with closing(self.partial(upload)) as connection:
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
                with db:
                    db.execute("CREATE TRIGGER reject_release BEFORE UPDATE ON uploads WHEN OLD.state='receiving' AND NEW.state='reserved' BEGIN SELECT RAISE(ABORT,'injected lease release failure'); END")
            connection.pending.popleft()
            connection.h2.reset_stream(1); connection._flush()
            # The subsequent response proves the reset callback has completed.
            connection.request('GET', '/v1/status')
            response = connection.getresponse()
            self.assertEqual(response.status, 200); response.read()
        self.assertEqual(self.status(upload)[1]['phase'], 'receiving')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            with db: db.execute('DROP TRIGGER reject_release')
        self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
        self.assertEqual(self.put(upload, b'xy')[0], 200)

    def test_oversized_stream_is_rejected_before_claiming_a_reservation(self):
        upload = self.reserve(b'xy')
        oversized = {**upload, 'file': {**upload['file'], 'bytes': str(100*1024*1024+1)}}
        with closing(self.partial(oversized)) as connection:
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        self.assertEqual(self.status(upload)[1]['phase'], 'reserved')
        self.assertFalse(self.local(upload).parent.exists())

    def test_idle_upload_timeout_releases_lease_without_closing_other_streams(self):
        upload = self.reserve(b'xy')
        with closing(self.partial(upload)) as connection:
            self.wait(lambda: self.status(upload)[1]['phase'] == 'receiving')
            connection.sock.settimeout(35)
            with self.assertRaises(http.client.HTTPException):
                connection.getresponse()
            connection.request('GET', '/v1/status')
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.read()
        self.wait(lambda: self.status(upload)[1]['phase'] == 'reserved')
        self.assertFalse(self.local(upload).exists())

    def test_unsafe_upload_root_disables_uploads_without_disabling_history(self):
        self.stop()
        outside = self.root/'outside'
        outside.mkdir()
        marker = outside/'keep.txt'
        marker.write_text('preserve this file')
        root = self.root/'data/uploads'
        root.rmdir(); root.symlink_to(outside, target_is_directory=True)
        self.start()
        status = self.get('/v1/status')
        self.assertTrue(status['adapter_ready'])
        self.assertFalse(status['capabilities']['attachment_uploads_v1'])
        self.assertEqual(self.request('POST', '/v1/uploads', '{}',
                                     headers={'content-type': 'application/json'})[0], 503)
        self.assertEqual(marker.read_text(), 'preserve this file')


if __name__ == '__main__':
    unittest.main()
