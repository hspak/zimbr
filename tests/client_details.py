#!/usr/bin/env python3
"""Exercise live and cached diagnostics through the production worker."""
import json
import os
from relay_fixture import Fixture
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
from fixture import create

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'zig-out/bin'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-details-') as temp:
        root = Path(temp)
        os.environ['XDG_CONFIG_HOME'] = str(root/'config')
        source, relay, client = root / 'source.db', root / 'relay', root / 'client'
        create(source, count=8)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        tls = Fixture(root, port)
        args = ['--data-dir', str(relay), '--messages-db', str(source), '--config', str(tls.config)]
        subprocess.run([str(BIN / 'fake-relay'), 'setup', *args], check=True, capture_output=True)
        private_key_line = (tls.root/'client-key.pem').read_text().splitlines()[1]
        with (root / 'server.log').open('w') as log:
            server = subprocess.Popen([str(BIN / 'fake-relay'), 'serve', *args], stdout=log, stderr=log)
            proc = None
            def start():
                nonlocal proc
                proc = subprocess.Popen([str(BIN / 'client-probe'), '--control', '--data-dir', str(client), *tls.client_args()], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
                views = queue.Queue()
                def read():
                    for line in proc.stdout:
                        views.put(line)
                threading.Thread(target=read, daemon=True).start()
                return views
            def command(**value):
                proc.stdin.write(json.dumps(value) + '\n')
                proc.stdin.flush()
            def until(views, predicate):
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    line = views.get(timeout=max(.1, deadline-time.monotonic()))
                    assert private_key_line not in line, 'Credentials must never enter diagnostics'
                    value = json.loads(line)
                    if predicate(value):
                        return value
                raise AssertionError('No matching diagnostics snapshot')
            def stop():
                nonlocal proc
                proc.stdin.write('quit\n')
                proc.stdin.flush()
                assert proc.wait(timeout=10) == 0
                proc = None
            try:
                views = start()
                until(views, lambda v: v['online'] and v['chats'] > 0)
                with sqlite3.connect(client / 'client.db') as db:
                    selected = db.execute("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.title')='Fixture group'").fetchone()[0]
                command(kind='select', key=selected)
                view = until(views, lambda v: v['online'] and v['diagnostics']['cached_messages'] > 0)
                details = view['diagnostics']
                assert details['server']['api_version'] == '1'
                assert details['server']['capabilities']['read_history']
                assert details['bootstrapped'] and details['stream_active']
                assert details['cursor'].startswith(details['server']['server_epoch'] + ':')
                assert details['last_status_ms'] > 0
                assert len(details['transport']['fingerprint']) == 64
                assert details['transport']['expires'].endswith('Z')
                assert details['transport']['failure'] == 'none'
                assert details['transport']['fingerprint'] == tls.fingerprint('client')
                stop()
                server.terminate()
                server.wait(timeout=5)
                views = start()
                offline = until(views, lambda v: not v['online'] and v['diagnostics']['server'] is not None)
                assert offline['diagnostics']['cached_messages'] > 0
                assert offline['diagnostics']['last_status_ms'] == details['last_status_ms']
                until(views, lambda v: v['diagnostics']['retry_at'] > 0)
                stop()
                print('PASS: live diagnostics, offline server status, retry state, and private credentials')
            finally:
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait()
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)


if __name__ == '__main__':
    main()
