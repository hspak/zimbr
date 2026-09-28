#!/usr/bin/env python3
"""Brief live Contacts updates remain visible even when every status poll is idle."""
import json
import os
from pathlib import Path
import queue
import sqlite3
import tempfile
import time
from urllib.parse import urlsplit

from client_tls import EPOCH, Handler
from performance import Probe
from tls_fixture import PKI, TLSServer

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-contact-sync-') as tmp:
        root = Path(tmp)
        os.environ['XDG_CONFIG_HOME'] = str(root / 'config')
        pki = PKI(root / 'tls')
        updates = queue.Queue()

        class Endpoint(Handler):
            def response(self, value):
                raw = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                path = urlsplit(self.path).path
                if path == '/v1/status':
                    return self.response(dict(
                        api_version='1', server_epoch=EPOCH, adapter_ready=True,
                        capabilities=dict(send_direct=True, reply_existing=True,
                                          identity_directory_v1=True),
                        event_extensions=['identity-v1'], degraded_reasons=[],
                        enrichment_readiness=dict(identity_directory_v1=dict(
                            ready=True, permission='authorized')),
                        sync_activity=dict(contacts=False)))
                if path == '/v1/identities':
                    return self.response(dict(identities=[], next=None))
                if path != '/v1/events':
                    return super().do_GET()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Zimbr-Event-Extensions', 'identity-v1')
                self.end_headers()
                try:
                    while True:
                        try:
                            frame = updates.get(timeout=.1)
                        except queue.Empty:
                            frame = b': heartbeat\n\n'
                        self.wfile.write(frame)
                        self.wfile.flush()
                except OSError:
                    pass

        server = TLSServer(Endpoint, pki.context())
        server.mode, server.requests = 'ok', []
        data = root / 'client'
        with (root / 'client.log').open('w+') as log:
            probe = Probe([str(ROOT / 'zig-out/bin/client-probe'), '--control',
                           '--data-dir', str(data), *pki.client_args(server.server_port)], log)
            try:
                probe.until(lambda v: v['online'] and not any(v['sync_activity'].values()))
                checked_at = probe.latest['diagnostics']['last_status_ms']
                cursor = EPOCH + ':1'
                update = dict(cursor=cursor, sequence='1', type='identity.upsert',
                              origin='reconciliation', record=dict(
                                  id='peer', revision='1', service='imessage',
                                  address='peer@example.invalid', match_state='matched',
                                  display_name='Updated contact'))
                updates.put(f'id: {cursor}\nevent: identity.upsert\n'
                            f'data: {json.dumps(update)}\n\n'.encode())
                probe.until(lambda v: v['diagnostics']['cursor'] == cursor, timeout=3)
                with sqlite3.connect(data / 'client.db') as db:
                    record = json.loads(db.execute('SELECT record FROM identities').fetchone()[0])
                assert record['display_name'] == 'Updated contact'
                assert probe.latest['sync_activity']['contacts'], (
                    'Live contact update was applied without showing contact sync')
                assert not probe.latest['diagnostics']['server']['sync_activity']['contacts']
                visible_at = time.monotonic()
                probe.until(lambda v: not any(v['sync_activity'].values()), timeout=3)
                assert time.monotonic() - visible_at >= .75, 'Contact sync vanished before it was visible'
                assert probe.latest['online']
                assert probe.latest['diagnostics']['last_status_ms'] == checked_at, (
                    'Indicator should expire without waiting for another status poll')
                print('PASS: live contact updates show sync between idle status polls and expire promptly')
            finally:
                probe.close()
                server.close()


if __name__ == '__main__':
    main()
