#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""可见真实对局驱动（2026-10-11 阶段一，试玩/录像专用）。

窗口化运行 ai_perf_probe.tscn（真实 Match、1/3 个电脑、起始资金 10000），
通过 DCS（--debugport）做只读采样与镜头 look_at（不注入 OS 输入、不抢前台），
按 60-120 秒分段后台录像（record_playtest.py，隐藏控制台）。
对局由探针 runner 在 --frames 用尽后自行正常退出（rc=0 + JSON）。

用法：
  python tools/dev/ai_visible_match.py --out <dir> --run-id m1 --ai-count 1 \
      --minutes 10 --record
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from match_instance import allocate_ports, kill_tree, tcp_call  # noqa: E402

GUI_EXE = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe"
RECORD_TOOL = str(HERE / "record_playtest.py")
PROBE_SCENE = "res://tools/ai_perf_probe.tscn"
CREATE_NO_WINDOW = 0x08000000


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--ai-count", type=int, default=1)
    parser.add_argument("--minutes", type=float, default=10.0)
    parser.add_argument("--difficulty", type=int, default=1)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--deadline-s", type=float, default=0.0,
                        help="额外墙钟余量；0=minutes*60+300")
    args = parser.parse_args()

    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    result_json = output / ("ai_perf_%s.json" % args.run_id)
    samples_path = output / ("%s.status.jsonl" % args.run_id)
    ports = allocate_ports()
    dcs_port = ports["client_dcs"]
    minutes = args.minutes
    frames = int(minutes * 60 * 23.3) + 400  # PlainAndSimple ~23.3Hz tick + 预热余量
    deadline_s = args.deadline_s or (minutes * 60 + 300)

    argv = [GUI_EXE, "--path", ".",
            # 屏内后台位置（不激活）：2026-10-11 实测 --position 屏外会被 PrintWindow
            # 判定 hidden/minimized，录制 7s 即中止（clip-02 status=partial）。
            # 非干扰模式要求窗口可见但后台，不能用屏外/最小化。
            "--position", "80,80",
            PROBE_SCENE, "--",
            "--debugport", str(dcs_port),
            "--perf-out=" + result_json.as_posix(),
            "--ai-count=%d" % args.ai_count,
            "--frames=%d" % frames,
            "--warmup-frames=300",
            "--difficulty=%d" % args.difficulty,
            "--extra-units=0",
            "--watchdog-s=%.0f" % (deadline_s + 60),
            "--run-id=" + args.run_id]
    out_log = open(output / ("%s.out.log" % args.run_id), "w", encoding="utf-8", errors="replace")
    err_log = open(output / ("%s.err.log" % args.run_id), "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(argv, cwd=str(PROJECT), stdout=out_log, stderr=err_log)
    print("launched visible match pid=%d dcs=%d frames=%d" % (proc.pid, dcs_port, frames), flush=True)

    samples = open(samples_path, "w", encoding="utf-8")
    recordings = []
    pending_recordings = []
    camera_set = False
    camera_index = -1
    started = time.time()
    next_sample = 0.0
    next_record_start = 45.0  # 首段延迟：等游戏窗口就绪（clip-01 抢跑教训）
    segment = 0
    try:
        while proc.poll() is None:
            now = time.time()
            if now - started > deadline_s:
                print("DEADLINE exceeded, killing", flush=True)
                kill_tree(proc.pid)
                break
            if now >= next_sample:
                next_sample = now + 1.0
                try:
                    status = tcp_call(dcs_port, {"op": "status"}, timeout=4.0)
                    if isinstance(status, dict):
                        units = status.get("units") or []
                        ccs = [u for u in units
                               if str(u.get("unit_type", "")) == "command_center" and u.get("pos")]
                        if ccs:
                            # 1AI：全程看第一个电脑基地；3AI：每 150s 轮换一个电脑基地。
                            index = 0 if args.ai_count == 1 else int((now - started) // 150) % len(ccs)
                            target = ccs[min(index, len(ccs) - 1)]["pos"]
                            if not camera_set or index != camera_index:
                                tcp_call(dcs_port,
                                         {"op": "camera",
                                          "look_at": [target[0], target[2]]},
                                         timeout=4.0)
                                camera_set = True
                                camera_index = index
                    samples.write(json.dumps({"wall_s": round(now - started, 1),
                                              "status": status}, ensure_ascii=False) + "\n")
                    samples.flush()
                except Exception as exc:  # DCS 未就绪/瞬时忙：留空轮次
                    samples.write(json.dumps({"wall_s": round(now - started, 1),
                                              "error": str(exc)}, ensure_ascii=False) + "\n")
                    samples.flush()
            if args.record and now >= next_record_start and now - started < minutes * 60 - 25:
                segment += 1
                next_record_start = now + 75  # 非阻塞节拍：段长 70s + 5s 间隔
                clip = output / ("%s-video" % args.run_id) / ("clip-%02d.mp4" % segment)
                clip.parent.mkdir(parents=True, exist_ok=True)
                cmd = [sys.executable, RECORD_TOOL, "record",
                       "--pid", str(proc.pid), "--fps", "5",
                       "--seconds", "70", "--max-width", "1280",
                       "--output", str(clip)]
                print("recording segment %d -> %s" % (segment, clip.name), flush=True)
                rec = subprocess.Popen(cmd, creationflags=CREATE_NO_WINDOW,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                pending_recordings.append((segment, clip, rec))
            # 收割完成的录像段（只等待本驱动启动的录制进程）。
            still_pending = []
            for seg, clip, rec in pending_recordings:
                code = rec.poll()
                if code is None:
                    still_pending.append((seg, clip, rec))
                elif clip.exists() and clip.stat().st_size > 10000:
                    recordings.append(str(clip))
                else:
                    print("segment %d failed rc=%s size=%s" % (
                        seg, code, clip.stat().st_size if clip.exists() else 0), flush=True)
            pending_recordings = still_pending
            time.sleep(0.4)
        rc = proc.returncode
        # 收尾：给最后的录像段最多 90s 收尾时间。
        wait_deadline = time.time() + 90
        for seg, clip, rec in pending_recordings:
            while rec.poll() is None and time.time() < wait_deadline:
                time.sleep(1.0)
            if clip.exists() and clip.stat().st_size > 10000:
                recordings.append(str(clip))
        fresh = result_json.exists() and result_json.stat().st_mtime >= started
        print("match exited rc=%s fresh_json=%s segments=%d" % (rc, fresh, len(recordings)),
              flush=True)
        return 0 if (rc == 0 and fresh) else 1
    finally:
        samples.close()
        out_log.close()
        err_log.close()
        if proc.poll() is None:
            kill_tree(proc.pid)


if __name__ == "__main__":
    sys.exit(main())
