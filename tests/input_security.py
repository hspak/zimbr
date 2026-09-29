#!/usr/bin/env python3
"""Hostile attachment metadata through the authenticated production HTTP/2 API."""
import hashlib
import http.client
import json
import sqlite3
import unittest
from contextlib import closing
from pathlib import Path

from fixture import add_message, new_id
from h2.settings import SettingCodes
import attachment_sends
import attachment_uploads


class InputSecurity(unittest.TestCase):
    setUp = attachment_sends.AttachmentSends.setUp
    tearDown = attachment_sends.AttachmentSends.tearDown
    start = attachment_sends.AttachmentSends.start
    stop = attachment_sends.AttachmentSends.stop
    get = attachment_sends.AttachmentSends.get
    request = attachment_sends.AttachmentSends.request
    reserve = attachment_sends.AttachmentSends.reserve
    headers = attachment_uploads.AttachmentUploads.headers
    put = attachment_uploads.AttachmentUploads.put
    local = attachment_uploads.AttachmentUploads.local
    wait = attachment_uploads.AttachmentUploads.wait
    upload = attachment_sends.AttachmentSends.upload
    outgoing = attachment_sends.AttachmentSends.outgoing
    send = attachment_sends.AttachmentSends.send
    record = attachment_sends.AttachmentSends.record
    settled = attachment_sends.AttachmentSends.settled
    source_rows = attachment_sends.AttachmentSends.source_rows

    def counts(self):
        with closing(sqlite3.connect(self.root / 'data/relay.db')) as db:
            return (db.execute('SELECT count(*) FROM uploads').fetchone()[0],
                    db.execute('SELECT count(*) FROM send_requests').fetchone()[0])

    def metadata(self):
        return dict(server_epoch=self.get('/v1/sync')['server_epoch'], file=dict(
            id=new_id(), name='safe.bin', mime_type='application/octet-stream',
            bytes='0', sha256=hashlib.sha256(b'').hexdigest()))

    def reject(self, raw, status=400):
        before = self.counts()
        actual, reply = self.request('POST', '/v1/uploads', raw,
                                     headers={'content-type': 'application/json'})
        self.assertEqual(actual, status, reply)
        self.assertEqual(self.counts(), before)
        self.assertTrue(self.get('/v1/status')['adapter_ready'])

    def test_invalid_metadata_is_rejected_without_reservations(self):
        good = self.metadata()
        cases = {
            'name': ['', '.', '..', '../escape', 'folder/file', 'folder\\file',
                     'nul\0suffix', 'line\r\nname', 'x' * 256, '😀' * 64,
                     'photo\u0085.png', 'photo\u009b.png', 'photo\u2028.png',
                     'photo\u2029.png', 'photo\u202egnp.exe', 'photo\u2066.png'],
            'id': ["'; DROP TABLE uploads;--", good['file']['id'] + '/', 'x' * 10000],
            'mime_type': ['image/png\r\nx: y', 'image/png/extra', 'image/\0png', 'x' * 128],
            'bytes': ['-1', '+1', '01', '1e6', '1_000', '１２', ' 1', ''],
            'sha256': ['0' * 63, 'X' * 64, '0' * 65],
        }
        for field, values in cases.items():
            for value in values:
                with self.subTest(field=field, value=repr(value)[:80]):
                    self.reject(json.dumps({**good, 'file': {**good['file'], field: value}}))
        for value in ['104857601', '18446744073709551616', '9' * 10000]:
            self.reject(json.dumps({**good, 'file': {**good['file'], 'bytes': value}}), 413)

    def test_json_encoding_depth_complexity_and_size_are_bounded(self):
        good = json.dumps(self.metadata()).encode()
        for raw in [good.replace(b'safe.bin', invalid) for invalid in
                    [b'bad\xff', b'bad\xc0\xaf', b'bad\xed\xa0\x80', b'bad\x00', b'bad\\ud800']]:
            self.reject(raw)
        self.reject(good[:-1] + b',"file":' + json.dumps(self.metadata()['file']).encode() + b'}')
        self.reject(good[:-1] + b',"unknown":' + b'[' * 40 + b'0' + b']' * 40 + b'}')
        self.reject(good[:-1] + b',"unknown":[' + b'0,' * 1000 + b'0]}')
        self.reject(b' ' * (64 * 1024 + 1), 413)

    def test_sql_and_shell_metacharacters_remain_literal_through_dispatch(self):
        name = "x'); DROP TABLE uploads;-- $(literal) `quote`.bin"
        content = bytes(range(256)) * 4
        file = self.upload(content, name)
        caption = "'); DROP TABLE send_requests;--\n$() `literal` 👩‍💻"
        outgoing = self.outgoing([file], caption)
        self.send(outgoing)
        self.settled(outgoing)
        rows = self.source_rows()
        self.assertEqual([row[0] for row in rows], [caption, ''])
        self.assertEqual(rows[1][1], name)
        self.assertEqual(Path(rows[1][2]).read_bytes(), content)
        self.assertEqual(self.counts()[1], 1)
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), rows)

    def test_stalled_large_history_responses_exhaust_a_budget_then_recover(self):
        with closing(sqlite3.connect(self.source)) as db:
            with db:
                for _ in range(120):
                    last = add_message(db, 'x' * 64000)

        def imported():
            with closing(sqlite3.connect(self.root / 'data/relay.db')) as db:
                return db.execute('SELECT 1 FROM messages WHERE source_row=?', (last,)).fetchone()

        self.wait(imported, timeout=10)
        with closing(sqlite3.connect(self.root / 'data/relay.db')) as db:
            chat = db.execute('SELECT id FROM conversations WHERE source_row=1').fetchone()[0]
        path = '/v1/conversations/' + chat + '/messages?limit=200'
        connections = []
        accepted = 0
        rejected = False
        try:
            for _ in range(2):
                connection = self.tls.connection()
                connection.connect()
                connection.h2.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 0})
                connection._flush()
                connections.append(connection)
            for i in range(16):
                connection = connections[i % 2]
                connection.request('GET', path)
                try:
                    response = connection.getresponse()
                except http.client.HTTPException:
                    rejected = True
                    break
                if response.status == 503:
                    rejected = True
                    break
                self.assertEqual(response.status, 200)
                self.assertGreater(int(response.getheader('content-length')), 7 * 1024 * 1024)
                accepted += 1
            self.assertGreaterEqual(accepted, 2)
            self.assertTrue(rejected, 'Slow readers retained sixteen large response arenas')
        finally:
            for connection in connections:
                connection.close()
        self.assertTrue(self.get('/v1/status')['adapter_ready'])
        self.assertGreaterEqual(len(self.get(path)['messages']), 120)


if __name__ == '__main__':
    unittest.main()
