"""Godot 引擎任务封装：每个外部进程记录命令行、退出码、日志与超时。

路径来源（按优先级）：
1. 环境变量 RTSMAP_GODOT / RTSMAP_AIRTS；
2. rtsmap/workbench/engine.local.json（gitignore，本机可选）；
3. 从 tools/mapgen 向上找 project.godot；Godot 再查 PATH 与工程旁 *mono*_console.exe。
启动前检测文件存在；缺失时抛 EngineError（不静默返回旧图冒充成功）。
"""
import json
import os
import subprocess
import time
from pathlib import Path

from ..contract import G4_AIRTS, G4_GODOT_MONO

TOOLS_DIR = Path(__file__).resolve().parents[2] / "tools" / "godot"
LOCAL_CONFIG = Path(__file__).parent / "engine.local.json"


class EngineError(RuntimeError):
    pass


def _local_config():
    if LOCAL_CONFIG.exists():
        try:
            return json.loads(LOCAL_CONFIG.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
    return {}


def godot_exe():
    cfg = _local_config()
    for candidate in (os.environ.get("RTSMAP_GODOT"), cfg.get("godot"), G4_GODOT_MONO):
        if candidate and Path(candidate).exists():
            return str(Path(candidate))
    raise EngineError(
        "找不到 Godot Mono 可执行文件。请设置环境变量 RTSMAP_GODOT 或在 "
        "rtsmap/workbench/engine.local.json 配置 godot 路径。")


def airts_root():
    cfg = _local_config()
    for candidate in (os.environ.get("RTSMAP_AIRTS"), cfg.get("airts"), G4_AIRTS):
        if candidate and Path(candidate).exists():
            return str(Path(candidate))
    raise EngineError("找不到 AI_RTS 工程目录（RTSMAP_AIRTS / engine.local.json / contract.G4_AIRTS）。")


def run_godot(args, log_path, timeout_s, cwd=None):
    """运行一个 Godot 进程；返回 dict(cmd/exit_code/duration_s/timed_out/log)。"""
    exe = godot_exe()
    cmd = [exe] + [str(a) for a in args]
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    timed_out = False
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        log.write("$ " + " ".join(cmd) + "\n\n")
        log.flush()
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                cwd=cwd, stdin=subprocess.DEVNULL,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            exit_code = proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()
            exit_code = proc.wait(timeout=30)
    duration = round(time.time() - t0, 2)
    record = dict(cmd=cmd, exit_code=int(exit_code), duration_s=duration,
                  timed_out=timed_out, log=str(log_path))
    if timed_out:
        raise EngineError(f"Godot 进程超时（{timeout_s}s）：{' '.join(cmd[:6])}… 日志 {log_path}")
    return record


def import_assets(airts, log_dir, timeout_s=2400):
    """headless 资产导入（新复制的 FBX/PNG 生成 .import 与 uid）。"""
    return run_godot(["--headless", "--path", str(airts), "--import"],
                     Path(log_dir) / "godot_import.log", timeout_s)


def capture_ortho(airts, scene_res, out_png, log_dir, oblique=False, size=256,
                  timeout_s=600, flat=False, center=None, radius=None, iso45=False):
    """截图。默认正交俯视；iso45=正交 45° 轴测（验收立体图）；oblique=透视斜视（仅观感）。"""
    script = TOOLS_DIR / "ortho_capture.gd"
    out_png = Path(out_png).resolve()          # Godot 进程 CWD 不同，必须绝对路径
    args = ["--rendering-driver", "opengl3", "--resolution", "1920x1920",
            "--path", str(airts), "--script", str(script), "--",
            f"--map={scene_res}", f"--out={out_png}", f"--size={size}"]
    if oblique:
        args.append("--oblique")
    if iso45:
        args.append("--iso45")
    if flat:
        args.append("--flat")
    if center is not None and radius:
        args.append(f"--center={center[0]},{center[1]}")
        args.append(f"--radius={radius}")
    name = ("godot_capture_flat.log" if flat else
            "godot_capture_iso45.log" if iso45 else
            "godot_capture_oblique.log" if oblique else "godot_capture_ortho.log")
    rec = run_godot(args, Path(log_dir) / name, timeout_s)
    if not Path(out_png).exists():
        raise EngineError(f"截图未生成：{out_png}（见 {rec['log']}）")
    return rec


def nav_check(airts, scene_res, targets_json, out_json, log_dir, timeout_s=900):
    script = TOOLS_DIR / "nav_check.gd"
    rec = run_godot(["--rendering-driver", "opengl3", "--path", str(airts),
                     "--script", str(script), "--",
                     f"--map={scene_res}", f"--targets={Path(targets_json).resolve()}",
                     f"--out={Path(out_json).resolve()}"],
                    Path(log_dir) / "godot_nav_check.log", timeout_s)
    rec["pass"] = rec["exit_code"] == 0 and Path(out_json).exists()
    return rec


def smoke_match(airts, scene_res, out_dir, targets_json, log_dir, minutes=5,
                timeout_s=None):
    script = TOOLS_DIR / "smoke_test.gd"
    timeout_s = timeout_s or int(minutes * 60 + 900)
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    rec = run_godot(["--rendering-driver", "opengl3", "--resolution", "1280x800",
                     "--path", str(airts), "--script", str(script), "--",
                     f"--map={scene_res}", f"--out_dir={Path(out_dir).resolve()}",
                     f"--minutes={minutes}", f"--targets={Path(targets_json).resolve()}"],
                    Path(log_dir) / "godot_smoke.log", timeout_s)
    return rec
