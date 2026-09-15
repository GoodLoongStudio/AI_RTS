import json, socket, time
PORT = 24570

def tcp(p, timeout=15.0):
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall((json.dumps(p) + "\n").encode())
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            i = buf.find(b"{")
            j = buf.find(b"\n", i)
            if i >= 0 and j > i:
                return json.loads(buf[i:j].decode("utf-8", "replace"))
    raise TimeoutError(p.get("op"))

st = tcp({"op": "status"}, timeout=20)
rules = tcp({"op": "rules"}, timeout=15)
ver = rules.get("rules_version")
hashv = ver.get("content_hash") if isinstance(ver, dict) else ver
meta = {
    "op": "adjutant_command",
    "match_id": st.get("match_id") or rules.get("match_id"),
    "player_id": "Player_0",
    "rules_version": hashv,
    "issued_tick": int(st.get("server_tick") or 1),
    "expires_tick": int(st.get("server_tick") or 1) + 200000,
}
mine = [u for u in (st.get("units") or []) if u.get("mine")]
tanks = [u for u in mine if "tank" in str(u.get("unit_type") or "").lower()]
workers = [u for u in mine if "worker" in str(u.get("unit_type") or "").lower()]
factory = next((u for u in mine if "factory" in str(u.get("unit_type") or "").lower() and "air" not in str(u.get("unit_type") or "").lower()), None)
print("tanks", [(u.get("name"), u.get("pos")) for u in tanks])
print("factory", None if factory is None else factory.get("name"))
seq = 900
for u in tanks:
    seq += 1
    p = dict(meta)
    p.update({
        "command_id": "push-am-%d" % seq,
        "action": "attack_move",
        "params": {"units": [u["name"]], "dest": [84.2, 54.6], "reacquire": True},
    })
    r = tcp(p)
    print("AM", u.get("name"), r.get("status"), r.get("reason"))
if factory:
    seq += 1
    p = dict(meta)
    p.update({
        "command_id": "push-prod-%d" % seq,
        "action": "produce",
        "params": {"unit": factory["name"], "scene": "res://source/match/units/Tank.tscn", "reacquire": True},
    })
    r = tcp(p)
    print("PROD", r.get("status"), r.get("reason"))
print("outcome", st.get("outcome"))
