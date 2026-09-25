#!/usr/bin/env python3
"""Synchronize automatic Contacts changes through the production relay and client."""
import json
import os
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import tempfile
import threading

from client_integration import wait
from fixture import create, add_message
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-contact-refresh-') as tmp:
        root = Path(tmp)
        os.environ['XDG_CONFIG_HOME'] = str(root / 'config')
        source, relay, client = root / 'source.db', root / 'relay', root / 'client'
        create(source, count=5)
        # Cross both the relay's 100-identity work batches and the client's
        # 200-identity pages while synchronizing automatic updates.
        aliases = [f'alias-{i}@example.invalid' for i in range(205)]
        with sqlite3.connect(source) as db:
            for handle_id, address in enumerate(aliases, 10):
                db.execute('INSERT INTO handle VALUES(?,?,?)', (handle_id, address, 'iMessage'))
                add_message(db, 'Observed alias', chat=2, handle_id=handle_id)
        contacts_path = root / 'source.db.contacts.json'
        generation = 0

        def contacts(name, permission='authorized', failed=False):
            nonlocal generation
            generation += 1
            temporary = contacts_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(dict(
                permission=permission, generation=generation, failed=failed,
                contacts=[dict(id='private-alice', name=name, emails=['alice@example.invalid', *aliases])],
            )))
            temporary.replace(contacts_path)

        contacts('Original name')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN / 'fake-relay'), 'setup', *args], check=True, capture_output=True)
        with (root / 'test.log').open('w+') as log:
            server = subprocess.Popen([str(BIN / 'fake-relay'), 'serve', *args], stdout=log, stderr=log)
            proc = None
            events = queue.Queue()
            latest = {}

            def request(path, method='GET', body=None):
                connection = tls.connection()
                try:
                    connection.request(method, path, body=body)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()

            def ready():
                status, value = request('/v1/status')
                return status == 200 and value['enrichment_readiness']['identity_directory_v1']['ready']

            def relay_directory():
                identities, before = [], ''
                while True:
                    status, page = request('/v1/identities?limit=200' + ('&before=' + before if before else ''))
                    assert status == 200
                    identities.extend(page['identities'])
                    before = page['next']
                    if before is None:
                        return identities

            def rows(sql, args=()):
                with sqlite3.connect(client / 'client.db') as db:
                    return db.execute(sql, args).fetchall()

            def directory():
                found = rows("SELECT record FROM identities WHERE address='alice@example.invalid'")
                return json.loads(found[0][0]) if found else {}

            def read():
                for line in proc.stdout:
                    events.put(json.loads(line))

            def pump():
                nonlocal latest
                assert proc.poll() is None, 'Client worker exited'
                while not events.empty():
                    latest = events.get_nowait()
                return latest

            def command(**value):
                proc.stdin.write(json.dumps(value) + '\n')
                proc.stdin.flush()

            try:
                wait(ready)
                before = relay_directory()
                assert len(before) > 200
                assert any(value.get('display_name') == 'Original name' for value in before)
                contacts('Renamed automatically')
                wait(lambda: all(value.get('display_name') == 'Renamed automatically'
                                 for value in relay_directory() if value['address'] in aliases))
                assert 'refresh_contacts_v1' not in request('/v1/status')[1]['capabilities']
                assert request('/v1/contacts/refresh', 'GET')[0] == 404
                assert request('/v1/contacts/refresh', 'POST', '')[0] == 404
                assert request('/v1/contacts/refresh', 'POST', '{}')[0] == 404

                proc = subprocess.Popen(
                    [str(BIN / 'client-probe'), '--control', '--data-dir', str(client), *tls.client_args()],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
                )
                threading.Thread(target=read, daemon=True).start()
                wait(lambda: pump().get('online'))
                wait(lambda: directory().get('display_name') == 'Renamed automatically')
                cid = rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1")[0][0]
                command(kind='select', key=cid, text='no')
                wait(lambda: pump().get('messages', 0) > 0)
                command(kind='draft', key=cid, text='Keep my draft')
                wait(lambda: rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [('Keep my draft',)])
                with sqlite3.connect(client / 'client.db') as db:
                    db.execute('INSERT OR REPLACE INTO unread VALUES(?,3)', (cid,))
                messages = rows("SELECT id,record FROM records WHERE kind='message' ORDER BY id")
                epoch = rows("SELECT value FROM meta WHERE key='epoch'")

                wait(lambda: pump().get('selected_title') == 'Renamed automatically')
                directory_revision = latest['directory_revision']
                contacts('Automatically refreshed 👋')
                wait(lambda: directory().get('display_name') == 'Automatically refreshed 👋')
                wait(lambda: pump().get('selected_title') == 'Automatically refreshed 👋')
                assert latest['directory_revision'] != directory_revision
                wait(lambda: rows("SELECT count(*) FROM identities WHERE json_extract(record,'$.display_name')='Automatically refreshed 👋'") == [(206,)])
                assert rows("SELECT id,record FROM records WHERE kind='message' ORDER BY id") == messages
                assert rows('SELECT count FROM unread WHERE chat=?', (cid,)) == [(3,)]
                assert rows('SELECT text FROM drafts WHERE key=?', (cid,)) == [('Keep my draft',)]
                assert rows("SELECT value FROM meta WHERE key='epoch'") == epoch

                with sqlite3.connect(relay / 'relay.db') as db:
                    db.execute("CREATE TRIGGER reject_contact_queue BEFORE INSERT ON identity_work BEGIN SELECT RAISE(ABORT,'synthetic queue failure'); END")
                contacts('Recovered queue')
                wait(lambda: request('/v1/status')[1]['enrichment_readiness']['identity_directory_v1']['reason'] == 'contacts_persistence_failure')
                pending = request('/v1/status')[1]['enrichment_readiness']['identity_directory_v1']
                assert not pending['ready']
                with sqlite3.connect(relay / 'relay.db') as db:
                    db.execute('DROP TRIGGER reject_contact_queue')
                wait(lambda: directory().get('display_name') == 'Recovered queue')
                wait(ready)

                contacts('Unreadable rename', failed=True)
                wait(lambda: directory().get('freshness') == 'stale')
                assert directory()['display_name'] == 'Recovered queue'
                contacts('Retry succeeded')
                wait(lambda: directory().get('display_name') == 'Retry succeeded')
                assert directory()['freshness'] == 'fresh'
                wait(ready)

                contacts('Permission denied', permission='denied')
                wait(lambda: directory().get('match_state') == 'unavailable')
                wait(lambda: rows("SELECT value FROM meta WHERE key='contacts_blocked'") == [('1',)])
                proc.stdin.write('quit\n')
                proc.stdin.flush()
                assert proc.wait(timeout=10) == 0
                print('PASS: automatic contact updates across batches/pages, preserved messages/drafts/unread, scan failure and recovery, removed manual refresh endpoint')
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read()[-10000:])
                print('Last view:', latest)
                raise
            finally:
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait()
                server.terminate()
                server.wait(timeout=5)


if __name__ == '__main__':
    main()
