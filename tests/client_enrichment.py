#!/usr/bin/env python3
"""Production Linux sync/media workers against the real synthetic relay service."""
import json
import os
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid

from fixture import create, add_message
from relay_fixture import Fixture
from client_integration import wait

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-client-enrichment-') as tmp:
        root = Path(tmp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        source, relay, client = root/'source.db', root/'relay', root/'client'
        create(source, count=5)
        attachments = root/'source.db.attachments'
        attachments.mkdir(mode=0o700)
        contacts_path = root/'source.db.contacts.json'
        generation = 0
        def contacts(name='Élodie 👋', permission='authorized', photo=True, advance=True):
            nonlocal generation
            generation += int(advance)
            temp = contacts_path.with_suffix('.tmp')
            temp.write_text(json.dumps(dict(permission=permission, generation=generation, contacts=[dict(id='private-peer', name=name, emails=['alice@example.invalid'], has_image=photo, thumbnail='ZIMBR-IMAGE avatar')])))
            temp.replace(contacts_path)
        contacts()
        target_guid = str(uuid.uuid4())
        with sqlite3.connect(source) as db:
            db.executescript('ALTER TABLE attachment ADD COLUMN filename TEXT; ALTER TABLE message ADD COLUMN associated_message_guid TEXT; ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;')
            mid = add_message(db, 'Caption retained 👩🏽‍💻', guid=target_guid)
            for i in range(36):
                path = attachments/f'photo-{i}'
                path.write_bytes(b'ZIMBR-IMAGE fixture')
                db.execute('INSERT INTO attachment VALUES(?,?,?,?,?,?)', (i+10, str(uuid.uuid4()), f'photo-{i}.heic', 'image/heic', 19, str(path)))
                db.execute('INSERT INTO message_attachment_join VALUES(?,?)', (mid, i+10))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN/'fake-relay'), 'setup', *args], check=True, capture_output=True)
        log = open(root/'test.log', 'w+')
        server = subprocess.Popen([str(BIN/'fake-relay'), 'serve', *args], stdout=log, stderr=log)
        proc = None
        events = queue.Queue()
        views, media_results = [], []
        def rows(sql, args=(), path=client/'client.db'):
            with sqlite3.connect(path) as db: return db.execute(sql, args).fetchall()
        def reader(pipe):
            for line in pipe: events.put(json.loads(line))
        def start():
            nonlocal proc
            views.clear(); media_results.clear()
            proc = subprocess.Popen([str(BIN/'client-probe'), '--control', '--data-dir', str(client), *tls.client_args()], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
            threading.Thread(target=reader, args=(proc.stdout,), daemon=True).start()
        def pump():
            assert proc.poll() is None, (log.seek(0), log.read())
            while not events.empty():
                value = events.get_nowait()
                (media_results if 'media' in value else views).append(value.get('media', value))
            return views[-1] if views else {}
        def command(**value):
            proc.stdin.write((json.dumps(value)+'\n').encode()); proc.stdin.flush()
        def stop():
            proc.stdin.write(b'quit\n'); proc.stdin.flush()
            assert proc.wait(timeout=10) == 0
        def record():
            found = rows("SELECT record FROM records WHERE kind='message' AND json_extract(record,'$.text')='Caption retained 👩🏽‍💻'")
            return json.loads(found[0][0]) if found else {}
        def directory():
            found = rows("SELECT record FROM identities WHERE address='alice@example.invalid'")
            return json.loads(found[0][0]) if found else {}
        def fetch(asset, online=True, avatar_allowed=True):
            epoch = rows("SELECT value FROM meta WHERE key='epoch'")[0][0]
            command(kind='media_context', epoch=epoch, chat='visible', online=online, avatars=avatar_allowed)
            for _ in range(15):
                pump(); before=len(media_results)
                command(kind='media', asset=asset)
                def complete():
                    pump()
                    if len(media_results)>before: return media_results[-1]
                    command(kind='media', asset=asset)  # keep the synthetic viewport visible
                result=wait(complete, timeout=10)
                if result['state']!='pending': return result
                time.sleep(.3)
            raise AssertionError('Image never became ready')
        try:
            start(); wait(lambda:pump().get('online'))
            wait(lambda:directory().get('display_name')=='Élodie 👋')
            assert rows("SELECT value FROM meta WHERE key='accepted_extensions'")==[('identity-v1',)]
            assert rows("SELECT value FROM meta WHERE key='identity_bootstrapped'")==[('1',)]
            cid = rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1")[0][0]
            command(kind='select', key=cid)
            wait(lambda:record().get('attachments'))
            command(kind='draft', key=cid, text='Draft survives enrichment')
            asset=record()['attachments'][0]['image']
            image=fetch(asset)
            assert image['state']=='ready' and image['width']==1 and image['height']==1 and image['bytes']==4, image
            key=image['key']
            cached=client/'media'/key
            assert cached.exists() and cached.stat().st_mode & 0o777 == 0o600
            assert (client/'media').stat().st_mode & 0o777 == 0o700
            offline=fetch(asset, online=False)
            assert offline['state']=='ready', offline
            missing=dict(asset, id=str(uuid.uuid4()))
            assert fetch(missing, online=False)['state']=='offline'
            avatar_ref=wait(lambda:directory().get('avatar'))
            avatar=fetch(avatar_ref)
            assert avatar['state']=='ready', avatar
            avatar_key=avatar['key']
            assert (client/'media'/avatar_key).exists()
            epoch=rows("SELECT value FROM meta WHERE key='epoch'")[0][0]
            command(kind='media_context', epoch=epoch, chat='visible', avatars=False)
            wait(lambda:not (client/'media'/avatar_key).exists())
            # Completion is revision-bound; a conversion may update the owner
            # between the click and GET, so retry using the newly published record.
            def expanded():
                m=record()
                command(kind='enrichment', key=m['id'], recipient=m['revision'], text='attachments')
                found=rows('SELECT record FROM enrichment_cache WHERE message_id=?',(m['id'],))
                return json.loads(found[0][0]) if found and json.loads(found[0][0])['enrichment']['attachments']['complete'] else None
            full=wait(expanded)
            assert len(full['attachments'])==36 and full['text']=='Caption retained 👩🏽‍💻'
            # A live reaction updates the old target quietly, then a deletion
            # clears its aggregate without alerting or resetting the epoch.
            command(kind='viewed', text='no')
            with sqlite3.connect(source) as db:
                reaction=add_message(db, 'Reaction fallback', associated_message_type=2006, associated_message_guid='p:0/'+target_guid, associated_message_emoji='👩🏽‍💻')
            wait(lambda:len(record().get('reactions') or [])==1)
            assert rows('SELECT count(*) FROM unread')==[(0,)]
            with sqlite3.connect(source) as db:
                db.execute('DELETE FROM chat_message_join WHERE message_id=?',(reaction,))
                db.execute('DELETE FROM message WHERE ROWID=?',(reaction,))
            wait(lambda:record().get('reactions')==[])
            assert rows("SELECT value FROM meta WHERE key='epoch'")==[(epoch,)]
            contacts('Renamed offline 👋')
            wait(lambda:directory().get('display_name')=='Renamed offline 👋')
            stop()
            # Upgrade a legacy cache in the same epoch. The new stream must not
            # treat a legacy cursor as evidence of a complete identity directory.
            with sqlite3.connect(client/'client.db') as db:
                db.execute('DELETE FROM identities')
                db.execute("UPDATE meta SET value='0' WHERE key='identity_bootstrapped'")
                db.execute("UPDATE meta SET value='' WHERE key='accepted_extensions'")
            start(); wait(lambda:pump().get('online'))
            wait(lambda:directory().get('display_name')=='Renamed offline 👋')
            assert rows('SELECT text FROM drafts WHERE key=?',(cid,))==[('Draft survives enrichment',)]
            # The native relay now exposes live permission-monitor results.
            # Every unavailable state gates presentation, and a permission-only
            # regrant must recover without a new source generation or epoch.
            identity_id=directory()['id']
            for permission in ('denied', 'restricted', 'unavailable'):
                contacts(permission=permission)
                wait(lambda:directory().get('match_state')=='unavailable')
                command(kind='reconnect')
                wait(lambda:rows("SELECT value FROM meta WHERE key='contacts_blocked'")==[('1',)])
                assert directory()['display_name'] is None and directory()['avatar'] is None
                contacts('Recovered 👋', advance=False)
                wait(lambda:directory().get('display_name')=='Recovered 👋')
                command(kind='reconnect')
                wait(lambda:rows("SELECT value FROM meta WHERE key='contacts_blocked'")==[('0',)])
                assert directory()['id']==identity_id
                assert rows("SELECT value FROM meta WHERE key='epoch'")==[(epoch,)]
                assert rows('SELECT text FROM drafts WHERE key=?',(cid,))==[('Draft survives enrichment',)]
                assert rows('SELECT count(*) FROM unread')==[(0,)]
            stop(); proc=None
            print('PASS: identity negotiation/bootstrap/rename, denied/restricted/unavailable permission and same-generation recovery, quiet reactions/deletion, revision-bound overflow, authenticated images/avatar, offline cache and private media files')
        except Exception:
            log.flush(); log.seek(0); print(log.read()[-10000:])
            if (client/'client.db').exists():
                print('Pages:', rows('SELECT message_id,section,revision,length(items),next FROM enrichment_pages'))
                print('Cache:', rows('SELECT message_id,revision,length(record),serial FROM enrichment_cache'))
                print('View:', views[-1] if views else {})
            raise
        finally:
            if proc and proc.poll() is None: proc.kill(); proc.wait()
            server.terminate(); server.wait(timeout=5); log.close()

if __name__=='__main__': main()
