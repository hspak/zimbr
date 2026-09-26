#!/usr/bin/env python3
"""Read selected relay/Messages chat metadata without sending or changing either DB.

Addresses, account identifiers, chat identifiers and grouping identifiers share
opaque labels within one report so their relationships remain visible. Names,
message bodies and original identifier values are never printed.
"""
import argparse
from collections import Counter
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'packaging/macos'))
from profiles import PROFILES


def service(value):
    return value if value in ('any', 'iMessage', 'SMS', 'RCS', 'imessage', 'sms', 'rcs') else 'unknown'


def inspect(journal_path, messages_path, conversation_ids):
    labels = {}

    def label(value):
        if value is None or value == '' or value == b'':
            return None
        key = (type(value).__name__, value)
        if key not in labels:
            labels[key] = f'value-{len(labels)+1}'
        return labels[key]

    def readonly(path):
        db = sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        return db

    with closing(readonly(journal_path)) as relay, closing(readonly(messages_path)) as source:
        columns = {row['name'] for row in source.execute('PRAGMA table_info(chat)')}
        optional = [name for name in (
            'chat_identifier', 'group_id', 'original_group_id', 'room_name',
            'account_id', 'account_login', 'last_addressed_handle',
        ) if name in columns]
        flags = [name for name in ('style', 'state', 'is_filtered', 'is_archived') if name in columns]
        # Identifiers interpolated below are exclusively from these fixed lists.
        fields = ','.join(['ROWID', 'guid', 'service_name', *optional, *flags])
        report = []
        for index, conversation_id in enumerate(conversation_ids, 1):
            entry = {'selection': index}
            relay_chat = relay.execute(
                'SELECT source,source_row,route,record FROM conversations WHERE id=?',
                (conversation_id,),
            ).fetchone()
            if relay_chat is None:
                entry['error'] = 'conversation_not_in_relay'
                report.append(entry)
                continue
            record = json.loads(relay_chat['record'])
            entry['relay'] = {'service': service(record['service']), 'sendable': record.get('sendable', False)}
            chats = source.execute(f'SELECT {fields} FROM chat WHERE guid=? LIMIT 2', (relay_chat['source'],)).fetchall()
            if len(chats) != 1:
                entry['error'] = 'source_chat_missing_or_ambiguous'
                report.append(entry)
                continue
            chat = chats[0]
            participants = [row[0] for row in source.execute(
                'SELECT DISTINCT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=? ORDER BY h.id LIMIT 256',
                (chat['ROWID'],),
            )]
            entry['source'] = {
                'service': service(chat['service_name']),
                'guid_service_prefix': service(chat['guid'].split(';', 1)[0]),
                'relay_route_matches_guid': relay_chat['route'] == chat['guid'],
                'relay_source_row_matches': relay_chat['source_row'] == chat['ROWID'],
                'participants': [label(value) for value in participants],
                'identifiers': {name: label(chat[name]) for name in optional},
                'flags': {name: chat[name] if isinstance(chat[name], int) else None for name in flags},
            }
            messages = source.execute(
                'SELECT m.ROWID,m.service,m.is_from_me,m.associated_message_type,m.item_type,m.is_system_message '
                'FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id '
                'WHERE j.chat_id=? ORDER BY m.date DESC,m.ROWID DESC LIMIT 200',
                (chat['ROWID'],),
            ).fetchall()
            ordinary = [row for row in messages if not any(row[name] for name in ('associated_message_type', 'item_type', 'is_system_message'))]
            entry['recent_messages'] = {
                'sampled': len(messages),
                'services': dict(Counter(service(row['service']) for row in messages)),
                'incoming': sum(not row['is_from_me'] for row in messages),
                'outgoing': sum(bool(row['is_from_me']) for row in messages),
                'latest_ordinary_service': service(ordinary[0]['service']) if ordinary else None,
                'latest_outgoing_service': next((service(row['service']) for row in ordinary if row['is_from_me']), None),
            }
            report.append(entry)
        return {'conversations': report, 'identifiers_are_report_local_labels': True, 'read_only': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--conversation', action='append', required=True, help='Relay conversation ID; repeat to compare up to eight chats')
    parser.add_argument('--data-dir', type=Path, default=None)
    parser.add_argument('--messages-db', type=Path, default=Path.home()/'Library/Messages/chat.db')
    parser.add_argument('--profile', choices=PROFILES, default='dev')
    args = parser.parse_args()
    profile = PROFILES[args.profile]
    args.data_dir = args.data_dir or profile.data(Path.home())
    if len(args.conversation) > 8:
        parser.error('Select at most eight conversations')
    try:
        result = inspect(args.data_dir/'relay.db', args.messages_db, args.conversation)
    except (sqlite3.Error, OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Conversation probe failed ({type(error).__name__}); check database paths, schema and read permission.\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
