"""Acceptance-tool failures must retain evidence without sending again."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import mac_acceptance as acceptance


class AcceptanceTests(unittest.TestCase):
    def test_request_id_survives_lost_submission_response(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'evidence.json'
            client=Mock()
            client.request.side_effect=[
                {'capabilities':{'send_direct':True}},
                {'server_epoch':'epoch','cursor':'epoch:0'},
                OSError('lost response after acceptance'),
            ]
            args=['mac_acceptance.py','--recipient','self@example.invalid','--confirm-send','--output',str(output)]
            with patch.object(sys,'argv',args), patch.object(acceptance,'Client',return_value=client), patch.object(acceptance.subprocess,'check_output',return_value='test-build\n'):
                with self.assertRaises(OSError):acceptance.main()
                saved=json.loads(output.read_text())
                payload=client.request.call_args.args[1]
                self.assertEqual(saved['sends'][0]['request_id'],payload['request_id'])
                self.assertEqual(saved['sends'][0]['state'],'submission_unresolved')
                self.assertFalse(saved['complete'])
                self.assertEqual(output.stat().st_mode & 0o777,0o600)
                self.assertNotIn('self@example.invalid',output.read_text())
                # Running the tool again must not overwrite the request ID or
                # submit another real message after an ambiguous network result.
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):acceptance.main()
                self.assertEqual(client.request.call_count,3)

    def test_sse_replay_stops_at_committed_boundary_and_closes(self):
        client=acceptance.Client.__new__(acceptance.Client)
        response=io.BytesIO(b': heartbeat\n\ndata: {"sequence":"1"}\n\ndata: {"sequence":"2"}\n\ndata: {"sequence":"3"}\n\n')
        connection=Mock()
        with patch.object(client,'connect',return_value=(connection,response)):
            self.assertEqual(client.events('epoch:0','epoch:2'),[{'sequence':'1'},{'sequence':'2'}])
        self.assertTrue(response.closed)
        connection.close.assert_called_once()

    def test_lock_requires_this_users_console_session(self):
        def registry(uid,locked=None):
            session={'kCGSSessionUserIDKey':uid,'kCGSSessionOnConsoleKey':True}
            if locked is not None:session['CGSSessionScreenIsLocked']=locked
            return plistlib.dumps({'IOConsoleUsers':[session]})
        with patch.object(acceptance.subprocess,'check_output',return_value=registry(os.getuid(),True)):
            self.assertTrue(acceptance.screen_locked())
        with patch.object(acceptance.subprocess,'check_output',return_value=registry(os.getuid())):
            self.assertFalse(acceptance.screen_locked())
        with patch.object(acceptance.subprocess,'check_output',return_value=registry(os.getuid()+1,True)):
            with self.assertRaises(RuntimeError):acceptance.screen_locked()


if __name__=='__main__':unittest.main()
