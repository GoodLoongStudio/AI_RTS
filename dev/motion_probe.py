import json, socket, time
PORT = 24635
def call(op, timeout=60, **kw):
    payload={'op':op}; payload.update(kw)
    for attempt in range(4):
        try:
            with socket.create_connection(('127.0.0.1',PORT),timeout=timeout) as s:
                s.sendall((json.dumps(payload)+'\n').encode())
                buf=b''; deadline=time.time()+timeout
                while time.time()<deadline:
                    c=s.recv(262144)
                    if not c: break
                    buf+=c
                    if buf.endswith(b'\n'): break
            a=buf.find(b'{'); b=buf.find(b'\n',a)
            return json.loads(buf[a:b].decode('utf-8','replace'))
        except Exception:
            if attempt == 3: raise
            time.sleep(3)
ORE = (117.5, 32.5)
def entities():
    tact = call('tactical', as_player='Player_0', limit=100)
    return {e['name']: e for e in tact.get('entities',[]) if e.get('kind')=='unit_self'}
for _ in range(20):
    ents = entities()
    workers = [n for n,e in ents.items() if e.get('unit_type')=='worker']
    if workers: break
    time.sleep(5)
r = call('move', units=[workers[0]], dest=list(ORE)); print('scout:', r.get('status'), flush=True)
for i in range(30):
    time.sleep(5)
    ents = entities(); w = ents.get(workers[0])
    if not w: break
    p = w.get('pos') or [0,0,0]
    if ((p[0]-ORE[0])**2 + (p[2]-ORE[1])**2)**0.5 < 14:
        print('arrived', flush=True); break
r2 = call('build', units=[workers[0]], scene='res://source/match/units/OreRefinery.tscn', hint=list(ORE))
print('build:', r2.get('status'), flush=True)
t0=time.time()
while time.time()-t0 < 280:
    time.sleep(20)
    try:
        m = call('unit_motion')
        ents = entities()
    except Exception as e:
        print('probe err', e, flush=True); continue
    for row in m.get('units') or []:
        if row.get('type') == 'worker':
            e = ents.get(row['unit']) or {}
            print('t+%3d %s pos=%s committed=%s path=%d vel=%.2f rec=%s carry=%s act=%s' % (
                int(time.time()-t0), row['unit'], row.get('pos'), row.get('committed'),
                row.get('path_points', -1), row.get('velocity', -1), row.get('recovery_mode'),
                e.get('carried'), str(e.get('action','')).split('/')[-1][:18]), flush=True)
