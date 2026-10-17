#!/usr/bin/env bash
# 补 3 粒带"再生/矿场服务"仪表的种子（仪表是在扫局中途才加的，之前的 result 没这列）。
# 等整条主链跑完再动，避免抢 CPU 污染任何一局的 10Hz 采样口径。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609
LOG=tools/_regen.log
echo "=== WAIT capture done @ $(date) ===" >> "$LOG"
while ! grep -q "CAPTURE DONE" tools/_capture.log 2>/dev/null; do sleep 20; done
echo "=== REGEN batch @ $(date) ===" >> "$LOG"
python source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map res://source/match/maps/PlainAndSimple.tscn --seeds 44,13,77 \
  --seconds 300 --backend off --refinery-at 30 --boot-budget 300 --tag fs_regen >> "$LOG" 2>&1
PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609 python source/adjutant_coordinator/deploy/rerender_sweep.py >> "$LOG" 2>&1
echo "=== REGEN DONE @ $(date) ===" >> "$LOG"
