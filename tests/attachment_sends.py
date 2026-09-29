#!/usr/bin/env python3
"""Outgoing attachments must never silently become caption-only sends."""
import hashlib
import json
import sqlite3
import unittest
from contextlib import closing

from fixture import new_id
import relay_tls


class AttachmentSends(unittest.TestCase):
    setUp = relay_tls.RelayTls.setUp
    tearDown = relay_tls.RelayTls.tearDown
    start = relay_tls.RelayTls.start
    stop = relay_tls.RelayTls.stop
    get = relay_tls.RelayTls.get

    def test_unavailable_attachment_send_never_dispatches_its_caption(self):
        outgoing = dict(
            request_id=new_id(), server_epoch=self.get('/v1/sync')['server_epoch'],
            target={'recipient': {'address': 'alice@example.invalid', 'service': 'imessage'}},
            text='This caption must not be sent without its file',
            attachments=[dict(id=new_id(), name='photo.png', mime_type='image/png',
                              bytes='4', sha256=hashlib.sha256(b'file').hexdigest())],
        )
        with closing(self.tls.connection()) as connection:
            connection.request('POST', '/v1/messages', json.dumps(outgoing),
                               {'content-type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            self.assertEqual(json.loads(response.read())['error_info']['outcome'], 'unstarted')
        with closing(sqlite3.connect(self.root/'data/relay.db')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM send_requests WHERE id=?',
                                       (outgoing['request_id'],)).fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
