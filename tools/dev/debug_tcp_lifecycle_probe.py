"""Owned hidden real-Match TCP lifecycle stress and protocol boundary replay."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time

ROOT = Path('G:/AIRTS/AI_RTS')
OUT = ROOT / 'agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/lifecycle'
GODOT = 'G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'

def receive(s):
    def exact(n):
        b = b''
        while len(b) < n:
            part = s.recv(n-len(b))
            if not part:
                raise EOFError('incomplete response')
            b += part
        return b
    n = struct.unpack('<I', exact(4))[0]
    assert n < 16*1048576, n
    return json.loads(exact(n).decode())

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        bridge_port = s.getsockname()[1]
    env = dict(os.environ, AIRTS_INSTANCE_DIR='', AIRTS_INSTANCE_STRICT_DCS='0', GODOT_BRIDGE_PORT=str(bridge_port), GODOT_BRIDGE_TOKEN='tcp-lifecycle-owned')
    cmd = [GODOT, '--headless', '--path', str(ROOT), 'res://tools/dev/debug_tcp_match_fixture.tscn', '--', '--debugport', str(port), '--tcp-out='+str(OUT)]
    result = {'command':cmd, 'started_at':time.time(), 'checks':{}, 'samples':[], 'hash':hashlib.sha256((ROOT/'source/net/DebugControlServer.gd').read_bytes()).hexdigest()}
    log = open(OUT/'match.log', 'wb')
    process = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
    result['pid'] = process.pid
    def connect():
        # Windows may exhaust ephemeral ports under legal close/TIME_WAIT bursts.
        # Retry only connect failures before sending; never replay a submitted command.
        deadline = time.time() + 180
        while True:
            try:
                return socket.create_connection(('127.0.0.1', port), timeout=12)
            except OSError as exc:
                if getattr(exc, 'winerror', None) != 10048 or time.time() >= deadline:
                    raise
                time.sleep(.5)
    def call(body):
        with connect() as s:
            s.sendall((json.dumps(body,ensure_ascii=False)+'\n').encode())
            return receive(s)
    def wait_file(name, timeout=100):
        deadline=time.time()+timeout
        p=OUT/name
        while time.time()<deadline:
            if p.exists() and p.stat().st_mtime>=result['started_at']:
                return json.loads(p.read_text())
            if process.poll() is not None:
                raise RuntimeError('process exited '+str(process.returncode))
            time.sleep(.2)
        raise TimeoutError(name)
    try:
        result['ready']=wait_file('ready-1.json')
        status=call({'op':'status'})
        assert status['match'] and len(status['units'])>0, status
        result['status_before']=status
        result['samples'].append({'phase':'before', **call({'op':'perf'})})
        started=time.time()
        def request(_):
            t=time.perf_counter()
            r=call({'op':'adjutant_fast_state','as_player':status['local_player_name']})
            assert r.get('ok') and r.get('state',{}).get('units'),r
            return (time.perf_counter()-t)*1000
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            latencies=list(pool.map(request,range(10000)))
        result['stress']={'success':len(latencies),'requests':10000,'wall_s':time.time()-started,'latency_ms':latencies}
        for i in range(5):
            time.sleep(1)
            result['samples'].append({'phase':'after-stress','i':i,**call({'op':'perf'})})
        assert result['samples'][-1]['tcp_clients']<=2 and result['samples'][-1]['tcp_buffers']<=2
        with connect() as s:
            for i in range(12):
                payload=(json.dumps({'op':'status','lite':True,'tag':'半包'},ensure_ascii=False)+'\n').encode()
                cut=payload.index('半'.encode())+1
                s.sendall(payload[:cut]);time.sleep(.01);s.sendall(payload[cut:])
                assert receive(s)['match']
            s.sendall(b'{"op":"status","lite":true}\n'*300)
            for i in range(300): assert receive(s)['match']
        result['checks']['persistent_utf8_halfpacket_multiline_300']=True
        with connect() as s:
            s.sendall(b'{"op":"status"')
        assert call({'op':'status','lite':True})['match']
        result['checks']['abrupt_disconnect_reconnect']=True
        with connect() as s:
            s.sendall(b'x'*1048576)
            error=receive(s)
            assert error.get('error')=='request too large',error
            result['checks']['buffer_limit']=error
        with connect() as s:
            s.sendall(b'{"op":"screenshot"}\n'*17)
            error=receive(s)
            assert error.get('retryable') and error.get('error')=='screenshot queue full',error
            result['checks']['shot_limit']=error
        # FIN-safe pending screenshots cannot be polled away before the draw obligation.
        # Headless has an explicit 5s no-rendered-frame deadline; then output/write errors reclaim.
        time.sleep(6)
        perf=call({'op':'perf'})
        assert perf['tcp_pending_shots']==0,perf
        result['checks']['headless_dead_shot_pruned']=perf
        rules=call({'op':'rules'})
        player=status['local_player_name']
        worker=next(u for u in status['units'] if u['mine'] and u['movement'])
        dest=[worker['pos'][0]+14,worker['pos'][2]+8]
        body={'op':'adjutant_intent','intent_id':'tcp-scout-1','command_id':'tcp-move-1','request_id':'tcp-move-1','match_id':rules['match_id'],'player_id':player,'rules_version':rules['rules_version']['content_hash'],'based_on_snapshot':-1,'issued_tick':0,'expires_tick':6000000,'action':'scout','params':{'units':[worker['name']],'dest':dest}}
        receipt=call(body)
        assert receipt.get('accepted'),receipt
        time.sleep(5)
        later=call({'op':'status'})
        moved=next(u for u in later['units'] if u['name']==worker['name'])
        distance=sum((moved['pos'][i]-worker['pos'][i])**2 for i in (0,2))**.5
        assert distance>1,(worker,moved)
        result['checks']['adjutant_move']={'receipt':receipt,'displacement_m':distance,'before':worker,'after':moved}
        (OUT/'select.json').write_text(json.dumps({'unit':worker['name']}))
        time.sleep(.5)
        body['command_id']='tcp-selected-2';body['request_id']='tcp-selected-2';body['intent_id']='tcp-selected-2'
        denied=call(body)
        assert not denied.get('accepted'),denied
        result['checks']['selection_group_takeover_command_level']=denied
        (OUT/'next-round').write_text('next')
        result['ready2']=wait_file('ready-2.json')
        second=call({'op':'status'})
        assert second['match'] and second['match_id']!=status['match_id'],second
        result['checks']['second_match']={'before':status['match_id'],'after':second['match_id'],'units':len(second['units'])}
        (OUT/'quit').write_text('quit')
        result['match_rc']=process.wait(timeout=30)
        assert result['match_rc']==0
        result['passed']=True
    except Exception as exc:
        result['error']=repr(exc)
        result['passed']=False
        raise
    finally:
        if process.poll() is None:
            subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],capture_output=True,creationflags=0x08000000)
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired: process.kill();process.wait()
        result['cleanup_ok']=process.poll() is not None
        result['ended_at']=time.time()
        log.close()
        (OUT/'probe.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps({k:v for k,v in result.items() if k not in ['status_before','samples','stress','checks']},ensure_ascii=False))

if __name__=='__main__': main()
