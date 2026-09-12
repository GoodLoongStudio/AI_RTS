#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI_RTS 副官 daemon v5.1：连通测试 + 会话自愈（僵尸感知）。
- ping            → 游戏权威端点连通 + latency_ms
- ping_llm        → 模型 API 直连探测 + latency_ms
- ping_llm_result → 轮询 ping_llm 结果
- takeover/stop   → Hermes 副官会话管理
v5.1 修复：_alive 僵尸感知（/proc/<pid>/stat），supervisor 先 waitpid 收尸再判定；
stop 显式清 _EXPECTED_RUNNING（否则看门狗会把手动停止的会话复活）。
v5 的教训：会话退出后成为 zombie，os.kill(pid,0) 对 zombie 返回成功，
supervisor 以为它还活着，永远不重启——副官死后基地无人值守。
"""
import json
import os
import re
import signal
import subprocess
import threading
import time as _time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = "/home/ubuntu/ai-adjutant/config/adjutant_token"


def _load_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
            return handle.read().strip() or None
    except OSError:
        return None
HERMES = "/home/ubuntu/.hermes/hermes-agent/venv/bin/hermes"
LOG = "/home/ubuntu/hermes_adjutant.log"
PIDFILE = "/home/ubuntu/adjutant.pid"
LLM_RESULT = "/home/ubuntu/.hermes/llm_ping_result.json"
DEFAULT_PORT = 24571
HERMES_HOME = "/home/ubuntu/.hermes"

PROVIDER_DEFAULTS = {
    "stepfun": ("https://api.stepfun.ai/v1", "STEPFUN_API_KEY"),
    "openai": ("https://api.openai.com/v1", "OPENAI_API_KEY"),
    "deepseek": ("https://api.deepseek.com/v1", "DEEPSEEK_API_KEY"),
    "moonshot": ("https://api.moonshot.cn/v1", "MOONSHOT_API_KEY"),
    "minimax": ("https://api.minimax.chat/v1", "MINIMAX_API_KEY"),
    "anthropic": ("https://api.anthropic.com/v1", "ANTHROPIC_API_KEY"),
}

PROMPT = "You are the autonomous AI adjutant for the active AI_RTS match. Use ai-rts-commander scripts only. First run rts_ctl.py all, identify the human player. Loop observe, plan, act, verify; gather, build, produce mobile units, explore separate sectors. Replan after three acts. Never wait for user input. Stop when no active match remains."


def _read_pid():
    try:
        with open(PIDFILE) as f:
            return int(f.read().strip())
    except Exception:
        return None


def _alive(pid):
    """僵尸进程视为已死：/proc/<pid>/stat 的状态位是 Z 时返回 False。"""
    if pid is None:
        return False
    try:
        with open("/proc/%d/stat" % pid, encoding="utf-8") as f:
            state = f.read().rsplit(")", 1)[-1].split()[0]
        return state != "Z"
    except OSError:
        return False


def _reap_children():
    """回收所有已退出的子进程，避免 zombie 卡住 _alive 判定。"""
    while True:
        try:
            wpid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        except OSError:
            return
        if wpid == 0:
            return


def _load_model_cfg():
    cfg = {"default": "", "provider": "", "base_url": ""}
    try:
        with open(os.path.join(HERMES_HOME, "config.yaml"), encoding="utf-8") as f:
            in_model = False
            for line in f:
                if line.startswith("model:"):
                    in_model = True
                    continue
                if in_model:
                    if line and not line[0].isspace():
                        break
                    for k in cfg:
                        if line.strip().startswith(k + ":"):
                            cfg[k] = line.split(":", 1)[1].strip().strip("'\"")
    except Exception:
        pass
    return cfg


def _load_env():
    env = {}
    try:
        with open(os.path.join(HERMES_HOME, ".env"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    env[k.strip()] = v.strip().strip("'\"")
    except Exception:
        pass
    env.update({k: v for k, v in os.environ.items() if k.endswith("_API_KEY") or k.endswith("_BASE_URL")})
    return env


def _ping_llm_blocking():
    """直连模型 API（OpenAI 兼容 chat/completions，max_tokens=5，30s 超时）+ 延时。"""
    cfg = _load_model_cfg()
    env = _load_env()
    provider = cfg.get("provider", "").lower()
    model = cfg.get("default", "")
    if not provider or not model:
        return {"llm_alive": False, "error": "config 未配置主模型 (model.provider/default)"}

    default_base, key_env = PROVIDER_DEFAULTS.get(provider, (None, None))
    if default_base is None:
        return {"llm_alive": False,
                "error": f"provider '{provider}' 不支持自动探测（可扩展 PROVIDER_DEFAULTS）"}

    base = cfg.get("base_url") or env.get(provider.upper() + "_BASE_URL") or default_base
    if not base.rstrip("/").endswith("/v1"):
        base = base.rstrip("/") + "/v1"
    key = env.get(key_env, "")
    if not key:
        return {"llm_alive": False, "error": f"{key_env} 未配置（检查 ~/.hermes/.env）"}

    url = base.rstrip("/") + "/chat/completions"
    body = json.dumps({
        "model": model,
        "max_tokens": 5,
        "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
    }).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = _time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
        latency_ms = int((_time.perf_counter() - t0) * 1000)
        reply = (data.get("choices") or [{}])[0].get("message", {}).get("content", "")
        return {"llm_alive": True, "provider": provider, "model": model,
                "latency_ms": latency_ms, "reply": (reply or "OK")[-60:]}
    except urllib.error.HTTPError as e:
        latency_ms = int((_time.perf_counter() - t0) * 1000)
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        return {"llm_alive": False, "latency_ms": latency_ms,
                "error": f"HTTP {e.code}: {detail}"}
    except Exception as exc:
        latency_ms = int((_time.perf_counter() - t0) * 1000)
        return {"llm_alive": False, "latency_ms": latency_ms, "error": str(exc)}


def _ping_llm_start():
    try:
        os.remove(LLM_RESULT)
    except OSError:
        pass

    def worker():
        result = _ping_llm_blocking()
        result["done"] = True
        result["ts"] = _time.time()
        with open(LLM_RESULT, "w") as f:
            json.dump(result, f)

    threading.Thread(target=worker, daemon=True).start()


def _llm_result_read():
    try:
        with open(LLM_RESULT) as f:
            d = json.load(f)
        d["stale"] = (_time.time() - d.get("ts", 0)) > 900
        return d
    except Exception:
        return {"done": False}


def _ping_game(port):
    t0 = _time.perf_counter()
    import socket
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.settimeout(5)
            sock.sendall(b'{"op":"status"}\n')
            header = b""
            while len(header) < 4:
                chunk = sock.recv(4 - len(header))
                if not chunk:
                    raise EOFError("frame header")
                header += chunk
            length = int.from_bytes(header, "little")
            if length <= 0 or length > (32 << 20):
                raise ValueError("invalid frame length")
            body = b""
            while len(body) < length:
                chunk = sock.recv(min(65536, length - len(body)))
                if not chunk:
                    raise EOFError("frame body")
                body += chunk
        resp = json.loads(body.decode("utf-8", "replace"))
        latency_ms = int((_time.perf_counter() - t0) * 1000)
        return {"ok": True, "game_alive": True, "latency_ms": latency_ms, "match": bool(resp.get("match")), "players": len(resp.get("players", [])), "units": len(resp.get("units", []))}
    except Exception as exc:
        latency_ms = int((_time.perf_counter() - t0) * 1000)
        return {"ok": True, "game_alive": False, "latency_ms": latency_ms, "error": str(exc)}



_ANSI_RE = re.compile(r"\x1b\\[[0-9;]*[A-Za-z]|\x1b\\][^\x07]*\x07|\x1b[>=()][0-9A-B]?")


def _tail_adjutant(limit=40):
    try:
        with open(LOG, "r", encoding="utf-8", errors="replace") as f:
            data = f.read()[-16384:]
        lines = []
        for raw in data.splitlines():
            line = _ANSI_RE.sub("", raw).replace("\r", "").strip()
            if not line:
                continue
            if line.startswith("[daemon]"):
                continue
            lines.append(line)
        return lines[-limit:]
    except Exception as exc:
        return [f"(tail error: {exc})"]


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        with open("/home/ubuntu/adjutant_http.log", "a") as f:
            f.write("[daemon] " + (fmt % args) + "\n")

    def do_GET(self):
        if self.path != "/adjutant/status":
            self._json(404, {"error": "not found"})
            return
        pid = _read_pid()
        self._json(200, {"running": _alive(pid), "pid": pid if _alive(pid) else None})

    def do_POST(self):
        if self.path != "/adjutant/control":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json(400, {"error": "bad json"})
            return
        expected = _load_token()
        if not expected:
            self._json(503, {"error": "token not configured"})
            return
        import hmac
        if not hmac.compare_digest(str(data.get("token", "")), expected):
            self._json(403, {"error": "bad token"})
            return
            self._json(403, {"error": "bad token"})
            return
        action = data.get("action", "")
        if action == "ping":
            port = int(data.get("port", DEFAULT_PORT))
            self._json(200, _ping_game(port))
        elif action == "ping_llm":
            _ping_llm_start()
            self._json(200, {"started": True})
        elif action == "ping_llm_result":
            self._json(200, _llm_result_read())
        elif action == "tail":
            self._json(200, {"lines": _tail_adjutant(40)})
        elif action == "takeover":
            pid = _read_pid()
            if _alive(pid):
                self._json(409, {"error": "already running", "pid": pid})
                return
            port = int(data.get("port", DEFAULT_PORT))
            if not _game_has_match(port):
                self._json(409, {"error": "no active match", "port": port})
                return
            env = dict(os.environ)
            env["AI_RTS_ADJ_PORT"] = str(port)
            env["HOME"] = "/home/ubuntu"
            env["PYTHONUNBUFFERED"] = "1"
            with open(LOG, "a") as lf:
                proc = subprocess.Popen(
                    [HERMES, "chat", "-s", "ai-rts-commander", "--yolo",
                     "--max-turns", "500", "-q", PROMPT],
                    stdout=lf, stderr=subprocess.STDOUT,
                    env=env, cwd="/home/ubuntu",
                    start_new_session=True,
                )
            with open(PIDFILE, "w") as f:
                f.write(str(proc.pid))
            global _EXPECTED_RUNNING, _LAST_PORT
            _EXPECTED_RUNNING = True
            _LAST_PORT = port
            self._json(200, {"ok": True, "pid": proc.pid, "port": port})
        elif action == "stop":
            # takeover 分支已有 global 声明，函数作用域内直接赋值即可
            pid = _read_pid()
            _EXPECTED_RUNNING = False
            if not _alive(pid):
                self._json(200, {"ok": True, "note": "not running"})
                return
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
            self._json(200, {"ok": True, "stopped": pid})
        else:
            self._json(400, {"error": "unknown action"})


# ---------- 副官会话自愈 ----------
# Hermes 会话可能因模型主动停止/异常而退出（无人值守 prompt 未必约束得住），
# 这里做工程兜底：只要用户没显式 stop，会话退出后自动重启，保证持续托管。
_EXPECTED_RUNNING = False
_LAST_PORT = DEFAULT_PORT
_RESPAWNS = {"n": 0, "hour": None}
RESPAWN_BUDGET_PER_HOUR = 30


def _budget_ok():
    hour = int(_time.time() // 3600)
    if _RESPAWNS["hour"] != hour:
        _RESPAWNS["hour"] = hour
        _RESPAWNS["n"] = 0
    return _RESPAWNS["n"] < RESPAWN_BUDGET_PER_HOUR


def _respawn(port):
    env = dict(os.environ)
    env["AI_RTS_ADJ_PORT"] = str(port)
    env["HOME"] = "/home/ubuntu"
    env["PYTHONUNBUFFERED"] = "1"
    with open(LOG, "a") as lf:
        proc = subprocess.Popen(
            [HERMES, "chat", "-s", "ai-rts-commander", "--yolo",
             "--max-turns", "500", "-q", PROMPT],
            stdout=lf, stderr=subprocess.STDOUT,
            env=env, cwd="/home/ubuntu",
            start_new_session=True,
        )
    with open(PIDFILE, "w") as f:
        f.write(str(proc.pid))
    with open(LOG, "a") as lf:
        lf.write("[daemon] auto-respawn adjutant pid=%s port=%s\n" % (proc.pid, port))
    return proc.pid


def _supervisor():
    while True:
        _time.sleep(15)
        try:
            _reap_children()
            if not _EXPECTED_RUNNING:
                continue
            pid = _read_pid()
            if _alive(pid):
                if not _game_has_match(_LAST_PORT):
                    _EXPECTED_RUNNING = False
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except OSError:
                        pass
                    with open(LOG, "a") as lf:
                        lf.write("[daemon] active match ended; stopped Hermes pid=%s\n" % pid)
                continue
            if not _budget_ok():
                with open(LOG, "a") as lf:
                    lf.write("[daemon] respawn budget exhausted, skip (pid=%s)\n" % pid)
                continue
            _RESPAWNS["n"] += 1
            with open(LOG, "a") as lf:
                lf.write("[daemon] adjutant session exited (pid=%s) -> respawn #%d\n"
                         % (pid, _RESPAWNS["n"]))
            _respawn(_LAST_PORT)
        except Exception as exc:
            try:
                with open(LOG, "a") as lf:
                    lf.write("[daemon] supervisor error: %s\n" % exc)
            except Exception:
                pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 24580), Handler)
    with open(LOG, "a") as f:
        f.write("[daemon] v5.1 started on 127.0.0.1:24580\n")
    threading.Thread(target=_supervisor, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
