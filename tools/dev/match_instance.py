#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本机对局实例工具（2026-09-29）：多开单人对局 + 从根上不留僵尸局。

一句话：**端口动态分配、实例登记发现、清理只按进程树**。

## 为什么不是"再加一段预留端口"

`config/dev_ports.json` 的预留段是**有限**的：两路会话就要互相抢（2026-09-13 血案：
验收与并行会话同挂一个权威口，收尾还互相按端口杀）。本工具改用三条:

1. **端口**：从口径表的 `dynamic_dev` 段里**实测**挑一段连续空闲块（TCP+UDP 都试绑），
   多路会话天然不撞；玩家/面板/验收预留段原样保留，谁都不碰。
2. **发现**：拉起游戏时设 `AIRTS_INSTANCE_DIR` / `AIRTS_INSTANCE` / `AIRTS_PARENT_PID`，
   游戏侧 `MatchInstanceRegistry.gd` 把 pid / 角色 / **实际监听端口** / 心跳写进登记文件。
   本工具**读登记**等就绪、取端口 —— 永远连到自己那一局，不猜端口
   （2026-09-28 实测过：测试脚本"秒连"成功，其实连上了并行会话的客户端）。
3. **清理**：一律 `taskkill /PID <pid> /T /F`（进程树），**绝不按端口杀**。另外游戏侧
   看门狗在启动器死后会自退，所以本工具哪怕崩了，也不会在桌面上留"僵尸局"。
4. **兜底**：`reap` 扫登记目录 —— "pid 已死"的残留登记直接删，"pid 还活着但心跳过期"的
   僵尸按 pid 杀掉；只看登记，不做任何端口推断。

## CLI

    python tools/dev/match_instance.py ls                  # 列出登记（live/zombie/stale）
    python tools/dev/match_instance.py reap [--dry-run]    # 清僵尸（只按 pid）+ 删残留登记
    python tools/dev/match_instance.py ports [-n 3]        # 打印一段空闲端口块

## 库用法（推荐给所有新的对局验证脚本）

    from match_instance import MatchGroup

    with MatchGroup(prefix="probe") as group:
        group.launch_server()
        group.launch_client()
        group.wait_ready()                 # 两边登记都到 controllable
        group.start_match(with_ai=False)
        group.wait_match()                 # 服务端 status 出现单位
        print(group.server.dcs({"op": "status"}))
    # 退出即：按 pid 树清理 + 断言无残留

兼容既有约定：端口偏移 +0（游戏 UDP）/ +1（客户端 DCS）/ +3（服务端 DCS），
与口径表里的 `accept_parallel`（24609/24610/24612）同构；也可 `MatchGroup(base=24609)`
显式指定预留段（给必须用固定段的老流程留后门）。
"""

from __future__ import annotations

import argparse
import atexit
import glob
import json
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))          # AI_RTS
WORKSPACE = os.path.dirname(PROJECT)                       # G:/AIRTS
REGISTRY_JSON = os.path.join(PROJECT, "config", "dev_ports.json")
DEFAULT_REGISTRY_DIR = os.path.join(WORKSPACE, "tmp_logs", "instances")
DEFAULT_LOG_DIR = os.path.join(DEFAULT_REGISTRY_DIR, "logs")
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
## 进程内已分配的端口块（见 allocate_ports 的注释）+ 分配序号（把起点打散）。
_LOCAL_RESERVATIONS = set()
_ALLOC_SEQ = 0


# --------------------------------------------------------------------------- 口径


def registry_json() -> dict:
    """端口/实例口径表（**唯一事实来源**，见 config/dev_ports.json 的 _readme）。"""
    with open(REGISTRY_JSON, encoding="utf-8") as handle:
        return json.load(handle)


def port_offsets() -> dict:
    return dict(registry_json().get("instances", {}).get(
        "port_offsets", {"game": 0, "client_dcs": 1, "server_dcs": 3}))


def dynamic_range() -> tuple:
    blocks = registry_json()["reserved_blocks"]
    if "dynamic_dev" not in blocks:
        raise RuntimeError("口径表缺少 dynamic_dev 段（多开对局的动态端口段）")
    low, high = blocks["dynamic_dev"]
    return int(low), int(high)


def reserved_ports() -> set:
    """一切**已有归属**的端口：角色、面板候选、禁列表、各预留段（不含动态段）。"""
    data = registry_json()
    used = set(int(value) for value in data["roles"].values())
    used |= set(int(value) for value in data.get("panel", {}).get("authority_candidates", []))
    used |= set(int(value) for value in data.get("forbidden_for_acceptance", []))
    for name, block in data["reserved_blocks"].items():
        if str(name).startswith("_") or name == "dynamic_dev":
            continue
        low, high = block
        used |= set(range(int(low), int(high) + 1))
    return used


def registry_dir() -> str:
    return os.environ.get("AIRTS_INSTANCE_DIR") or DEFAULT_REGISTRY_DIR


PARENT_LEASE_DIRNAME = "parents"


class ParentLease:
    """启动器租约：给游戏侧看门狗的"我还活着"心跳文件。

    为什么不用 pid 判活：Godot 的 `OS.is_process_running` 只认**它自己 create_process
    出来的子进程**，对外部启动器的 pid 永远返回 false（2026-09-29 实测：驱动活得好好的，
    游戏却立刻判"启动器已退出"并自退）。租约文件还能覆盖"启动器卡死"这种情况。

    文件：`<登记目录>/parents/parent-<本进程 pid>.json`，每 2s 刷新 `heartbeat_at`；
    本进程退出（含被强杀）后文件不再更新 ⇒ 游戏侧过期即自退。
    """

    def __init__(self, directory: str = "", interval: float = 2.0):
        self.path = os.path.join(directory or registry_dir(), PARENT_LEASE_DIRNAME,
                                 "parent-%d.json" % os.getpid())
        self.interval = interval
        self._thread = None
        self._stop = threading.Event()

    def start(self) -> "ParentLease":
        if self._thread is not None:
            return self
        self._write()
        self._thread = threading.Thread(target=self._loop, name="AIRTS-parent-lease", daemon=True)
        self._thread.start()
        atexit.register(self.stop)
        return self

    def _write(self) -> None:
        directory = os.path.dirname(self.path)
        os.makedirs(directory, exist_ok=True)
        payload = {"pid": os.getpid(), "heartbeat_at": time.time(),
                   "program": sys.argv[0] if sys.argv else ""}
        tmp = "%s.tmp" % self.path
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, self.path)

    def _loop(self) -> None:
        while not self._stop.wait(self.interval):
            try:
                self._write()
            except Exception as exc:  # noqa: BLE001
                # **绝不能静默退出**：线程一死，游戏侧就会判"启动器已挂"并自退整局。
                print("[match_instance] 租约刷新失败：%r" % exc, file=sys.stderr, flush=True)

    def stop(self) -> None:
        self._stop.set()
        try:
            os.remove(self.path)
        except OSError:
            pass


_LEASES = {}


def ensure_parent_lease(directory: str = "") -> ParentLease:
    """保证本进程的租约在刷新（同一登记目录只起一个线程）。"""
    key = directory or registry_dir()
    lease = _LEASES.get(key)
    if lease is None:
        lease = ParentLease(key).start()
        _LEASES[key] = lease
    return lease


def godot_exe() -> str:
    """Godot 可执行文件：环境变量 AIRTS_GODOT > 工程旁的 godot_mono_471 > PATH。"""
    override = os.environ.get("AIRTS_GODOT")
    if override and os.path.exists(override):
        return override
    patterns = [
        os.path.join(WORKSPACE, "godot_mono_471", "Godot_v*_mono_win64", "*_console.exe"),
        os.path.join(PROJECT, "godot_mono_471", "Godot_v*_mono_win64", "*_console.exe"),
        os.path.join(WORKSPACE, "godot_mono_471", "*", "*mono*_console.exe"),
    ]
    for pattern in patterns:
        found = sorted(glob.glob(pattern))
        if found:
            return found[-1]
    import shutil
    for name in ("godot", "godot4"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("找不到 Godot 可执行文件：设 AIRTS_GODOT 或放好 godot_mono_471/")


# ------------------------------------------------------------------- 端口与进程


def port_free(port: int) -> bool:
    """TCP(127.0.0.1) 与 UDP(0.0.0.0) 都必须能绑上（游戏 UDP 绑通配、DCS 绑回环）。"""
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        host = "127.0.0.1" if kind == socket.SOCK_STREAM else "0.0.0.0"
        probe = socket.socket(socket.AF_INET, kind)
        try:
            probe.bind((host, port))
        except OSError:
            return False
        finally:
            probe.close()
    return True


def allocate_ports(base: int = 0, span: int = 4) -> dict:
    """挑一段空闲端口块。显式 base 时只校验（不满足就抛）；否则从动态段里找。

    返回 {"base", "game", "client_dcs", "server_dcs"}；偏移来自口径表。
    """
    offsets = port_offsets()
    need = sorted(set(offsets.values()))
    reserved = reserved_ports()

    def usable(candidate: int) -> bool:
        # 进程内预留：同一驱动进程连开两局时，端口还没被游戏绑上就要先占住，
        # 否则第二次分配会拿到同一个块（2026-09-29 验证驱动实测抓到的 bug）。
        if candidate in _LOCAL_RESERVATIONS:
            return False
        for delta in need:
            port = candidate + delta
            if port in reserved or not port_free(port):
                return False
        return True

    if base:
        if not usable(base):
            raise RuntimeError("指定的基端口 %d 不可用（被占用或落在预留段内）" % base)
        _LOCAL_RESERVATIONS.add(base)
        return _block(base, offsets)

    low, high = dynamic_range()
    width = high - low + 1
    # 起点按 pid + 分配序号打散，避免多路会话/同一进程连开多局时扫同一段。
    global _ALLOC_SEQ
    start_offset = (os.getpid() * 7 + _ALLOC_SEQ * 37) % max(1, width - span)
    for step in range(width - span):
        candidate = low + ((start_offset + step) % (width - span))
        if candidate in reserved:
            continue
        if candidate + span - 1 > high:
            continue
        if usable(candidate):
            _ALLOC_SEQ += 1
            _LOCAL_RESERVATIONS.add(candidate)
            return _block(candidate, offsets)
    raise RuntimeError("动态段 %d-%d 内找不到 %d 个连续空闲端口" % (low, high, span))


def release_ports(block: dict) -> None:
    """归还进程内预留（实例收尾后调用；跨进程的占用由实际绑定兜底）。"""
    if block:
        _LOCAL_RESERVATIONS.discard(int(block.get("base", 0)))


def _block(base: int, offsets: dict) -> dict:
    return {
        "base": base,
        "game": base + int(offsets["game"]),
        "client_dcs": base + int(offsets["client_dcs"]),
        "server_dcs": base + int(offsets["server_dcs"]),
    }


def is_pid_running(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            # 中文 Windows 的 tasklist 输出是 GBK：UTF-8 模式的 venv 解码会炸
            # （UnicodeDecodeError 0xd0），errors="replace" 保住 ASCII 的 PID 匹配。
            out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"],
                                 capture_output=True, text=True,
                                 errors="replace").stdout
        except OSError:
            return False
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def kill_tree(pid: int, timeout: float = 15.0) -> bool:
    """按**进程树**杀（绝不按端口）。返回是否确认已退出。"""
    if pid <= 0 or not is_pid_running(pid):
        return True
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not is_pid_running(pid):
            return True
        time.sleep(0.3)
    return not is_pid_running(pid)


def tcp_call(port: int, payload: dict, timeout: float = 30.0, host: str = "127.0.0.1") -> dict:
    """DCS 的裸 TCP 一行 JSON 协议。

    实现与项目里已验证的客户端同源（`tmp_logs/dcs/dcs.py` ← `e2e_dual_layer.py`）：
    Godot 侧回包**可能带 32 位长度前缀**，所以不能按"行首"解析，而要从第一个 `{`
    起截到其后的换行。2026-09-29 实测：按行首解析 → JSON 解析失败 → 只拿到
    `{"raw": ...}` → wait_match 假红"对局未就绪"。
    """
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        buffer = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
            start = buffer.find(b"{")
            end = buffer.find(b"\n", start + 1)
            if start >= 0 and end > start:
                return json.loads(buffer[start:end].decode("utf-8", errors="replace"))
    raise TimeoutError("DCS 无响应：op=%s port=%d" % (payload.get("op"), port))


# --------------------------------------------------------------------- 实例登记


def record_path(name: str, directory: str = "") -> str:
    return os.path.join(directory or registry_dir(), "%s.json" % name)


def read_record(name: str, directory: str = "") -> dict:
    path = record_path(name, directory)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (ValueError, OSError):
        return {}


def list_instances(directory: str = "", stale_after: float = 20.0) -> list:
    """登记目录里的实例分类：live（活着且心跳新）/ zombie（活着但心跳过期）/ stale（pid 已死）。"""
    directory = directory or registry_dir()
    now = time.time()
    result = []
    if not os.path.isdir(directory):
        return result
    for file_name in sorted(os.listdir(directory)):
        if not file_name.endswith(".json"):
            continue
        path = os.path.join(directory, file_name)
        try:
            with open(path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (ValueError, OSError):
            continue
        pid = int(record.get("pid", 0))
        age = now - float(record.get("heartbeat_at", 0))
        if not is_pid_running(pid):
            state = "stale"
        elif age > stale_after:
            state = "zombie"
        else:
            state = "live"
        record["_state"] = state
        record["_heartbeat_age_s"] = round(age, 1)
        record["_path"] = path
        result.append(record)
    return result


def list_parent_leases(directory: str = "", stale_after: float = 20.0) -> list:
    """启动器租约的分类：live（活着且心跳新）/ hung（活着但心跳过期）/ stale（pid 已死）。

    为什么要单独管：启动器被 `taskkill /F` 强杀时来不及跑 atexit，租约文件会留下。
    游戏侧**不能**删别人的租约（它无法可靠判定外部 pid 存活，见 MatchInstanceRegistry），
    所以这份清理只能由本工具（Python 能可靠查 pid）兜底。
    """
    directory = directory or registry_dir()
    lease_dir = os.path.join(directory, PARENT_LEASE_DIRNAME)
    result = []
    if not os.path.isdir(lease_dir):
        return result
    now = time.time()
    for file_name in sorted(os.listdir(lease_dir)):
        if not file_name.endswith(".json"):
            continue
        path = os.path.join(lease_dir, file_name)
        try:
            with open(path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (ValueError, OSError):
            record = {}
        pid = int(record.get("pid", 0))
        age = now - float(record.get("heartbeat_at", 0))
        if not is_pid_running(pid):
            state = "stale"
        elif age > stale_after:
            state = "hung"
        else:
            state = "live"
        result.append({"path": path, "pid": pid, "state": state,
                       "heartbeat_age_s": round(age, 1),
                       "program": str(record.get("program", ""))})
    return result


def reap(directory: str = "", dry_run: bool = False, stale_after: float = 20.0,
         name_prefix: str = "", keep: int = 0) -> dict:
    """清僵尸：**按 pid** 杀（zombie）+ 删残留登记（stale）。绝不动 live。

    keep>0 时按实例名排序保留最新的 N 个（用于"只清我自己的旧实例"）。
    """
    directory = directory or registry_dir()
    actions = {"killed": [], "removed": [], "kept": [], "leases_removed": [], "leases_hung": []}
    items = [record for record in list_instances(directory, stale_after)
             if not name_prefix or str(record.get("instance", "")).startswith(name_prefix)]
    stale = [item for item in items if item["_state"] == "stale"]
    zombies = [item for item in items if item["_state"] == "zombie"]
    if keep > 0:
        # keep=0（默认）时**全清**；只有显式 keep>0 才保留最新的 N 个。
        zombies = (sorted(zombies, key=lambda item: item.get("started_at", 0))[:-keep]
                   if len(zombies) > keep else [])
    for record in stale:
        actions["removed"].append(record["instance"])
        if not dry_run:
            try:
                os.remove(record["_path"])
            except OSError:
                pass
    for record in zombies:
        actions["killed"].append({"instance": record["instance"], "pid": record.get("pid")})
        if not dry_run:
            kill_tree(int(record.get("pid", 0)))
            try:
                os.remove(record["_path"])
            except OSError:
                pass
    # 启动器租约：被 taskkill /F 强杀的启动器来不及跑 atexit，文件会留下。
    # 只删"pid 已死"的（确定是垃圾）；"pid 活着但心跳过期"只报告 —— 那个 pid 可能已被
    # 系统复用给无关进程，据它杀进程风险太大（宁可让人看一眼）。
    for lease in list_parent_leases(directory, stale_after):
        if lease["state"] == "stale":
            actions["leases_removed"].append(os.path.basename(lease["path"]))
            if not dry_run:
                try:
                    os.remove(lease["path"])
                except OSError:
                    pass
        elif lease["state"] == "hung":
            actions["leases_hung"].append({"pid": lease["pid"],
                                           "heartbeat_age_s": lease["heartbeat_age_s"],
                                           "program": lease["program"]})
    return actions


# ------------------------------------------------------------------ 实例生命周期


class Instance:
    """一个游戏进程（专用服或客户端），带登记发现与按 pid 清理。"""

    def __init__(self, role: str, name: str, ports: dict, extra_args=None,
                 log_dir: str = "", env_extra=None, directory: str = ""):
        self.role = role                      # "server" | "client"
        self.name = name
        self.ports = ports
        self.extra_args = list(extra_args or [])
        self.log_dir = log_dir or DEFAULT_LOG_DIR
        self.directory = directory or registry_dir()
        self.env_extra = dict(env_extra or {})
        self.process = None
        self._out = None
        self._err = None

    # -- 启动 ---------------------------------------------------------------
    def argv(self) -> list:
        if self.role == "server":
            cmd = [godot_exe(), "--headless", "--path", PROJECT, "--",
                   "--server", "--port", str(self.ports["game"]),
                   "--debugport", str(self.ports["server_dcs"])]
        else:
            cmd = [godot_exe(), "--path", PROJECT, "--position", "-4000,-4000", "--",
                   "--debugport", str(self.ports["client_dcs"]),
                   "--autojoin", "--autojoin-lobby",
                   "--smokehost", "127.0.0.1", "--smokeport", str(self.ports["game"])]
        return cmd + self.extra_args

    def env(self) -> dict:
        env = os.environ.copy()
        env["AIRTS_INSTANCE_DIR"] = self.directory
        env["AIRTS_INSTANCE"] = self.name
        env["AIRTS_PARENT_PID"] = str(os.getpid())
        env.setdefault("AIRTS_INSTANCE_STALE_S", "20")
        env["PYTHONIOENCODING"] = "utf-8"
        env.update(self.env_extra)
        return env

    def launch(self) -> "Instance":
        os.makedirs(self.log_dir, exist_ok=True)
        os.makedirs(self.directory, exist_ok=True)
        # 先起租约（游戏侧看门狗靠它判活）：本进程一死，租约过期，游戏自退。
        ensure_parent_lease(self.directory)
        # 同名的旧登记先删：保证接下来读到的登记**一定**属于本次启动的进程。
        stale_path = record_path(self.name, self.directory)
        if os.path.exists(stale_path):
            os.remove(stale_path)
        self._out = open(os.path.join(self.log_dir, "%s.out.log" % self.name), "w",
                         encoding="utf-8", errors="replace")
        self._err = open(os.path.join(self.log_dir, "%s.err.log" % self.name), "w",
                         encoding="utf-8", errors="replace")
        self.process = subprocess.Popen(self.argv(), cwd=PROJECT, env=self.env(),
                                        stdout=self._out, stderr=self._err,
                                        creationflags=CREATE_NO_WINDOW)
        return self

    @property
    def pid(self) -> int:
        """Popen 拿到的 pid（Windows 上是 `*_console.exe` 包装进程）。"""
        return self.process.pid if self.process else 0

    @property
    def game_pid(self) -> int:
        """**真正跑游戏**的 pid：登记里自报的那个（没登记时退回包装 pid）。"""
        return int(self.record().get("pid", 0)) or self.pid

    # -- 观测 ---------------------------------------------------------------
    def record(self) -> dict:
        return read_record(self.name, self.directory)

    def wait_controllable(self, timeout: float = 180.0) -> dict:
        """等游戏侧登记到 `controllable`（调试口已监听）。这一步就是"永远连到自己那一局"的把关。

        ⚠ 身份校验**不能比 pid 相等**：Windows 上 `*_console.exe` 是包装进程，真正跑游戏的
        是它的子进程（2026-09-29 验证驱动实测：console 包装 pid=26872，游戏自报 pid=23980）。
        所以判据用登记里的 `parent_pid == 本进程`（游戏侧写的就是启动器 pid），
        加上"启动前先删同名旧登记"，两头合起来保证读到的就是**本次**拉起的实例。
        """
        if self.process is None:
            raise RuntimeError("%s 还没有启动（先调用 launch_server/launch_client）" % self.name)
        deadline = time.time() + timeout
        last_phase = ""
        while time.time() < deadline:
            record = self.record()
            if self.pid and not is_pid_running(self.game_pid) and not record:
                raise RuntimeError("%s 进程已退出（包装 pid=%d），日志尾部：%s"
                                   % (self.name, self.pid, self.log_tail()))
            if record:
                last_phase = str(record.get("phase", ""))
                parent = int(record.get("parent_pid", -1))
                if parent not in (0, os.getpid()):
                    raise RuntimeError("%s 的登记属于别的启动器（parent_pid=%s，本次 pid=%d）"
                                       % (self.name, parent, os.getpid()))
                if last_phase == "controllable" and int(record.get("dcs_port", 0)) > 0:
                    return record
                if last_phase in ("dcs_down", "launcher_gone"):
                    raise RuntimeError("%s 无法调试控制（phase=%s, dcs_error=%s），日志尾部：%s"
                                       % (self.name, last_phase, record.get("dcs_error"), self.log_tail()))
            time.sleep(0.5)
        raise RuntimeError("%s 在 %.0fs 内没到 controllable（最后 phase=%s）" % (self.name, timeout, last_phase))

    @property
    def dcs_port(self) -> int:
        record = self.record()
        port = int(record.get("dcs_port", 0))
        if port:
            return port
        return int(self.ports["server_dcs"] if self.role == "server" else self.ports["client_dcs"])

    def dcs(self, payload: dict, timeout: float = 30.0) -> dict:
        return tcp_call(self.dcs_port, payload, timeout=timeout)

    def log_tail(self, lines: int = 12) -> str:
        path = os.path.join(self.log_dir, "%s.out.log" % self.name)
        if not os.path.exists(path):
            return "(无日志)"
        with open(path, encoding="utf-8", errors="replace") as handle:
            return "\n".join(handle.read().splitlines()[-lines:])

    # -- 收尾 ---------------------------------------------------------------
    def stop(self) -> bool:
        """按**进程树**收尾：包装进程与登记自报的游戏进程都杀（都带 /T），绝不按端口。"""
        game_pid = int(self.record().get("pid", 0))
        ok = kill_tree(self.pid)
        if game_pid and game_pid != self.pid:
            ok = kill_tree(game_pid) and ok
        for handle in (self._out, self._err):
            try:
                if handle:
                    handle.close()
            except OSError:
                pass
        # 登记文件必须消失：进程被硬杀时游戏来不及自清，这里按"pid 已死"补删。
        path = record_path(self.name, self.directory)
        if os.path.exists(path):
            record = read_record(self.name, self.directory)
            if not is_pid_running(int(record.get("pid", 0))):
                try:
                    os.remove(path)
                except OSError:
                    pass
        return ok


class MatchGroup:
    """一组对局实例（专用服 + 客户端）的生命周期，含动态端口与开局。

    ```python
    with MatchGroup(prefix="probe") as group:
        group.launch_server(); group.launch_client()
        group.wait_ready(); group.start_match(); group.wait_match()
    ```
    """

    def __init__(self, prefix: str = "match", base: int = 0, log_dir: str = "",
                 server_args=None, client_args=None, directory: str = "",
                 stale_after: float = 20.0):
        self.prefix = prefix
        self.ports = allocate_ports(base=base)
        self.log_dir = log_dir or os.path.join(DEFAULT_LOG_DIR, prefix)
        self.directory = directory or registry_dir()
        self.stale_after = stale_after
        self.suffix = "%d" % (os.getpid() % 100000)
        self.server = Instance("server", "%s-server-%s" % (prefix, self.suffix), self.ports,
                               extra_args=server_args, log_dir=self.log_dir,
                               directory=self.directory)
        self.client = Instance("client", "%s-client-%s" % (prefix, self.suffix), self.ports,
                               extra_args=client_args, log_dir=self.log_dir,
                               directory=self.directory)

    # -- 生命周期 -----------------------------------------------------------
    def __enter__(self) -> "MatchGroup":
        return self

    def __exit__(self, *_exc) -> bool:
        self.close()
        return False

    def launch_server(self) -> Instance:
        return self.server.launch()

    def launch_client(self) -> Instance:
        return self.client.launch()

    def wait_ready(self, timeout: float = 240.0) -> tuple:
        """等**已启动**的实例登记到 controllable（只等真的拉起来的那些）。"""
        server = self.server.wait_controllable(timeout) if self.server.process else {}
        client = self.client.wait_controllable(timeout) if self.client.process else {}
        return server, client

    def start_match(self, with_ai: bool = False, timeout: float = 180.0) -> dict:
        """让客户端请求开局；`not networked` 时重试（连接是异步的）。"""
        deadline = time.time() + timeout
        last = {}
        while time.time() < deadline:
            try:
                last = self.client.dcs({"op": "start", "with_ai": with_ai}, timeout=20)
            except OSError:
                time.sleep(2)
                continue
            if last.get("error") == "not networked":
                time.sleep(2)
                continue
            if last.get("error"):
                raise RuntimeError("开局被拒：%s" % last)
            return last
        raise RuntimeError("开局超时（最后回复 %s）" % last)

    def wait_match(self, timeout: float = 180.0, min_units: int = 1) -> dict:
        """等服务端权威 status 里出现单位（对局真的跑起来了）。"""
        deadline = time.time() + timeout
        status = {}
        while time.time() < deadline:
            try:
                status = self.server.dcs({"op": "status"}, timeout=15)
            except OSError:
                time.sleep(2)
                continue
            if status.get("match") and len(status.get("units", [])) >= min_units:
                return status
            time.sleep(2)
        raise RuntimeError("对局未就绪（最后 status 键 %s）" % sorted(status.keys()))

    def human_name(self, status: dict = None) -> str:
        status = status or self.server.dcs({"op": "status"})
        humans = [player.get("name") for player in status.get("players", []) if player.get("human")]
        return humans[0] if humans else "Player_0"

    def close(self) -> list:
        """按 pid 树收尾（客户端先、专用服后），归还端口预留，返回未退干净的实例名。"""
        leftovers = []
        for instance in (self.client, self.server):
            if instance.process is not None and not instance.stop():
                leftovers.append(instance.name)
        release_ports(self.ports)
        return leftovers


# ------------------------------------------------------------------------- CLI


def _cmd_selftest(args) -> int:
    """完全无人化自检（2026-09-29）：一条命令验证"能真开局、能下命令、能取证、能清场"。

    全程零人工决策：不挑端口（动态分配）、不猜连接（读实例登记）、清理必做（按 pid 树）。
    退出码 0 = 全部断言通过。给 AI coding 工具/交接用：跑这一条就够。
    """
    started = time.time()
    log_dir = os.path.join(DEFAULT_LOG_DIR, "selftest")
    checks = []

    def check(cond, label):
        print("[SELFTEST] %s %s" % ("PASS" if cond else "FAIL", label), flush=True)
        checks.append(bool(cond))
        return bool(cond)

    group = MatchGroup(prefix="selftest", log_dir=log_dir)
    print("[SELFTEST] 端口块 base=%d（游戏 %d / 客户端 DCS %d / 服务端 DCS %d）"
          % (group.ports["base"], group.ports["game"],
             group.ports["client_dcs"], group.ports["server_dcs"]), flush=True)
    try:
        group.launch_server()
        group.launch_client()
        server_record, _client_record = group.wait_ready()
        check(int(server_record.get("dcs_port", 0)) == group.ports["server_dcs"],
              "两侧实例登记到 controllable（读登记，不猜端口）")
        group.start_match(with_ai=bool(args.with_ai))
        status = group.wait_match()
        human = group.human_name(status)
        check(len(status.get("units", [])) >= 1, "对局就绪（玩家 %s，单位 %d 个）"
              % (human, len(status.get("units", []))))

        # 等一辆可移动单位（矿车可能晚几拍出生）
        mover = None
        deadline = time.time() + 45
        while time.time() < deadline and mover is None:
            status = group.server.dcs({"op": "status"}, timeout=15)
            mine = [unit for unit in status.get("units", []) if unit.get("owner") == human]
            mover = next((unit for unit in mine if unit.get("movement")), None)
            if mover is None:
                time.sleep(2)
        if not check(mover is not None, "场上出现可移动单位（矿车）"):
            raise RuntimeError("没有可移动单位，后续断言无法进行")

        def planar(pos):
            return (round(float(pos[0]), 1), round(float(pos[2]), 1))

        before = planar(mover["pos"])
        dest = [before[0] + 12.0, before[1] + 12.0]
        reply = group.server.dcs({"op": "move", "units": [mover["name"]], "dest": dest})
        if check(bool(reply.get("accepted")), "移动命令被权威接受（%s）" % reply.get("status")):
            deadline = time.time() + 30
            after_pos = before
            while time.time() < deadline:
                status = group.server.dcs({"op": "status"}, timeout=15)
                unit = next((u for u in status.get("units", []) if u.get("name") == mover["name"]), None)
                if unit is None:
                    break
                after_pos = planar(unit["pos"])
                if (abs(after_pos[0] - before[0]) + abs(after_pos[1] - before[1])) > 2.0:
                    break
                time.sleep(2)
            check((abs(after_pos[0] - before[0]) + abs(after_pos[1] - before[1])) > 2.0,
                  "单位真实位移 %s → %s" % (before, after_pos))

        shot = os.path.join(log_dir, "selftest_%s_%d.png" % (time.strftime("%H%M%S"), os.getpid()))
        group.client.dcs({"op": "screenshot", "path": shot}, timeout=60)
        check(os.path.exists(shot), "客户端出图 %s" % os.path.basename(shot))
    except Exception as exc:  # noqa: BLE001
        check(False, "异常：%r" % exc)
    finally:
        leftovers = group.close()
        check(not leftovers, "按 pid 树收尾无残留（%s）" % (leftovers or "干净"))
        time.sleep(1)
        bad = [item["instance"] for item in list_instances()
               if str(item.get("instance", "")).startswith("selftest")]
        check(not bad, "登记目录无 selftest 残留：%s" % (bad or "无"))

    ok = all(checks)
    print("[SELFTEST] 结果：%s（耗时 %.0fs，日志 %s）"
          % ("全部通过" if ok else "存在失败", time.time() - started, log_dir), flush=True)
    return 0 if ok else 1


def _cmd_ls(args) -> int:
    items = list_instances(args.directory or "", stale_after=args.stale_after)
    if not items:
        print("登记目录 %s 里没有实例" % registry_dir())
        return 0
    print("%-10s %-24s %-7s %-9s %-7s %s" % ("状态", "实例", "pid", "游戏口", "调试口", "心跳"))
    for item in items:
        print("%-10s %-24s %-7s %-9s %-7s %.1fs 前" % (
            item["_state"], item.get("instance", "?"), item.get("pid", "?"),
            item.get("game_port", "?"), item.get("dcs_port", "?"), item["_heartbeat_age_s"]))
    zombies = [item for item in items if item["_state"] != "live"]
    if zombies:
        print("\n非 live 的有 %d 个：用 `match_instance.py reap` 按 pid 清理" % len(zombies))
    leases = list_parent_leases(args.directory or "", stale_after=args.stale_after)
    if leases:
        summary = ", ".join("%s[%s]" % (os.path.basename(item["path"]), item["state"]) for item in leases)
        print("启动器租约 %d 个：%s" % (len(leases), summary))
        if any(item["state"] != "live" for item in leases):
            print("（stale=启动器已死可清；hung=启动器心跳过期但 pid 还在，需人工确认）")
    return 0


def _cmd_reap(args) -> int:
    actions = reap(args.directory or "", dry_run=args.dry_run,
                   stale_after=args.stale_after, name_prefix=args.name_prefix, keep=args.keep)
    head = "（dry-run）" if args.dry_run else ""
    print("%s按 pid 杀掉僵尸：%s" % (head, [entry["instance"] for entry in actions["killed"]] or "无"))
    print("%s删除残留登记：%s" % (head, actions["removed"] or "无"))
    print("%s清理失效启动器租约：%s" % (head, actions["leases_removed"] or "无"))
    if actions["leases_hung"]:
        print("注意：%s 个启动器租约心跳过期但 pid 仍在（需人工确认，本工具不擅自杀）"
              % len(actions["leases_hung"]))
    return 0


def _cmd_ports(args) -> int:
    block = allocate_ports(base=args.base)
    print(json.dumps(block, ensure_ascii=False))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="本机对局实例工具（多开 + 不留僵尸局）")
    parser.add_argument("--directory", default="", help="登记目录（默认 %s）" % DEFAULT_REGISTRY_DIR)
    parser.add_argument("--stale-after", type=float, default=20.0, help="心跳过期阈值（秒）")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ls", help="列出登记：live / zombie / stale")
    reap_parser = sub.add_parser("reap", help="清僵尸（按 pid）+ 删残留登记")
    reap_parser.add_argument("--dry-run", action="store_true")
    reap_parser.add_argument("--name-prefix", default="", help="只处理该前缀的实例")
    reap_parser.add_argument("--keep", type=int, default=0, help="每种状态保留最新的 N 个")
    ports_parser = sub.add_parser("ports", help="打印一段空闲端口块")
    ports_parser.add_argument("--base", type=int, default=0, help="校验指定基端口（0=动态挑）")
    selftest_parser = sub.add_parser(
        "selftest", help="完全无人化自检：真开局+真实命令+出图+清场（退出码判定成败）")
    selftest_parser.add_argument("--with-ai", action="store_true",
                                 help="带 AI 对手（默认不带，便于无战斗断言）")
    args = parser.parse_args(argv)
    return {"ls": _cmd_ls, "reap": _cmd_reap, "ports": _cmd_ports,
            "selftest": _cmd_selftest}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
