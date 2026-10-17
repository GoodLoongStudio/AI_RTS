#!/usr/bin/env bash
# §6 的 10 局回归里有 4 粒种子被同机会话的进程树清理打断（表里那几行的
# 首座兵营/矿场列是 None）。补齐它们，让 10 局回归每一行都有逐局字段。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609
LOG=tools/_fill.log
echo "=== WAIT regen done @ $(date) ===" >> "$LOG"
while ! grep -q "REGEN DONE" tools/_regen.log 2>/dev/null; do sleep 20; done
echo "=== FILL 4 seeds @ $(date) ===" >> "$LOG"
python source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map res://source/match/maps/PlainAndSimple.tscn --seeds 1024,424242,467,6006 \
  --seconds 300 --backend off --refinery-at 30 --boot-budget 360 --retries 2 --tag fs_fill >> "$LOG" 2>&1
PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609 python source/adjutant_coordinator/deploy/rerender_sweep.py \
  --tags fs_screen,fs_reg,fs_fill,fs_regen >> "$LOG" 2>&1
echo "=== FILL DONE @ $(date) ===" >> "$LOG"
