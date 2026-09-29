#!/usr/bin/env python3
"""Outgoing attachments must never silently become caption-only sends."""
import hashlib
import json
import sqlite3
from pathlib import Path
import unittest
from contextlib import closing

from fixture import new_id
import relay_tls
import attachment_uploads


class AttachmentSends(unittest.TestCase):
    tearDown = relay_tls.RelayTls.tearDown
    start = relay_tls.RelayTls.start
    stop = relay_tls.RelayTls.stop
    get = relay_tls.RelayTls.get
    request = attachment_uploads.AttachmentUploads.request
    reserve = attachment_uploads.AttachmentUploads.reserve
    headers = attachment_uploads.AttachmentUploads.headers
    put = attachment_uploads.AttachmentUploads.put
    local = attachment_uploads.AttachmentUploads.local
    wait = attachment_uploads.AttachmentUploads.wait

    def setUp(self):
        relay_tls.RelayTls.setUp(self)
        self.stop()
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('ALTER TABLE attachment ADD COLUMN filename TEXT')
            self.before = db.execute('SELECT max(ROWID) FROM message').fetchone()[0]
            db.commit()
        self.start()

    def upload(self, content, name='file.bin', mime='application/octet-stream'):
        upload = self.reserve(content, name, mime)
        self.assertEqual(self.put(upload, content)[0], 200)
        return upload

    def outgoing(self, uploads, text='', target=None):
        return dict(request_id=new_id(), server_epoch=self.get('/v1/sync')['server_epoch'],
                    target=target or {'recipient': {'address': 'alice@example.invalid',
                                                   'service': 'imessage'}},
                    text=text, attachments=[item['file'] for item in uploads])

    def send(self, outgoing, expected=202, **kwargs):
        status, result = self.request('POST', '/v1/messages', json.dumps(outgoing),
                                      headers={'content-type': 'application/json'}, **kwargs)
        self.assertEqual(status, expected, result)
        return result

    def record(self, outgoing):
        return self.get('/v1/send-requests/'+outgoing['request_id'])

    def settled(self, outgoing):
        self.wait(lambda: self.record(outgoing)['state'] not in ('queued', 'dispatching'))
        return self.record(outgoing)

    def source_rows(self):
        with closing(sqlite3.connect(self.source)) as db:
            return db.execute('SELECT m.text,a.transfer_name,a.filename FROM message m '
                              'LEFT JOIN message_attachment_join j ON j.message_id=m.ROWID '
                              'LEFT JOIN attachment a ON a.ROWID=j.attachment_id '
                              'WHERE m.ROWID>? ORDER BY m.ROWID', (self.before,)).fetchall()

    def test_caption_and_original_files_dispatch_once_in_order(self):
        content = bytes(range(256))*1024
        files = [self.upload(content, 'résumé "; $x.dat'), self.upload(b'', 'empty.txt', 'text/plain')]
        outgoing = self.outgoing(files, 'Caption 👩‍💻')
        self.assertTrue(self.get('/v1/status')['capabilities']['send_attachments_v1'])
        self.send(outgoing)
        record = self.settled(outgoing)
        self.assertEqual([part['kind'] for part in record['parts']], ['text', 'attachment', 'attachment'])
        self.assertTrue(all(part['state'] == 'invoked' for part in record['parts']))
        rows = self.source_rows()
        self.assertEqual([row[0] for row in rows], ['Caption 👩‍💻', '', ''])
        for row, upload, data in zip(rows[1:], files, [content, b'']):
            self.assertEqual(row[1], upload['file']['name'])
            self.assertEqual(Path(row[2]).read_bytes(), data)
            self.assertNotEqual(Path(row[2]), self.local(upload))
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            bounds = db.execute('SELECT position,source_floor FROM send_parts ORDER BY position').fetchall()
            self.assertEqual(bounds, [(0, self.before), (1, self.before+1), (2, self.before+2)])
        self.send(outgoing, 200)
        self.stop(); self.start()
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), rows)

    def test_partial_failure_skips_successors_and_retry_never_replays_caption(self):
        files = [self.upload(b'one'), self.upload(b'two', 'fake-reject.bin'), self.upload(b'three')]
        outgoing = self.outgoing(files, 'Keep this caption once')
        self.send(outgoing)
        record = self.settled(outgoing)
        self.assertEqual([part['state'] for part in record['parts']], ['invoked', 'invoked', 'failed', 'skipped'])
        self.assertEqual(record['state'], 'unknown')
        self.assertEqual(record['error_info']['code'], 'partial_send')
        self.assertEqual(record['parts'][2]['error_info']['outcome'], 'unstarted')
        self.assertEqual(record['parts'][3]['error_info']['outcome'], 'unstarted')
        rows = self.source_rows()
        self.assertEqual(len(rows), 2)
        self.send(outgoing, 200)
        self.stop(); self.start()
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), rows)

    def test_uncertain_file_invocation_can_have_an_echo_without_replaying(self):
        outgoing = self.outgoing([self.upload(b'one', 'fake-uncertain-after.bin'), self.upload(b'two')])
        self.send(outgoing)
        record = self.settled(outgoing)
        self.assertEqual([part['state'] for part in record['parts']], ['unknown', 'skipped'])
        self.assertEqual(record['parts'][0]['error_info']['outcome'], 'uncertain')
        rows = self.source_rows()
        self.assertEqual(len(rows), 1)
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), rows)

    def test_restart_during_file_invocation_holds_only_unfinished_parts(self):
        outgoing = self.outgoing([self.upload(b'one', 'fake-stall.bin'), self.upload(b'two')], 'Once')
        self.send(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][1]['state'] == 'dispatching')
        self.proc.kill(); self.proc.wait(timeout=5)
        self.start()
        record = self.record(outgoing)
        self.assertEqual([part['state'] for part in record['parts']], ['invoked', 'unknown', 'skipped'])
        self.assertEqual(record['parts'][1]['error_info']['code'], 'interrupted_dispatch')
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), [('Once', None, None)])
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM uploads WHERE state='pinned'").fetchone()[0], 2)

    def test_result_commit_failure_preserves_the_completed_file_without_replay(self):
        outgoing = self.outgoing([self.upload(b'one', 'fake-stall.bin'), self.upload(b'two')])
        self.send(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][0]['state'] == 'dispatching')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            db.execute("CREATE TRIGGER fail_result BEFORE UPDATE ON send_requests "
                       "WHEN OLD.state='dispatching' AND json_extract(NEW.record,'$.parts[0].state')='invoked' "
                       "BEGIN SELECT RAISE(ABORT,'fixture'); END")
            db.commit()
        record = self.settled(outgoing)
        self.assertEqual([part['state'] for part in record['parts']], ['unknown', 'skipped'])
        self.assertEqual(record['parts'][0]['error_info']['code'], 'interrupted_dispatch')
        rows = self.source_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(Path(rows[0][2]).read_bytes(), b'one')
        self.send(outgoing, 200)
        self.assertEqual(self.source_rows(), rows)

    def test_missing_staged_file_fails_before_caption_or_other_files_are_sent(self):
        upload = self.upload(b'missing')
        self.local(upload).unlink()
        outgoing = self.outgoing([upload], 'Must remain unsent')
        self.send(outgoing)
        record = self.settled(outgoing)
        self.assertEqual(record['state'], 'failed')
        self.assertEqual([part['state'] for part in record['parts']], ['failed', 'skipped'])
        self.assertEqual(record['parts'][0]['error_info']['code'], 'upload_file_unavailable')
        self.assertEqual(self.source_rows(), [])

    def test_incomplete_or_foreign_uploads_do_not_pin_or_send_any_part(self):
        complete = self.upload(b'one')
        incomplete = self.reserve(b'two')
        outgoing = self.outgoing([complete, incomplete], 'Unsent')
        self.send(outgoing, 400)
        self.tls.issue('other'); self.tls.enroll('other')
        self.stop(); self.start()
        self.send(self.outgoing([complete]), 400, name='other')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM uploads WHERE state='pinned'").fetchone()[0], 0)
        self.assertEqual(self.source_rows(), [])

    def test_attachment_only_send_uses_the_existing_group_route(self):
        group = next(chat for chat in self.get('/v1/conversations')['conversations']
                     if chat['title'] == 'Fixture group')
        outgoing = self.outgoing([self.upload(b'group-file')], target={'conversation_id': group['id']})
        self.send(outgoing)
        record = self.settled(outgoing)
        self.assertEqual([part['kind'] for part in record['parts']], ['attachment'])
        with closing(sqlite3.connect(self.source)) as db:
            chats = db.execute('SELECT c.guid FROM chat_message_join j JOIN chat c ON c.ROWID=j.chat_id '
                               'WHERE j.message_id>?', (self.before,)).fetchall()
            self.assertEqual(chats, [('iMessage;+;group-fixture',)])
        rows = self.source_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], '')
        self.assertEqual(Path(rows[0][2]).read_bytes(), b'group-file')

    def test_reset_during_dispatch_cannot_start_the_next_file_or_overwrite_the_hold(self):
        outgoing = self.outgoing([self.upload(b'one', 'fake-stall.bin'), self.upload(b'two')], 'Once')
        self.send(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][1]['state'] == 'dispatching')
        status, reset = self.request('POST', '/v1/reset', json.dumps({'server_epoch': outgoing['server_epoch']}),
                                    headers={'content-type': 'application/json'})
        self.assertEqual(status, 200, reset)
        self.wait(lambda: len(self.source_rows()) == 2)
        record = self.record(outgoing)
        self.assertEqual([part['state'] for part in record['parts']], ['invoked', 'unknown', 'skipped'])
        self.assertEqual(record['error_info']['code'], 'source_reset')
        self.send(outgoing, 409)
        self.assertEqual(len(self.source_rows()), 2)

    def test_unavailable_attachment_send_never_dispatches_its_caption(self):
        outgoing = dict(
            request_id=new_id(), server_epoch=self.get('/v1/sync')['server_epoch'],
            target={'recipient': {'address': 'alice@example.invalid', 'service': 'imessage'}},
            text='This caption must not be sent without its file',
            attachments=[dict(id=new_id(), name='photo.png', mime_type='image/png',
                              bytes='4', sha256=hashlib.sha256(b'file').hexdigest())],
        )
        with closing(self.tls.connection()) as connection:
            connection.request('POST', '/v1/messages', json.dumps(outgoing),
                               {'content-type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            self.assertEqual(json.loads(response.read())['error_info']['outcome'], 'unstarted')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests WHERE id=?',
                                       (outgoing['request_id'],)).fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
