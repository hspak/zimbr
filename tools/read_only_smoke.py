#!/usr/bin/env python3
"""Read-only development-identity API smoke test; no automation and no sends."""
import argparse
import http.client
import json
from pathlib import Path
import subprocess
import tempfile
import time

from tls_support import Credentials

ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'zig-out/bin/relay'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay-config',type=Path,required=True,help='TLS relay config with an unused explicit local port')
    parser.add_argument('--tls-config',type=Path,required=True,help='Enrolled administrative HTTPS credentials')
    args=parser.parse_args()
    credentials=Credentials(args.tls_config)
    with tempfile.TemporaryDirectory(prefix='zimbr-read-probe-') as temporary:
        data=Path(temporary)
        subprocess.run([str(BIN),'setup','--data-dir',str(data)],check=True,stdout=subprocess.DEVNULL)
        def request(path):
            c=credentials.connection(timeout=8)
            c.request('GET',path)
            r=c.getresponse();assert r.status==200;body=json.loads(r.read());c.close();return body
        with (data/'log').open('w+') as log:
            def start():return subprocess.Popen([str(BIN),'serve','--read-only','--data-dir',str(data),'--config',str(args.relay_config)],stdout=log,stderr=log)
            proc=start()
            try:
                deadline=time.monotonic()+30
                while True:
                    try:
                        status=request('/v1/status')
                        if status['adapter_ready']:break
                    except OSError:pass
                    if time.monotonic()>deadline:raise RuntimeError('Read-only adapter did not become ready')
                    time.sleep(.25)
                assert not status['capabilities']['send_direct']
                before=request('/v1/sync')
                conversations=request('/v1/conversations?limit=200')['conversations']
                message=None
                for conversation in conversations:
                    history=request('/v1/conversations/'+conversation['id']+'/messages?limit=2')['messages']
                    if history:message=history[0];break
                assert message and message['revision']!='0'
                assert 'source' not in message and 'source_row' not in message
                proc.terminate();proc.wait(timeout=5);proc=start()
                deadline=time.monotonic()+20
                while True:
                    try:after=request('/v1/sync');break
                    except OSError:
                        if time.monotonic()>deadline:raise
                        time.sleep(.25)
                assert before['server_epoch']==after['server_epoch']
                history=request('/v1/conversations/'+message['conversation_id']+'/messages?limit=200')['messages']
                assert any(m['id']==message['id'] for m in history)
                print(json.dumps({'real_database_api_read':True,'conversation_page_count':len(conversations),'history_record_visible':True,'epoch_and_message_id_survived_restart':True,'automation_used':False,'installed_identity_validated':False}))
            finally:
                if proc.poll() is None:proc.terminate();proc.wait(timeout=5)

if __name__=='__main__':main()
