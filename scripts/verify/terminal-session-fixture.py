#!/usr/bin/env python3
"""Isolated real SSH/SFTP, Herdr and optional tmux lab for simulator UI tests.

start --state /tmp/ui-session.json; run --state ... -- xcodebuild ...; stop --state ...
Fresh keys authenticate only to this loopback sshd. Herdr state/socket and tmux
socket are private. Test shells start in the lab and skip user shell profiles.
The explicit __MOSHPIT_REJECT_DRAFT__ marker is rejected by a Unix-socket proxy;
all other Herdr API requests are forwarded to the real isolated server.
"""
import argparse, base64, getpass, hashlib, json, os
from pathlib import Path
import shlex, signal, socket, subprocess, sys, tempfile, threading, time

SCRIPT = str(Path(__file__).resolve())
HERDR = '/Users/aias/.local/bin/herdr'
TMUX = '/opt/homebrew/bin/tmux'
MOSH = '/opt/homebrew/bin/mosh-server'

def write(path, text, mode=0o600):
    path.write_text(text)
    path.chmod(mode)

def save(path, state):
    tmp = Path(str(path) + '.new')
    write(tmp, json.dumps(state, indent=2) + '\n')
    tmp.replace(path)

def environment(root):
    env = os.environ.copy()
    env.update(XDG_CONFIG_HOME=str(root/'config'), XDG_STATE_HOME=str(root/'state'),
               XDG_CACHE_HOME=str(root/'cache'), HERDR_CONFIG_PATH=str(root/'config/herdr/config.toml'),
               SHELL=str(root/'shell'), PATH=str(root/'bin')+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               TERM='xterm-256color', HISTFILE='/dev/null', BASH_ENV='/dev/null', ENV='/dev/null')
    return env

def cli(root, *args):
    p = subprocess.run([HERDR, '--session', 'ui', *args], cwd=root, env=environment(root),
                       capture_output=True, timeout=12)
    if p.returncode: raise RuntimeError('isolated herdr command failed: '+p.stderr.decode()[:200])
    return json.loads(p.stdout) if p.stdout.strip() else {}

def wrapper(root, args):
    if args == ['status', 'server', '--json']:
        result = cli(root, *args)
        result['socket'] = str(root/'input.sock')
        print(json.dumps(result))
        return
    os.execve(HERDR, [HERDR, '--session', 'ui', *args], environment(root))

def ssh_command(root):
    command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
    os.chdir(root)
    env = environment(root)
    if command == 'fixture-sftp':
        os.execve('/usr/libexec/sftp-server', ['sftp-server', '-d', str(root)], env)
    elif command:
        os.execve('/bin/bash', ['bash', '--noprofile', '--norc', '-c', command], env)
    else:
        os.execve(str(root/'shell'), [str(root/'shell')], env)

def serve(state_path):
    state = json.loads(state_path.read_text())
    root = Path(state['fixture_dir'])
    processes = []
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM): signal.signal(sig, lambda *_: stopped.set())
    log = open(root/'services.log','ab',buffering=0)
    proxy = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        herdr = subprocess.Popen([HERDR,'--session','ui','server'],env=environment(root),cwd=root,
                                 stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        processes.append(herdr)
        for _ in range(80):
            status = cli(root, 'status','server','--json')
            if status.get('running'): break
            if herdr.poll() is not None: raise RuntimeError('isolated Herdr exited')
            time.sleep(.1)
        actual_socket = status['socket']
        assert Path(actual_socket).is_relative_to(root), 'Herdr escaped fixture state'
        cli(root,'workspace','create','--cwd',str(root),'--label','ui-lab','--focus')
        snap = cli(root,'api','snapshot')['result']['snapshot']
        workspace = snap['focused_workspace_id']
        cli(root,'tab','create','--workspace',workspace,'--cwd',str(root),'--label','second','--no-focus')
        proxy.bind(str(root/'input.sock')); proxy.listen(); proxy.settimeout(.25)
        def handle(client):
            with client:
                client.settimeout(12)
                request = client.makefile('rb').readline(1_000_000)
                try:
                    message=json.loads(request)
                    if '__MOSHPIT_REJECT_DRAFT__' in message.get('params',{}).get('text',''):
                        response={'id':message.get('id'),'error':{'code':'test_rejected','message':'explicit fixture rejection'}}
                        client.sendall(json.dumps(response).encode()+b'\n')
                        with open(root/'rejections.log','a') as f: f.write('rejected\n')
                    else:
                        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as remote:
                            remote.settimeout(12);remote.connect(actual_socket);remote.sendall(request)
                            client.sendall(remote.makefile('rb').readline(1_000_000))
                except (OSError, ValueError): pass
        def accept():
            while not stopped.is_set():
                try: c,_=proxy.accept()
                except socket.timeout: continue
                except OSError: break
                threading.Thread(target=handle,args=(c,),daemon=True).start()
        threading.Thread(target=accept,daemon=True).start()
        sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(root/'sshd_config')],
                              stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        processes.append(sshd)
        for _ in range(80):
            if sshd.poll() is not None: raise RuntimeError('isolated sshd exited')
            try:
                with socket.create_connection(('127.0.0.1',state['port']),timeout=.25): break
            except OSError: time.sleep(.1)
        state.update(status='ready',pid=os.getpid(),sshd_pid=sshd.pid,herdr_pid=herdr.pid,herdr_socket=actual_socket)
        save(state_path,state)
        while not stopped.wait(.25):
            if any(p.poll() is not None for p in processes): raise RuntimeError('fixture service exited')
    finally:
        stopped.set();proxy.close()
        try: cli(root,'server','stop')
        except Exception: pass
        if Path(TMUX).exists() and (root/'tmux.sock').exists():
            subprocess.run([TMUX,'-S',str(root/'tmux.sock'),'kill-server'],stdout=log,stderr=log)
        # The mosh bootstrap forks a UDP daemon; only reap this lab's
        # explicitly named shell, never another user's mosh-server.
        listing = subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True)
        for line in listing.stdout.splitlines():
            fields=line.strip().split(None,1)
            if len(fields)==2 and fields[1].startswith(MOSH+' ') and str(root/'shell') in fields[1]:
                try: os.kill(int(fields[0]),signal.SIGTERM)
                except ProcessLookupError: pass
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill();p.wait()
        state['status']='stopped';save(state_path,state);log.close()

def start(state_path, root):
    if state_path.exists() or root.exists(): raise RuntimeError('Use an unused state and lab path; existing data preserved')
    root.mkdir(mode=0o700)
    root=root.resolve()
    (root/'config/herdr').mkdir(parents=True)
    (root/'bin').mkdir();(root/'nested/subfolder').mkdir(parents=True)
    write(root/'marker.txt','Hermit isolated simulator file browser fixture\n')
    write(root/'nested/subfolder/example.txt','Nested file preview fixture\n')
    write(root/'shell', '#!/bin/sh\ncd '+shlex.quote(str(root))+'\nexec /bin/bash --noprofile --norc -i\n',0o700)
    write(root/'config/herdr/config.toml', 'onboarding = false\n[terminal]\ndefault_shell = '+json.dumps(str(root/'shell'))+'\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n')
    write(root/'herdr','#!/bin/sh\nexec '+shlex.quote(sys.executable)+' '+shlex.quote(SCRIPT)+' _herdr --root '+shlex.quote(str(root))+' -- "$@"\n',0o700)
    (root/'bin/herdr').symlink_to(root/'herdr')
    write(root/'tmux','#!/bin/sh\nexec '+TMUX+' -S '+shlex.quote(str(root/'tmux.sock'))+' -f /dev/null "$@"\n',0o700)
    (root/'bin/tmux').symlink_to(root/'tmux')
    write(root/'mosh-server','#!/bin/sh\nexec '+MOSH+' \"$@\" -- '+shlex.quote(str(root/'shell'))+'\n',0o700)
    (root/'bin/mosh-server').symlink_to(root/'mosh-server')
    write(root/'visual-check.py',Path(SCRIPT).with_name('terminal-visual-fixture.py').read_text(),0o700)
    write(root/'received.log','')
    for name in ['host_key','client_key']:
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
    # Herdr sockets need the short /tmp path. OpenSSH StrictModes rejects
    # that shared ancestor, so only the fresh authorized key lives under
    # macOS's private per-user temporary directory.
    auth_root=Path(tempfile.mkdtemp(prefix='moshpit-session-auth-')).resolve()
    auth_root.chmod(0o700)
    write(auth_root/'authorized_keys',(root/'client_key.pub').read_text())
    with socket.socket() as listener: listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
    public=(root/'host_key.pub').read_text().split()
    fp='SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(public[1])).digest()).decode().rstrip('=')
    config=['AddressFamily inet','ListenAddress 127.0.0.1',f'Port {port}',f'HostKey {root}/host_key',f'PidFile {root}/sshd.pid',f'AuthorizedKeysFile {auth_root}/authorized_keys',
            'StrictModes yes',f'AllowUsers {getpass.getuser()}','AuthenticationMethods publickey','PubkeyAuthentication yes','PasswordAuthentication no','KbdInteractiveAuthentication no','UsePAM no','PermitRootLogin no',
            'AllowAgentForwarding no','AllowTcpForwarding no','X11Forwarding no','PermitTunnel no','UseDNS no','PrintMotd no','PrintLastLog no','LogLevel ERROR','Subsystem sftp fixture-sftp',
            f'ForceCommand {sys.executable} {SCRIPT} _ssh --root {root}']
    write(root/'sshd_config','\n'.join(config)+'\n')
    write(root/'known_hosts',f'[127.0.0.1]:{port} {public[0]} {public[1]}\n')
    state=dict(kind='moshpit-session-fixture-v1',status='starting',fixture_dir=str(root),auth_dir=str(auth_root),port=port,username=getpass.getuser(),fingerprint=fp)
    save(state_path,state)
    with open(root/'supervisor.log','ab',buffering=0) as log:
        process=subprocess.Popen([sys.executable,SCRIPT,'_serve','--state',str(state_path)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    for _ in range(200):
        if process.poll() is not None: raise RuntimeError('Fixture exited; inspect '+str(root/'supervisor.log'))
        state=json.loads(state_path.read_text())
        if state['status']=='ready': print(json.dumps(state));return
        time.sleep(.1)
    os.killpg(process.pid,signal.SIGTERM);raise RuntimeError('Fixture startup timeout')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['start','stop','run','_serve','_ssh','_herdr','tmux-start'])
    parser.add_argument('--state',type=Path)
    parser.add_argument('--root',type=Path,default=Path('/tmp/moshpit-ui-lab'))
    args,command=parser.parse_known_args()
    if command and command[0]=='--':command.pop(0)
    if args.command=='_herdr':return wrapper(args.root,command)
    if args.command=='_ssh':return ssh_command(args.root)
    if not args.state:parser.error('--state required')
    state_path=args.state.resolve()
    if args.command=='start':return start(state_path,args.root)
    if args.command=='_serve':return serve(state_path)
    state=json.loads(state_path.read_text());root=Path(state['fixture_dir'])
    if state.get('kind')!='moshpit-session-fixture-v1':raise RuntimeError('Not this fixture')
    if args.command=='stop':
        listing=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True)
        for line in listing.stdout.splitlines():
            fields=line.strip().split(None,1)
            if len(fields)==2 and fields[1].startswith(MOSH+' ') and str(root/'shell') in fields[1]:
                try: os.kill(int(fields[0]),signal.SIGTERM)
                except ProcessLookupError: pass
        p=subprocess.run(['ps','-p',str(state.get('pid',0)),'-o','command='],capture_output=True,text=True)
        if SCRIPT in p.stdout and '_serve' in p.stdout:os.kill(state['pid'],signal.SIGTERM)
        print('Fixture shutdown requested');return
    if args.command=='tmux-start':
        if (root/'tmux.sock').exists():raise RuntimeError('tmux fixture already exists')
        prefix=[TMUX,'-S',str(root/'tmux.sock'),'-f','/dev/null']
        subprocess.run(prefix+['new-session','-d','-s','ui','-n','shell','-c',str(root),str(root/'shell')],check=True,env=environment(root))
        subprocess.run(prefix+['set-option','-g','base-index','1'],check=True)
        subprocess.run(prefix+['move-window','-s','ui:0','-t','ui:1'],check=True)
        subprocess.run(prefix+['new-window','-t','ui:2','-n','logs','-c',str(root),str(root/'shell')],check=True)
        subprocess.run(prefix+['select-window','-t','ui:1'],check=True)
        print('Isolated tmux ui:1=shell, ui:2=logs ready');return
    if not command:parser.error('run requires command after --')
    if state['status']!='ready':raise RuntimeError('Fixture not ready')
    env=os.environ.copy()
    values={'MOSHPIT_SEED_USER':state['username'],'MOSHPIT_SEED_HOST':'127.0.0.1','MOSHPIT_SEED_PORT':str(state['port']),'MOSHPIT_SEED_TRUST_FP':state['fingerprint'],
            'MOSHPIT_SEED_KEY_B64':base64.b64encode((root/'client_key').read_bytes()).decode(),'MOSHPIT_SEED_HERDR_BIN':str(root/'herdr'),'MOSHPIT_SEED_TMUX_BIN':str(root/'tmux'),'MOSHPIT_SEED_MOSH_BIN':str(root/'mosh-server'),'MOSHPIT_SWITCH_FIXTURE_DIR':str(root)}
    env.pop('TEST_RUNNER_MOSHPIT_SEED_PASSWORD',None)
    env.update({'TEST_RUNNER_'+k:v for k,v in values.items()})
    os.execvpe(command[0],command,env)

if __name__=='__main__': main()
