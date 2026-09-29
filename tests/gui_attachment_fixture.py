#!/usr/bin/env python3
"""Private synthetic relay controlled by the Wayland composer integration test."""
import json
from pathlib import Path
import signal
import sqlite3
import sys
from contextlib import closing

from attachment_sends import AttachmentSends
from client_media_transport import png


def timed_out(signum, frame):
    raise TimeoutError('GUI attachment fixture exceeded its deadline')


def reply(value):
    print(json.dumps(value), flush=True)


def main():
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(60)
    fixture = AttachmentSends()
    fixture.setUp()
    try:
        data = fixture.root/'client'
        data.mkdir(mode=0o700)
        originals = [png(), b'', bytes(range(256))*1024]
        paths = [fixture.root/name for name in ('photo 👋.png', 'empty.txt', 'original.bin')]
        for path, content in zip(paths, originals):
            path.write_bytes(content)
        reply(dict(config=dict(
            data=str(data), relay_url=f'https://localhost:{fixture.port}',
            ca_file=str(fixture.tls.root/'ca.pem'),
            client_cert_file=str(fixture.tls.root/'client.pem'),
            client_key_file=str(fixture.tls.root/'client-key.pem')),
            paths=[str(path) for path in paths]))
        for command in sys.stdin:
            if command == 'staged\n':
                fixture.assertEqual(fixture.source_rows(), [])
                with closing(sqlite3.connect(fixture.root/'data/relay.db')) as db:
                    fixture.assertEqual(db.execute('SELECT count(*) FROM send_requests').fetchone()[0], 0)
                paths[0].unlink()
                paths[1].write_bytes(b'No longer empty')
                paths[2].write_bytes(b'Replaced after review')
                reply('changed')
            elif command == 'verify\n':
                rows = fixture.source_rows()
                fixture.assertEqual([row[0] for row in rows], ['Reviewed caption 👋', '', '', ''])
                fixture.assertEqual([row[1] for row in rows[1:]], [path.name for path in paths])
                for row, content in zip(rows[1:], originals):
                    fixture.assertEqual(Path(row[2]).read_bytes(), content)
                with closing(sqlite3.connect(fixture.root/'data/relay.db')) as db:
                    records = db.execute('SELECT record FROM send_requests').fetchall()
                fixture.assertEqual(len(records), 1)
                record = json.loads(records[0][0])
                fixture.assertEqual(record['state'], 'delivered')
                fixture.assertEqual([part['state'] for part in record['parts']], ['delivered']*4)
                reply('verified')
            else:
                raise AssertionError(f'Unexpected fixture command: {command!r}')
    finally:
        fixture.tearDown()


if __name__ == '__main__':
    main()
