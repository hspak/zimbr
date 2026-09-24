#!/usr/bin/env python3
"""Authenticated media fault injection; service behavior uses client_enrichment.py."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import sqlite3
import struct
import tempfile
import threading
import time
import uuid
import zlib
from client_tls import Handler, EPOCH
from tls_fixture import PKI, TLSServer
from performance import Probe
from client_integration import wait

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT/'zig-out/bin/client-probe'


def png(width=2, height=3):
    def chunk(kind, data):
        return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\x00'+b'\x80\x20\x30\x80'*min(width,2))*min(height,3)))+chunk(b'IEND',b'')


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-media-transport-') as tmp:
        root=Path(tmp)
        os.environ['XDG_CONFIG_HOME']=str(root/'config')
        pki=PKI(root/'tls')
        behavior={}; counts={}; active=0; peak=0
        lock=threading.Lock(); release=threading.Event(); posts=[]
        class MediaHandler(Handler):
            def do_POST(self):
                data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                posts.append(data)
                data.update(revision='1',state='submitted')
                raw=json.dumps(data).encode()
                self.send_response(202); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                nonlocal active,peak
                if not self.path.startswith('/v1/assets/'):
                    return super().do_GET()
                assert self.connection.version()=='TLSv1.3' and self.connection.getpeercert(binary_form=True)
                ident=self.path.split('/')[3]
                mode=behavior.get(ident,'good')
                with lock:
                    counts[ident]=counts.get(ident,0)+1; active+=1; peak=max(peak,active)
                try:
                    data=png(); status=200; mime='image/png'
                    if mode=='slow': release.wait(timeout=8)
                    elif mode=='redirect': status=302
                    elif mode=='retired': status=410
                    elif mode=='denied': status=403
                    elif mode=='pending':
                        status=409; mime='application/json'; data=json.dumps(dict(retryable=True,retry_after=3)).encode()
                    elif mode=='unavailable':
                        status=409; mime='application/json'; data=b'{"retryable":false}'
                    elif mode=='corrupt': data=b'\x89PNG\r\n\x1a\ncorrupt'
                    elif mode=='huge': data=png(50000,50000)
                    elif mode=='mime': mime='image/gif'
                    elif mode=='oversize': data=b'x'*(8*1024*1024+1)
                    elif mode=='jpeg': data=JPEG; mime='image/jpeg'
                    elif mode=='jpeg_truncated': data=JPEG[:-2]; mime='image/jpeg'
                    self.send_response(status); self.send_header('Content-Type',mime)
                    self.send_header('Content-Length',str(len(data)))
                    if mode=='redirect': self.send_header('Location','https://localhost:%d/never-follow' % self.server.server_port)
                    self.send_header('Connection','close'); self.end_headers()
                    if mode=='truncated': data=data[:len(data)//2]
                    self.wfile.write(data); self.wfile.flush(); self.close_connection=True
                except (OSError, BrokenPipeError): pass
                finally:
                    with lock: active-=1
        server=TLSServer(MediaHandler,pki.context()); server.mode='ok'; server.requests=[]
        log=open(root/'client.log','w+')
        probe=Probe([str(BIN),'--control','--data-dir',str(root/'client'),*pki.client_args(server.server_port)],log)
        def asset(mode='good'):
            ident=str(uuid.uuid4()); behavior[ident]=mode
            return dict(id=ident,version=str(uuid.uuid4()),variant='inline_image',availability='ready')
        def fetch(ref):
            probe.command(kind='media',asset=ref)
            probe.until(lambda v:'media' in v, timeout=10)
            return probe.latest['media']
        try:
            probe.until(lambda v:v.get('online'))
            probe.command(kind='media_context',epoch=EPOCH,chat='one')
            good=asset(); result=fetch(good)
            assert result['state']=='ready' and (result['width'],result['height'])==(2,3),result
            cache=root/'client/media'/result['key']
            assert cache.exists()
            assert fetch(good)['state']=='ready' and counts[good['id']]==1
            jpeg=fetch(asset('jpeg')); assert jpeg['state']=='ready' and (jpeg['width'],jpeg['height'])==(4,3),jpeg
            for mode,expected in [('truncated','failed'),('jpeg_truncated','failed'),('corrupt','failed'),('huge','failed'),('mime','failed'),('oversize','failed'),('redirect','failed'),('retired','retired'),('pending','pending'),('unavailable','failed'),('denied','denied')]:
                result=fetch(asset(mode)); assert result['state']==expected,(mode,result)
                assert not (root/'client/media'/result['key']).exists(),mode
            assert not any('/never-follow' in row[0] for row in server.requests)
            assert not list((root/'client/media').glob('tmp-*'))
            # Two media transfers can be held while the ordinary worker sends.
            slow=[asset('slow') for _ in range(3)]
            for ref in slow: probe.command(kind='media',asset=ref)
            wait(lambda:sum(counts.get(ref['id'],0) for ref in slow)==2)
            for ref in slow[:2]: probe.command(kind='media',asset=ref)
            probe.command(kind='send',key='new:peer@example.invalid',recipient='peer@example.invalid',text='Send while images are blocked')
            wait(lambda:len(posts)==1,timeout=2)
            with sqlite3.connect(root/'client/client.db') as db:
                assert db.execute('SELECT count(*) FROM outbox').fetchone()[0]==1
            probe.command(kind='media_context',epoch=EPOCH,chat='two')
            time.sleep(.15); release.set()
            probe.command(kind='media',asset=good)
            probe.until(lambda v:'media' in v,timeout=10)
            current=probe.latest['media']
            assert current['state']=='ready' and current['generation']==2,current
            assert counts.get(slow[2]['id'],0)==0
            # Namespace invalidation prevents cached bytes from crossing epochs.
            probe.command(kind='media_context',epoch=str(uuid.uuid4()),chat='two',online=False)
            assert fetch(good)['state']=='offline'
            probe.command(kind='media_context',epoch=EPOCH,chat='two',online=False)
            assert fetch(good)['state']=='ready'
            # Unsafe cache files are rejected, not followed or decoded.
            cache.unlink(); cache.symlink_to(root/'tls/client-key.pem')
            assert fetch(good)['state']=='offline'
            assert (root/'tls/client-key.pem').exists()
            # A newly retired descriptor must invalidate previously cached bytes,
            # including while offline; it cannot resurrect an old image.
            probe.command(kind='media_context',epoch=EPOCH,chat='two')
            retired=asset(); result=fetch(retired)
            retired_cache=root/'client/media'/result['key']
            assert result['state']=='ready' and retired_cache.exists()
            probe.command(kind='media_context',epoch=EPOCH,chat='two',online=False)
            retired['availability']='retired'
            assert fetch(retired)['state']=='retired'
            assert not retired_cache.exists() and counts[retired['id']]==1
            print('PASS: bounded PNG/JPEG decoding, truncated/corrupt/oversized/MIME/redirect failures, pending/retired/auth states, two media slots, send priority, cancellation, epoch isolation, symlink rejection, and cached retirement')
        finally:
            release.set(); probe.close(); server.close(); log.close()

# Generated 4x3 solid RGB JPEG; contains no account data or image metadata.
JPEG = base64.b64decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAADAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzSiiipPdP/9k=')
if __name__=='__main__': main()
