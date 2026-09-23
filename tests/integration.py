#!/usr/bin/env python3
"""Exercise the production HTTP/journal/send paths with synthetic source data."""
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid
from fixture import create, add_message

ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'zig-out/bin/fake-relay'

def wait_for(fn, timeout=20):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            value=fn()
            if value:return value
        except (OSError, http.client.HTTPException):pass
        time.sleep(.15)
    raise AssertionError('Timed out waiting for expected behavior')

def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-test-') as folder:
        root=Path(folder);source=root/'source.db';data=root/'data';create(source)
        s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close()
        common=['--data-dir',str(data),'--messages-db',str(source),'--port',str(port)]
        subprocess.run([str(BIN),'setup',*common],check=True,stdout=subprocess.DEVNULL)
        token=(data/'token').read_text();assert (data/'token').stat().st_mode & 0o777==0o600
        log=open(root/'relay.log','w+')
        proc=None
        def start():return subprocess.Popen([str(BIN),'serve',*common],stdout=log,stderr=log)
        def request(path, body=None, auth=True, method=None, headers=None):
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=4)
            h={'Authorization':'Bearer '+token} if auth else {}
            if body is not None:h['Content-Type']='application/json'
            h.update(headers or {})
            c.request(method or ('POST' if body is not None else 'GET'),path,json.dumps(body).encode() if body is not None else None,h)
            r=c.getresponse();raw=r.read();status=r.status;c.close()
            return status,json.loads(raw)
        def snapshot():return request('/v1/sync')[1]
        def ready():return request('/v1/status')[1].get('capabilities',{}).get('send_direct')
        def send(text, target=None):
            return {'request_id':str(uuid.uuid4()),'server_epoch':snapshot()['server_epoch'],'target':target or {'recipient':{'address':'alice@example.invalid','service':'imessage'}},'text':text}
        def sql(statement,args=()):
            with sqlite3.connect(data/'relay.db') as db:return db.execute(statement,args).fetchall()
        try:
            proc=start();wait_for(ready)
            # A reused socket must still authenticate each request independently.
            persistent=http.client.HTTPConnection('127.0.0.1',port,timeout=4)
            persistent.request('GET','/v1/status',headers={'Authorization':'Bearer '+token})
            response=persistent.getresponse();assert response.status==200;response.read()
            original_socket=persistent.sock
            persistent.request('GET','/v1/sync',headers={'Authorization':'Bearer '+token})
            response=persistent.getresponse();assert response.status==200;response.read()
            assert persistent.sock is original_socket and original_socket is not None
            persistent.request('GET','/v1/status',headers={'Authorization':'Bearer '+'0'*64})
            response=persistent.getresponse();assert response.status==401;response.read();persistent.close()
            duplicate=subprocess.run([str(BIN),'serve',*common],capture_output=True,timeout=5)
            assert duplicate.returncode!=0 and b'AlreadyRunning' in duplicate.stderr
            assert request('/v1/status',auth=False)[0]==401
            assert request('/v1/events?after=bad',auth=False)[0]==401
            wait_for(lambda:sql('SELECT count(*) FROM messages')[0][0]==244)
            conversations=request('/v1/conversations?limit=2')[1]
            assert len(conversations['conversations'])==2 and conversations['next']
            projected=request('/v1/conversations?limit=2&previews=1')[1]
            assert projected['conversations']==conversations['conversations']
            assert projected['previews'] is not None
            assert all(p['conversation_id'] in {c['id'] for c in projected['conversations']} and len(p['text'])<=256 for p in projected['previews'])
            ids=[];page=conversations
            while True:
                ids.extend(c['id'] for c in page['conversations'])
                if not page['next']:break
                page=request('/v1/conversations?limit=2&before='+page['next'])[1]
            assert len(ids)==len(set(ids))==4
            cid=sql("SELECT id FROM conversations WHERE route='iMessage;-;alice@example.invalid'")[0][0]
            page=request('/v1/conversations/'+cid+'/messages?limit=10')[1]
            assert len(page['messages'])==10 and page['next']
            kinds={json.loads(r[0])['kind'] for r in sql('SELECT record FROM messages')}
            assert {'text','unsupported','attachment','reaction','system'}<=kinds
            assert all('source' not in m and 'date_ns' not in m for m in page['messages'])
            before=snapshot();old_count=sql('SELECT count(*) FROM messages')[0][0]
            with sqlite3.connect(source) as db:
                delayed=add_message(db,'Delayed join',chat=None)
                add_message(db,'Arrived between snapshot and stream',date=1)
            wait_for(lambda:sql('SELECT count(*) FROM messages')[0][0]==old_count+1)
            with sqlite3.connect(source) as db:db.execute('INSERT INTO chat_message_join VALUES(1,?)',(delayed,))
            wait_for(lambda:sql('SELECT count(*) FROM messages')[0][0]==old_count+2)
            # Replay a cursor captured before the insertion, using actual SSE framing.
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
            c.request('GET','/v1/events?after='+before['cursor'],headers={'Authorization':'Bearer '+token})
            r=c.getresponse();assert r.status==200
            observed=[]
            while len(observed)<2:
                line=r.readline().decode()
                if line.startswith('data: '):
                    event=json.loads(line[6:])
                    if event['type']=='message.upsert':observed.append(event)
            r.close();c.close();time.sleep(.3);assert len({e['record']['id'] for e in observed})==2
            # Recent reconciliation can discover rows ahead of the 100-row
            # live scan. Their first events must still allow live notifications.
            with sqlite3.connect(source) as db:
                for index in range(220):add_message(db,'Live burst '+str(index))
            wait_for(lambda:sql("SELECT count(*) FROM messages WHERE text LIKE 'Live burst %'")[0][0]==220)
            first_events=sql("SELECT origin,min(sequence) FROM events WHERE type='message.upsert' AND json_extract(record,'$.text') LIKE 'Live burst %' GROUP BY json_extract(record,'$.id')")
            assert len(first_events)==220 and all(origin=='live' for origin,_ in first_events)
            assert request('/v1/events?after='+before['cursor'],headers={'Last-Event-ID':snapshot()['cursor']})[0]==400
            assert request('/v1/conversations?limit=201')[0]==400
            oversized=http.client.HTTPConnection('127.0.0.1',port,timeout=4)
            oversized.request('POST','/v1/messages',b'x'*65537,{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
            assert oversized.getresponse().status==413;oversized.close()
            assert request('/v1/conversations?limit=2&limit=3')[0]==400
            # Streams are capped independently of normal request connections.
            streams=[]
            for _ in range(8):
                connection=http.client.HTTPConnection('127.0.0.1',port,timeout=4)
                connection.request('GET','/v1/events?after='+snapshot()['cursor'],headers={'Authorization':'Bearer '+token})
                response=connection.getresponse();assert response.status==200
                streams.append((connection,response))
            assert request('/v1/events?after='+snapshot()['cursor'])[0]==503
            assert request('/v1/status')[0]==200
            for connection,response in streams:response.close();connection.close()
            assert request('/v1/messages',send('x'*16385))[0]==413
            # Inject a journal failure only after dispatching has been persisted.
            # The running worker must recover its unresolved result without a
            # process restart and must never execute the same request again.
            lost_result=send('[fake:stall]');assert request('/v1/messages',lost_result)[0]==202
            wait_for(lambda:request('/v1/send-requests/'+lost_result['request_id'])[1]['state']=='dispatching')
            with sqlite3.connect(data/'relay.db') as db:
                db.execute("CREATE TRIGGER lose_dispatch_result BEFORE UPDATE ON send_requests WHEN OLD.id='"+lost_result['request_id']+"' AND NEW.state!='dispatching' BEGIN SELECT RAISE(ABORT,'injected_after_dispatch'); END")
            def source_count(text):
                with sqlite3.connect(source) as db:return db.execute('SELECT count(*) FROM message WHERE text=?',(text,)).fetchone()[0]
            wait_for(lambda:source_count(lost_result['text'])==1)
            time.sleep(.4)
            assert request('/v1/send-requests/'+lost_result['request_id'])[1]['state']=='dispatching'
            with sqlite3.connect(data/'relay.db') as db:db.execute('DROP TRIGGER lose_dispatch_result')
            wait_for(lambda:request('/v1/send-requests/'+lost_result['request_id'])[1]['state']=='unknown',timeout=4)
            assert request('/v1/messages',lost_result)[0]==200
            assert source_count(lost_result['text'])==1
            v=send('Queued Unicode\n👩‍💻 e\u0301')
            assert request('/v1/messages',v)[0]==202
            assert request('/v1/messages',v)[0]==200
            assert request('/v1/messages',{**v,'request_id':v['request_id'].upper(),'server_epoch':v['server_epoch'].upper()})[0]==200
            assert request('/v1/messages',{**v,'text':'different'})[0]==409
            assert request('/v1/send-requests/'+v['request_id'])[0]==200
            wait_for(lambda:sql("SELECT count(*) FROM messages WHERE text=?",(v['text'],))[0][0]==1)
            bad=send('no SMS',{'recipient':{'address':'+14155550123','service':'sms'}})
            assert request('/v1/messages',bad)[0]==400
            mismatch={**send('wrong epoch'),'server_epoch':str(uuid.uuid4())}
            assert request('/v1/messages',mismatch)[0]==409
            new_direct=send('A previously unseen recipient',{'recipient':{'address':'new@example.invalid','service':'imessage'}})
            assert request('/v1/messages',new_direct)[0]==202
            group_id=sql("SELECT id FROM conversations WHERE route='iMessage;+;group-fixture'")[0][0]
            group=send('Existing group reply',{'conversation_id':group_id})
            assert request('/v1/messages',group)[0]==202
            ambiguous=send('[fake:unknown]');assert request('/v1/messages',ambiguous)[0]==202
            wait_for(lambda:request('/v1/send-requests/'+ambiguous['request_id'])[1]['state']=='unknown')
            with sqlite3.connect(source) as db:
                add_message(db,ambiguous['text'],is_from_me=1,is_sent=1,is_delivered=1)
                add_message(db,ambiguous['text'],is_from_me=1,is_sent=1,is_delivered=1)
            rejected=send('[fake:reject]');assert request('/v1/messages',rejected)[0]==202
            wait_for(lambda:request('/v1/send-requests/'+rejected['request_id'])[1]['state']=='failed')
            # Correlation must observe the outgoing record; osascript/fake return is insufficient.
            wait_for(lambda:request('/v1/send-requests/'+v['request_id'])[1]['state']=='delivered',timeout=40)
            observed_request=request('/v1/send-requests/'+v['request_id'])[1]
            assert observed_request['message_id'] and observed_request['error_info'] is None
            for checked in (new_direct,group):
                wait_for(lambda:request('/v1/send-requests/'+checked['request_id'])[1]['state']=='delivered',timeout=10)
            group_message=request('/v1/send-requests/'+group['request_id'])[1]['message_id']
            assert sql('SELECT conversation_id FROM messages WHERE id=?',(group_message,))[0][0]==group_id
            assert request('/v1/send-requests/'+ambiguous['request_id'])[1]['state']=='unknown'
            assert request('/v1/send-requests/'+ambiguous['request_id'])[1]['message_id'] is None
            # Temporary source locks degrade readiness without losing the journal.
            blocker=sqlite3.connect(source);blocker.execute('BEGIN EXCLUSIVE')
            try:wait_for(lambda:not request('/v1/status')[1]['adapter_ready'],timeout=8)
            finally:blocker.rollback();blocker.close()
            wait_for(ready)
            assert snapshot()['server_epoch']==v['server_epoch']
            # Restart preserves epoch, IDs, journal, and idempotency identity.
            old=snapshot();known=sql('SELECT id FROM messages ORDER BY id')
            proc.terminate();proc.wait(timeout=5);proc=start();wait_for(ready)
            assert snapshot()['server_epoch']==old['server_epoch']
            assert sql('SELECT id FROM messages ORDER BY id')==known
            assert request('/v1/messages',v)[0]==200
            # Expiry is explicit over HTTP and never removes the idempotency record.
            proc.terminate();proc.wait(timeout=5)
            with sqlite3.connect(data/'relay.db') as db:db.execute('UPDATE events SET created_ms=0')
            proc=start();wait_for(ready)
            assert request('/v1/events?after='+old['server_epoch']+':0')[0]==410
            assert request('/v1/messages',v)[0]==200
            # A stalled send cannot hold the journal or stop ingestion. Kill the
            # process mid-dispatch and verify its durable request is not resent.
            stall_count=source_count('[fake:stall]')
            interrupted=send('[fake:stall]');assert request('/v1/messages',interrupted)[0]==202
            wait_for(lambda:request('/v1/send-requests/'+interrupted['request_id'])[1]['state']=='dispatching')
            queued=send('Resume this queued request after restart')
            assert request('/v1/messages',queued)[0]==202
            assert request('/v1/send-requests/'+queued['request_id'])[1]['state']=='queued'
            begun=time.monotonic();assert request('/v1/status')[0]==200
            assert time.monotonic()-begun<1
            with sqlite3.connect(source) as db:add_message(db,'ingested during stalled send')
            wait_for(lambda:sql("SELECT count(*) FROM messages WHERE text='ingested during stalled send'")[0][0]==1,timeout=2.5)
            proc.kill();proc.wait(timeout=5);proc=start();wait_for(ready)
            assert request('/v1/send-requests/'+interrupted['request_id'])[1]['state']=='unknown'
            assert request('/v1/messages',interrupted)[0]==200
            assert source_count(interrupted['text'])==stall_count
            wait_for(lambda:source_count(queued['text'])==1)
            assert request('/v1/messages',queued)[0]==200
            assert source_count(queued['text'])==1
            # Source replacement causes a fresh epoch and invalidates old cursors.
            replacement=root/'replacement.db';create(replacement,4);os.replace(replacement,source)
            wait_for(lambda:snapshot()['server_epoch']!=old['server_epoch'])
            assert request('/v1/events?after='+old['cursor'])[0]==409
            assert request('/v1/messages',v)[0]==409
            assert sql('SELECT count(*) FROM send_requests')[0][0]>=4
            # Token rotation invalidates credentials; unauthorized requests expose no content.
            subprocess.run([str(BIN),'rotate-token',*common],check=True,stdout=subprocess.DEVNULL)
            assert request('/v1/status')[0]==401
            token=(data/'token').read_text();assert request('/v1/status')[0]==200
            print('PASS: HTTP auth, pagination, import, delayed joins, SSE overlap, Unicode, send idempotency, result persistence failure, queued recovery, restart, interrupted dispatch, source reset, token rotation')
        except Exception:
            log.flush();log.seek(0);print(log.read());raise
        finally:
            if proc and proc.poll() is None:proc.terminate();proc.wait(timeout=5)
            log.close()

if __name__=='__main__':main()
