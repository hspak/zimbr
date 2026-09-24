#!/usr/bin/env python3
"""Identity extension negotiation and interrupted bootstrap transport fixtures."""
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from client_tls import Handler, EPOCH
from client_integration import wait
from performance import Probe
from tls_fixture import PKI, TLSServer

ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'zig-out/bin/client-probe'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-enrichment-protocol-') as tmp:
        root=Path(tmp); os.environ['XDG_CONFIG_HOME']=str(root/'config')
        pki=PKI(root/'tls')
        state=dict(enabled=False,echo=True,hold=False,expire=False,syncs=0,pages=0,identity_streams=0)
        held=threading.Event(); release=threading.Event()
        class Endpoint(Handler):
            def response(self, body):
                raw=json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                path=urlsplit(self.path); query=parse_qs(path.query)
                if path.path=='/v1/status':
                    body=dict(api_version='1',server_epoch=EPOCH,adapter_ready=True,capabilities=dict(send_direct=True,reply_existing=True),degraded_reasons=[])
                    if state['enabled']:
                        body['event_extensions']=['identity-v1']; body['capabilities']['identity_directory_v1']=True
                        body['enrichment_readiness']=dict(identity_directory_v1=dict(ready=True,permission='authorized'))
                    return self.response(body)
                if path.path=='/v1/sync':
                    state['syncs']+=1
                    return self.response(dict(server_epoch=EPOCH,cursor=EPOCH+':0'))
                if path.path=='/v1/identities':
                    assert state['enabled']
                    state['pages']+=1
                    second='before' in query
                    if second and state['hold']:
                        held.set(); release.wait(timeout=20)
                    identity=dict(id='peer-2' if second else 'peer-1',revision='2' if second else '1',service='imessage',address='other@example.invalid' if second else 'peer@example.invalid',display_name='Second' if second else 'First',match_state='matched')
                    return self.response(dict(identities=[identity],next=None if second else 'next-id'))
                if path.path=='/v1/events':
                    if state['enabled']:
                        assert query.get('extensions')==['identity-v1']; state['identity_streams']+=1
                    else: assert 'extensions' not in query
                    if state['expire']:
                        state['expire']=False
                        self.send_response(410); self.send_header('Content-Length','0'); self.end_headers(); return
                    self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Connection','close')
                    if state['enabled'] and state['echo']: self.send_header('ZiMbR-EvEnT-ExTeNsIoNs','identity-v1')
                    self.end_headers(); self.close_connection=True
                    try:
                        for _ in range(300):
                            self.wfile.write(b': heartbeat\n\n'); self.wfile.flush(); time.sleep(.1)
                    except OSError: pass
                    return
                return super().do_GET()
        server=TLSServer(Endpoint,pki.context()); server.mode='ok'; server.requests=[]
        log=open(root/'client.log','w+')
        data=root/'client'
        def start(): return Probe([str(BIN),'--control','--data-dir',str(data),*pki.client_args(server.server_port)],log)
        def rows(sql):
            with sqlite3.connect(data/'client.db') as db: return db.execute(sql).fetchall()
        probe=start()
        try:
            probe.until(lambda v:v.get('online'))
            assert state['pages']==0
            probe.command(kind='draft',key='new:peer@example.invalid',text='Keep through upgrade')
            wait(lambda:rows('SELECT count(*) FROM drafts')==[(1,)])
            state.update(enabled=True,hold=True)
            probe.command(kind='reconnect')
            assert held.wait(timeout=10)
            assert rows("SELECT value FROM meta WHERE key='bootstrapped'")==[('0',)]
            assert rows("SELECT value FROM meta WHERE key='identity_bootstrapped'")==[('0',)]
            assert state['identity_streams']==0
            probe.proc.kill(); probe.proc.wait(timeout=5); probe.close()
            release.set(); state['hold']=False
            probe=start(); probe.until(lambda v:v.get('online'))
            assert rows('SELECT count(*) FROM identities')==[(2,)]
            assert state['pages']>=4
            assert rows("SELECT value FROM meta WHERE key='accepted_extensions'")==[('identity-v1',)]
            assert rows('SELECT text FROM drafts')==[('Keep through upgrade',)]
            # A lying/old relay cannot silently accept a requested extension.
            state['echo']=False
            probe.command(kind='reconnect')
            probe.until(lambda v:v.get('diagnostics',{}).get('auth_blocked'))
            assert not probe.latest['online']
            assert rows("SELECT value FROM meta WHERE key='cursor'")==[(EPOCH+':0',)]
            streams=state['identity_streams']; time.sleep(.5)
            assert state['identity_streams']==streams
            state['echo']=True; state['expire']=True; syncs=state['syncs']
            probe.command(kind='reconnect'); probe.until(lambda v:v.get('online'))
            assert state['syncs']>syncs
            # Dropping back to legacy invalidates directory completeness, even
            # if a previous identity bootstrap finished in the same epoch.
            state['enabled']=False; probe.command(kind='reconnect'); probe.until(lambda v:v.get('online') and not v['diagnostics']['server']['capabilities']['identity_directory_v1'])
            assert rows("SELECT value FROM meta WHERE key='identity_bootstrapped'")==[('0',)]
            pages=state['pages']; state['enabled']=True; probe.command(kind='reconnect')
            probe.until(lambda v:v.get('online') and v['diagnostics']['server']['capabilities']['identity_directory_v1'])
            assert state['pages']==pages+2
            print('PASS: legacy relay fallback, same-epoch upgrade, interrupted multi-page bootstrap, mandatory extension echo, expired cursor recovery, and downgrade/re-upgrade')
        finally:
            release.set(); probe.close(); server.close(); log.close()

if __name__=='__main__': main()
