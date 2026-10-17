#!/usr/bin/env python3
"""Observe the unmodified adjutant in a normal solo practice Match.

Windows, Python stdlib + existing psutil. No desktop capture or OS input.
The child runner only receives read-only instrumentation and a stop flag.
The HTTP tee preserves the request/response bytes and excludes hidden reasoning
from saved evidence. A completed run is diagnostic evidence, not product approval.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import http.client
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
WORKSPACE = PROJECT.parent
PYTHON = WORKSPACE / "临时文件夹/airts_agent_venv/Scripts/python.exe"
GODOT = WORKSPACE / "godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe"
RUNTIME = PROJECT / "build/adjutant_runtime"
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_LOCK = threading.RLock()


def plain(value):
    if hasattr(value, "model_dump"):
        return plain(value.model_dump(mode="json"))
    if hasattr(value, "to_plan_dict"):
        return plain(value.to_plan_dict())
    if dataclasses.is_dataclass(value):
        return plain(dataclasses.asdict(value))
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items() if str(k).lower() not in
                {"reasoning_content", "thinking", "reasoning", "api_key", "authorization"}}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, str):
        return re.sub(r"<think(?:ing)?>.*?(?:</think(?:ing)?>|$)", "[隐藏推理未记录]", value,
                      flags=re.S | re.I)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with _LOCK:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(plain(value), ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)


def emit(path, **value):
    with _LOCK:
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(plain(dict(ts=time.time(), mono=time.perf_counter(), **value)),
                                    ensure_ascii=False) + "\n")


def read_lines(path):
    if not Path(path).exists():
        return []
    rows = []
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            rows.append({"kind": "unparsed_line", "text": line[:200]})
    return rows


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_freeze():
    paths = [PROJECT / "project.godot"]
    for relative in ("source/adjutant_coordinator/graph", "source/adjutant_coordinator/deploy"):
        paths += sorted((PROJECT / relative).glob("*.py"))
    paths += [PROJECT / "source/net/DebugControlServer.gd", PROJECT / "source/main-menu/Play.gd"]
    paths += sorted((PROJECT / ".godot/mono/temp/bin/Debug").glob("*.dll"))
    return {str(p): sha(p) for p in paths if p.is_file()}


def tcp(port, payload, timeout=8, framed=False):
    deadline = time.monotonic() + timeout
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as conn:
        conn.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        if framed:
            def exact(size):
                parts = bytearray()
                while len(parts) < size:
                    conn.settimeout(max(0.01, deadline - time.monotonic()))
                    part = conn.recv(size - len(parts))
                    if not part:
                        raise ConnectionError("Short framed control response")
                    parts.extend(part)
                return bytes(parts)
            size = struct.unpack("<I", exact(4))[0]
            if not 0 < size <= 1048576:
                raise ValueError("Invalid framed response length")
            return json.loads(exact(size))
        data = bytearray()
        while b"\n" not in data:
            conn.settimeout(max(0.01, deadline - time.monotonic()))
            chunk = conn.recv(65536)
            if not chunk:
                raise ConnectionError("Control endpoint closed without newline")
            data.extend(chunk)
            if len(data) > 24 * 1024 * 1024:
                raise ValueError("Control response exceeds observation bound")
        return json.loads(data.split(b"\n", 1)[0])


def http_json(url, payload=None, timeout=10):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with OPENER.open(req, timeout=timeout) as response:
        return json.load(response)


class Tee(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, upstream_port, run):
        self.upstream_port, self.run = upstream_port, run
        self.seq = 0
        super().__init__(("127.0.0.1", port), TeeHandler)


class TeeHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        with _LOCK:
            self.server.seq += 1
            number = self.server.seq
        role, _, route = self.path.lstrip("/").partition("/")
        name = "%04d-%s" % (number, role)
        out = self.server.run / "http"
        started = time.time()
        code = 502
        connection = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8 * 1024 * 1024:
                raise ValueError("Invalid HTTP body length")
            body = self.rfile.read(length)
            request = json.loads(body)
            if request.get("stream"):
                raise ValueError("Observation tee requires the production non-streaming call")
            write_json(out / (name + ".request.json"), request)
            emit(self.server.run / "http.jsonl", kind="request", request_id=name, role=role,
                 started_at=started, request_bytes=len(body),
                 max_tokens=request.get("max_completion_tokens", request.get("max_tokens")),
                 request=str(out / (name + ".request.json")))
            connection = http.client.HTTPConnection("127.0.0.1", self.server.upstream_port, timeout=120)
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in {"host", "content-length", "connection", "accept-encoding"}}
            connection.request("POST", "/" + route, body=body, headers=headers)
            response = connection.getresponse()
            code = response.status
            raw = response.read(8 * 1024 * 1024 + 1)
            if len(raw) > 8 * 1024 * 1024:
                raise ValueError("Model response exceeds observation bound")
            try:
                value = json.loads(raw)
            except ValueError:
                value = {"unparsed_response": raw.decode("utf-8", errors="replace")}
            write_json(out / (name + ".response.json"), value)
            emit(self.server.run / "http.jsonl", kind="response", request_id=name, role=role,
                 started_at=started, latency_s=time.time() - started, status=code,
                 usage=value.get("usage"), response=str(out / (name + ".response.json")))
            self.send_response(code)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            emit(self.server.run / "http.jsonl", kind="client_disconnected", request_id=name, role=role)
        except Exception as exc:
            emit(self.server.run / "http.jsonl", kind="proxy_error", request_id=name, role=role,
                 error=repr(exc), latency_s=time.time() - started)
            try:
                raw = json.dumps({"error": {"message": type(exc).__name__}}).encode()
                self.send_response(502)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            except OSError:
                pass
        finally:
            if connection:
                connection.close()


def runner_child(run, argv):
    """Instrumentation is local to this child; production files stay untouched."""
    sys.path.insert(0, str(PROJECT / "source"))
    sys.path.insert(0, str(PROJECT / "source/adjutant_coordinator/deploy"))
    import agent_runner as module
    trace = run / "attempts.jsonl"
    seq = Counter()

    def wrap(original, method):
        def wrapped(self, *args, **kwargs):
            role = self.role
            with _LOCK:
                seq[role] += 1
                attempt_id = "%s-%04d" % (role, seq[role])
            started = time.time()
            payload = args[1] if method == "_invoke" else args[0]
            write_json(run / "attempts" / (attempt_id + ".context.json"), payload)
            emit(trace, kind="attempt_start", attempt_id=attempt_id, role=role,
                 started_at=started, method=str(args[0]) if method == "_invoke" else method)
            try:
                result = original(self, *args, **kwargs)
                meta = self.inner.request_meta() if hasattr(self.inner, "request_meta") else {}
                write_json(run / "attempts" / (attempt_id + ".result.json"),
                           {"result": plain(result), "selection": meta,
                            "laya": plain(getattr(self.inner, "last_laya", None)),
                            "decode": plain(getattr(self.inner, "last_decode", None))})
                emit(trace, kind="attempt_end", attempt_id=attempt_id, role=role, ok=True,
                     started_at=started, latency_s=time.time() - started, selection=meta)
                return result
            except Exception as exc:
                emit(trace, kind="attempt_end", attempt_id=attempt_id, role=role, ok=False,
                     started_at=started, latency_s=time.time() - started, error_type=type(exc).__name__,
                     error=str(exc)[:1200])
                raise
        return wrapped

    module.MeteredModel._invoke = wrap(module.MeteredModel._invoke, "_invoke")
    module.MeteredModel.propose_task_patch = wrap(module.MeteredModel.propose_task_patch, "propose_task_patch")
    runner = module.AgentRunner(module.build_parser().parse_args(argv))
    archive_original = runner._archive_round
    last_state = 0.0

    def archive(tick, obs, result, metrics):
        nonlocal last_state
        archive_original(tick, obs, result, metrics)
        now = time.time()
        if not (run / "runner-ready.json").exists():
            write_json(run / "runner-ready.json", {"ts": now, "server_tick": tick,
                       "match_id": runner.match_id, "player": runner.player, "pid": os.getpid()})
        if now - last_state >= 5:
            last_state = now
            state = result.state
            live = runner.runtime.state
            emit(run / "strategy-state.jsonl", kind="state", server_tick=tick,
                 current_plan=getattr(live, "active_plan", None),
                 active_tasks=getattr(live, "active_tasks", None),
                 control_generation=getattr(live, "control_generation", None),
                 campaign=state.get("campaign"), degraded_reason=result.degraded_reason,
                 accepted=list(result.accepted_intents), dropped=list(result.dropped_intents))
    runner._archive_round = archive

    def stop_watch():
        while not (run / "STOP").exists():
            time.sleep(0.2)
        runner._stop_reason = "observation_complete"
        runner._stopping = True
    threading.Thread(target=stop_watch, daemon=True).start()
    code = runner.run()
    # 留下退出后的线程现场；不能只凭 exit 日志认定 OS 进程已经结束。
    frames = sys._current_frames()
    write_json(run / "runner-exit-threads.json", [
        {"name": thread.name, "daemon": thread.daemon, "ident": thread.ident,
         "stack": traceback.format_stack(frames[thread.ident]) if thread.ident in frames else []}
        for thread in threading.enumerate()])
    return code


class Owner:
    def __init__(self, run):
        import psutil
        self.psutil, self.run, self.items = psutil, run, []

    def launch(self, name, argv, env):
        stdout = (self.run / (name + ".stdout.log")).open("wb")
        stderr = (self.run / (name + ".stderr.log")).open("wb")
        startup = None
        if os.name == "nt" and name == "game" and "--windowed" in argv:
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 4  # SW_SHOWNOACTIVATE；不抢前台。
        child = subprocess.Popen([str(x) for x in argv], cwd=PROJECT, env=env,
                                 stdout=stdout, stderr=stderr, creationflags=CREATE_NO_WINDOW,
                                 startupinfo=startup)
        proc = self.psutil.Process(child.pid)
        identity = {"name": name, "pid": child.pid, "creation_time": proc.create_time(),
                    "exe": proc.exe(), "command": proc.cmdline(), "parent_pid": os.getpid()}
        self.items.append((child, identity, stdout, stderr))
        write_json(self.run / "processes.json", [x[1] for x in self.items])
        return child

    def cleanup(self):
        results = []
        for child, identity, stdout, stderr in reversed(self.items):
            forced, descendants = [], []
            if child.poll() is None:
                try:
                    proc = self.psutil.Process(child.pid)
                    if proc.create_time() != identity["creation_time"] or proc.exe() != identity["exe"]:
                        raise RuntimeError("Process ownership changed")
                    descendants = proc.children(recursive=True)
                    # Only this owned tree, with creation-time pins retained in the report.
                    for descendant in reversed(descendants):
                        try:
                            forced.append({"pid": descendant.pid, "creation_time": descendant.create_time(),
                                           "exe": descendant.exe(), "command": descendant.cmdline()})
                            descendant.terminate()
                        except self.psutil.NoSuchProcess:
                            pass
                    proc.terminate()
                    forced.append({"pid": proc.pid, "creation_time": identity["creation_time"]})
                    child.wait(timeout=15)
                except Exception as exc:
                    results.append({"name": identity["name"], "cleanup_error": repr(exc)})
            stdout.close()
            stderr.close()
            results.append({**identity, "os_returncode": child.poll(), "forced": forced,
                            "alive": child.poll() is None})
        try:
            write_json(self.run / "cleanup.json", results)
        except OSError:
            # Cleanup must still finish when the evidence drive is unavailable.
            pass
        return results


def wait_until(check, timeout, label):
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, RuntimeError) as exc:
            last = repr(exc)
        time.sleep(0.4)
    raise TimeoutError("%s: %s" % (label, last))


def model_config():
    manifest = RUNTIME / "models/manifests/registry.ollama.ai/library/minicpm5-adj-16k/latest"
    data = json.loads(manifest.read_text(encoding="utf-8"))
    params = next(layer for layer in data["layers"] if "params" in layer["mediaType"])
    blob = RUNTIME / "models/blobs" / params["digest"].replace(":", "-")
    return {"model": "minicpm5-adj-16k", "manifest_sha256": sha(manifest),
            "parameters": json.loads(blob.read_text(encoding="utf-8"))}


def observe(args):
    sys.path.insert(0, str(HERE))
    from match_instance import allocate_ports, ParentLease, port_free
    run = Path(args.output or PROJECT / "agent/runs" / time.strftime("%Y%m%d-%H%M%S-adjutant-observe"))
    run.mkdir(parents=True, exist_ok=False)
    for sub in ("http", "attempts", "runner-logs", "runner-state", "instances"):
        (run / sub).mkdir()
    owner = Owner(run)
    summary = {"requested_seconds": args.seconds, "status": "preparing", "run": str(run),
               "headless": True, "entry": "normal Main/Play/Loading/Match menu callbacks",
               "strategy_mode": args.strategy_mode, "tactics": "on", "engine": "langgraph",
               "model": model_config(), "started_at": time.time()}
    before = source_freeze()
    write_json(run / "source-before.json", before)
    write_json(run / "summary.json", summary)
    lease, tee, game, runner = None, None, None, None
    mcp_port = None
    try:
        for _ in range(32):
            ports = allocate_ports(span=8)
            if all(port_free(ports["base"] + offset) for offset in range(8)):
                break
        else:
            raise RuntimeError("No fully free observation port block")
        base = ports["base"]
        game_port, dcs_port, mcp_port, model_port, tee_port = base, base + 1, base + 2, base + 4, base + 5
        summary["ports"] = {"game": game_port, "dcs": dcs_port, "mcp": mcp_port,
                            "ollama": model_port, "tee": tee_port}
        emit(run / "actions.jsonl", kind="prepare", ports=summary["ports"])
        env = os.environ.copy()
        env.update({"PYTHONIOENCODING": "utf-8", "PYTHONDONTWRITEBYTECODE": "1",
                    "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"})
        if args.model_port:
            model_port = args.model_port
            summary["ports"]["ollama"] = model_port
            summary["model_service_ownership"] = "existing service; never stopped by this tool"
        else:
            model_env = dict(env, OLLAMA_HOST="127.0.0.1:%s" % model_port,
                             OLLAMA_MODELS=str(RUNTIME / "models"), OLLAMA_KEEP_ALIVE="15m")
            owner.launch("ollama", [RUNTIME / "ollama/ollama.exe", "serve"], model_env)
            summary["model_service_ownership"] = "owned isolated service"
        endpoint = "http://127.0.0.1:%s" % model_port
        wait_until(lambda: http_json(endpoint + "/api/tags", timeout=2), 45, "model service")
        write_json(run / "warmup.json", http_json(endpoint + "/api/generate", {
            "model": "minicpm5-adj-16k", "prompt": "hello", "stream": False,
            "keep_alive": "15m", "options": {"num_predict": 1}}, timeout=180))
        write_json(run / "model-ps-start.json", http_json(endpoint + "/api/ps"))
        tee = Tee(tee_port, model_port, run)
        threading.Thread(target=tee.serve_forever, daemon=True).start()
        lease = ParentLease(str(run / "instances")).start()
        game_env = dict(env, AIRTS_INSTANCE_DIR=str(run / "instances"),
                        AIRTS_INSTANCE=run.name + "-solo", AIRTS_PARENT_PID=str(os.getpid()),
                        AIRTS_ADJ_AUTO_TAKEOVER="0", AIRTS_RUNNER_HUD=str(run / "runner-logs"),
                        GODOT_BRIDGE_PORT=str(mcp_port), GODOT_BRIDGE_TOKEN=run.name)
        display = ["--windowed", "--resolution", "1280x720", "--position", "-4000,-4000",
                   "--audio-driver", "Dummy"] if args.background_window else ["--headless"]
        summary["headless"] = not args.background_window
        game = owner.launch("game", [GODOT, *display, "--path", PROJECT, "--", "--port",
                            game_port, "--debugport", dcs_port, "--seed", args.seed], game_env)

        def mcp(command, params=None):
            result = tcp(mcp_port, {"command": command, "params": params or {}, "id": time.time_ns()})
            if result.get("error"):
                raise RuntimeError(str(result["error"]))
            return result

        identity = wait_until(lambda: mcp("get_instance_info"), 45, "MCP identity")
        write_json(run / "game-identity.json", identity)
        if int(identity.get("pid", 0)) != game.pid:
            raise RuntimeError("MCP ownership PID mismatch")
        wait_until(lambda: mcp("eval", {"code":
            "var scene = get_tree().current_scene\n"
            "return scene != null and scene.has_method(\"_on_play_button_pressed\")"}).get("result"),
            30, "main menu after splash")
        # Normal menu entry, no fixture Match, no injected units or resources.
        write_json(run / "menu-main.json", mcp("get_scene_tree"))
        mcp("eval", {"code": "get_tree().current_scene._on_play_button_pressed()\nreturn true"})
        time.sleep(1)
        setup = mcp("eval", {"code": (
            "var page = get_tree().current_scene\n"
            "for i in range(page._slot_selects.size()):\n"
            "\tpage._slot_selects[i].select(1 if i == 0 else 0)\n"
            "\tpage._on_offline_slot_selected(page._slot_selects[i].selected, i)\n"
            "var chosen = page._map_paths.find(\"" + args.map + "\")\n"
            "if chosen < 0:\n\treturn {\"error\": \"map not registered\"}\n"
            "page._map_select.select(chosen)\npage._on_map_selected(chosen)\n"
            "var kinds = []\nfor button in page._slot_selects:\n"
            "\tkinds.append(button.get_selected_id())\n"
            "return {\"map\": page.selected_map_path(), \"slots\": kinds}")})
        write_json(run / "room-setup.json", setup)
        if (setup.get("result") or {}).get("map") != args.map:
            raise RuntimeError("Menu configuration was not confirmed")
        mcp("eval", {"code": "get_tree().current_scene._on_start_button_pressed()\nreturn true"})
        status = wait_until(lambda: (lambda x: x if x.get("match") else None)(
            tcp(dcs_port, {"op": "status"}, framed=True)), 120, "normal solo Match")
        write_json(run / "opening-status.json", status)
        player = status.get("local_player_name") or "Player_0"
        runner_env = dict(env, LLM_BASE_URL="http://127.0.0.1:%s/strategy/v1" % tee_port,
                          STRATEGY_BASE_URL="http://127.0.0.1:%s/strategy/v1" % tee_port,
                          TACTICS_BASE_URL="http://127.0.0.1:%s/tactics/v1" % tee_port,
                          AIRTS_RUNNER_HUD=str(run / "runner-logs"))
        runner = owner.launch("runner", [PYTHON, "-B", "-u", Path(__file__).resolve(), "runner-child",
            "--run", run, "--", "--authority-port", dcs_port, "--allow-other-port", "--player", player,
            "--provider", "real", "--model", "on", "--engine", "langgraph", "--strategy-mode",
            args.strategy_mode, "--tactics", "on", "--env-file", PROJECT / "source/adjutant_coordinator/.env.local",
            "--log-dir", run / "runner-logs", "--state-dir", run / "runner-state", "--pidfile",
            run / "runner-logs/agent_runner.pid"], runner_env)
        ready = wait_until(lambda: json.loads((run / "runner-ready.json").read_text(encoding="utf-8"))
                           if (run / "runner-ready.json").exists() else
                           (_ for _ in ()).throw(RuntimeError("runner exited %s" % runner.poll()))
                           if runner.poll() is not None else None, 120, "runner first real tick")
        start = time.perf_counter()
        if args.background_window:
            (run / "video").mkdir()
            owner.launch("recorder", [sys.executable, "tools/dev/record_playtest.py", "record",
                "--pid", game.pid, "--fps", "5", "--seconds", str(args.seconds),
                "--output", run / "video/observe.mp4"], env)
        summary.update(status="observing", observation_start=time.time(), runner_ready=ready)
        write_json(run / "summary.json", summary)
        print(json.dumps({"run": str(run), "status": "observing", "seconds": args.seconds}, ensure_ascii=False), flush=True)
        next_sample, next_progress = 0.0, 0.0
        while time.perf_counter() - start < args.seconds:
            elapsed = time.perf_counter() - start
            if game.poll() is not None or runner.poll() is not None:
                raise RuntimeError("Game or runner exited during observation")
            if elapsed >= next_sample:
                next_sample += 5
                try:
                    world = tcp(dcs_port, {"op": "status", "lite": True}, timeout=3, framed=True)
                    emit(run / "world.jsonl", kind="status", elapsed_s=elapsed, world=world)
                    if not world.get("match"):
                        raise RuntimeError("Match ended before observation completed")
                except OSError as exc:
                    emit(run / "world.jsonl", kind="sample_gap", elapsed_s=elapsed, error=repr(exc))
            if elapsed >= next_progress:
                next_progress += 30
                write_json(run / "progress.json", {"elapsed_s": elapsed, "target_s": args.seconds,
                           "http_requests": tee.seq, "ts": time.time()})
                print("Observation %.1f / %.1f seconds; HTTP requests %d" %
                      (elapsed, args.seconds, tee.seq), flush=True)
            time.sleep(min(0.2, max(0.01, args.seconds - (time.perf_counter() - start))))
        summary.update(observed_seconds=time.perf_counter() - start,
                       observation_end=time.time(), status="observed")
        write_json(run / "model-ps-end.json", http_json(endpoint + "/api/ps"))
    except Exception as exc:
        summary.update(status="incomplete", error=repr(exc), traceback=traceback.format_exc())
        if summary.get("observation_start"):
            summary["observed_seconds"] = time.time() - summary["observation_start"]
    finally:
        try:
            (run / "STOP").write_text("stop owned runner\n", encoding="utf-8")
        except OSError as exc:
            summary["stop_flag_write_error"] = repr(exc)
        if runner and runner.poll() is None:
            try:
                # Tee 的单个后端请求上限为 120 秒；图主循环退出后，Python 仍须
                # 等在途模型线程结束。保留 180 秒有界排空时间，不把 45 秒误作僵尸。
                drain_start = time.perf_counter()
                runner.wait(timeout=180)
                summary["runner_drain_seconds"] = time.perf_counter() - drain_start
            except subprocess.TimeoutExpired:
                summary["runner_stop_timeout"] = True
        if game and game.poll() is None and mcp_port:
            try:
                # Process quit is reported separately from a menu return test.
                tcp(mcp_port, {"command": "eval", "params": {"code": "get_tree().quit(0)\nreturn true"}})
                game.wait(timeout=20)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
        if tee:
            tee.shutdown()
            tee.server_close()
        summary["cleanup"] = owner.cleanup()
        if lease:
            lease.stop()
        after = source_freeze()
        try:
            write_json(run / "source-after.json", after)
        except OSError as exc:
            summary["evidence_write_error"] = repr(exc)
        summary["source_changed"] = [p for p in set(before) | set(after) if before.get(p) != after.get(p)]
        summary["finished_at"] = time.time()
        try:
            write_json(run / "summary.json", summary)
            report(run)
        except OSError as exc:
            summary["status"] = "incomplete"
            summary["evidence_write_error"] = repr(exc)
            fallback = Path(os.environ.get("TEMP", str(Path.home()))) / (run.name + "-recovery.json")
            write_json(fallback, summary)
            print("Evidence interrupted; cleanup summary: %s" % fallback, flush=True)
        print(json.dumps({"run": str(run), "status": summary["status"],
                          "report": str(run / "report.md")}, ensure_ascii=False), flush=True)
    clean = not summary.get("runner_stop_timeout") and all(
        not item.get("alive") and not item.get("forced") and item.get("os_returncode") == 0
        for item in summary.get("cleanup", []))
    return 0 if summary["status"] == "observed" and not summary["source_changed"] and clean else 2


def link(path, label=None):
    return "[%s](%s)" % (label or Path(path).name, str(path).replace("\\", "/"))


def cell(value, limit=180):
    text = json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else str(value)
    return text.replace("|", "\\|").replace("\n", " ")[:limit]


def report(run):
    summary = json.loads((run / "summary.json").read_text(encoding="utf-8"))
    start = summary.get("observation_start", summary["started_at"])
    attempts = read_lines(run / "attempts.jsonl")
    http_rows = read_lines(run / "http.jsonl")
    ends = [x for x in attempts if x.get("kind") == "attempt_end"]
    requests = [x for x in http_rows if x.get("kind") == "request"]
    responses = {x["request_id"]: x for x in http_rows if x.get("kind") == "response"}
    archives = sorted((run / "runner-logs").glob("archive_*"))
    archive = archives[0] if archives else run / "missing-archive"
    rounds, decisions, commands = [read_lines(archive / f) for f in
                                   ("rounds.jsonl", "decisions.jsonl", "commands.jsonl")]
    contexts = {}
    for attempt in ends:
        context_path = run / "attempts" / (attempt["attempt_id"] + ".context.json")
        if context_path.exists() and attempt["role"] == "strategy":
            contexts[attempt["attempt_id"]] = json.loads(context_path.read_text(encoding="utf-8"))
    strategy_ends = [x for x in ends if x["role"] == "strategy"]
    strategy_ticks = sorted(int(x.get("server_tick", 0)) for x in contexts.values())

    def tick_seconds(tick):
        if not rounds:
            return None
        nearest = min(rounds, key=lambda x: abs(int(x.get("server_tick", 0)) - int(tick)))
        return round(nearest.get("ts", start) - start, 1)

    def processed(attempt):
        context = contexts.get(attempt["attempt_id"], {})
        tick = int(context.get("server_tick", 0))
        next_tick = next((t for t in strategy_ticks if t > tick), 10 ** 18)
        return [x for x in decisions if tick <= int(x.get("server_tick", 0)) < next_tick
                and x.get("kind") in ("plan_hold", "plan_adopted", "plan_rejected",
                                       "strategy_result_rejected", "strategy_empty")]

    hold_empty = []
    for attempt in strategy_ends:
        result_path = run / "attempts" / (attempt["attempt_id"] + ".result.json")
        value = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
        context = contexts.get(attempt["attempt_id"], {})
        if (value.get("result") or {}).get("maintain_current") and not context.get("current_plan"):
            hold_empty.append(attempt["attempt_id"])
    adopted = [x for x in decisions if x.get("kind") == "plan_adopted"]
    stale = Counter(x.get("reason", "") for x in decisions if x.get("kind") == "strategy_result_rejected")
    sample_times = [x.get("ts", 0) for x in rounds]
    sample_gaps = [b - a for a, b in zip(sample_times, sample_times[1:])]
    lines = ["# AI 副官 10 分钟决策观察", "", "本报告来自真实本机模型与正常单人练习房。记录可核查的局势、模型可见结论和程序处理结果；不记录或推测隐藏思维链。", "",
             "- 运行状态：**%s**；请求 %.1f 秒，实际观察 %.3f 秒墙钟。" %
             (summary["status"], summary["requested_seconds"], summary.get("observed_seconds", 0)),
             "- 模式：`%s / tactics on / LangGraph / real`；模型 `minicpm5-adj-16k`。模型端口 `%s`，服务归属：%s。" %
             (summary["strategy_mode"], summary.get("ports", {}).get("ollama"),
              summary.get("model_service_ownership", "unknown")),
             "- 房间：1 名人类、其他槽位空。正常 Main → Play → Loading → Match；菜单回调自动化，**%s / command-level / 日志观察**。鼠标 UI 与对战收益未认证；录像覆盖以 video/observe.json 为准。" %
             ("headless" if summary.get("headless", True) else "后台独立窗口"),
             "- 用户电脑输入未接管，未录桌面；仅结束本轮有归属的进程。", "- 详细原件：%s；%s；%s。" %
             (link(run / "summary.json"), link(run / "model-calls.md"), link(archive, "原生副官留档")), ""]
    if summary.get("error"):
        lines += ["**中断原因：** " + summary["error"], ""]
    config = summary["model"]["parameters"]
    ctx = config.get("num_ctx", 16384)
    measured_tokens = [(r, (responses.get(r["request_id"], {}).get("usage") or {}).get("prompt_tokens"))
                       for r in requests]
    measured_tokens = [(r, n) for r, n in measured_tokens if isinstance(n, int)]
    lines += ["## 先看这几项", ""]
    if measured_tokens:
        lines += ["1. 实测输入最多 **%d token**；配置上下文 **%d token**。这局可以直接检查是否超预算，不能外推复杂战况或有效理解能力。" %
                  (max(n for _, n in measured_tokens), ctx)]
    lines += ["2. **%d 次**模型在输入 `current_plan=null` 时返回 `maintain_current=true`。对应调用：%s。图内的 `no_active_plan` 另有原始记录，不能把规则任务运行当成战略计划已存在。" %
              (len(hold_empty), ", ".join(hold_empty) or "无"),
              "3. 正式战略采纳 **%d 次**；首个采纳在 **%s 秒**。结果被丢弃的原因分布：`%s`。" %
              (len(adopted), tick_seconds(adopted[0]["server_tick"]) if adopted else "未发生", dict(stale)),
              "4. 战术遵循当前 `.env.local` 的 Laya → 2B → 规则链。战术调用数与 HTTP 请求数不同属于可能的正常分层，不能把 Laya 决策伪装成 2B 聊天输出。", "",
              "## 可以确认的统计", "", "| 项目 | 实测 |", "|---|---|",
              "| 模型角色调用完成记录 | %d（成功返回 %d；异常 %d） |" %
              (len(ends), sum(bool(x.get("ok")) for x in ends), sum(not x.get("ok") for x in ends)),
              "| HTTP 实际请求 / 已收到响应 | %d / %d |" % (len(requests), len(responses)),
              "| 世界轮次 / 决策记录 / 命令回执 | %d / %d / %d |" % (len(rounds), len(decisions), len(commands)),
              "| 模型文件参数上下文 | %s token（运行分配另见 model-ps；有效理解能力未测） |" % ctx,
              "| 产品源码变化 | %s |" % (cell(summary["source_changed"]) or "无"), ""]
    if rounds:
        lines += ["- 原生世界采样覆盖 %.3f 秒；最大相邻采样间隔 %.3f 秒。首末 tick %s → %s，未修改模拟速度。" %
                  (sample_times[-1] - sample_times[0], max(sample_gaps, default=0),
                   rounds[0].get("server_tick"), rounds[-1].get("server_tick")), ""]
    economic = None
    if strategy_ends:
        last_context = contexts.get(strategy_ends[-1]["attempt_id"], {})
        economic = (last_context.get("campaign") or {}).get("economy") or {}
        last_plan = last_context.get("current_plan") or {}
        lines += ["## 经济停滞与计划有效性：需要定点定位的事实", ""]
        if rounds:
            last_balance = rounds[-1].get("balance")
            same_since = len(rounds) - 1
            while same_since > 0 and rounds[same_since - 1].get("balance") == last_balance:
                same_since -= 1
            lines += ["- 余额 `%s → %s`；最后 **%.1f 秒**余额连续为 `%s`。自有单位 `%d → %d`。" %
                      (rounds[0].get("balance"), last_balance,
                       rounds[-1]["ts"] - rounds[same_since]["ts"], last_balance,
                       len(rounds[0].get("units") or []), len(rounds[-1].get("units") or []))]
        lines += ["- 最后一次战略输入中：矿车/工人 `%s`，矿场完工 `%s`，矿场交货 `%s`，首次交货完成 `%s`。" %
                  (economic.get("workers", "unknown"), economic.get("refinery_constructed", "unknown"),
                   economic.get("refinery_delivered", "unknown"), economic.get("first_delivery_done", "unknown")),
                  "- 最后一次战略输入的活动计划：`valid_until_tick=%s`；当时 `server_tick=%s`。" %
                  (last_plan.get("valid_until_tick", "unknown"), last_context.get("server_tick", "unknown")),
                  "- 这些是输入和世界记录中的事实。下一步应分别定位：里程碑是否过早完成；经济失败是否触发重规划；计划过期后为何仍维持；资源是否被其他支出耗尽。不能仅凭本局把原因归为上下文不足。", ""]
    lines += ["## 上下文是否承载得住", "", "这里使用服务端 usage.prompt_tokens，包含聊天模板与结构化输出提示的开销；输入文件的字节数单列。请求预算检查 = prompt_tokens + max_tokens 与模型 num_ctx 比较。未收到 usage 的请求标 unknown，不用字节数估算 token。", "",
              "| 角色 | 请求数 | 有 token 实测数 | 输入最小 / 最大 | 请求输出上限 | 超出配置预算次数 |",
              "|---|---:|---:|---|---|---:|"]
    for role in ("strategy", "tactics"):
        reqs = [x for x in requests if x["role"] == role]
        measured = [(x, (responses.get(x["request_id"], {}).get("usage") or {}).get("prompt_tokens")) for x in reqs]
        measured = [(x, n) for x, n in measured if isinstance(n, int)]
        limits = sorted({str(x.get("max_tokens")) for x in reqs})
        exceeded = sum(n + int(x.get("max_tokens") or 0) > ctx for x, n in measured)
        lines.append("| %s | %d | %d | %s | %s | %d |" % (role, len(reqs), len(measured),
                     "%d / %d" % (min(n for _, n in measured), max(n for _, n in measured)) if measured else "unknown",
                     ", ".join(limits), exceeded))
    lines += ["", "## 每分钟发生了什么", "", "| 分钟 | 调用：战略 / 战术 | 成功 / 异常 | 世界余额（首→末） | 自有单位（首→末） | 降级轮次 | 命令回执 |", "|---|---|---|---|---|---|---|"]
    for minute in range(max(1, int((summary.get("observed_seconds", 0) - 0.001) / 60 + 0.999))):
        low, high = start + minute * 60, start + (minute + 1) * 60
        calls = [x for x in ends if low <= x.get("started_at", 0) < high]
        worlds = [x for x in rounds if low <= x.get("ts", 0) < high]
        receipts = [x for x in commands if (lambda t: t is not None and minute * 60 <= t < (minute + 1) * 60)(
                    tick_seconds(x.get("server_tick", 0)))]
        balance = "%s → %s" % (worlds[0].get("balance"), worlds[-1].get("balance")) if worlds else "缺测"
        units = "%d → %d" % (len(worlds[0].get("units") or []), len(worlds[-1].get("units") or [])) if worlds else "缺测"
        lines.append("| %d–%d | %d / %d | %d / %d | %s | %s | %d | %d |" %
                     (minute, minute + 1, sum(x["role"] == "strategy" for x in calls),
                      sum(x["role"] == "tactics" for x in calls), sum(bool(x.get("ok")) for x in calls),
                      sum(not x.get("ok") for x in calls), balance, units,
                      sum(bool(x.get("degraded_reason")) for x in worlds), len(receipts)))
    details = ["# 每次模型调用索引", "", "可见输出原件保存在 response.json；应用层结果另在 attempts 中。返回了文本不代表验证通过或正式采纳。", "",
               "| 时间 | 角色 | 请求 | 延迟秒 | HTTP | 输入 / 输出 token | 输入字节 | 完整输入 | 可见输出 |",
               "|---|---|---|---:|---|---|---:|---|---|"]
    for req in requests:
        response = responses.get(req["request_id"], {})
        usage = response.get("usage") or {}
        details.append("| %.1fs | %s | %s | %s | %s | %s / %s | %d | %s | %s |" %
                       (req["started_at"] - start, req["role"], req["request_id"],
                        round(response["latency_s"], 3) if response else "unknown", response.get("status", "unknown"),
                        usage.get("prompt_tokens", "unknown"), usage.get("completion_tokens", "unknown"),
                        req["request_bytes"], link(req["request"], "输入"),
                        link(response["response"], "输出") if response else "未收到"))
    lines += ["", "## 逐次战略：它看到了什么、说了什么、程序怎么处理", "",
              "时间从接管首轮计；首个请求可能早于计时起点小于一秒。每次完整输入、输出均有链接。程序处理按本次请求 tick 到下次战略请求 tick 对齐；异常或区间不唯一时以原始记录为准。", "",
              "| 时间 / 调用 | 输入 token | 模型结论 | 程序处理 |",
              "|---|---:|---|---|"]
    strategy_details = ["# 逐次战略详情", "", "模型可见说明按原样记录；不是内部隐藏思维链。程序处理单列，不把模型提议冒充正式采纳。", ""]
    for attempt in strategy_ends:
        ident = attempt["attempt_id"]
        result_path = run / "attempts" / (ident + ".result.json")
        context_path = run / "attempts" / (ident + ".context.json")
        result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
        context = contexts.get(ident, {})
        value = result.get("result") or {}
        related = [r for r in requests if r["role"] == "strategy" and
                   abs(r["started_at"] - attempt["started_at"]) < 1.0]
        tokens = [(responses.get(r["request_id"], {}).get("usage") or {}).get("prompt_tokens") for r in related]
        conclusion = ("维持计划；" if value.get("maintain_current") else "提议计划；") + str(value.get("rationale") or value.get("phase_goal") or "")
        if not attempt.get("ok"):
            conclusion = str(attempt.get("error_type")) + "；" + str(attempt.get("error"))
        handling = processed(attempt)
        lines += ["| %.1fs · %s | %s | %s | %s |" %
                  (attempt["started_at"] - start, link(result_path if result_path.exists() else context_path, ident),
                   cell(tokens or "unknown"), cell(conclusion, 260),
                   cell("；".join(x["kind"] + ":" + str(x.get("reason", "")) for x in handling) or "未见处理记录", 240))]
        strategy_details += ["## %.1fs · %s · %s" % (attempt["started_at"] - start, ident,
                   "成功返回" if attempt.get("ok") else "调用异常"), "",
                  "- 输入：%s；耗时 %.3fs；程序处理：`%s`。" %
                  (link(context_path, "完整战略局势"), attempt["latency_s"], cell(handling, 1200)),
                  "- 当前阶段：`%s`；前沿：`%s`；活动计划存在：`%s`；输入 server_tick=`%s`。" %
                  ((context.get("campaign") or {}).get("phase"), (context.get("campaign") or {}).get("frontier"),
                   bool(context.get("current_plan")), context.get("server_tick"))]
        if attempt.get("error"):
            strategy_details += ["- 异常：" + cell(attempt["error"], 1400)]
        else:
            strategy_details += ["- 应用层结果：%s。" % link(result_path, "完整计划 / 选择元数据"), "", "```json",
                      json.dumps(result, ensure_ascii=False, indent=2), "```"]
        strategy_details += [""]
    errors = Counter(x.get("error_type", "unknown") for x in ends if not x.get("ok"))
    degraded = Counter(str(x.get("degraded_reason")) for x in rounds if x.get("degraded_reason"))
    receipts = Counter(str(x.get("status")) for x in commands)
    lines += ["## 已观察现象与定位入口", "", "- 模型调用异常分布：`%s`。" % dict(errors),
              "- 降级原因与轮次：`%s`。" % dict(degraded), "- 命令回执状态：`%s`；Accepted/PendingAuthority 不能直接证明位移、建造或采矿完成。" % dict(receipts),
              "- 分析顺序：先看真实输入是否在预算内，再核关键事实是否存在，再看模型输出是否有效 / 新鲜 / 采纳，最后核权威回执与世界变化。",
              "- 单人练习房没有敌人，本次不能判定复杂敌情、战斗策略或跨图泛化能力；上下文不超窗也不证明战略正确。", "",
              "- 逐次详细模型说明和完整计划：%s。" % link(run / "strategy-details.md"), "",
              "## 收尾与证据限制", "", "- 源码冻结：%s → %s。" % (link(run / "source-before.json"), link(run / "source-after.json")),
              "- 进程身份与实际 OS 退出码：%s；强制清理单列，进程 quit 不冒充正常菜单退局测试。" % link(run / "cleanup.json"),
              "- 模型实际驻留状态：%s / %s。" % (link(run / "model-ps-start.json"), link(run / "model-ps-end.json")),
              "- 原件使用本轮独立目录；详细输入按调用保存，没有把图历史存储与实际模型上下文混为一谈。",
              "- 这次交付观察程序和诊断材料；产品 champion、默认战略及先前未验证项保持原状态。", ""]
    truncated = []
    for req in requests:
        response = responses.get(req["request_id"])
        if not response:
            continue
        value = json.loads(Path(response["response"]).read_text(encoding="utf-8"))
        if any(c.get("finish_reason") == "length" for c in value.get("choices") or []):
            truncated.append({"request_id": req["request_id"], "requested_output_tokens": req.get("max_tokens"),
                              "actual_completion_tokens": (response.get("usage") or {}).get("completion_tokens"),
                              "request": req["request"], "response": response["response"]})
    lines += ["## 输出截断与收尾门禁", "", "- `finish_reason=length` 的原始响应：`%s`。模型文件 num_predict=`%s`。请求上限、实际输出和部署参数分别记录，是否参数覆盖需单独复验。" %
              (cell(truncated, 2200), config.get("num_predict", "unknown")),
              "- runner 正常退出等待超时：`%s`；实际 OS 退出码与强制清理：`%s`。退出日志中的 code=0 不能替代 OS 句柄退出码。" %
              (summary.get("runner_stop_timeout", False),
               cell([{k: x.get(k) for k in ("name", "os_returncode", "forced", "alive")} for x in summary.get("cleanup", [])], 2200)),
              "- stderr、租约写入告警、采样间隙和进程退出限制都保留原件；完整 600 秒观察不代表收尾与产品行为全绿。", ""]
    pending = [x for x in attempts if x.get("kind") == "attempt_start" and
               x["attempt_id"] not in {e["attempt_id"] for e in ends}]
    audit = {"requests": len(requests), "responses": len(responses), "attempts_completed": len(ends),
             "attempts_without_end": [x["attempt_id"] for x in pending],
             "strategy_adoptions": len(adopted), "first_adoption_s":
             tick_seconds(adopted[0]["server_tick"]) if adopted else None,
             "hold_without_active_plan": hold_empty, "strategy_rejected_reasons": dict(stale),
             "last_strategy_economy": economic, "raw_world_rounds": len(rounds),
             "max_world_gap_s": max(sample_gaps, default=None), "output_truncation": truncated}
    write_json(run / "analysis.json", audit)
    (run / "report.md").write_text("\n".join(lines), encoding="utf-8")
    (run / "model-calls.md").write_text("\n".join(details) + "\n", encoding="utf-8")
    (run / "strategy-details.md").write_text("\n".join(strategy_details) + "\n", encoding="utf-8")
    tactics = ["# 逐次战术选择", "", "保留每次输入、Laya 可见选择及应用层输出；返回成功不等于正式下发或实际执行成功。", "",
               "| 秒数 | 调用 | 延迟秒 | Laya 选择 | 意图数 | 状态 | 输入 | 输出 |",
               "|---|---|---:|---|---:|---|---|---|"]
    for attempt in (x for x in ends if x["role"] == "tactics"):
        ident = attempt["attempt_id"]
        result_path = run / "attempts" / (ident + ".result.json")
        value = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
        laya = value.get("laya") or {}
        choice = {k: laya[k] for k in ("event", "task", "actor", "target", "confidence") if k in laya}
        tactics.append("| %.1f | %s | %.3f | %s | %d | %s | %s | %s |" %
                       (attempt["started_at"] - start, ident, attempt["latency_s"], cell(choice, 400),
                        len((value.get("result") or {}).get("intents") or []),
                        "返回成功" if attempt.get("ok") else cell(attempt.get("error"), 500),
                        link(run / "attempts" / (ident + ".context.json"), "输入帧"),
                        link(result_path, "完整结果") if result_path.exists() else "异常"))
    (run / "tactics-decisions.md").write_text("\n".join(tactics) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    observe_parser = sub.add_parser("observe")
    observe_parser.add_argument("--seconds", type=float, default=600)
    observe_parser.add_argument("--background-window", action="store_true",
                                help="Record the owned offscreen window without taking focus or OS input")
    observe_parser.add_argument("--output", default="")
    observe_parser.add_argument("--map", default="res://source/match/maps/PlainAndSimple.tscn")
    observe_parser.add_argument("--seed", type=int, default=11)
    observe_parser.add_argument("--model-port", type=int, default=0,
                                help="Reuse an existing local model service without owning/stopping it")
    observe_parser.add_argument("--strategy-mode", choices=("plan", "choice", "template", "score"), default="plan")
    child = sub.add_parser("runner-child")
    child.add_argument("--run", type=Path, required=True)
    child.add_argument("runner_args", nargs=argparse.REMAINDER)
    renderer = sub.add_parser("report")
    renderer.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "runner-child":
        return runner_child(args.run, args.runner_args[1:] if args.runner_args[:1] == ["--"] else args.runner_args)
    if args.command == "report":
        report(args.run)
        return 0
    if not 1 <= args.seconds <= 3600:
        parser.error("--seconds must be in [1, 3600]")
    return observe(args)


if __name__ == "__main__":
    sys.exit(main())
