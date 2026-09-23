#!/usr/bin/env python3
"""Fault injection in front of the real fixture relay and production client worker."""
import http.client
import http.server
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
from fixture import create
from client_integration import wait
ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'zig-out/bin'

def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-transport-') as temp:
        root=Path(temp);source=root/'source.db';relay=root/'relay';client=root/'client';create(source)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        opts=['--data-dir',str(relay),'--messages-db',str(source),'--port',str(port)]
        subprocess.run([str(BIN/'fake-relay'),'setup',*opts],check=True,capture_output=True)
        log=open(root/'log','w+')
        server=subprocess.Popen([str(BIN/'fake-relay'),'serve',*opts],stdout=log,stderr=log)
        faults={'history':True,'post':True,'posts':0,'lookups':0,'auth':0,'stream':True}
        slow_history=threading.Event();release_history=threading.Event()
        class Proxy(http.server.BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def log_message(self,*args):pass
            def do_GET(self):self.forward()
            def do_POST(self):self.forward()
            def forward(self):
                conn=http.client.HTTPConnection('127.0.0.1',port,timeout=20)
                try:
                    if faults.get('slow_history') and '/messages?' in self.path and 'limit=100' in self.path:
                        faults['slow_history']=False;slow_history.set();release_history.wait(timeout=8)
                    body=self.rfile.read(int(self.headers.get('Content-Length',0)))
                    if self.command=='POST':faults['posts']+=1
                    if '/send-requests/' in self.path:faults['lookups']+=1
                    conn.request(self.command,self.path,body,{'Authorization':self.headers.get('Authorization',''),'Content-Type':'application/json'})
                    result=conn.getresponse()
                    if result.status==401:faults['auth']+=1
                    if self.path.startswith('/v1/events') and result.status==200:
                        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
                        if faults['stream']:
                            faults['stream']=False
                            self.wfile.write(b'id: incomplete\nevent: message.upsert\ndata: {"record":');self.wfile.flush();self.close_connection=True;return
                        while chunk:=result.readline():
                            self.wfile.write(chunk);self.wfile.flush()
                        return
                    raw=result.read()
                    if self.command=='POST' and faults['post']:
                        faults['post']=False;self.close_connection=True;self.connection.shutdown(socket.SHUT_RDWR);return
                    self.send_response(result.status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.send_header('Connection','close');self.end_headers()
                    if '/messages?' in self.path and 'limit=100' in self.path and faults['history']:
                        faults['history']=False;raw=raw[:len(raw)//2]
                    self.wfile.write(raw);self.wfile.flush();self.close_connection=True
                except (OSError,http.client.HTTPException):
                    self.close_connection=True
                finally:conn.close()
        proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
        threading.Thread(target=proxy.serve_forever,daemon=True).start()
        proc=None
        def rows(sql,args=(),path=client/'client.db'):
            with sqlite3.connect(path) as db:return db.execute(sql,args).fetchall()
        def command(**value):
            proc.stdin.write((json.dumps(value)+'\n').encode());proc.stdin.flush()
        token=root/'token';token.write_text('0'*64);token.chmod(0o600)
        try:
            proc=subprocess.Popen([str(BIN/'client-probe'),'--control','--data-dir',str(client),'--token-file',str(token),'--port',str(proxy.server_port)],stdin=subprocess.PIPE,stdout=log,stderr=log)
            wait(lambda:faults['auth']==1)
            time.sleep(1.5);assert faults['auth']==1,'Authentication failures must await user action'
            token.write_bytes((relay/'token').read_bytes());command(kind='reconnect')
            cid=wait(lambda:rows("SELECT id FROM records WHERE kind='conversation' AND json_extract(record,'$.participants[0]')='alice@example.invalid' AND json_array_length(json_extract(record,'$.participants'))=1"))[0][0]
            command(kind='select',key=cid)
            wait(lambda:rows("SELECT count(*) FROM records WHERE kind='message' AND chat=?",(cid,))[0][0]>=100)
            assert not faults['history'] and not faults['stream']
            command(kind='send',key=cid,text='Lost POST response fixture')
            wait(lambda:faults['lookups']>0)
            try:
                wait(lambda:rows("SELECT count(*) FROM outbox WHERE record IS NOT NULL")[0][0]==1)
            except AssertionError:
                print('Fault state:', faults, rows("SELECT state,detail,record FROM outbox"));raise
            assert faults['posts']==1,'Recovery must never POST again'
            wait(lambda:rows("SELECT count(*) FROM message WHERE text='Lost POST response fixture'",path=source)[0][0]==1)
            # A blocked history GET must not delay a newly requested send.
            faults['slow_history']=True
            command(kind='select',key=cid)
            assert slow_history.wait(timeout=10)
            command(kind='send',key=cid,text='Send during blocked history')
            wait(lambda:rows("SELECT count(*) FROM message WHERE text='Send during blocked history'",path=source)[0][0]==1,timeout=3)
            assert faults['posts']==2,'Preemption must not cancel or repeat an active POST'
            release_history.set()
            proc.stdin.write(b'quit\n');proc.stdin.flush();assert proc.wait(timeout=10)==0;proc=None
            print('PASS: authentication backpressure, fragmented/disconnected SSE, interrupted history retry, send priority over blocked history, and lost POST response resolved by original UUID without duplicate dispatch')
        finally:
            release_history.set()
            if proc and proc.poll() is None:proc.kill();proc.wait()
            proxy.shutdown();proxy.server_close()
            server.terminate();server.wait(timeout=5);log.close()
if __name__=='__main__':main()
