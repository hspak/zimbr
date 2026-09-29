#!/usr/bin/env python3
"""Observe multipart sends using synthetic Messages rows and original-file proofs."""
import sqlite3
import subprocess
import time
import unittest
import uuid
from contextlib import closing
from pathlib import Path

import attachment_sends
from fixture import add_message


class AttachmentObservation(unittest.TestCase):
    setUp = attachment_sends.AttachmentSends.setUp
    tearDown = attachment_sends.AttachmentSends.tearDown
    start = attachment_sends.AttachmentSends.start
    stop = attachment_sends.AttachmentSends.stop
    get = attachment_sends.AttachmentSends.get
    request = attachment_sends.AttachmentSends.request
    reserve = attachment_sends.AttachmentSends.reserve
    headers = attachment_sends.AttachmentSends.headers
    put = attachment_sends.AttachmentSends.put
    local = attachment_sends.AttachmentSends.local
    wait = attachment_sends.AttachmentSends.wait
    upload = attachment_sends.AttachmentSends.upload
    outgoing = attachment_sends.AttachmentSends.outgoing
    send = attachment_sends.AttachmentSends.send
    record = attachment_sends.AttachmentSends.record
    settled = attachment_sends.AttachmentSends.settled
    source_rows = attachment_sends.AttachmentSends.source_rows

    def confirmed(self, outgoing):
        self.wait(lambda: self.record(outgoing)['state'] == 'delivered', timeout=16)
        return self.record(outgoing)

    def echo(self, *, name=None, chat=1, contents=None, pending=False):
        with closing(sqlite3.connect(self.source)) as db:
            row = add_message(db, text='', chat=chat, is_from_me=1,
                              is_sent=1, is_delivered=1, is_finished=not pending)
            if name is not None:
                filename = self.root/'source.db.attachments'/str(uuid.uuid4())
                filename.parent.mkdir(exist_ok=True, mode=0o700)
                filename.write_bytes(contents)
                attachment = db.execute('INSERT INTO attachment(guid,transfer_name,mime_type,total_bytes,filename) '
                                        "VALUES(?,?,'application/octet-stream',?,?)",
                                        (str(uuid.uuid4()), name, len(contents), str(filename))).lastrowid
                db.execute('INSERT INTO message_attachment_join VALUES(?,?)', (row, attachment))
            db.commit()
            return row

    def test_caption_and_verified_independent_files_confirm_then_release_originals(self):
        content = bytes(range(256)) * (9*1024*1024//256)
        files = [self.upload(content, 'one.bin'), self.upload(b'', 'empty.txt')]
        outgoing = self.outgoing(files, 'Caption')
        self.send(outgoing)
        self.settled(outgoing)
        self.wait(lambda: all(part['candidate_message_id'] for part in self.record(outgoing)['parts']))
        provisional = self.record(outgoing)
        self.assertTrue(all(part['message_id'] is None for part in provisional['parts']))
        self.assertTrue(all(self.local(file).exists() for file in files))
        confirmed = self.confirmed(outgoing)
        ids = [part['message_id'] for part in confirmed['parts']]
        self.assertEqual(len(set(ids)), 3)
        self.assertTrue(all(part['state'] == 'delivered' for part in confirmed['parts']))
        self.assertTrue(all(part['candidate_message_id'] is None for part in confirmed['parts']))
        self.wait(lambda: all(not self.local(file).exists() for file in files))
        copies = [Path(row[2]).read_bytes() for row in self.source_rows()[1:]]
        self.assertEqual(copies, [content, b''])
        self.stop(); self.start()
        retried = self.send(outgoing, 200)
        self.assertEqual([part['message_id'] for part in retried['parts']], ids)
        self.assertEqual(len(self.source_rows()), 3)
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM uploads').fetchone()[0], 0)

    def test_same_name_and_size_with_different_bytes_match_the_correct_requests(self):
        first = self.outgoing([self.upload(b'one', 'same.bin')])
        second = self.outgoing([self.upload(b'two', 'same.bin')])
        self.send(first); self.settled(first)
        self.send(second); self.settled(second)
        one = self.confirmed(first)['parts'][0]['message_id']
        two = self.confirmed(second)['parts'][0]['message_id']
        self.assertNotEqual(one, two)
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            rows = [db.execute('SELECT source_row FROM messages WHERE id=?', (mid,)).fetchone()[0]
                    for mid in (one, two)]
        self.assertEqual(rows, [self.before+1, self.before+2])

    def test_identical_files_remain_ambiguous_across_retry_and_restart(self):
        files = [self.upload(b'same', 'same.bin'), self.upload(b'same', 'same.bin')]
        outgoing = self.outgoing(files)
        self.send(outgoing); self.settled(outgoing)
        time.sleep(11)
        record = self.record(outgoing)
        self.assertEqual(record['state'], 'unknown')
        self.assertTrue(all(part['message_id'] is None for part in record['parts']))
        self.assertTrue(all(part['candidate_message_id'] is None for part in record['parts']))
        self.assertTrue(all(self.local(file).exists() for file in files))
        self.stop(); self.start()
        self.send(outgoing, 200)
        self.assertEqual(len(self.source_rows()), 2)

    def test_an_unrelated_identical_echo_withdraws_the_provisional_match(self):
        upload = self.upload(b'same', 'same.bin')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is not None)
        self.echo(name='same.bin', contents=b'same')
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is None)
        time.sleep(10)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        self.assertTrue(self.local(upload).exists())

    def test_same_file_in_another_conversation_is_not_a_candidate(self):
        outgoing = self.outgoing([self.upload(b'same', 'same.bin')])
        self.send(outgoing); self.settled(outgoing)
        self.echo(name='same.bin', contents=b'same', chat=2)
        record = self.confirmed(outgoing)
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            row = db.execute('SELECT source_row FROM messages WHERE id=?',
                             (record['parts'][0]['message_id'],)).fetchone()[0]
        self.assertEqual(row, self.before+1)

    def test_changed_source_bytes_invalidate_cached_proof_until_restored(self):
        upload = self.upload(b'safe', 'file.bin')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is not None)
        copy = Path(self.source_rows()[0][2])
        copy.write_bytes(b'evil')
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is None)
        time.sleep(10)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        self.assertTrue(self.local(upload).exists())
        copy.write_bytes(b'safe')
        self.confirmed(outgoing)
        self.wait(lambda: not self.local(upload).exists())

    def test_missing_or_unsafe_source_files_cannot_confirm_or_release_uploads(self):
        files = [self.upload(b'one', 'missing.bin'), self.upload(b'two', 'symlink.bin'),
                 self.upload(b'three', 'outside.bin')]
        outgoing = self.outgoing(files)
        self.send(outgoing); self.settled(outgoing)
        copies = [Path(row[2]) for row in self.source_rows()]
        copies[0].unlink()
        copies[1].unlink(); copies[1].symlink_to(self.local(files[1]))
        outside = self.root/'outside'; outside.write_bytes(b'three')
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('UPDATE attachment SET filename=? WHERE transfer_name=?', (str(outside), 'outside.bin'))
            db.commit()
        time.sleep(11)
        self.assertTrue(all(part['message_id'] is None for part in self.record(outgoing)['parts']))
        self.assertTrue(all(part['candidate_message_id'] is None for part in self.record(outgoing)['parts']))
        self.assertTrue(all(self.local(file).exists() for file in files))
        copies[0].write_bytes(b'one')
        copies[1].unlink(); copies[1].write_bytes(b'two')
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('UPDATE attachment SET filename=? WHERE transfer_name=?', (str(copies[2]), 'outside.bin'))
            db.commit()
        self.confirmed(outgoing)

    def test_source_path_to_the_staged_original_is_not_an_independent_copy(self):
        self.stop()
        data = self.root/'source.db.attachments/relay-data'
        data.parent.mkdir(mode=0o700)
        self.args[self.args.index('--data-dir')+1] = str(data)
        subprocess.run([str(attachment_sends.relay_tls.BIN), 'setup', *self.args],
                       check=True, stdout=subprocess.DEVNULL)
        self.start()
        upload = self.upload(b'only original')
        original = data/'uploads'/upload['file']['id']/upload['file']['name']
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('UPDATE attachment SET filename=? WHERE ROWID IN '
                       '(SELECT attachment_id FROM message_attachment_join WHERE message_id>?)',
                       (str(original), self.before))
            db.commit()
        time.sleep(11)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        self.assertTrue(original.exists())

    def test_delayed_attachment_join_blocks_confirmation_until_it_is_resolved(self):
        outgoing = self.outgoing([self.upload(b'one', 'file.bin')])
        self.send(outgoing); self.settled(outgoing)
        pending = self.echo(pending=True)
        time.sleep(11)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        with closing(sqlite3.connect(self.source)) as db:
            db.execute("UPDATE message SET text='unrelated delayed text',is_finished=1 WHERE ROWID=?", (pending,))
            db.commit()
        self.confirmed(outgoing)

    def test_malformed_outgoing_records_cannot_disappear_from_the_uniqueness_check(self):
        outgoing = self.outgoing([self.upload(b'one', 'file.bin')])
        self.send(outgoing); self.settled(outgoing)
        with closing(sqlite3.connect(self.source)) as db:
            malformed = add_message(db, text=b'\xff\x00', is_from_me=1, is_sent=1, is_delivered=1)
            db.commit()
        time.sleep(11)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        with closing(sqlite3.connect(self.source)) as db:
            db.execute("UPDATE message SET text='decoded unrelated text' WHERE ROWID=?", (malformed,))
            db.commit()
        self.confirmed(outgoing)

    def test_failed_retirement_rolls_back_confirmation_and_preserves_the_original(self):
        upload = self.upload(b'owned original')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            db.execute("CREATE TRIGGER hold_original BEFORE UPDATE ON uploads "
                       "WHEN OLD.state='pinned' AND NEW.state='deleting' "
                       "BEGIN SELECT RAISE(ABORT,'fixture'); END")
            db.commit()
        time.sleep(11)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        self.assertTrue(self.local(upload).exists())
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute("SELECT state FROM uploads WHERE id=?", (upload['file']['id'],)).fetchone()[0], 'pinned')
            db.execute('DROP TRIGGER hold_original'); db.commit()
        self.confirmed(outgoing)
        self.wait(lambda: not self.local(upload).exists())

    def test_source_scan_budget_withdraws_hints_without_claiming_uniqueness(self):
        upload = self.upload(b'bounded work')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is not None)
        with closing(sqlite3.connect(self.source)) as db:
            for _ in range(4096):
                add_message(db, text='unrelated source activity', chat=2)
            db.commit()
        self.wait(lambda: self.record(outgoing)['parts'][0]['candidate_message_id'] is None)
        time.sleep(10)
        self.assertIsNone(self.record(outgoing)['parts'][0]['message_id'])
        self.assertTrue(self.local(upload).exists())

    def test_submission_retains_the_original_until_a_delivery_receipt(self):
        upload = self.upload(b'wait for receipt')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('UPDATE message SET is_delivered=0 WHERE ROWID>?', (self.before,))
            db.commit()
        self.wait(lambda: self.record(outgoing)['state'] == 'submitted', timeout=16)
        self.assertTrue(self.local(upload).exists())
        Path(self.source_rows()[0][2]).unlink()
        with closing(sqlite3.connect(self.source)) as db:
            for _ in range(4096):
                add_message(db, text='newer unrelated activity', chat=2)
            db.execute('UPDATE message SET is_delivered=1 WHERE ROWID=?', (self.before+1,))
            db.commit()
        self.confirmed(outgoing)
        self.wait(lambda: not self.local(upload).exists())

    def test_observed_failure_is_reported_without_releasing_or_resending_the_file(self):
        upload = self.upload(b'failed by Messages')
        outgoing = self.outgoing([upload])
        self.send(outgoing); self.settled(outgoing)
        with closing(sqlite3.connect(self.source)) as db:
            db.execute('UPDATE message SET error=42,is_delivered=0 WHERE ROWID>?', (self.before,))
            db.commit()
        self.wait(lambda: self.record(outgoing)['parts'][0]['state'] == 'failed', timeout=16)
        record = self.record(outgoing)
        self.assertEqual(record['state'], 'failed')
        self.assertEqual(record['error_info']['code'], 'observed_failure')
        self.assertEqual(record['parts'][0]['error_info']['outcome'], 'uncertain')
        self.assertTrue(self.local(upload).exists())
        self.send(outgoing, 200)
        self.assertEqual(len(self.source_rows()), 1)

    def test_a_partial_uncertain_send_can_confirm_its_echo_without_resuming_skipped_parts(self):
        files = [self.upload(b'one', 'fake-uncertain-after.bin'), self.upload(b'two')]
        outgoing = self.outgoing(files)
        self.send(outgoing); self.settled(outgoing)
        self.wait(lambda: self.record(outgoing)['parts'][0]['state'] == 'delivered', timeout=16)
        record = self.record(outgoing)
        self.assertEqual(record['state'], 'unknown')
        self.assertEqual(record['parts'][1]['state'], 'skipped')
        self.wait(lambda: all(not self.local(file).exists() for file in files))
        self.send(outgoing, 200)
        self.assertEqual(len(self.source_rows()), 1)

    def test_a_message_cannot_confirm_both_legacy_text_and_a_multipart_caption(self):
        legacy = self.outgoing([], '[fake:unknown]')
        multipart = self.outgoing([self.upload(b'unstarted')], '[fake:unknown]')
        self.send(legacy); self.settled(legacy)
        self.send(multipart); self.settled(multipart)
        with closing(sqlite3.connect(self.source)) as db:
            add_message(db, text='[fake:unknown]', is_from_me=1, is_sent=1, is_delivered=1)
            db.commit()
        time.sleep(11)
        self.assertIsNone(self.record(legacy)['message_id'])
        self.assertIsNone(self.record(legacy)['candidate_message_id'])
        self.assertIsNone(self.record(multipart)['parts'][0]['message_id'])
        self.assertIsNone(self.record(multipart)['parts'][0]['candidate_message_id'])


if __name__ == '__main__':
    unittest.main()
