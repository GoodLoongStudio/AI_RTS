"""Real Match global output saturation; socket responses only, no fabricated queue state."""
import concurrent.futures, hashlib, json, os, socket, subprocess, time
from pathlib import Path
from debug_tcp_lifecycle_probe import ROOT, GODOT, receive
OUT=ROOT/'agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/global-03'

def main():
 OUT.mkdir(parents=True,exist_ok=False)
 def port():
  with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
 tcp,bridge=port(),port()
 cmd=[GODOT,'--headless','--path',str(ROOT),'res://tools/dev/debug_tcp_match_fixture.tscn','--','--debugport',str(tcp),'--tcp-out='+str(OUT)]
 r={'started':time.time(),'command':cmd,'hash':hashlib.sha256((ROOT/'source/net/DebugControlServer.gd').read_bytes()).hexdigest(),'samples':[]}
 log=(OUT/'match.log').open('xb');p=subprocess.Popen(cmd,env=dict(os.environ,AIRTS_INSTANCE_DIR='',AIRTS_INSTANCE_STRICT_DCS='0',GODOT_BRIDGE_PORT=str(bridge)),stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000);r['launcher_pid']=p.pid
 peers=[];extra=None
 def connect():return socket.create_connection(('127.0.0.1',tcp),timeout=15)
 def inspect():
  f=OUT/'tcp-state.json'
  if f.exists():f.unlink()
  (OUT/'tcp-inspect').write_text('inspect')
  deadline=time.monotonic()+10
  while not f.exists():
   if p.poll() is not None or time.monotonic()>deadline:raise TimeoutError('inspection')
   time.sleep(.01)
  while True:
   try:return json.loads(f.read_text())
   except json.JSONDecodeError:
    if time.monotonic()>deadline:raise
    time.sleep(.01)
 try:
  deadline=time.monotonic()+100
  while not (OUT/'ready-1.json').exists():
   if p.poll() is not None or time.monotonic()>deadline:raise TimeoutError('ready')
   time.sleep(.2)
  r['ready']=json.loads((OUT/'ready-1.json').read_text())
  # Full status responses fill kernel send windows and application watermarks naturally.
  for i in range(80):
   s=connect();s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1024);peers.append(s)
  payload=b'{"op":"status"}\n'*3000
  def send(s):s.sendall(payload);s.shutdown(socket.SHUT_WR)
  with concurrent.futures.ThreadPoolExecutor(max_workers=80) as pool:
   futures=[pool.submit(send,s) for s in peers]
   deadline=time.monotonic()+150
   while True:
    state=inspect();r['samples'].append({'wall':time.time(),**state})
    if state['output_bytes']>=16777216:break
    if time.monotonic()>deadline:raise TimeoutError('global high water not reached')
    time.sleep(1)
   extra=connect();r['extra_port']=extra.getsockname()[1]
   extra.sendall(b'{"op":"status","lite":true}\n');extra.shutdown(socket.SHUT_WR)
   started=time.monotonic()
   while time.monotonic()-started<7:
    state=inspect();r['samples'].append({'wall':time.time(),**state})
    target=next((x for x in state['peers'] if x['port']==r['extra_port']),None)
    assert state['output_bytes']>=16777216,('saturation lost',state)
    assert target and target['kernel_bytes']>0 and target['input_bytes']==0 and target['output_bytes']==0,('request not preserved in kernel',target)
    time.sleep(1)
   r['saturation_hold_s']=time.monotonic()-started
   # Release slow readers by actually receiving all their responses, no command replay.
   def drain(s):
    s.settimeout(120);count=0
    for _ in range(3000):
     ans=receive(s);assert ans.get('match'),ans;count+=1
    return count
   with concurrent.futures.ThreadPoolExecutor(max_workers=80) as readers:
    drained=list(readers.map(drain,peers))
   for f in futures:f.result()
   r['drained_responses']=sum(drained)
   extra.settimeout(30);r['extra_response']=receive(extra);assert r['extra_response'].get('match')
   r['after']=inspect();r['passed']=True
 except Exception as e:r['error']=repr(e);r['passed']=False
 finally:
  if extra:extra.close()
  for s in peers:s.close()
  (OUT/'quit').write_text('quit')
  try:r['rc']=p.wait(timeout=30)
  except subprocess.TimeoutExpired:
   subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],capture_output=True,creationflags=0x08000000);p.wait(timeout=15);r['watchdog']=True
  r['cleanup_ok']=p.poll() is not None;r['ended']=time.time();log.close();(OUT/'result.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='samples'}))
 return 0 if r.get('passed') else 1
if __name__=='__main__':raise SystemExit(main())
