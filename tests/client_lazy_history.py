#!/usr/bin/env python3
"""Text stays available while contact and visible-message metadata GETs stall."""
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from client_tls import EPOCH, Handler
from performance import Probe, wait
from tls_fixture import PKI, TLSServer

ROOT = Path(__file__).resolve().parents[1]
CHAT = '11111111-1111-1111-1111-111111111111'
OTHER = '22222222-2222-2222-2222-222222222222'
PHOTO = '33333333-3333-3333-3333-333333333333'
OLDER = '44444444-4444-4444-4444-444444444444'
OTHER_MESSAGE = '55555555-5555-5555-5555-555555555555'
ECHO = '66666666-6666-6666-6666-666666666666'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-lazy-history-') as tmp:
        root = Path(tmp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        pki = PKI(root/'pki')
        contacts_held, contacts_release = threading.Event(), threading.Event()
        metadata_held, metadata_release = threading.Event(), threading.Event()
        metadata_requests = []
        submissions, echo_requests = [], []
        fail_metadata = False

        def message(mid, chat, text, deferred=False):
            return dict(id=mid, revision='1', conversation_id=chat,
                        sender='peer@example.invalid', direction='incoming',
                        service='imessage', timestamp='2026-01-01T00:00:00Z',
                        kind='attachment' if deferred else 'text', text=text,
                        decoding='plain', observed_status='received',
                        metadata_deferred=deferred)

        class Endpoint(Handler):
            def response(self, body, status=200):
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                assert self.path == '/v1/messages'
                value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                submissions.append(dict(value, state='delivered', revision='41', message_id=ECHO))
                self.response(submissions[-1], 202)

            def do_GET(self):
                path = urlsplit(self.path)
                query = parse_qs(path.query)
                try:
                    if path.path == '/v1/status':
                        return self.response(dict(
                            api_version='1', server_epoch=EPOCH, adapter_ready=True,
                            event_extensions=['identity-v1'], degraded_reasons=[],
                            capabilities=dict(send_direct=True, reply_existing=True,
                                              identity_directory_v1=True, text_first_history_v1=True)))
                    if path.path == '/v1/conversations':
                        chats = [dict(id=cid, service='imessage') for cid in (CHAT, OTHER)]
                        return self.response(dict(conversations=chats, previews=[], next=None))
                    if path.path == '/v1/identities':
                        contacts_held.set()
                        contacts_release.wait(timeout=20)
                        return self.response(dict(identities=[], next=None))
                    if path.path == '/v1/events':
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.send_header('Zimbr-Event-Extensions', 'identity-v1')
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        self.close_connection = True
                        # Relay backfill/reconciliation must not populate the
                        # local archive, even while a conversation is open.
                        for index in range(40):
                            value = message(f'archive-{index}', CHAT, 'Unrequested older history')
                            value['timestamp'] = '2010-01-01T00:00:00Z'
                            sequence = str(index + 1)
                            cursor = EPOCH + ':' + sequence
                            event = dict(cursor=cursor, sequence=sequence, type='message.upsert',
                                         origin='historical_import' if index % 2 else 'reconciliation',
                                         record=value)
                            self.wfile.write(f'id: {cursor}\nevent: message.upsert\ndata: {json.dumps(event)}\n\n'.encode())
                        for _ in range(200):
                            self.wfile.write(b': heartbeat\n\n')
                            self.wfile.flush()
                            time.sleep(.1)
                        return
                    if path.path.endswith('/messages'):
                        assert query.get('content') == ['text']
                        if OTHER in path.path:
                            values = [message(OTHER_MESSAGE, OTHER, 'Other conversation text')]
                            cursor = None
                        elif 'before' in query:
                            values = [message(OLDER, CHAT, 'Older text loads during metadata request')]
                            cursor = None
                        else:
                            values = [message(PHOTO, CHAT, 'Caption renders before the photo 👋', True)]
                            cursor = 'older-page'
                        return self.response(dict(messages=values, next=cursor))
                    if path.path == '/v1/messages/' + PHOTO:
                        metadata_requests.append(PHOTO)
                        metadata_held.set()
                        metadata_release.wait(timeout=20)
                        if fail_metadata:
                            return self.response({}, 503)
                        value = message(PHOTO, CHAT, 'Caption renders before the photo 👋')
                        value['kind'] = 'attachment'
                        value['attachments'] = [dict(id='photo', name='Photo', mime_type='image/png', bytes='1')]
                        return self.response(value)
                    if path.path == '/v1/messages/' + ECHO:
                        echo_requests.append(ECHO)
                        value = message(ECHO, OTHER, submissions[-1]['text'])
                        value.update(direction='outgoing', observed_status='delivered')
                        return self.response(value)
                    if path.path.startswith('/v1/send-requests/') and submissions:
                        return self.response(submissions[-1])
                    return super().do_GET()
                except (BrokenPipeError, ConnectionResetError):
                    self.close_connection = True

        server = TLSServer(Endpoint, pki.context())
        server.mode, server.requests = 'ok', []
        log = open(root/'client.log', 'w+')
        data = root/'client'
        probe = Probe([str(ROOT/'zig-out/bin/client-probe'), '--control', '--data-dir', str(data),
                       *pki.client_args(server.server_port)], log)

        def record(mid):
            with sqlite3.connect(data/'client.db') as db:
                row = db.execute("SELECT record FROM records WHERE kind='message' AND id=?", (mid,)).fetchone()
                return json.loads(row[0]) if row else None

        try:
            assert contacts_held.wait(timeout=10)
            probe.command(kind='select', key=CHAT)
            probe.until(lambda v: v['selected'] == CHAT and v['messages'] == 1, timeout=3)
            assert not contacts_release.is_set()
            assert record(PHOTO)['text'] == 'Caption renders before the photo 👋'
            assert record(PHOTO)['metadata_deferred']
            assert metadata_requests == [], 'Offscreen metadata must not load automatically'
            contacts_release.set()
            probe.until(lambda v: v['online'], timeout=5)
            probe.until(lambda v: v['diagnostics']['cursor'] == EPOCH + ':40', timeout=3)
            with sqlite3.connect(data/'client.db') as db:
                assert db.execute("SELECT count(*) FROM records WHERE kind='message'").fetchone()[0] == 1
                assert db.execute('SELECT count(*) FROM unread').fetchone()[0] == 0

            probe.command(kind='hydrate', key=CHAT, text=json.dumps([PHOTO]))
            assert metadata_held.wait(timeout=5)
            probe.command(kind='older')
            probe.until(lambda v: v['selected'] == CHAT and v['messages'] == 2, timeout=3)
            assert record(OLDER) and not metadata_release.is_set()
            probe.command(kind='select', key=OTHER)
            probe.until(lambda v: v['selected'] == OTHER and v['messages'] == 1, timeout=3)
            assert record(OTHER_MESSAGE)['text'] == 'Other conversation text'
            assert not metadata_release.is_set()

            # Returning to the caption can retry metadata without disturbing text.
            fail_metadata = True
            metadata_release.set()
            probe.command(kind='select', key=CHAT)
            probe.until(lambda v: v['selected'] == CHAT and v['messages'] == 2, timeout=3)
            probe.command(kind='hydrate', key=CHAT, text=json.dumps([PHOTO]))
            probe.until(lambda v: v['diagnostics']['last_http_status'] == 503, timeout=5)
            assert probe.latest['online']
            assert record(PHOTO)['metadata_deferred']
            fail_metadata = False
            wait(lambda: not record(PHOTO).get('metadata_deferred'), timeout=8)
            assert record(PHOTO)['attachments'][0]['id'] == 'photo'
            assert record(PHOTO)['text'] == 'Caption renders before the photo 👋'
            # A send result can reference an echo outside cached history. Fetch
            # that message by ID and resolve the direct conversation, never POST again.
            direct = 'new:echo@example.invalid'
            probe.command(kind='select', key=direct)
            probe.command(kind='send', key=direct, recipient='echo@example.invalid', text='Fixture echo')
            probe.until(lambda v: v['selected'] == OTHER and v['pending'] == 0, timeout=8)
            assert record(ECHO)['text'] == 'Fixture echo'
            assert len(submissions) == 1 and echo_requests == [ECHO]
            print('PASS: background archive stays uncached, explicit older history, uncached send echo recovery, text before contacts/media, visible-only metadata, selection preemption and metadata failure isolation')
        finally:
            contacts_release.set()
            metadata_release.set()
            probe.close()
            server.close()
            log.close()


if __name__ == '__main__':
    main()
