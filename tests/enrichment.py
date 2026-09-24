#!/usr/bin/env python3
"""Enrichment through the real journal, workers, and authenticated transport.

All contacts and Messages rows here are synthetic. No native Contacts grant or
account access is required; native normalization has its own Zig test target.
"""
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import uuid
from contextlib import closing

from fixture import create, add_message
from integration import database, wait_for
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/fake-relay'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-enrichment-') as directory:
        root = Path(directory).resolve()
        source, data = root / 'source.db', root / 'data'
        create(source, count=8)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(data), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN), 'setup', *args], check=True, stdout=subprocess.DEVNULL)
        contacts_path = source.with_suffix('.db.contacts.json')
        generation = 0

        def contacts(items=(), permission='authorized', failed=False, changed=True):
            nonlocal generation
            generation += int(changed)
            temporary = contacts_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(dict(permission=permission, generation=generation, contacts=items, failed=failed)))
            temporary.replace(contacts_path)

        alice = dict(id='private-unified-alice', name='Élodie 👩‍💻', emails=['alice@example.invalid', 'alias+tag@example.invalid'], phones=['phone:+14155550123'], has_image=True, thumbnail='ZIMBR-IMAGE contact thumbnail')
        unobserved = dict(id='private-unobserved', name='Do not export', emails=['unobserved@example.invalid'])
        contacts([alice, unobserved])
        log = open(root / 'relay.log', 'w+')
        process = None

        def start():
            return subprocess.Popen([str(BIN), 'serve', *args], stdout=log, stderr=log)

        def request(path):
            with closing(tls.connection(timeout=5)) as conn:
                conn.request('GET', path)
                response = conn.getresponse()
                return response.status, json.loads(response.read())

        def directory_page():
            records, cursor = [], ''
            while True:
                status, page = request('/v1/identities?limit=1' + ('&before=' + cursor if cursor else ''))
                assert status == 200
                records.extend(page['identities'])
                cursor = page['next']
                if not cursor:
                    break
            assert len({r['id'] for r in records}) == len(records)
            return {r['address']: r for r in records}

        def identity(address='alice@example.invalid'):
            return directory_page().get(address, {})

        def sync():
            return request('/v1/sync')[1]

        def avatar(ref):
            with closing(tls.connection(timeout=5)) as conn:
                conn.request('GET', f'/v1/assets/{ref["id"]}/{ref["version"]}/avatar')
                response = conn.getresponse()
                return response.status, response.read()

        def replay(cursor, identities, marker):
            with closing(tls.connection(timeout=5)) as conn:
                conn.request('GET', '/v1/events?after=' + cursor + ('&extensions=identity-v1' if identities else ''))
                response = conn.getresponse()
                assert response.status == 200
                assert response.getheader('zimbr-event-extensions') == ('identity-v1' if identities else '')
                frames = []
                while True:
                    line = response.fp.readline()
                    assert line
                    if line.startswith(b'data: '):
                        event = json.loads(line[6:])
                        frames.append(event)
                        if event['type'] == 'message.upsert' and event['record'].get('text') == marker:
                            return frames

        try:
            process = start()
            wait_for(lambda: request('/v1/status')[1].get('adapter_ready'))
            wait_for(lambda: identity().get('display_name') == alice['name'])
            initial = identity()
            initial_sync = sync()
            status = request('/v1/status')[1]
            assert status['capabilities']['identity_directory_v1']
            assert status['capabilities']['image_assets_v1']
            assert status['capabilities']['contact_avatars_v1']
            assert not status['enrichment_readiness']['image_attachments_v1']['ready']
            assert not any(status['source_features'].values())
            assert status['enrichment_readiness']['identity_directory_v1']['permission'] == 'authorized'
            assert 'unobserved@example.invalid' not in directory_page()
            assert identity('+14155550123')['display_name'] == alice['name']
            # Photos stay lazy and aliases share one approved representation.
            assert initial['avatar']['availability'] == 'pending'
            assert initial['avatar'] == identity('+14155550123')['avatar']
            with sqlite3.connect(data / 'relay.db') as db:
                assert db.execute('SELECT count(*) FROM asset_work').fetchone()[0] == 0
                assert db.execute('SELECT count(*) FROM asset_representations WHERE file_name IS NOT NULL').fetchone()[0] == 0
            assert avatar(initial['avatar'])[0] == 409
            wait_for(lambda: identity()['avatar']['availability'] == 'ready')
            old_avatar = identity()['avatar']
            assert avatar(old_avatar)[1].startswith(b'\x89PNG\r\n\x1a\n')
            assert old_avatar == identity('+14155550123')['avatar']
            assert old_avatar['width'] <= 128 and old_avatar['height'] <= 128
            # A photo-only edit invalidates requested thumbnails even though
            # name and imageDataAvailable are unchanged. No second GET needed.
            alice['thumbnail'] = 'ZIMBR-IMAGE changed contact thumbnail'
            contacts([alice, unobserved])
            wait_for(lambda: identity()['avatar']['version'] != old_avatar['version'])
            assert avatar(old_avatar)[0] == 410
            wait_for(lambda: identity()['avatar']['availability'] == 'ready')
            assert identity('bob@example.invalid')['match_state'] == 'unmatched'
            assert 'private-unified-alice' not in json.dumps(directory_page())
            assert request('/v1/identities?before=not-an-id')[0] == 400
            assert request('/v1/events?after=' + initial_sync['cursor'] + '&extensions=unknown')[0] == 400
            assert request('/v1/events?after=' + initial_sync['cursor'] + '&extensions=identity-v1&extensions=identity-v1')[0] == 400

            # Explicit chat titles and raw routing remain unchanged by Contacts.
            chats = request('/v1/conversations')[1]['conversations']
            assert any(c['title'] == 'Fixture group' for c in chats)
            assert any('alice@example.invalid' in c['participants'] for c in chats)

            # New historical sender and a second alias are observed independently.
            with database(source) as db:
                db.execute("INSERT INTO handle VALUES(20,'alias+tag@example.invalid','iMessage')")
                add_message(db, 'Alias message', handle_id=20, date=10)
            wait_for(lambda: identity('alias+tag@example.invalid').get('display_name') == alice['name'])
            assert identity('alias+tag@example.invalid')['id'] != initial['id']

            # Captured H precedes a rename: keyset snapshot + replay converges.
            h = sync()['cursor']
            alice['name'] = 'Renamed synthetic contact'
            contacts([alice])
            wait_for(lambda: identity().get('display_name') == alice['name'])
            assert identity()['id'] == initial['id']
            assert int(identity()['revision']) > int(initial['revision'])
            marker = 'Replay barrier ' + str(uuid.uuid4())
            with database(source) as db:
                add_message(db, marker)
            def imported():
                with sqlite3.connect(data / 'relay.db') as db:
                    return db.execute('SELECT count(*) FROM messages WHERE text=?', (marker,)).fetchone()[0]
            wait_for(imported)
            rich, legacy = replay(h, True, marker), replay(h, False, marker)
            assert any(e['type'] == 'identity.upsert' for e in rich)
            assert all(e['type'] in ('message.upsert', 'conversation.upsert', 'send_request.updated') for e in legacy)
            assert all(int(a['sequence']) < int(b['sequence']) for a, b in zip(legacy, legacy[1:]))
            assert legacy[-1]['sequence'] == rich[-1]['sequence']

            # A failed fetch is not evidence of deletion. Retain names as stale.
            contacts(permission='authorized', failed=True)
            wait_for(lambda: identity().get('freshness') == 'stale')
            assert identity()['display_name'] == alice['name']
            assert request('/v1/status')[1]['capabilities']['read_history']
            # A new generation can recover before the periodic retry deadline.
            contacts([alice])
            wait_for(lambda: identity().get('freshness') == 'fresh')

            # An unreadable/incomplete scan with unchanged generation also
            # marks cached names stale; it is never treated as an empty store.
            contacts_path.write_text('{incomplete synthetic snapshot')
            wait_for(lambda: identity().get('freshness') == 'stale')
            assert identity()['display_name'] == alice['name']
            contacts([alice])
            wait_for(lambda: identity().get('freshness') == 'fresh')

            # A failed queue transaction must not acknowledge the new Contacts
            # generation, otherwise this rename would wait for a 15-minute scan.
            with sqlite3.connect(data / 'relay.db') as db:
                db.execute("CREATE TRIGGER reject_contact_queue BEFORE INSERT ON identity_work BEGIN SELECT RAISE(ABORT,'synthetic queue failure'); END")
            alice['name'] = 'Rename after queue recovery'
            contacts([alice])
            wait_for(lambda: request('/v1/status')[1]['enrichment_readiness']['identity_directory_v1']['reason'] == 'contacts_persistence_failure')
            with sqlite3.connect(data / 'relay.db') as db:
                db.execute('DROP TRIGGER reject_contact_queue')
            wait_for(lambda: identity().get('display_name') == alice['name'])

            # Conflicting unified contacts do not choose the first candidate.
            duplicate = dict(id='private-other', name='Wrong candidate', emails=['alice@example.invalid'])
            contacts([alice, duplicate])
            wait_for(lambda: identity().get('match_state') == 'ambiguous')
            assert identity()['display_name'] is None
            assert identity()['avatar'] is None

            # Revocation clears observed records, keeps protocol negotiation,
            # leaves messages available, and persists across a process restart.
            contacts([alice])
            wait_for(lambda: identity().get('match_state') == 'matched')
            contacts(permission='denied')
            wait_for(lambda: all(r['match_state'] == 'unavailable' for r in directory_page().values()))
            assert identity()['display_name'] is None
            assert identity()['avatar'] is None
            assert avatar(old_avatar)[0] in (404, 409)
            status = request('/v1/status')[1]
            assert status['capabilities']['identity_directory_v1']
            assert status['capabilities']['read_history']
            assert not status['enrichment_readiness']['identity_directory_v1']['ready']
            # Native permission transitions need not emit a store generation.
            # Restore names immediately, without waiting for the periodic scan.
            for permission in ('restricted', 'unavailable', 'denied'):
                contacts([alice], changed=False)
                wait_for(lambda: identity().get('display_name') == alice['name'])
                current_avatar = identity()['avatar']
                avatar(current_avatar)
                wait_for(lambda: avatar(current_avatar)[0] == 200)
                contacts(permission=permission, changed=False)
                wait_for(lambda: all(r['match_state'] == 'unavailable' for r in directory_page().values()))
                assert identity()['display_name'] is None and identity()['avatar'] is None
                assert avatar(current_avatar)[0] in (404, 409, 410)
                status = request('/v1/status')[1]
                assert status['enrichment_readiness']['identity_directory_v1']['permission'] == permission
                assert status['capabilities']['identity_directory_v1'] and status['capabilities']['contact_avatars_v1']
                assert status['capabilities']['read_history']
            epoch = sync()['server_epoch']
            process.terminate(); process.wait(timeout=5)
            process = start()
            wait_for(lambda: request('/v1/status')[1].get('adapter_ready'))
            assert sync()['server_epoch'] == epoch
            assert identity()['id'] == initial['id']
            assert identity()['display_name'] is None
            contacts([alice])
            wait_for(lambda: identity().get('match_state') == 'matched')
            contacts([])
            wait_for(lambda: identity().get('match_state') == 'unmatched')
            assert identity()['display_name'] is None

            # Simulate a pre-enrichment journal while preserving messages,
            # requests, epoch, and cursor; migration/backfill must recover names.
            process.terminate(); process.wait(timeout=5)
            process = None
            with sqlite3.connect(data / 'relay.db') as db:
                before = db.execute('SELECT epoch,sequence FROM relay_meta').fetchone()
                db.executescript("DROP TABLE contact_mappings; DROP TABLE identity_work; DROP TABLE identities; DROP TABLE enrichment_sections; UPDATE relay_meta SET version=1; DELETE FROM ingestion_progress WHERE key='identity_backfill_v1';")
            contacts([alice])
            process = start()
            wait_for(lambda: identity().get('match_state') == 'matched')
            assert sync()['server_epoch'] == before[0]
            def backfill_done():
                with sqlite3.connect(data / 'relay.db') as db:
                    value = db.execute("SELECT value FROM ingestion_progress WHERE key='identity_backfill_v1'").fetchone()
                    return value and value[0] == 'complete'
            wait_for(backfill_done)
            with sqlite3.connect(data / 'relay.db') as db:
                assert db.execute('SELECT version FROM relay_meta').fetchone()[0] == 6
                assert db.execute('SELECT sequence FROM relay_meta').fetchone()[0] > before[1]
                assert db.execute("SELECT value FROM ingestion_progress WHERE key='identity_backfill_v1'").fetchone()[0] == 'complete'
            assert identity('alias+tag@example.invalid')['display_name'] == alice['name']
            # Optional-column probes are independent and do not disable text.
            with database(source) as db:
                db.execute('ALTER TABLE message ADD COLUMN payload_data BLOB')
            wait_for(lambda: request('/v1/status')[1]['source_features']['link_payload'])
            feature_status = request('/v1/status')[1]
            assert feature_status['capabilities']['read_history']
            assert not feature_status['source_features']['reaction_target']
            print('PASS: observed identities, aliases, keysets, rename, stale fetch, ambiguity, denial, removal, restart, migration, negotiated/legacy mTLS streams')
        except Exception:
            log.seek(0)
            print(log.read())  # Synthetic fixture output only.
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=5)
            log.close()


if __name__ == '__main__':
    main()
