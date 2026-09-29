#!/usr/bin/env python3
"""Drive attachment preparation, upload, and recovery through the real client worker."""
from contextlib import closing
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import sqlite3
import stat
import threading
import time
import unittest

import attachment_sends
from client_integration import wait
from client_media_transport import png, JPEG
from performance import Probe
from fixture import add_message
from tls_fixture import TLSServer
import relay_tls

BIN = Path(__file__).resolve().parents[1] / 'zig-out/bin/client-probe'


class ClientAttachments(unittest.TestCase):
    start = relay_tls.RelayTls.start
    stop = relay_tls.RelayTls.stop
    get = relay_tls.RelayTls.get
    source_rows = attachment_sends.AttachmentSends.source_rows

    def setUp(self):
        attachment_sends.AttachmentSends.setUp(self)
        self.client = self.root / 'client'
        self.client_log = (self.root / 'client.log').open('w+')
        self.probe = None
        self.proxy = None
        self.release = threading.Event()
        self.launch()

    def tearDown(self):
        self.release.set()
        if self.probe:
            self.probe.close()
        if self.proxy:
            self.proxy.close()
        self.client_log.close()
        relay_tls.RelayTls.tearDown(self)

    def launch(self, port=None):
        self.command_serial = 0
        self.probe = Probe([str(BIN), '--control', '--data-dir', str(self.client),
                            *self.tls.client_args(port=port)], self.client_log)
        self.probe.until(lambda v: v.get('online') and v.get('send_attachments'), timeout=15)

    def faultProxy(self, mode):
        self.probe.close()
        self.calls = []
        self.held = threading.Event()
        owner = self

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self): self.forward()
            def do_POST(self): self.forward()
            def do_PUT(self): self.forward()

            def forward(self):
                owner.calls.append((self.command, self.path))
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                is_put = self.command == 'PUT'
                is_send = self.command == 'POST' and self.path == '/v1/messages'
                if is_send and mode == 'lost_unaccepted_send':
                    self.send_response(202)
                    self.send_header('Content-Length', '5')
                    self.end_headers()
                    self.wfile.write(b'{')
                    return
                with closing(owner.tls.connection(timeout=30)) as connection:
                    headers = {name: self.headers[name] for name in ('Content-Type', 'Zimbr-Server-Epoch') if name in self.headers}
                    connection.request(self.command, self.path, body if self.command in ('PUT', 'POST') else None, headers)
                    response = connection.getresponse()
                    if self.path.startswith('/v1/events') and response.status == 200:
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.send_header('Zimbr-Event-Extensions', response.getheader('Zimbr-Event-Extensions', ''))
                        self.end_headers()
                        frame = bytearray()
                        try:
                            while line := response.readline():
                                frame.extend(line)
                                if line.strip():
                                    continue
                                if mode != 'lost_accepted_send' or b'event: send_request.updated' not in frame:
                                    self.wfile.write(frame)
                                frame.clear()
                        except (OSError, http.client.HTTPException):
                            pass
                        return
                    raw = response.read()
                    if (is_put and mode == 'hold_upload') or (is_send and mode == 'lost_accepted_send'):
                        owner.held.set()
                        owner.release.wait(timeout=25)
                    truncate = is_put and mode == 'lost_upload_response'
                    self.send_response(response.status)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(raw) + int(truncate)))
                    self.end_headers()
                    self.wfile.write(raw)

        self.proxy = TLSServer(Proxy, self.tls.server_context())
        self.launch(self.proxy.server_port)

    def rows(self, query, args=(), path=None):
        with closing(sqlite3.connect(path or self.client / 'client.db')) as db:
            return db.execute(query, args).fetchall()

    def stage(self, name, data, key='new:alice@example.invalid'):
        source = self.root / name
        source.write_bytes(data)
        before = self.rows('SELECT count(*) FROM outgoing_files')[0][0]
        self.command_serial += 1
        self.probe.command(kind='attach', key=key, text=str(source), serial=self.command_serial)
        wait(lambda: self.rows('SELECT count(*) FROM outgoing_files')[0][0] == before + 1)
        self.probe.until(lambda v: not v.get('preparing_attachments') and
                         v.get('command_serial', 0) >= self.command_serial, timeout=10)
        record = json.loads(self.rows('SELECT record FROM outgoing_files ORDER BY rowid DESC LIMIT 1')[0][0])
        self.assertEqual(record['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual((self.client / 'outgoing' / record['id']).read_bytes(), data)
        self.assertEqual(stat.S_IMODE((self.client / 'outgoing' / record['id']).stat().st_mode), 0o600)
        return source, record

    def send(self, text='', key='new:alice@example.invalid'):
        self.probe.command(kind='send', key=key, recipient='alice@example.invalid', text=text)
        wait(lambda: self.rows('SELECT count(*) FROM outbox')[0][0] > 0)
        return self.rows('SELECT id FROM outbox ORDER BY rowid DESC LIMIT 1')[0][0]

    def test_originals_and_empty_files_send_after_source_changes_and_restart(self):
        key = 'new:alice@example.invalid'
        self.probe.command(kind='select', key=key)
        data = bytes(range(256)) * (9 * 4096)
        source, first = self.stage('résumé ; $x.dat', data)
        empty_source, empty = self.stage('empty.txt', b'')
        source.write_bytes(b'changed source')
        empty_source.unlink()
        self.probe.close()
        self.launch()
        self.probe.command(kind='select', key=key)
        self.probe.until(lambda v: len(v.get('draft_attachments', [])) == 2)
        request_id = self.send('Caption 👋')
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('delivered',)], timeout=20)
        rows = self.source_rows()
        self.assertEqual([row[0] for row in rows], ['Caption 👋', '', ''])
        self.assertEqual(Path(rows[1][2]).read_bytes(), data)
        self.assertEqual(Path(rows[2][2]).read_bytes(), b'')
        self.assertEqual([row[1] for row in rows[1:]], [first['name'], empty['name']])
        payload, record = self.rows('SELECT payload,record FROM outbox WHERE id=?', (request_id,))[0]
        self.assertEqual([item['id'] for item in json.loads(payload)['attachments']], [first['id'], empty['id']])
        self.assertEqual([part['state'] for part in json.loads(record)['parts']], ['delivered'] * 3)
        parts = json.loads(record)['parts']
        echo_ids = {part['message_id'] for part in parts}
        self.probe.until(lambda v: v.get('selected') and not v['selected'].startswith('new:') and
                         v.get('messages', 0) >= 3 and not v.get('pending'), timeout=15)
        self.assertTrue(echo_ids <= {row[0] for row in self.rows("SELECT id FROM records WHERE kind='message'")})
        wait(lambda: self.rows('SELECT count(*) FROM outgoing_files') == [(0,)])
        self.assertEqual(list((self.client / 'outgoing').iterdir()), [])
        self.probe.close()
        self.launch()
        time.sleep(.5)
        self.assertEqual(self.source_rows(), rows)

    def test_local_previews_use_private_originals_offline_and_bound_decoding(self):
        source, photo = self.stage('photo.png', png())
        _, jpeg = self.stage('photo.jpg', JPEG)
        _, document = self.stage('document.pdf', b'%PDF test')
        _, large = self.stage('oversized.png', png(50000, 50000))
        source.unlink()
        self.stop()
        self.probe.until(lambda v: not v.get('online'))
        self.probe.command(kind='media_context', epoch='', chat='draft', online=False)

        def preview(file):
            self.probe.command(kind='local_media', file=file)
            self.probe.until(lambda v: 'media' in v, timeout=5)
            return self.probe.latest['media']

        first = preview(photo)
        self.assertEqual((first['state'], first['width'], first['height']), ('ready', 2, 3))
        second = preview(jpeg)
        self.assertEqual((second['state'], second['width'], second['height']), ('ready', 4, 3))
        self.assertNotEqual(first['key'], second['key'])
        for file in (document, large):
            result = preview(file)
            self.assertEqual((result['state'], result['bytes']), ('failed', 0))
        original = self.client / 'outgoing' / photo['id']
        original.unlink()
        original.symlink_to(self.client / 'outgoing' / jpeg['id'])
        self.assertEqual(preview(photo)['state'], 'failed')
        self.assertEqual(preview(jpeg)['state'], 'ready')
        self.assertEqual(self.rows('SELECT count(*) FROM outgoing_files WHERE draft_key IS NOT NULL'), [(4,)])
        self.assertEqual(self.rows('SELECT count(*) FROM outbox'), [(0,)])

    def test_corrupt_second_original_cannot_dispatch_its_caption_or_first_file(self):
        _, first = self.stage('first.bin', b'good')
        _, second = self.stage('second.bin', b'original')
        (self.client / 'outgoing' / second['id']).write_bytes(b'modified')
        request_id = self.send('Keep this caption with its files')
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('failed',)])
        self.assertEqual(self.source_rows(), [])
        self.assertEqual(self.rows('SELECT count(*) FROM send_requests', path=self.root / 'data/relay.db'), [(0,)])
        self.assertEqual(self.rows('SELECT count(*) FROM outgoing_files WHERE request_id=?', (request_id,)), [(2,)])
        self.assertEqual((self.client / 'outgoing' / first['id']).read_bytes(), b'good')

    def test_offline_preparation_removal_and_invalid_sources_leave_the_client_usable(self):
        self.stop()
        self.probe.until(lambda v: not v.get('online'))
        key = 'new:alice@example.invalid'
        source, file = self.stage('offline.pdf', b'%PDF test')
        self.probe.command(kind='send', key=key, recipient='alice@example.invalid', text='Offline caption')
        wait(lambda: self.rows('SELECT text FROM drafts WHERE key=?', (key,)) == [('Offline caption',)])
        self.assertEqual(self.rows('SELECT count(*) FROM outbox'), [(0,)])
        self.probe.command(kind='remove_attachment', key=key, text=file['id'])
        wait(lambda: not (self.client / 'outgoing' / file['id']).exists())
        link = self.root / 'symlink.pdf'
        link.symlink_to(source)
        self.probe.command(kind='attach', key=key, text=str(link))
        self.probe.until(lambda v: 'local regular file' in v.get('attachment_error', ''))
        self.assertEqual(self.rows('SELECT count(*) FROM outgoing_files'), [(0,)])
        self.start()
        self.probe.command(kind='reconnect')
        self.probe.until(lambda v: v.get('online'))
        self.assertEqual(self.rows('SELECT text FROM drafts WHERE key=?', (key,)), [('Offline caption',)])

    def test_lost_upload_response_reuses_verified_bytes_and_the_same_request(self):
        self.faultProxy('lost_upload_response')
        _, file = self.stage('retry.bin', b'\x00original\xff' * 1024)
        request_id = self.send()
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('delivered',)], timeout=25)
        self.assertEqual(self.calls.count(('PUT', '/v1/uploads/' + file['id'])), 1)
        self.assertEqual(self.calls.count(('POST', '/v1/messages')), 1)
        self.assertGreaterEqual(self.calls.count(('GET', '/v1/send-requests/' + request_id)), 2)
        self.assertEqual(len(self.source_rows()), 1)

    def test_live_events_and_drafts_continue_during_upload_and_cancel_prevents_submission(self):
        self.faultProxy('hold_upload')
        key = self.rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(record,'$.participants')=1")[0][0]
        self.probe.command(kind='select', key=key)
        _, file = self.stage('large.bin', b'\x00\xff' * (9 * 512 * 1024), key=key)
        request_id = self.send('Cancel this caption', key=key)
        self.assertTrue(self.held.wait(timeout=10))
        self.probe.until(lambda v: v.get('upload', {}).get('phase') == 'transfer' and v['upload']['bytes'] == int(file['bytes']), timeout=5)
        self.probe.command(kind='draft', key=key, text='Next draft while uploading')
        wait(lambda: self.rows('SELECT text FROM drafts WHERE key=?', (key,)) == [('Next draft while uploading',)], timeout=3)
        with closing(sqlite3.connect(self.source)) as db:
            add_message(db, 'Live during attachment upload')
            db.commit()
        wait(lambda: self.rows("SELECT count(*) FROM records WHERE kind='message' AND json_extract(record,'$.text')='Live during attachment upload'") == [(1,)], timeout=3)
        self.probe.command(kind='cancel_upload', key=request_id)
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('cancelled',)])
        self.release.set()
        self.probe.close()
        self.launch(self.proxy.server_port)
        time.sleep(.5)
        self.assertEqual(self.calls.count(('POST', '/v1/messages')), 0)
        self.assertEqual(self.rows('SELECT count(*) FROM outgoing_files WHERE request_id=?', (request_id,)), [(1,)])
        self.assertEqual(self.rows('SELECT count(*) FROM send_requests', path=self.root / 'data/relay.db'), [(0,)])

    def test_restart_resolves_accepted_request_after_relay_uploads_are_already_gone(self):
        self.faultProxy('lost_accepted_send')
        _, file = self.stage('accepted.bin', b'accepted original')
        request_id = self.send()
        self.assertTrue(self.held.wait(timeout=10))
        self.assertEqual(self.rows('SELECT state,record FROM outbox WHERE id=?', (request_id,)), [('sending', None)])
        self.probe.proc.kill()
        self.probe.proc.wait(timeout=5)
        self.probe.close()
        wait(lambda: self.rows("SELECT state FROM send_requests WHERE id=?", (request_id,), self.root / 'data/relay.db') == [('delivered',)], timeout=18)
        wait(lambda: self.rows('SELECT count(*) FROM uploads', path=self.root / 'data/relay.db') == [(0,)])
        self.release.set()
        self.launch(self.proxy.server_port)
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('delivered',)])
        self.assertEqual(self.calls.count(('POST', '/v1/messages')), 1)
        self.assertEqual(self.calls.count(('POST', '/v1/uploads')), 1)
        self.assertEqual(self.calls.count(('PUT', '/v1/uploads/' + file['id'])), 1)
        self.assertGreaterEqual(self.calls.count(('GET', '/v1/send-requests/' + request_id)), 2)
        self.assertEqual(len(self.source_rows()), 1)

    def test_unaccepted_uncertain_submission_is_held_without_automatic_replay(self):
        self.faultProxy('lost_unaccepted_send')
        _, file = self.stage('uncertain.bin', b'keep local original')
        request_id = self.send()
        wait(lambda: self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)) == [('unconfirmed',)], timeout=15)
        self.probe.close()
        self.launch(self.proxy.server_port)
        time.sleep(.5)
        self.assertEqual(self.calls.count(('POST', '/v1/messages')), 1)
        self.assertEqual(self.source_rows(), [])
        self.assertEqual((self.client / 'outgoing' / file['id']).read_bytes(), b'keep local original')

    def test_unavailable_private_storage_keeps_the_attachment_and_caption_in_the_draft(self):
        _, file = self.stage('private.bin', b'private original')
        self.probe.close()
        (self.client / 'outgoing').chmod(0o755)
        self.probe = Probe([str(BIN), '--control', '--data-dir', str(self.client),
                            *self.tls.client_args()], self.client_log)
        self.probe.until(lambda v: v.get('online') and not v.get('send_attachments'))
        key = 'new:alice@example.invalid'
        self.probe.command(kind='send', key=key, recipient='alice@example.invalid', text='Keep this draft')
        self.probe.until(lambda v: v.get('ack') == 1)
        self.assertEqual(self.rows('SELECT count(*) FROM outbox'), [(0,)])
        self.assertEqual(self.rows('SELECT text FROM drafts WHERE key=?', (key,)), [('Keep this draft',)])
        self.assertEqual(self.rows('SELECT draft_key FROM outgoing_files WHERE id=?', (file['id'],)), [(key,)])

    def test_relay_epoch_change_holds_an_upload_without_submitting_in_the_new_epoch(self):
        self.faultProxy('hold_upload')
        _, file = self.stage('old-epoch.bin', b'old epoch original')
        request_id = self.send('Keep with the old request')
        self.assertTrue(self.held.wait(timeout=10))
        epoch = self.rows("SELECT value FROM meta WHERE key='epoch'")[0][0]
        with closing(self.tls.connection()) as connection:
            connection.request('POST', '/v1/reset', json.dumps(dict(server_epoch=epoch)), {'Content-Type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            next_epoch = json.loads(response.read())['server_epoch']
        wait(lambda: self.rows("SELECT value FROM meta WHERE key='epoch'") == [(next_epoch,)], timeout=15)
        self.release.set()
        self.assertEqual(self.rows('SELECT state FROM outbox WHERE id=?', (request_id,)), [('unknown',)])
        self.assertEqual(self.calls.count(('POST', '/v1/messages')), 0)
        self.assertEqual((self.client / 'outgoing' / file['id']).read_bytes(), b'old epoch original')


if __name__ == '__main__':
    unittest.main()
