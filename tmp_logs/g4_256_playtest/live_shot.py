import json, socket, time
from pathlib import Path
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
PORT = 24570

def tcp(p, timeout=12.0):
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

print("fog", tcp({"op": "fog_status"}))
print("cam_fog", tcp({"op": "camera", "look_at": [200.0, 8.0, 80.0], "size": 36.0}))
time.sleep(0.6)
print("shot_fog", tcp({"op": "screenshot", "path": str(OUT / "fog_unexplored.png")}, timeout=20))
print("cam_spawn", tcp({"op": "camera", "look_at": [58.2, 8.1, 179.5], "size": 22.0}))
time.sleep(0.6)
print("shot_now", tcp({"op": "screenshot", "path": str(OUT / "live_now.png")}, timeout=20))
st = tcp({"op": "status"}, timeout=20)
units = st.get("units") or []
print("units", [(u.get("name"), u.get("unit_type"), u.get("mine"), u.get("pos")) for u in units])
print("outcome", st.get("outcome"))
