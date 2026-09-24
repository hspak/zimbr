#!/usr/bin/env python3
"""Independent plistlib fixtures through the real read-only adapter and mTLS."""
from contextlib import closing
import json
from pathlib import Path
import plistlib
import socket
import sqlite3
import subprocess
import tempfile
from urllib.parse import urlencode

from fixture import create, add_message
from integration import database, wait_for
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = 'com.apple.messages.URLBalloonProvider'


def archive(value):
    objects = ['$null']
    classes = {}

    def classname(name):
        if name not in classes:
            classes[name] = plistlib.UID(len(objects))
            objects.append({'$classname': name, '$classes': [name, 'NSObject']})
        return classes[name]

    def encode(item):
        if isinstance(item, dict):
            entry = {'NS.keys': [encode(k) for k in item], 'NS.objects': [encode(v) for v in item.values()], '$class': classname('NSDictionary')}
        elif isinstance(item, list):
            entry = {'NS.objects': [encode(v) for v in item], '$class': classname('NSArray')}
        elif isinstance(item, bytes):
            entry = {'NS.data': item, '$class': classname('NSData')}
        elif isinstance(item, str) and item.startswith('https://'):
            relative = plistlib.UID(len(objects)); objects.append(item)
            entry = {'NS.relative': relative, 'NS.base': plistlib.UID(0), '$class': classname('NSURL')}
        else:
            entry = item
        pointer = plistlib.UID(len(objects)); objects.append(entry)
        return pointer

    top = encode(value)
    return {'$archiver': 'NSKeyedArchiver', '$version': 100000, '$objects': objects, '$top': {'root': top}}


def xml_uids(value):
    if isinstance(value, plistlib.UID):
        return {'CF$UID': value.data}
    if isinstance(value, list):
        return [xml_uids(v) for v in value]
    if isinstance(value, dict):
        return {k: xml_uids(v) for k, v in value.items()}
    return value


def rich_link(wrapper='RichLink', placeholder=False):
    # Apple archive field layout, independently generated with synthetic values.
    # Substitute artwork needs a verified local join; its index is not a GUID.
    objects = ['$null', {'$class': plistlib.UID(4), 'richLinkMetadata' if wrapper == 'RichLink' else 'metadata': plistlib.UID(2), 'richLinkIsPlaceholder': placeholder},
               {'$class': plistlib.UID(5), 'URL': plistlib.UID(3), 'title': 'Stored card', 'image': plistlib.UID(0), 'icon': plistlib.UID(7)},
               {'$class': plistlib.UID(6), 'NS.relative': 'https://stored.example.invalid/', 'NS.base': plistlib.UID(0)},
               {'$classname': wrapper}, {'$classname': 'LPLinkMetadata'}, {'$classname': 'NSURL'},
               {'$class': plistlib.UID(8), 'richLinkImageAttachmentSubstituteIndex': 0},
               {'$classname': 'RichLinkImageAttachmentSubstitute'}]
    return {'$archiver': 'NSKeyedArchiver', '$version': 100000, '$objects': objects, '$top': {'root': plistlib.UID(1)}}


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-links-') as temporary:
        root = Path(temporary).resolve()
        source, data = root / 'source.db', root / 'data'
        attachments = root / 'source.db.attachments'; attachments.mkdir(mode=0o700)
        create(source, count=2)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); tls = Fixture(root, sock.getsockname()[1])
        binary = ROOT / 'zig-out/bin/fake-relay'
        args = ['--data-dir', str(data), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(binary), 'setup', *args], check=True, stdout=subprocess.DEVNULL)
        records = {}
        meta = {'originalURL': 'https://shared.example.invalid/original', 'URL': 'https://final.example.invalid/redirect', 'title': 'Synthetic <title> 👩‍💻', 'summary': 'A & B\nSecond line', 'siteName': 'Fixture site', 'image': {'data': b'ZIMBR-IMAGE embedded local artwork'}, 'icon': {'URL': 'https://never-fetch.example.invalid/icon'}}
        with database(source) as db:
            db.executescript('ALTER TABLE message ADD COLUMN payload_data BLOB; ALTER TABLE attachment ADD COLUMN filename TEXT;')
            def add(name, value=None, state='complete', fmt=plistlib.FMT_BINARY, provider=PROVIDER, raw=None):
                if raw is None and value is not None:
                    raw = plistlib.dumps(xml_uids(value) if fmt == plistlib.FMT_XML else value, fmt=fmt)
                records[name] = (add_message(db, 'Original link and caption ' + name, balloon_bundle_id=provider, payload_data=raw), state)
            add('binary', {'richLinkMetadata': meta})
            add('xml', {'metadata': meta}, fmt=plistlib.FMT_XML)
            add('archive-binary', archive({'richLinkMetadata': meta}))
            add('archive-xml', archive({'richLinkMetadata': meta}), fmt=plistlib.FMT_XML)
            add('rich-link', rich_link())
            add('sharing-wrapper', rich_link('LPSharingMetadataWrapper'))
            add('rich-placeholder', rich_link(placeholder=True))
            add('indexed-join', rich_link())
            add('partial', {'metadata': {'originalURL': 'https://partial.example.invalid/'}})
            add('empty-fields', {'metadata': {'originalURL': 'https://empty.example.invalid/', 'title': '', 'image': b''}})
            add('remote-only', {'metadata': {'URL': 'https://partial.example.invalid/', 'image': {'URL': 'https://never-fetch.example.invalid/image'}}})
            add('plain', provider=None)
            add('unknown-balloon', {'metadata': meta}, provider='com.example.unsupported')
            add('delayed', state='pending')
            add('several', [{'richLinkMetadata': {'originalURL': f'https://example.invalid/{i}', 'title': f'Card {i}'}} for i in range(7)])
            add('invalid-url', {'metadata': {'URL': 'file:///etc/passwd'}}, state='malformed')
            add('bad-archive', {'$archiver': 'NSKeyedArchiver', '$objects': ['$null'], '$top': {'root': plistlib.UID(10)}}, state='malformed')
            add('cyclic', {'$archiver': 'NSKeyedArchiver', '$objects': ['$null', plistlib.UID(1)], '$top': {'root': plistlib.UID(1)}}, state='malformed')
            add('unknown-class', {'$archiver': 'NSKeyedArchiver', '$objects': ['$null', {'$class': plistlib.UID(2), 'metadata': meta}, {'$classname': 'UnexpectedExecutableClass'}], '$top': {'root': plistlib.UID(1)}}, state='unsupported')
            add('oversized', raw=b'x' * (1024 * 1024 + 1), state='oversized')
            deep = {'originalURL': 'https://example.invalid/'}
            for _ in range(40): deep = {'metadata': deep}
            add('deep', deep, state='oversized')
            add('internal-entity', raw=b'<!DOCTYPE plist [<!ENTITY read SYSTEM "file:///etc/passwd">]><plist version="1.0"><string>&read;</string></plist>', state='unsupported')
            add('local-join', {'metadata': {'URL': 'https://local.example.invalid/', 'image': {'attachmentGUID': 'private-joined-artwork'}}})
            (attachments / 'artwork').write_bytes(b'ZIMBR-IMAGE joined artwork')
            db.execute('INSERT INTO attachment VALUES(2,?,?,?,?,?)', ('private-joined-artwork', 'artwork.heic', '', 20, str(attachments / 'artwork')))
            db.execute('INSERT INTO message_attachment_join VALUES(?,2)', (records['local-join'][0],))
            indexed_row = records['indexed-join'][0]
            indexed_guid = db.execute('SELECT guid FROM message WHERE ROWID=?', (indexed_row,)).fetchone()[0]
            # Wrong message and wrong SQL position cannot capture the artwork.
            for row, guid in ((3, 'at_0_wrong-message'), (4, 'at_1_' + indexed_guid), (5, 'at_0_' + indexed_guid)):
                db.execute('INSERT INTO attachment VALUES(?,?,?,?,?,?)', (row, guid, 'local.png', 'image/png', 20, str(attachments / 'artwork')))
                db.execute('INSERT INTO message_attachment_join VALUES(?,?)', (indexed_row,row))
        log = open(root / 'relay.log', 'w+')
        process = subprocess.Popen([str(binary), 'serve', *args], stdout=log, stderr=log)

        def request(path):
            with closing(tls.connection(timeout=5)) as conn:
                conn.request('GET', path); response = conn.getresponse(); body = response.read()
                return response.status, json.loads(body) if response.getheader('content-type', '').startswith('application/json') else body

        def message(name):
            with sqlite3.connect(data / 'relay.db') as db:
                row = db.execute('SELECT record FROM messages WHERE source_row=?', (records[name][0],)).fetchone()
                return json.loads(row[0]) if row else {}

        def image_ready(name):
            image = message(name)['link_previews'][0]['image']
            code, body = request(f'/v1/assets/{image["id"]}/{image["version"]}/inline_image')
            return body if code == 200 else False

        try:
            wait_for(lambda: message('local-join'))
            for name, (_, state) in records.items():
                value = message(name)
                assert value['enrichment']['state'] == state, (name, value)
                assert value['text'] == 'Original link and caption ' + name
                assert 'private-joined-artwork' not in json.dumps(value)
                assert 'ZIMBR-IMAGE' not in json.dumps(value)
            for name in ('binary', 'xml', 'archive-binary', 'archive-xml'):
                card = message(name)['link_previews'][0]
                assert card['title'] == meta['title'] and card['summary'] == meta['summary']
                assert card['original_url'] == meta['originalURL'] and card['metadata_url'] == meta['URL']
                assert card['icon'] is None
                assert wait_for(lambda name=name: image_ready(name)).startswith(b'\x89PNG')
            assert message('plain')['link_previews'] == []
            assert message('unknown-balloon')['link_previews'] == []
            assert message('remote-only')['link_previews'][0]['image'] is None
            for name in ('rich-link', 'sharing-wrapper', 'rich-placeholder'):
                card = message(name)['link_previews'][0]
                assert card['title'] == 'Stored card'
                assert card['image'] is None and card['icon'] is None
                assert card['state'] == ('pending' if name == 'rich-placeholder' else 'complete')
            joined = message('local-join')
            assert joined['attachments'][0]['preview_artwork']
            assert [p['kind'] for p in joined['parts']] == ['text', 'link_preview']
            assert joined['attachments'][0]['image']['id'] == joined['link_previews'][0]['image']['id']
            assert wait_for(lambda: image_ready('local-join')).startswith(b'\x89PNG')
            indexed = message('indexed-join')
            assert indexed['link_previews'][0]['icon']['id'] == indexed['attachments'][2]['image']['id']
            assert [item['preview_artwork'] for item in indexed['attachments']] == [False, False, True]
            many = message('several')
            assert many['enrichment']['previews'] == {'total': 7, 'complete': False}
            params = urlencode(dict(section='previews', revision=many['revision']))
            code, full = request('/v1/messages/' + many['id'] + '/enrichment?' + params)
            assert code == 200 and len(full['items']) == 7
            before = message('delayed')
            with database(source) as db:
                db.execute('UPDATE message SET payload_data=? WHERE ROWID=?', (plistlib.dumps({'metadata': meta}, fmt=plistlib.FMT_BINARY), records['delayed'][0]))
            wait_for(lambda: message('delayed')['link_previews'])
            after = message('delayed')
            assert after['timestamp'] == before['timestamp'] and after['observed_status'] == before['observed_status']
            with sqlite3.connect(data / 'relay.db') as db:
                assert db.execute("SELECT origin FROM events WHERE type='message.upsert' AND json_extract(record,'$.id')=? ORDER BY sequence DESC LIMIT 1", (after['id'],)).fetchone() == ('reconciliation',)
            # A present empty aggregate clears removed metadata and ownership.
            with database(source) as db:
                db.execute('UPDATE message SET balloon_bundle_id=NULL,payload_data=NULL WHERE ROWID=?', (records['delayed'][0],))
            wait_for(lambda: not message('delayed')['link_previews'])
            print('PASS: binary/XML/keyed URL metadata, local-only artwork, attachment joins, captions, delayed/removed payloads, overflow, bounded malformed/unsafe fallback')
        except Exception:
            log.seek(0); print(log.read()); raise
        finally:
            process.terminate(); process.wait(timeout=5); log.close()


if __name__ == '__main__':
    main()
