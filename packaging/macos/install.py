#!/usr/bin/env python3
"""Package or install the relay with a stable per-user application identity."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
LABEL='com.hsp.zimbr.relay'

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--install',action='store_true',help='Install under ~/Applications and ~/Library/LaunchAgents')
    p.add_argument('--start',action='store_true',help='Bootstrap the installed user LaunchAgent')
    p.add_argument('--identity',default='-',help='codesign identity; default is ad-hoc signing')
    p.add_argument('--binary',type=Path,default=ROOT/'zig-out/bin/relay')
    args=p.parse_args()
    if args.start and not args.install:p.error('--start requires --install')
    os.umask(0o077)
    home=Path.home();data=home/'Library/Application Support/Zimbr'
    destination=home/'Applications/Zimbr Relay.app'
    staging=ROOT/'zig-out/macos';staging.mkdir(parents=True,exist_ok=True)
    bundle=staging/'Zimbr Relay.app'
    contents=bundle/'Contents';macos=contents/'MacOS';macos.mkdir(parents=True,exist_ok=True)
    shutil.copy2(args.binary,macos/'relay');(macos/'relay').chmod(0o755)
    info={'CFBundleIdentifier':LABEL,'CFBundleName':'Zimbr Relay','CFBundleDisplayName':'Zimbr Relay','CFBundleExecutable':'relay','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0','LSUIElement':True,'LSMinimumSystemVersion':'27.0','NSAppleEventsUsageDescription':'Zimbr sends text through your Messages account when you submit a message to your local relay.'}
    with (contents/'Info.plist').open('wb') as f:plistlib.dump(info,f)
    entitlements=staging/'entitlements.plist'
    with entitlements.open('wb') as f:plistlib.dump({'com.apple.security.automation.apple-events':True},f)
    subprocess.run(['codesign','--force','--sign',args.identity,'--identifier',LABEL,'--entitlements',str(entitlements),str(bundle)],check=True)
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    config={'Label':LABEL,'ProgramArguments':[str(destination/'Contents/MacOS/relay'),'serve'],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':30,'ProcessType':'Background','LimitLoadToSessionType':'Aqua','WorkingDirectory':str(data),'StandardOutPath':str(data/'relay.log'),'StandardErrorPath':str(data/'relay.log'),'Umask':0o077,'EnvironmentVariables':{'HOME':str(home)}}
    plist=staging/(LABEL+'.plist')
    with plist.open('wb') as f:plistlib.dump(config,f)
    subprocess.run(['plutil','-lint',str(plist)],check=True)
    if not args.install:
        print('Staged signed app and LaunchAgent at',staging);return
    service='gui/'+str(os.getuid())+'/'+LABEL
    subprocess.run(['launchctl','bootout',service],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    destination.parent.mkdir(parents=True,exist_ok=True)
    # Replace only this project's bundle; retain state, token, and journal.
    if destination.exists():
        with (destination/'Contents/Info.plist').open('rb') as f:old=plistlib.load(f)
        if old.get('CFBundleIdentifier')!=LABEL:raise RuntimeError('Refusing to replace an unrelated app')
        shutil.rmtree(destination)
    shutil.copytree(bundle,destination)
    subprocess.run([str(destination/'Contents/MacOS/relay'),'setup'],check=True)
    agents=home/'Library/LaunchAgents';agents.mkdir(parents=True,exist_ok=True)
    installed_plist=agents/plist.name;shutil.copy2(plist,installed_plist);installed_plist.chmod(0o600)
    if args.start:
        # launchctl's disabled override persists across boots and takes
        # precedence over RunAtLoad. Explicit startup must clear that override.
        subprocess.run(['launchctl','enable',service],check=True)
        subprocess.run(['launchctl','bootstrap','gui/'+str(os.getuid()),str(installed_plist)],check=True)
    print('Installed',destination)
    print('Grant Full Disk Access to this app and allow its Messages Automation prompt.')
    print('Doctor:',str(destination/'Contents/MacOS/relay'),'doctor --check-automation')

if __name__=='__main__':main()
