#!/usr/bin/env python3
"""Reset old relay IDs through the production client, with lost-response recovery."""
from contextlib import closing
import http.server
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile

from client_integration import wait
from fixture import create
from performance import Probe
from relay_fixture import Fixture
from tls_fixture import TLSServer

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'
OLD_EPOCH = '00112233-4455-6677-8899-aabbccddeeff'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-client-relay-reset-') as temporary:
        root = Path(temporary).resolve()
        os.environ['XDG_CONFIG_HOME'] = str(root / 'config')
        source, relay, client = root / 'source.db', root / 'relay', root / 'client'
        create(source, count=8)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            tls = Fixture(root, listener.getsockname()[1])
        options = ['--data-dir', str(relay), '--messages-db', str(source),
                   '--config', str(tls.config), '--read-only']
        subprocess.run([str(BIN / 'fake-relay'), 'setup', *options], check=True, capture_output=True)
        original_request = dict(request_id=OLD_EPOCH, server_epoch=OLD_EPOCH,
                                target=dict(recipient=dict(address='alice@example.invalid', service='imessage')),
                                text='Do not dispatch this old queued send', state='queued', revision='1')
        with closing(sqlite3.connect(relay / 'relay.db')) as db:
            db.execute('UPDATE relay_meta SET epoch=?', (OLD_EPOCH,))
            db.execute("INSERT INTO send_requests(id,epoch,payload,record,state,mode,route,accepted_ms) "
                       "VALUES(?,?,?,?,'queued','direct','alice@example.invalid',0)",
                       (OLD_EPOCH, OLD_EPOCH, json.dumps(original_request), json.dumps(original_request)))
            db.commit()
        assets = relay / 'assets'
        assets.mkdir(mode=0o700)
        orphan = assets / (OLD_EPOCH + '-' + OLD_EPOCH + '-avatar')
        orphan.write_bytes(b'old cached avatar')
        source.with_suffix('.db.contacts.json').write_text(json.dumps(dict(
            permission='authorized', generation=1, failed=False,
            contacts=[dict(id='alice-contact', name='Alice', emails=['alice@example.invalid'],
                           phones=[], has_image=True, thumbnail='ZIMBR-IMAGE avatar')],
        )))
        faults = dict(mode='unsupported', epochs=[])

        def request(path, body=None, auth=True):
            with closing(tls.connection(auth=auth)) as connection:
                connection.request('GET' if body is None else 'POST', path,
                                   None if body is None else json.dumps(body),
                                   {} if body is None else {'Content-Type': 'application/json'})
                response = connection.getresponse()
                raw = response.read()
                return response.status, raw

        def value(path, body=None):
            status, raw = request(path, body)
            return status, json.loads(raw)

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                status, raw = request(self.path)
                self.reply(status, raw)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert self.path == '/v1/reset'
                faults['epochs'].append(body['server_epoch'])
                if faults['mode'] == 'unsupported':
                    self.reply(404, b'{}')
                    return
                status, raw = request(self.path, body)
                self.reply(status, raw, incomplete=faults['mode'] == 'drop')

            def reply(self, status, raw, incomplete=False):
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw) + int(incomplete)))
                self.end_headers()
                self.wfile.write(raw)
                if incomplete:
                    self.close_connection = True

        def scalar(path, query):
            with closing(sqlite3.connect(path)) as db:
                return db.execute(query).fetchone()[0]

        with (root / 'log').open('w+') as log:
            server = subprocess.Popen([str(BIN / 'fake-relay'), 'serve', *options], stdout=log, stderr=log)
            proxy = TLSServer(Proxy, tls.server_context())
            probe = None
            try:
                wait(lambda: value('/v1/status')[1].get('server_epoch') == OLD_EPOCH)
                assert value('/v1/status')[1]['adapter_ready'] is False
                assert value('/v1/sync')[0] == 409
                assert orphan.exists()
                probe = Probe([str(BIN / 'client-probe'), '--control', '--data-dir', str(client),
                               *tls.client_args(port=proxy.server_port)], log)
                probe.until(lambda v: v['diagnostics']['server'] is not None)
                assert probe.latest['diagnostics']['auth_blocked']
                assert 'Reset client and relay' in probe.latest['status']
                probe.command(kind='draft', key='new:alice@example.invalid', text='Keep until reset succeeds')
                wait(lambda: scalar(client / 'client.db', 'SELECT count(*) FROM drafts') == 1)
                media = client / 'media'
                media.mkdir(exist_ok=True)
                sentinel = media / ('a' * 64)
                sentinel.write_bytes(b'local cached media')
                probe.command(kind='reset')
                probe.until(lambda v: v.get('reset') == 'failed')
                assert 'Update the relay' in probe.latest['status']
                assert value('/v1/status')[1]['server_epoch'] == OLD_EPOCH
                assert sentinel.exists()
                faults['mode'] = 'drop'
                probe.command(kind='reset')
                probe.until(lambda v: v.get('reset') == 'failed')
                epoch = value('/v1/sync')[1]['server_epoch']
                assert len(epoch) == 22
                assert scalar(client / 'client.db', 'SELECT count(*) FROM drafts') == 1
                assert sentinel.exists()
                faults['mode'] = 'ok'
                probe.command(kind='reset')
                probe.until(lambda v: v.get('reset') == 'complete')
                assert faults['epochs'] == [OLD_EPOCH] * 3
                assert value('/v1/sync')[1]['server_epoch'] == epoch, 'Retry reset twice'
                assert scalar(relay / 'relay.db', 'SELECT state FROM send_requests') == 'unknown'
                assert scalar(relay / 'relay.db', "SELECT count(*) FROM events WHERE type='send_request.updated'") == 0
                wait(lambda: not orphan.exists(), timeout=15)
                # The GUI performs this only after the complete result and both workers stop.
                probe.close()
                probe = None
                subprocess.run([str(BIN / 'zimbr'), '--reset-cache', '--data-dir', str(client)],
                               check=True, capture_output=True)
                assert not media.exists()
                assert scalar(client / 'client.db', 'SELECT count(*) FROM drafts') == 0
                probe = Probe([str(BIN / 'client-probe'), '--control', '--data-dir', str(client),
                               *tls.client_args()], log)
                probe.until(lambda v: v['online'] and v['chats'] > 0)
                assert probe.latest['diagnostics']['server']['server_epoch'] == epoch
                wait(lambda: any(item.get('avatar') for item in value('/v1/identities')[1]['identities']))
                identities = value('/v1/identities')[1]['identities']
                avatar = next(item['avatar'] for item in identities if item['address'] == 'alice@example.invalid')
                path = f'/v1/assets/{avatar["id"]}/{avatar["version"]}/avatar'
                wait(lambda: request(path)[0] == 200)
                # Invalid reset input and a failed transaction must preserve the current epoch.
                assert value('/v1/reset', {'server_epoch': ''})[0] == 400
                with closing(sqlite3.connect(relay / 'relay.db')) as db:
                    db.execute("CREATE TRIGGER deny_reset BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT,'fixture'); END")
                    db.commit()
                assert value('/v1/reset', {'server_epoch': epoch})[0] == 503
                assert value('/v1/sync')[1]['server_epoch'] == epoch
                with closing(sqlite3.connect(relay / 'relay.db')) as db:
                    db.execute('DROP TRIGGER deny_reset')
                    db.commit()
                try:
                    request('/v1/reset', {'server_epoch': epoch}, auth=False)
                except OSError:
                    pass
                else:
                    raise AssertionError('Unauthenticated reset accepted')
                assert value('/v1/sync')[1]['server_epoch'] == epoch
                assert scalar(source, "SELECT count(*) FROM message WHERE text='Do not dispatch this old queued send'") == 0
            finally:
                if probe:
                    probe.close()
                proxy.close()
                server.terminate()
                server.wait(timeout=10)
    print('PASS: client-triggered relay reset, old IDs, retained drafts on failure, lost-response retry, '
          'held sends, local wipe, rebuilt avatars, transaction rollback and authentication')


if __name__ == '__main__':
    main()
