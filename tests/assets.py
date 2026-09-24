#!/usr/bin/env python3
"""Real asset/journal/HTTP service with synthetic sources and a fake converter."""
from contextlib import closing
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid
from urllib.parse import urlencode

from fixture import create, add_message
from integration import database, wait_for
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/fake-relay'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-assets-') as temporary:
        root = Path(temporary).resolve()
        source, data = root / 'source.db', root / 'data'
        attachments = root / 'source.db.attachments'
        attachments.mkdir(mode=0o700)
        create(source, count=4)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(data), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN), 'setup', *args], check=True, stdout=subprocess.DEVNULL)
        with database(source) as db:
            db.executescript('ALTER TABLE attachment ADD COLUMN filename TEXT; ALTER TABLE attachment ADD COLUMN uti TEXT; ALTER TABLE attachment ADD COLUMN transfer_state INTEGER;')
            mid = add_message(db, 'Caption with several images 👩‍💻')
            for i in range(40):
                path = attachments / f'image-{i}'
                path.write_bytes(b'ZIMBR-IMAGE fixture')
                db.execute('INSERT INTO attachment VALUES(?,?,?,?,?,?,?,?)', (i + 10, 'private-attachment-' + str(i), f'photo-{i}.heic', '', 18, str(path), 'public.heic', 0))
                db.execute('INSERT INTO message_attachment_join VALUES(?,?)', (mid, i + 10))
        log = open(root / 'relay.log', 'w+')
        process = None

        def start():
            return subprocess.Popen([str(BIN), 'serve', *args], stdout=log, stderr=log)

        def request(path, headers=None, auth=True, body=None):
            with closing(tls.connection(timeout=5, auth=auth)) as conn:
                headers = dict(headers or {})
                if body is not None: headers['Content-Type'] = 'application/json'
                conn.request('POST' if body is not None else 'GET', path, json.dumps(body) if body is not None else None, headers=headers)
                response = conn.getresponse()
                payload = response.read()
                return response.status, dict(response.getheaders()), json.loads(payload) if response.getheader('content-type', '').startswith('application/json') else payload

        def canonical():
            with sqlite3.connect(data / 'relay.db') as db:
                row = db.execute('SELECT record FROM messages WHERE source_row=?', (mid,)).fetchone()
                return json.loads(row[0]) if row else {}

        def path(ref):
            return f'/v1/assets/{ref["id"]}/{ref["version"]}/{ref["variant"]}'

        def ready(index=0, variant='image'):
            message = canonical()
            items = message.get('attachments', [])
            if len(items) <= index or not items[index].get(variant):
                return False
            ref = items[index][variant]
            status, headers, body = request(path(ref))
            return (ref, headers, body) if status == 200 else False

        try:
            process = start()
            wait_for(lambda: request('/v1/status')[2].get('adapter_ready'))
            wait_for(lambda: canonical().get('attachments', [{}])[0].get('image'))
            message = canonical()
            assert message['text'] == 'Caption with several images 👩‍💻'
            assert message['enrichment']['attachments'] == {'total': 40, 'complete': False}
            assert len(message['attachments']) <= 32
            assert message['parts'][0]['kind'] == 'text'
            assert message['parts'][0]['text_length'] == len(message['text'].encode())
            assert all(p['source_index'] is None for p in message['parts'])
            metadata = {k: message[k] for k in ('attachments', 'parts', 'enrichment', 'link_previews', 'reactions', 'reaction_event')}
            assert len(json.dumps(metadata, ensure_ascii=False, separators=(',', ':')).encode()) <= 32768
            assert str(attachments) not in json.dumps(message)
            assert 'private-attachment-' not in json.dumps(message)
            endpoint = '/v1/messages/' + message['id'] + '/enrichment?'
            params = dict(section='attachments', revision=message['revision'], limit=7)
            all_items = []
            while True:
                status, _, page = request(endpoint + urlencode(params))
                assert status == 200
                assert len(json.dumps(page, separators=(',', ':')).encode()) <= 32768
                all_items.extend(page['items'])
                if not page['next']:
                    break
                params['after'] = page['next']
            assert len(all_items) == 40
            assert [item['name'] for item in all_items] == [f'photo-{i}.heic' for i in range(40)]
            ref = message['attachments'][0]['image']
            first_status, first_headers, first = request(path(ref))
            assert first_status == 409 and first['retryable']
            assert first_headers['retry-after'] == '2'
            ref, headers, image = wait_for(ready)
            assert image.startswith(b'\x89PNG\r\n\x1a\n')
            assert headers['content-type'] == 'image/png'
            assert headers['content-length'] == str(len(image))
            assert headers['x-content-type-options'] == 'nosniff'
            assert headers['cache-control'].startswith('private')
            assert headers['etag'] == '"' + hashlib.sha256(image).hexdigest() + '"'
            assert request(path(ref), {'If-None-Match': headers['etag']})[0] == 304
            assert request('/v1/assets/' + str(uuid.uuid4()) + '/' + ref['version'] + '/inline_image')[0] == 404
            assert request('/v1/assets/' + ref['id'] + '/' + str(uuid.uuid4()) + '/inline_image')[0] == 410
            assert request('/v1/assets/../../etc/passwd')[0] == 400
            try:
                request(path(ref), auth=False)
            except (OSError, http.client.HTTPException):
                pass
            else:
                raise AssertionError('Asset route accepted an unenrolled peer')
            assert request(endpoint + urlencode(params))[0] == 409  # conversion changed owner revision
            current = canonical()
            assert current['timestamp'] == message['timestamp']
            assert current['observed_status'] == message['observed_status']
            assert current['text'] == message['text']
            with sqlite3.connect(data / 'relay.db') as db:
                changes = db.execute("SELECT origin FROM events WHERE type='message.upsert' AND json_extract(record,'$.id')=? ORDER BY sequence DESC LIMIT 1", (current['id'],)).fetchone()
                assert changes == ('reconciliation',)
                cache_name = db.execute('SELECT file_name FROM asset_representations WHERE asset_id=? AND version=? AND variant=?', (ref['id'], ref['version'], ref['variant'])).fetchone()[0]
            cache_file = data / 'assets' / cache_name
            assert cache_file.stat().st_mode & 0o777 == 0o600
            # Eviction regenerates the same immutable bytes and ETag.
            cache_file.unlink()
            assert request(path(ref))[0] == 409
            ref2, headers2, image2 = wait_for(ready)
            assert ref2['version'] == ref['version'] and image2 == image
            assert headers2['etag'] == headers['etag']
            # A source change retires the old generation and updates its owner.
            (attachments / 'image-0').write_bytes(b'ZIMBR-IMAGE changed input')
            wait_for(lambda: canonical()['attachments'][0]['image']['version'] != ref['version'])
            assert request(path(ref))[0] == 410
            new_ref, _, _ = wait_for(ready)
            assert new_ref['id'] == ref['id']

            # A root replacement must invalidate descriptors into the old tree.
            old_root = root / 'old-attachments'
            attachments.rename(old_root)
            attachments.symlink_to(old_root, target_is_directory=True)
            wait_for(lambda: canonical()['attachments'][0]['image'].get('reason') == 'unsafe_source')
            attachments.unlink()
            attachments.mkdir(mode=0o700)
            for i in range(40):
                (attachments / f'image-{i}').write_bytes(b'ZIMBR-IMAGE replacement root')
            wait_for(lambda: canonical()['attachments'][0]['image']['availability'] == 'pending')
            assert request(path(new_ref))[0] == 410
            new_ref, _, _ = wait_for(ready)
            # Missing and delayed source files reconcile without a new row.
            missing_path = attachments / 'image-1'
            missing_path.unlink()
            wait_for(lambda: canonical()['attachments'][1]['image']['availability'] == 'not_local')
            unavailable = canonical()['attachments'][1]['image']
            code, _, pending = request(path(unavailable))
            assert code == 409 and pending['retryable']
            missing_path.write_bytes(b'ZIMBR-IMAGE arrived later')
            wait_for(lambda: ready(1), timeout=40)
            # The helper is not invoked on traversal/symlink/non-regular paths.
            (attachments / 'outside-link').symlink_to(root / 'outside')
            (root / 'outside').write_bytes(b'ZIMBR-IMAGE outside root')
            os.mkfifo(attachments / 'pipe')
            for index, unsafe in ((2, str(attachments / '../outside')), (3, str(attachments / 'outside-link')), (4, str(attachments / 'pipe')), (9, str(attachments / 'image-9') + '\0hidden')):
                with database(source) as db:
                    db.execute('UPDATE attachment SET filename=? WHERE ROWID=?', (unsafe, index + 10))
                wait_for(lambda index=index: canonical()['attachments'][index]['image'].get('reason') == 'unsafe_source')
                code, _, result = request(path(canonical()['attachments'][index]['image']))
                assert code == 409 and not result['retryable']
            # Unsupported bytes and oversized sources retain a usable message.
            (attachments / 'image-5').write_bytes(b'not an image')
            wait_for(lambda: canonical()['attachments'][5]['image']['availability'] == 'pending')
            request(path(canonical()['attachments'][5]['image']))
            wait_for(lambda: canonical()['attachments'][5]['image']['availability'] == 'unsupported')
            with (attachments / 'image-6').open('wb') as output:
                output.truncate(100 * 1024 * 1024 + 1)
            wait_for(lambda: canonical()['attachments'][6]['image']['availability'] == 'oversized')
            assert canonical()['text'] == message['text']
            # Four deliberately stalled large responses exhaust only the
            # reserved asset lane. Commands/history/SSE stay responsive.
            (attachments / 'image-7').write_bytes(b'ZIMBR-IMAGE-LARGE')
            large, _, large_body = wait_for(lambda: ready(7), timeout=40)
            assert len(large_body) == 8 * 1024 * 1024
            slow = []
            try:
                for _ in range(4):
                    conn = tls.connection(timeout=5); conn.connect()
                    conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                    conn.request('GET', path(large))
                    response = conn.getresponse()
                    assert response.status == 200
                    slow.append((conn, response))
                code, retry, _ = request(path(large))
                assert code == 503 and retry['retry-after'] == '2'
                started = time.monotonic()
                code, _, sync = request('/v1/sync'); assert code == 200
                assert request('/v1/conversations')[0] == 200
                outgoing = dict(request_id=str(uuid.uuid4()), server_epoch=sync['server_epoch'], target={'recipient': {'address': 'alice@example.invalid', 'service': 'imessage'}}, text='Send during slow image transfer')
                assert request('/v1/messages', body=outgoing)[0] == 202
                with closing(tls.connection(timeout=5)) as events:
                    events.request('GET', '/v1/events?after=' + sync['cursor'])
                    response = events.getresponse(); assert response.status == 200
                    while True:
                        line = response.fp.readline(); assert line
                        if line.startswith(b'data: ') and json.loads(line[6:])['type'] == 'send_request.updated': break
                assert time.monotonic() - started < 3
                # Stop reading entirely; the server's absolute deadline releases
                # its four response slots without requiring a client close.
                wait_for(lambda: request(path(large))[0] == 200, timeout=18)
            finally:
                for conn, response in slow: response.close(); conn.close()
            # Managed orphan derivatives from a crash/reset are swept, while
            # current referenced files survive the same pass.
            orphan = data / 'assets' / f'{uuid.uuid4()}-{uuid.uuid4()}-inline_image'
            orphan.write_bytes(b'orphan fixture')
            wait_for(lambda: not orphan.exists(), timeout=15)
            epoch = request('/v1/sync')[2]['server_epoch']
            process.terminate(); process.wait(timeout=5)
            process = start()
            wait_for(lambda: request('/v1/status')[2].get('adapter_ready'))
            assert request('/v1/sync')[2]['server_epoch'] == epoch
            assert request(path(new_ref))[0] == 200
            # Reset while a decoder is in flight: the old completion must not
            # publish into the new epoch or revive its old asset ownership.
            slow_before = canonical()['attachments'][8]['image']
            (attachments / 'image-8').write_bytes(b'ZIMBR-TIMEOUT')
            wait_for(lambda: canonical()['attachments'][8]['image']['version'] != slow_before['version'])
            old_pending = canonical()['attachments'][8]['image']
            assert request(path(old_pending))[0] == 409
            wait_for(lambda: list((data / 'assets').glob('.tmp-*')))
            replacement = root / 'replacement.db'
            with sqlite3.connect(source) as src, sqlite3.connect(replacement) as dst: src.backup(dst)
            replacement.replace(source)
            wait_for(lambda: request('/v1/sync')[2]['server_epoch'] != epoch)
            assert request(path(old_pending))[0] == 404
            wait_for(lambda: canonical().get('attachments', [{}])[0].get('image'))
            current_pending = canonical()['attachments'][8]['image']
            assert current_pending['id'] != old_pending['id']
            wait_for(lambda: not list((data / 'assets').glob('.tmp-*')), timeout=20)
            assert canonical()['attachments'][8]['image']['availability'] == 'pending'
            assert canonical()['attachments'][8]['image']['reason'] == 'conversion_pending'
            print('PASS: caption/overflow metadata, mTLS assets, ETag/304, immutable versions, eviction/regeneration, delayed files, unsafe paths, corrupt/oversized sources, slow-reader bounds and command/SSE capacity, orphan cleanup, restart, in-flight epoch invalidation')
        except Exception:
            log.seek(0); print(log.read())
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=5)
            log.close()


if __name__ == '__main__':
    main()
