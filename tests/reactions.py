#!/usr/bin/env python3
"""Synthetic reaction operations/deletions via the real source and journal."""
from contextlib import closing
import json
import plistlib
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid

from fixture import create, add_message
from integration import database, wait_for
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin/fake-relay'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-reactions-') as temporary:
        root = Path(temporary).resolve(); source, data = root / 'source.db', root / 'data'
        create(source, count=360)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); tls = Fixture(root, sock.getsockname()[1])
        args = ['--data-dir', str(data), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN), 'setup', *args], check=True, stdout=subprocess.DEVNULL)
        target = str(uuid.uuid4()); absent = str(uuid.uuid4())
        order = 1000000000

        def react(db, code=2001, actor=1, target_guid=target, chat=1, date=None, prefix='p:0/', **kwargs):
            nonlocal order
            order += 100
            row = add_message(db, 'Reaction fixture fallback', chat=chat, date=date if date is not None else order,
                              handle_id=actor, associated_message_type=code, associated_message_guid=prefix + target_guid, **kwargs)
            return row

        with database(source) as db:
            db.executescript('ALTER TABLE message ADD COLUMN associated_message_guid TEXT; ALTER TABLE message ADD COLUMN associated_message_emoji TEXT; ALTER TABLE message ADD COLUMN associated_message_range_location INTEGER; ALTER TABLE message ADD COLUMN associated_message_range_length INTEGER;')
            db.execute('ALTER TABLE message ADD COLUMN payload_data BLOB')
            # Outside both initial first/last source pages: dependency lookup
            # must import this target before the rolling scan gets here.
            db.execute('UPDATE message SET guid=?,text=?,date=10 WHERE ROWID=180', (target, 'Old target with caption'))
            # Source timestamp, then row, establishes the same result even
            # though initial import visits descending row IDs.
            like = react(db)
            heart = react(db, 2000)
            late_unlike = react(db, 3001)
            custom = react(db, 2006, actor=2, associated_message_emoji='👩🏽‍💻')
            mine = react(db, 2004, is_from_me=1)
            early_remove = react(db, 3005, actor=3, date=9000000000)
            late_add = react(db, 2005, actor=3, date=8000000000)
            unknown = react(db, 2007, actor=2)
            malformed = react(db, 2001, target_guid='not-a-guid')
            cross_chat = react(db, 2001, chat=2)
            unresolved = react(db, 2001, target_guid=absent)
            reply = add_message(db, 'Ordinary reply', associated_message_guid='p:0/' + target)
            # Independent Foundation archive with opposite attachment SQL order.
            parts_guid = str(uuid.uuid4())
            parts_row = add_message(db, None, guid=parts_guid, attributedBody=(ROOT / 'src/relay/adapter/fixtures/foundation-parts.bin').read_bytes())
            for i, guid in enumerate(('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111'), 10):
                db.execute('INSERT INTO attachment VALUES(?,?,?,?,?)', (i, guid, 'Synthetic image', 'image/png', 0))
                db.execute('INSERT INTO message_attachment_join VALUES(?,?)', (parts_row, i))
            image_reaction = react(db, target_guid=parts_guid, prefix='p:1/')
            text_reaction = react(db, target_guid=parts_guid, prefix='p:2/', actor=2)
            link_guid = str(uuid.uuid4())
            link_row = add_message(db, 'Link caption', guid=link_guid, balloon_bundle_id='com.apple.messages.URLBalloonProvider', payload_data=plistlib.dumps({'metadata': {'originalURL': 'https://example.invalid/', 'title': 'Fixture URL'}}, fmt=plistlib.FMT_BINARY))
            link_reaction = react(db, target_guid=link_guid, prefix='bp:')
            tie_guid = str(uuid.uuid4())
            add_message(db, 'Same timestamp target', guid=tie_guid)
            react(db, 2001, target_guid=tie_guid, date=42)
            tie_heart = react(db, 2000, target_guid=tie_guid, date=42)
            react(db, 3001, target_guid=tie_guid, date=42)
            preview_guid = str(uuid.uuid4())
            add_message(db, 'Sidebar keeps the target caption', guid=preview_guid, chat=4, date=100)
            react(db, target_guid=preview_guid, chat=4, date=200)
            highest = react(db, 2003, actor=3, date=10000000000)
        log = open(root / 'relay.log', 'w+')
        process = None

        def start(): return subprocess.Popen([str(BIN), 'serve', *args], stdout=log, stderr=log)

        def request(path):
            with closing(tls.connection(timeout=5)) as conn:
                conn.request('GET', path); response = conn.getresponse()
                return response.status, json.loads(response.read())

        def record(guid=target, row=None):
            with sqlite3.connect(data / 'relay.db') as db:
                value = db.execute('SELECT record FROM messages WHERE ' + ('source_row=?' if row is not None else 'source=?') + ' ORDER BY rowid DESC LIMIT 1', (row if row is not None else guid,)).fetchone()
                return json.loads(value[0]) if value else {}

        def active(guid=target): return record(guid).get('reactions') or []
        def epoch(): return request('/v1/sync')[1]['server_epoch']
        def imported(row): return record(row=row).get('reaction_event')
        def count(n): return len(active()) == n

        def remove(row):
            with database(source) as db:
                db.execute('DELETE FROM chat_message_join WHERE message_id=?', (row,))
                db.execute('DELETE FROM message WHERE ROWID=?', (row,))

        try:
            process = start()
            wait_for(lambda: count(4))
            initial = record(); original_epoch = epoch()
            assert {r['key'] for r in active()} == {'heart', 'emoji:👩🏽‍💻', 'emphasize', 'laugh'}
            assert sum(r['actor']['is_self'] for r in active()) == 1
            assert all(r['part_id'] is None and r['part_state'] == 'unresolved' for r in active())
            assert imported(heart)['resolution'] == 'resolved'
            assert imported(heart)['target_message_id'] == initial['id']
            assert imported(unknown)['resolution'] == 'unsupported'
            assert imported(malformed)['resolution'] == 'malformed'
            assert imported(cross_chat)['resolution'] == 'malformed'
            assert imported(unresolved)['resolution'] == 'pending'
            assert record(row=reply)['reaction_event'] is None
            part_message = record(parts_guid)
            assert part_message['enrichment']['part_mapping'] == 'resolved'
            assert part_message['parts'][1]['attachment_id'] == part_message['attachments'][1]['id']
            assert imported(image_reaction)['part_id'] == 'source:1'
            assert imported(text_reaction)['part_id'] == 'source:2'
            assert all(r['part_state'] == 'resolved' for r in active(parts_guid))
            assert imported(link_reaction)['part_id'] == record(link_guid)['link_previews'][0]['part_id']
            assert [r['key'] for r in active(tie_guid)] == ['heart']
            preview_target = record(preview_guid)
            sidebar = request('/v1/conversations?previews=1')[1]['previews']
            selected = next(p for p in sidebar if p['conversation_id'] == preview_target['conversation_id'])
            assert selected['message_id'] == preview_target['id'] and selected['text'] == preview_target['text']
            # A tracked source changing into an ordinary row retires its prior
            # reaction, without suppressing the ordinary row from history.
            with database(source) as db: db.execute('UPDATE message SET associated_message_type=0 WHERE ROWID=?', (tie_heart,))
            wait_for(lambda: record(tie_guid).get('reactions') == [])
            assert record(row=tie_heart)['kind'] == 'text'
            assert imported(tie_heart)['operation'] == 'retired'
            assert target not in json.dumps(initial) and absent not in json.dumps(record(row=unresolved))
            # Complete tracked-row absence retires the highest cursor anchor
            # without pretending the source database has been replaced.
            remove(highest)
            wait_for(lambda: count(3))
            assert epoch() == original_epoch
            assert imported(highest)['operation'] == 'retired'
            assert record()['timestamp'] == initial['timestamp'] and record()['observed_status'] == initial['observed_status']
            # A previously unknown target becomes available in the same chat.
            with database(source) as db: add_message(db, 'Late target', guid=absent, date=5)
            wait_for(lambda: len(active(absent)) == 1)
            assert imported(unresolved)['resolution'] == 'resolved'
            # Replacement, then a removal for a different key: it must not
            # erase the actor's current value.
            with database(source) as db:
                replacement = react(db, 2002, actor=2, date=11000000000)
                react(db, 3006, actor=2, date=12000000000, associated_message_emoji='👩🏽‍💻')
            wait_for(lambda: any(r['key'] == 'dislike' for r in active()))
            assert len(active()) == 3
            with database(source) as db: matching_remove = react(db, 3002, actor=2, date=13000000000)
            wait_for(lambda: count(2))
            remove(matching_remove)  # deleting an operation cannot revive old adds
            time.sleep(1.2)
            assert count(2) and epoch() == original_epoch
            # Retire a reaction far behind the latest ordinary rows; recent
            # source scanning alone cannot establish this disappearance.
            with database(source) as db:
                for i in range(180): add_message(db, 'Recent filler ' + str(i))
            wait_for(lambda: record(row=reply).get('id'))
            remove(heart)
            wait_for(lambda: not any(r['key'] == 'heart' for r in active()))
            assert count(1)
            # Same GUID resurrected by a stale/current-state source refresh is
            # still retired; a distinct later GUID is required for a new add.
            with sqlite3.connect(data / 'relay.db') as db:
                retired_guid = db.execute('SELECT source FROM reaction_sources WHERE source_row=?', (heart,)).fetchone()[0]
            with database(source) as db: resurrect = react(db, 2000, guid=retired_guid, date=1100000000)
            wait_for(lambda: imported(resurrect) and imported(resurrect)['operation'] == 'retired')
            assert count(1)
            # Removing a cursor reaction while higher rows appear rebases with
            # GUID deduplication, including ROWID reuse at the deleted cursor.
            with database(source) as db: cursor_reaction = react(db, 2001, actor=2, date=15000000000)
            wait_for(lambda: count(2))
            with sqlite3.connect(source) as db:
                cursor_guid = db.execute('SELECT guid FROM message WHERE ROWID=?', (cursor_reaction,)).fetchone()[0]
            def anchored():
                with sqlite3.connect(data / 'relay.db') as db:
                    return db.execute("SELECT value FROM ingestion_progress WHERE key='anchor'").fetchone()[0] == cursor_guid
            wait_for(anchored)
            with database(source) as db:
                db.execute('DELETE FROM chat_message_join WHERE message_id=?', (cursor_reaction,))
                db.execute('DELETE FROM message WHERE ROWID=?', (cursor_reaction,))
                reused = add_message(db, 'New ordinary at reused row', ROWID=cursor_reaction)
                higher = add_message(db, 'Higher row survives')
            wait_for(lambda: record(row=higher).get('text') == 'Higher row survives')
            wait_for(lambda: count(1))
            assert epoch() == original_epoch
            assert record(row=reused)['text'] == 'New ordinary at reused row'
            remove(mine)
            wait_for(lambda: record().get('reactions') == [])
            with sqlite3.connect(data / 'relay.db') as db:
                assert db.execute("SELECT origin FROM events WHERE type='message.upsert' AND json_extract(record,'$.id')=? ORDER BY sequence DESC LIMIT 1", (initial['id'],)).fetchone() == ('reconciliation',)
                before_revision = record()['revision']
            process.terminate(); process.wait(timeout=5); process = start()
            wait_for(lambda: request('/v1/status')[1]['adapter_ready'])
            assert epoch() == original_epoch and record()['id'] == initial['id']
            assert record()['reactions'] == []
            time.sleep(1.2)
            assert record()['revision'] == before_revision
            # Actual replacement still resets: matching metadata and copied
            # content are not enough when the source file identity changes.
            process.terminate(); process.wait(timeout=5); process = None
            replacement = root / 'replacement.db'
            with sqlite3.connect(source) as src, sqlite3.connect(replacement) as dst: src.backup(dst)
            replacement.replace(source)
            process = start()
            wait_for(lambda: epoch() != original_epoch)
            assert record().get('id') != initial['id']
            print('PASS: ordered standard/custom/self reactions, replacement and matching removal, out-of-order import, durable deletion, highest/cursor ROWID reuse continuity, unresolved/cross-chat targets, empty aggregate, restart, source replacement')
        except Exception:
            log.seek(0); print(log.read()); raise
        finally:
            if process is not None and process.poll() is None: process.terminate(); process.wait(timeout=5)
            log.close()


if __name__ == '__main__': main()
