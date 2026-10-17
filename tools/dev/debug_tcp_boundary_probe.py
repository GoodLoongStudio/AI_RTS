"""Owned headless real Match: idle saturation, FIN, nonreading-client watchdog."""
import json,os,socket,subprocess,time
from pathlib import Path
from debug_tcp_lifecycle_probe import receive,GODOT,ROOT
OUT=ROOT/'agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/boundary-02'
def main():
 OUT.mkdir(exist_ok=False)
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 with socket.socket() as s:s.bind(('127.0.0.1',0));bridge=s.getsockname()[1]
 env=dict(os.environ,AIRTS_INSTANCE_DIR='',AIRTS_INSTANCE_STRICT_DCS='0',GODOT_BRIDGE_PORT=str(bridge))
 cmd=[GODOT,'--headless','--path',str(ROOT),'res://tools/dev/debug_tcp_match_fixture.tscn','--','--debugport',str(port),'--tcp-out='+str(OUT)]
 r={'started':time.time(),'command':cmd,'checks':{}}; log=(OUT/'match.log').open('xb');p=subprocess.Popen(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000);r['launcher_pid']=p.pid
 def connect(timeout=5):return socket.create_connection(('127.0.0.1',port),timeout=timeout)
 def call(body,timeout=5):
  with connect(timeout) as s:s.sendall((json.dumps(body)+'\n').encode());return receive(s)
 try:
  deadline=time.monotonic()+100
  while not (OUT/'ready-1.json').exists():
   if p.poll() is not None:raise RuntimeError('exited '+str(p.returncode))
   if time.monotonic()>deadline:raise TimeoutError('ready')
   time.sleep(.2)
  r['ready']=json.loads((OUT/'ready-1.json').read_text());r['baseline']=call({'op':'perf'})
  peers=[]
  refreshed=time.monotonic()
  for _ in range(128):
   peers.append(connect())
   if time.monotonic()-refreshed>.5:
    for peer in peers:peer.sendall(b'{"op":"status","lite":true}\n')
    for peer in peers:receive(peer)
    refreshed=time.monotonic()
  # Refresh every admitted peer immediately before the idle-capacity observation.
  for peer in peers:peer.sendall(b'{"op":"status","lite":true}\n')
  for peer in peers:receive(peer)
  try:
   deadline=time.monotonic()+4
   while True:
    state_file=OUT/'tcp-state.json'
    if state_file.exists():state_file.unlink()
    (OUT/'tcp-inspect').write_text('inspect')
    while not state_file.exists():
     if time.monotonic()>deadline:raise TimeoutError('fixture TCP inspection')
     time.sleep(.01)
    while True:
     try:state=json.loads(state_file.read_text());break
     except json.JSONDecodeError:
      if time.monotonic()>deadline:raise
      time.sleep(.01)
    if state['clients']==128:break
    if time.monotonic()>deadline:raise AssertionError(('idle capacity not reached',state))
    time.sleep(.05)
   r['checks']['idle_capacity_observed']=state
   start=time.monotonic()
   try:
    ans=call({'op':'status','lite':True},10)
    assert ans.get('match'),ans
    r['checks']['128idle_129th']={'elapsed':time.monotonic()-start,'response':ans,'passed':True}
   except Exception as e:r['checks']['128idle_129th']={'error':repr(e),'passed':False}
   peers[0].close();time.sleep(.5);r['checks']['idle_release_recovery']=call({'op':'status','lite':True})
  finally:
   for s in peers:s.close()
  time.sleep(1)
  # FIN on write side after complete lines, still read every response.
  for count in [1,300]:
   with connect() as s:
    s.sendall(b'{"op":"status","lite":true}\n'*count);s.shutdown(socket.SHUT_WR)
    got=0;error=None
    try:
     for _ in range(count):receive(s);got+=1
    except Exception as e:error=repr(e)
    r['checks']['fin_'+str(count)]={'sent':count,'received':got,'error':error}
  r['checks']['fin_recovery']=call({'op':'perf'})
  with connect(10) as mixed:
   marker=str(OUT/'mixed-shot.png')
   mixed.sendall((json.dumps({'op':'screenshot','path':marker})+'\n'+json.dumps({'op':'status','lite':True})+'\n').encode())
   mixed.shutdown(socket.SHUT_WR)
   first=receive(mixed);second=receive(mixed)
   assert first.get('match') and second.get('path')==marker and second.get('error')=='no rendered frame',(first,second)
   r['checks']['mixed_async_fin']={'first':first,'second':second,'passed':True,'scope':'headless timeout correlation; visible freshness remains delegated'}
  # Deliberately do not read: finite request count, finite sender timeout and side-channel watchdog.
  with connect(3) as slow:
   slow.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1024)
   payload=b'{"op":"status"}\n'*20000
   try:slow.sendall(payload);r['checks']['slow_sent_bytes']=len(payload)
   except Exception as e:r['checks']['slow_send_error']=repr(e)
   r['checks']['slow_probes']=[]
   for i in range(5):
    time.sleep(1);start=time.monotonic()
    try:ans=call({'op':'perf'},2);row={'elapsed':time.monotonic()-start,'perf':ans}
    except Exception as e:row={'elapsed':time.monotonic()-start,'error':repr(e)}
    r['checks']['slow_probes'].append(row)
  time.sleep(1)
  try:r['checks']['slow_closed_recovery']=call({'op':'perf'},5)
  except Exception as e:r['checks']['slow_closed_recovery']={'error':repr(e)}
  r['passed']=bool(r['checks']['128idle_129th'].get('passed') and r['checks']['fin_300']['received']==300 and all('error' not in x for x in r['checks']['slow_probes']) and r['checks']['slow_closed_recovery'].get('ok') and r['checks']['mixed_async_fin']['passed'])
  assert r['passed'],r['checks']
 except Exception as e:r['error']=repr(e)
 finally:
  (OUT/'quit').write_text('quit')
  try:r['rc']=p.wait(timeout=15)
  except subprocess.TimeoutExpired:
   r['watchdog']=True;subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],capture_output=True,creationflags=0x08000000);p.wait(timeout=15)
  r['cleanup_ok']=p.poll() is not None;r['ended']=time.time();log.close();(OUT/'result.json').write_text(json.dumps(r,indent=2),encoding='utf-8');print(json.dumps(r,ensure_ascii=True))
if __name__=='__main__':main()
