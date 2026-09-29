#!/usr/bin/env python3
"""Check native Messages terminology without sending or querying real accounts."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT/'src/relay/adapter/send.applescript'


def capture_script(source):
    # Keep the production payload preparation, branches, and send operands.
    # Only compile against Messages terminology; replace account/chat lookup
    # with local fixtures and capture each send operand in a local handler.
    replacements = {
        'tell application "Messages"': 'using terms from application "Messages"',
        'end tell': 'end using terms from',
        'set candidates to every account whose service type is iMessage and enabled is true':
            'set candidates to {1}',
        'set recipient to participant destination of imAccount': 'set recipient to destination',
        'set destinationChat to chat id destination': 'set destinationChat to destination',
        'if service type of account of destinationChat is not iMessage then return "unsupported_target"':
            'if false then return "unsupported_target"',
        'if id of account of destinationChat is not id of imAccount then return "unsupported_account"':
            'if false then return "unsupported_account"',
    }
    for original, replacement in replacements.items():
        if source.count(original) != 1:
            raise AssertionError(f'Production script boundary changed: {original}')
        source = source.replace(original, replacement)
    source, count = re.subn(
        r'(?m)^(\s*)send (.+) to (recipient|destinationChat)$',
        r'\1return my capturePayload(\2, operation, bodyText)', source)
    if count != 2 or re.search(r'\btell\b|\bsend\b', source):
        raise AssertionError('Probe must contain exactly two captured sends and no application commands')
    return source + '''
on capturePayload(actualPayload, operation, originalBody)
    if operation is "direct-file" or operation is "chat-file" then
        if class of actualPayload is not alias then return "wrong file operand: " & (actualPayload as text)
        if POSIX path of actualPayload is not originalBody then return "wrong file path"
        return "file-ok"
    end if
    if class of actualPayload is not text then return "wrong text operand: " & (actualPayload as text)
    if actualPayload is not originalBody then return "wrong text body"
    return "text-ok"
end capturePayload
'''


@unittest.skipUnless(sys.platform == 'darwin', 'requires native AppleScript and Messages terminology')
class NativeSendScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text()
        cls.probe = capture_script(cls.source)

    def run_probe(self, mode, body):
        result = subprocess.run(
            ['/usr/bin/osascript', '-e', self.probe, '--', mode, 'synthetic-target', body],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_production_script_compiles_without_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ['/usr/bin/osacompile', '-o', str(Path(directory)/'send.scpt'), str(SCRIPT)],
                capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_text_operand_preserves_unicode_and_literal_script_characters(self):
        text = 'Reviewed caption 👋\n"; send \\ $HOME `literal`'
        for mode in ('direct', 'chat'):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_probe(mode, text), 'text-ok')

    def test_file_operand_is_the_requested_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            path = (Path(directory)/'photo 👋 "; $x.png').resolve()
            path.write_bytes(bytes(range(256)))
            for mode in ('direct-file', 'chat-file'):
                with self.subTest(mode=mode):
                    self.assertEqual(self.run_probe(mode, str(path)), 'file-ok')
            self.assertEqual(path.read_bytes(), bytes(range(256)))

    def test_missing_file_stops_before_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = (Path(directory)/'missing.png').resolve()
            for mode in ('direct-file', 'chat-file'):
                with self.subTest(mode=mode):
                    self.assertEqual(self.run_probe(mode, str(path)), 'adapter_unavailable')


if __name__ == '__main__':
    unittest.main()
