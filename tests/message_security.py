#!/usr/bin/env python3
"""Adversarial source messages and send bodies through the native mTLS relay."""
from contextlib import closing
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import uuid

from fixture import create, add_message
from integration import database, wait_for
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/fake-relay'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-message-security-') as temporary:
        root = Path(temporary).resolve()
        source, data = root / 'source.db', root / 'data'
        create(source, count=1)
        with database(source) as db:
            rows = {}
            for name, text, decoding in (
                ('nul', 'visible\0hidden', 'malformed'),
                ('invalid-utf8', b'bad\xff', 'malformed'),
                ('oversized', '😀' * 16385, 'oversized'),
                ('nul-before-limit', '\0' + 'x' * 65536, 'oversized'),
                ('boundary', '😀' * 16384, 'plain'),
                ('after-malformed', 'Still receiving 👩‍💻\nSecond line', 'plain'),
            ):
                rows[name] = (add_message(db, text), text, decoding)
            rows['nul-attributed'] = (add_message(db, None, attributedBody='\0' + 'x' * (1024 * 1024)), None, 'oversized')
            flood = add_message(db, 'Caption survives oversized attachment metadata')
            db.executemany('INSERT INTO attachment VALUES(?,?,?,?,?)',
                           [(i, f'guid-{i}', 'photo.png', 'image/png', 10) for i in range(2, 1027)])
            db.executemany('INSERT INTO message_attachment_join VALUES(?,?)',
                           [(flood, i) for i in range(2, 1027)])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(data), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN), 'setup', *args], check=True, stdout=subprocess.DEVNULL)
        with open(root / 'relay.log', 'w+') as log:
            process = subprocess.Popen([str(BIN), 'serve', *args], stdout=log, stderr=log)

            def request(path, body=None, content_type='application/json'):
                with closing(tls.connection(timeout=5)) as conn:
                    conn.request('POST' if body is not None else 'GET', path, body,
                                 {'Content-Type': content_type} if body is not None else {})
                    response = conn.getresponse()
                    return response.status, json.loads(response.read())

            def record(row):
                with sqlite3.connect(data / 'relay.db') as db:
                    result = db.execute('SELECT record FROM messages WHERE source_row=?', (row,)).fetchone()
                    return json.loads(result[0]) if result else None

            try:
                wait_for(lambda: request('/v1/status')[1].get('adapter_ready'))
                wait_for(lambda: record(flood))
                for name, (row, text, decoding) in rows.items():
                    value = record(row)
                    assert value['decoding'] == decoding, (name, value)
                    assert value['text'] == (text if decoding == 'plain' else None), name
                value = record(flood)
                assert value['enrichment']['state'] == 'oversized'
                assert value['attachments'] == [] and value['text'].startswith('Caption survives')
                epoch = request('/v1/sync')[1]['server_epoch']
                send = dict(request_id=str(uuid.uuid4()), server_epoch=epoch,
                            target=dict(recipient=dict(address='alice@example.invalid', service='imessage')),
                            text='Accepted Unicode 👩‍💻\nMultiline')
                encoded = json.dumps(send).encode()
                rejected = [
                    encoded[:-1] + b',"unknown":' + b'[' * 40 + b'0' + b']' * 40 + b'}',
                    encoded[:-1] + b',"unknown":[' + b'0,' * 9000 + b'0]}',
                    encoded[:-1] + b',"text":"duplicate"}',
                    json.dumps(dict(send, text='visible\0hidden')).encode(),
                ]
                # SIMD may skip ordinary string bytes, but typed parsing must
                # still reject controls and invalid escapes in unknown fields.
                for padding in range(32):
                    prefix = encoded[:-1] + b',"unknown":"' + b'a' * (64 + padding)
                    rejected.extend([prefix + b'\x00"}', prefix + b'\\q"}'])
                for body in rejected:
                    assert request('/v1/messages', body)[0] == 400
                assert request('/v1/messages', encoded, 'application/json-bogus')[0] == 400
                with sqlite3.connect(data / 'relay.db') as db:
                    assert db.execute('SELECT count(*) FROM send_requests').fetchone() == (0,)
                # Unknown additive fields and standard media-type parameters work.
                accepted = json.dumps(dict(send, future={'enabled': True})).encode()
                assert request('/v1/messages', accepted, 'application/json; charset=utf-8')[0] == 202
                assert request('/v1/messages', accepted)[0] == 200
                assert request('/v1/status')[1]['adapter_ready']
                print('PASS: hostile text/attachment fallback, bounded JSON, no rejected sends, Unicode and idempotency')
            except Exception:
                log.seek(0)
                print(log.read())
                raise
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    main()
