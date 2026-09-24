#!/usr/bin/env python3
"""Explicit real-account acceptance checks. Sends only with --confirm-send."""
import argparse
import http.client
import json
import os
from collections import Counter
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid
from urllib.parse import urlencode
from tls_support import Credentials


def screen_locked():
    registry=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-n','Root','-d1','-a']))
    roots=[registry] if isinstance(registry,dict) else registry
    for root in roots:
        for session in root.get('IOConsoleUsers',[]):
            if session.get('kCGSSessionUserIDKey')==os.getuid() and session.get('kCGSSessionOnConsoleKey'):
                return session.get('CGSSessionScreenIsLocked') is True
    raise RuntimeError('Cannot verify the logged-in console session')


def save_evidence(path, value):
    """Keep request IDs recoverable even when a check fails after dispatch."""
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd, temporary=tempfile.mkstemp(prefix=path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as output:
            json.dump(value,output,indent=2);output.write('\n')
            output.flush();os.fsync(output.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


class Client:
    def __init__(self,data_dir,tls_config=None):
        self.credentials=Credentials(tls_config or data_dir/'admin.json')

    def connect(self,path,body=None):
        connection=self.credentials.connection(timeout=20)
        headers={}
        if body is not None:headers['Content-Type']='application/json'
        try:
            connection.request('POST' if body is not None else 'GET',path,json.dumps(body).encode() if body is not None else None,headers)
            response=connection.getresponse()
            if response.status>=300:
                value=json.loads(response.read())
                raise RuntimeError(value.get('error_info',{}).get('code','http_error'))
            return connection,response
        except BaseException:
            connection.close();raise

    def request(self,path,body=None):
        connection,response=self.connect(path,body)
        try:return json.loads(response.read())
        finally:response.close();connection.close()

    def events(self,after,through,identities=False):
        """Read a finite, durable SSE interval without printing private history."""
        if after==through:return []
        if after.split(':')[0]!=through.split(':')[0]:raise RuntimeError('resync_required')
        end=int(through.split(':')[1]);events=[]
        params={'after':after}
        if identities:params['extensions']='identity-v1'
        connection,response=self.connect('/v1/events?'+urlencode(params))
        if identities and response.getheader('zimbr-event-extensions')!='identity-v1':
            response.close();connection.close()
            raise RuntimeError('identity_extension_not_accepted')
        deadline=time.monotonic()+30
        try:
            while time.monotonic()<deadline:
                line=response.readline(2*1024*1024)
                if not line:raise RuntimeError('event_stream_closed')
                if line.startswith(b'data: '):
                    # Large historical imports may make a finite replay take
                    # longer than 30 seconds; bound idle time, not active progress.
                    deadline=time.monotonic()+30
                    event=json.loads(line[6:]);sequence=int(event['sequence'])
                    if sequence<=end:events.append(event)
                    if sequence>=end:return events
            raise RuntimeError('event_replay_timeout')
        finally:response.close();connection.close()


def enrichment_evidence(client,conversation=None):
    """Aggregate-only read probe; never save names, handles, IDs, paths, or URLs."""
    status=client.request('/v1/status')
    capabilities=status.get('capabilities',{})
    feature_keys=('identity_directory_v1','image_assets_v1','image_attachments_v1',
                  'stored_link_previews_v1','reactions_v1','contact_avatars_v1')
    evidence={'capabilities':{key:capabilities.get(key,False) for key in feature_keys},
              'readiness':status.get('enrichment_readiness',{}),
              'identities':{},'messages':{},'identity_extension_accepted':False,
              'installed_contacts_attribution_verified':False,
              'complete':False}
    if capabilities.get('identity_directory_v1') or 'identity-v1' in status.get('event_extensions',[]):
        counts=Counter();before=None
        while True:
            path='/v1/identities?limit=200'
            if before:path+='&'+urlencode({'before':before})
            page=client.request(path)
            for record in page['identities']:
                counts['total']+=1
                counts['state_'+record['match_state']]+=1
                counts['has_name']+=record.get('display_name') is not None
                counts['has_avatar']+=record.get('avatar') is not None
            before=page.get('next')
            if not before:break
        evidence['identities']=dict(counts)
        cursor=client.request('/v1/sync')['cursor']
        connection,response=client.connect('/v1/events?'+urlencode({'after':cursor,'extensions':'identity-v1'}))
        try:evidence['identity_extension_accepted']=response.getheader('zimbr-event-extensions')=='identity-v1'
        finally:response.close();connection.close()
    if conversation:
        counts=Counter();before=None
        while True:
            path='/v1/conversations/'+conversation+'/messages?limit=200'
            if before:path+='&'+urlencode({'before':before})
            page=client.request(path)
            for record in page['messages']:
                counts['total']+=1
                counts['kind_'+record['kind']]+=1
                enrichment=record.get('enrichment') or {}
                counts['attachments']+=(enrichment.get('attachments') or {}).get('total',len(record.get('attachments') or []))
                counts['previews']+=(enrichment.get('previews') or {}).get('total',len(record.get('link_previews') or []))
                counts['active_reactions']+=(enrichment.get('reactions') or {}).get('total',len(record.get('reactions') or []))
                counts['parts_resolved']+=enrichment.get('part_mapping')=='resolved'
                counts['metadata_overflow']+=any(not (enrichment.get(section) or {}).get('complete',True) for section in ('attachments','previews','reactions','parts'))
                if record.get('reaction_event'):
                    counts['reaction_'+record['reaction_event']['resolution']]+=1
            before=page.get('next')
            if not before:break
        evidence['messages']=dict(counts)
    return evidence


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recipient',help='Deliberately selected iMessage email or international phone number')
    parser.add_argument('--confirm-send',action='store_true',help='Authorize two labeled test messages: direct and existing-chat reply')
    parser.add_argument('--enrichment',action='store_true',help='Read aggregate enrichment readiness and counts without sending; optionally inspect --conversation')
    parser.add_argument('--conversation',help='Instead test one explicitly selected existing conversation, including a group')
    parser.add_argument('--restart',action='store_true',help='Restart only com.hsp.zimbr.relay after the send checks')
    parser.add_argument('--wait-for-lock',type=int,metavar='SECONDS',help='Wait for the user to lock the screen, then verify one existing-chat send while locked')
    parser.add_argument('--data-dir',type=Path,default=Path.home()/'Library/Application Support/Zimbr')
    parser.add_argument('--tls-config',type=Path,help='Administrative HTTPS credential config (default: DATA/admin.json)')
    parser.add_argument('--output',type=Path,default=Path('.local/mac-acceptance.json'))
    args=parser.parse_args()
    if args.enrichment:
        if args.confirm_send or args.recipient or args.restart or args.wait_for_lock:
            parser.error('--enrichment is a read-only check; send/restart options cannot be combined')
        if args.output.exists():parser.error('Evidence already exists; choose a new --output')
        os.umask(0o077)
        evidence=enrichment_evidence(Client(args.data_dir,args.tls_config),args.conversation)
        evidence['os_build']=subprocess.check_output(['sw_vers','-buildVersion'],text=True).strip()
        evidence['timestamp_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        save_evidence(args.output,evidence)
        print('Saved aggregate enrichment evidence; installed permission attribution and platform fixtures require separate verification.')
        return
    if not args.confirm_send:parser.error('--confirm-send is required for a real-account test')
    if bool(args.recipient)==bool(args.conversation):parser.error('Select exactly one of --recipient or --conversation')
    if args.wait_for_lock is not None and (args.wait_for_lock<=0 or not args.conversation):parser.error('--wait-for-lock requires a positive timeout and --conversation')
    if args.output.exists():parser.error('Evidence already exists; inspect saved request IDs or choose a new --output instead of blindly repeating sends')
    os.umask(0o077)
    client=Client(args.data_dir,args.tls_config);request=client.request
    status=request('/v1/status')
    identity_events='identity-v1' in status.get('event_extensions',[]) or status.get('capabilities',{}).get('identity_directory_v1',False)
    if not status['capabilities']['send_direct']:raise RuntimeError('Integration not ready: '+','.join(status['degraded_reasons']))
    if args.wait_for_lock:
        print('Waiting for screen lock; one authorized test message will be sent after lock is observed.',flush=True)
        deadline=time.monotonic()+args.wait_for_lock
        while not screen_locked():
            if time.monotonic()>deadline:raise RuntimeError('Screen was not locked; nothing sent')
            time.sleep(1)
    baseline=request('/v1/sync');results=[];payloads=[]
    evidence={'os_build':subprocess.check_output(['sw_vers','-buildVersion'],text=True).strip(),'timestamp_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'baseline':baseline,'sends':results,'restart_verified':False,'locked_screen_verified':False,'recipient_confirmation_required':True,'complete':False}
    save_evidence(args.output,evidence)
    target={'conversation_id':args.conversation} if args.conversation else {'recipient':{'address':args.recipient,'service':'imessage'}}
    stayed_locked=bool(args.wait_for_lock)
    for index in range(1 if args.conversation else 2):
        identity=str(uuid.uuid4())
        text='Zimbr relay acceptance '+str(index+1)+' '+identity+'\nMultiline and emoji: 👩‍💻 e\u0301'
        payload={'request_id':identity,'server_epoch':baseline['server_epoch'],'target':target,'text':text}
        item={'request_id':identity,'state':'submission_unresolved','unicode_preserved':False}
        results.append(item);save_evidence(args.output,evidence)
        payloads.append(payload)
        if args.wait_for_lock and not screen_locked():raise RuntimeError('Screen unlocked before dispatch; nothing sent')
        if args.wait_for_lock:
            evidence['screen_locked_before_submission']=True
            save_evidence(args.output,evidence)
        accepted=request('/v1/messages',payload)
        assert accepted['request_id']==identity
        item['state']=accepted['state'];save_evidence(args.output,evidence)
        # Repeating the exact request must not dispatch again.
        assert request('/v1/messages',payload)['request_id']==identity
        deadline=time.monotonic()+65;result=accepted
        while time.monotonic()<deadline:
            if args.wait_for_lock:
                locked=screen_locked()
                if not locked and 'first_unlock_observed_utc' not in evidence:
                    evidence['first_unlock_observed_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
                stayed_locked=stayed_locked and locked
            result=request('/v1/send-requests/'+identity)
            item.update(state=result['state'],message_id=result['message_id'],error_code=(result.get('error_info') or {}).get('code'))
            save_evidence(args.output,evidence)
            if result['state'] in ('submitted','delivered','failed'):break
            time.sleep(1)
        if result['state'] not in ('submitted','delivered'):raise RuntimeError('Send outcome: '+result['state']+'; do not blindly retry')
        # Match only this known synthetic marker; do not print real history.
        events=client.events(baseline['cursor'],request('/v1/sync')['cursor'],identities=identity_events)
        found=next((e['record'] for e in events if e['type']=='message.upsert' and e['record']['id']==result['message_id'] and e['record']['text']==text),None)
        if not found:raise RuntimeError('Outgoing observation absent from history API')
        if target.get('conversation_id'):assert found['conversation_id']==target['conversation_id']
        assert found['direction']=='outgoing' and found['service']=='imessage'
        target={'conversation_id':found['conversation_id']}
        history=request('/v1/conversations/'+found['conversation_id']+'/messages?limit=200')['messages']
        assert any(m['id']==found['id'] and m['text']==text for m in history)
        item.update(conversation_id=found['conversation_id'],unicode_preserved=True,sse_observed=True,decoding=found['decoding'])
        # Self messages may produce an incoming echo. Record actual source
        # evidence separately from recipient-side or another-device confirmation.
        item['incoming_self_echo_observed']=any(e['type']=='message.upsert' and e['origin']=='live' and e['record']['direction']=='incoming' and e['record']['text']==text for e in events)
        save_evidence(args.output,evidence)
    if args.wait_for_lock:
        evidence['locked_screen_verified']=stayed_locked and screen_locked()
        evidence['send_checks_complete']=True
        save_evidence(args.output,evidence)
        if not evidence['locked_screen_verified']:raise RuntimeError('Send observed, but screen did not stay locked throughout the check')
    before_restart=request('/v1/sync')
    replay=client.events(baseline['cursor'],before_restart['cursor'],identities=identity_events)
    if args.restart:
        subprocess.run(['launchctl','kickstart','-k','gui/'+str(os.getuid())+'/com.hsp.zimbr.relay'],check=True)
        deadline=time.monotonic()+45
        while True:
            try:
                after=request('/v1/sync')
                if request('/v1/status')['capabilities']['send_direct']:break
            except (OSError,http.client.HTTPException):
                pass
            if time.monotonic()>deadline:raise RuntimeError('Relay did not recover after restart')
            time.sleep(1)
        assert after['server_epoch']==baseline['server_epoch']
        for item,payload in zip(results,payloads):
            assert request('/v1/send-requests/'+item['request_id'])['message_id']==item['message_id']
            assert request('/v1/messages',payload)['message_id']==item['message_id']
            history=request('/v1/conversations/'+item['conversation_id']+'/messages?limit=200')['messages']
            assert sum(m['text']==payload['text'] and m['direction']=='outgoing' for m in history)==1
            assert any(m['id']==item['message_id'] for m in history)
        assert client.events(baseline['cursor'],before_restart['cursor'],identities=identity_events)==replay
        evidence['restart_verified']=True
        evidence['event_replay_survived_restart']=True
    evidence['complete']=True;save_evidence(args.output,evidence)
    print('Observed test sends through API; recipient-side confirmation still required. Evidence:',args.output)

if __name__=='__main__':main()
