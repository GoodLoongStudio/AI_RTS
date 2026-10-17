#!/usr/bin/env bash
# 扫完之后顺序跑：定向非退化回归（§7 完成标准第 8 条）→ 散矿布局审计（§5 阶段 4）→ Python 全套。
# 串行而非并行：真实对局采样是 10Hz 墙钟口径，抢 CPU 会把"这局没走到"污染成"改造没生效"。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609   # 与同机另一路会话（24569/24589）完全隔离
LOG=tools/_post_sweep.log
GODOT="/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
echo "=== (串行调用，无需等待) @ $(date) ===" >> "$LOG"

# 【为什么走 run_full_regression.ps1 而不是自己起 godot】
# 那个 runner 才认 `expected_marker` **并且**会检查 `forbidden_output_patterns`
# （SCRIPT ERROR / Parse Error / ObjectDB 泄漏等）。手工起 godot 只看 marker，
# 正是阶段 0 记录过的"日志里 SCRIPT ERROR 刷屏也判绿"的假阳性来源。
# 子集按 §7 第 8 条逐项配齐：玩家控制 / 预算 / 权限 / 取消退款 / 战争迷雾 /
# 生产队列 / 战斗执行 / 联机权威入口（本轮 NetSync 改动的那条）。
echo "--- 定向非退化回归 @ $(date)" >> "$LOG"
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_full_regression.ps1 \
  -GodotExecutable "G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe" \
  -TestId automatic-construction,structure-placement,runtime-placement,`
          same-frame-overlap-placement,structure-repair-sell,repair-sell-targeting,`
          net-structure-command-contract,net-infantry,worker-gather,economy-account,`
          worker-engagement-policy,production-queue,command-center-worker-production,`
          fog-of-war-sight-range,ore-refinery,ore-regeneration,multi-unit-command `
  -SkipAudit >> "$LOG" 2>&1
echo "--- 定向回归 exit=$?" >> "$LOG"

echo "--- 散矿布局审计 @ $(date) ===" >> "$LOG"
"$GODOT" --headless --path G:/AIRTS/AI_RTS --script res://tools/audit_ore_layout.gd >> "$LOG" 2>&1

echo "--- Python 全套 @ $(date) ===" >> "$LOG"
python -m unittest discover -s source/adjutant_coordinator/tests -t source -v 2>&1 | tail -30 >> "$LOG"

echo "=== CHECKS DONE @ $(date) ===" >> "$LOG"
