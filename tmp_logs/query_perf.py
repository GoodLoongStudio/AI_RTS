import json
import socket

for port in (24579, 24568):
    try:
        sock = socket.create_connection(("127.0.0.1", port), 1.5)
        sock.sendall(b'{"op":"perf"}\n')
        sock.settimeout(4)
        data = b""
        while True:
            try:
                chunk = sock.recv(65536)
            except TimeoutError:
                break
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        sock.close()
        text = data.decode("utf-8", errors="replace")
        print("PORT", port)
        try:
            print(json.dumps(json.loads(text), ensure_ascii=False, indent=2)[:12000])
        except json.JSONDecodeError:
            print(text[:8000])
    except OSError as exc:
        print("PORT", port, "FAIL", exc)
