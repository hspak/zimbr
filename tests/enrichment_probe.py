"""Installed-doctor diagnostics stay bounded and do not disclose source values."""
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile

from fixture import create, add_message
from relay_fixture import Fixture

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-format-probe-') as temporary:
        root = Path(temporary).resolve()
        source = root/'source.db'
        create(source, count=1)
        tls = Fixture(root, 18731)
        with sqlite3.connect(source) as db:
            db.executescript('ALTER TABLE message ADD COLUMN payload_data BLOB; ALTER TABLE message ADD COLUMN associated_message_guid TEXT; ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;')
            metadata = {'richLinkMetadata': {'originalURL': 'https://private.invalid/secret', 'title': 'PRIVATE TITLE', 'PRIVATE KEY': 'PRIVATE VALUE'}}
            for i in range(110):
                add_message(db, 'PRIVATE TEXT', balloon_bundle_id='com.apple.messages.URLBalloonProvider', payload_data=plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY))
            add_message(db, 'PRIVATE REACTION', associated_message_type=2006, associated_message_guid='p:0/PRIVATE GUID', associated_message_emoji='👩🏽‍💻')
        output = subprocess.check_output([str(ROOT/'zig-out/bin/fake-relay'), 'doctor', '--enrichment', '--messages-db', str(source), '--config', str(tls.config)], text=True)
        report = json.loads(output)['enrichment_probe']
        assert report['url_samples'] == report['sample_limit'] == 100
        assert report['preview_count'] == report['binary_plists'] == 100
        assert report['target_part_prefix'] == report['custom_emoji_present'] == 1
        assert 'private' not in output.lower()
        assert '👩' not in output
        assert str(source) not in output
        print('PASS: source probe sample bounds, actual parser outcomes, reaction shapes, no source values')


if __name__ == '__main__':
    main()
