#!/usr/bin/env bash
# 固定种子扫描：5 筛查 + 10 回归，脱离终端跑（Bash 工具约 10 分钟上限，15 局要 ~110 分钟）。
# 日志逐批追加，随时可 tail；跑完由分析层读 sweep_*.json。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
PY=python
MAP=${MAP:-res://source/match/maps/PlainAndSimple.tscn}
LOG=tools/_sweep_all.log
echo "=== screen 5 seeds @ $(date) map=$MAP ===" >> "$LOG"
$PY source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map "$MAP" --seeds 11,22,33,44,55 --seconds 200 --backend off \
  --refinery-at 30 --tag fs_screen >> "$LOG" 2>&1
echo "=== regression 10 seeds @ $(date) ===" >> "$LOG"
$PY source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map "$MAP" --seeds 424242,467,1024,7777,31323,90210,55501,1234,8080,6006 \
  --seconds 280 --backend off --refinery-at 30 --tag fs_reg >> "$LOG" 2>&1
echo "=== model-on 对照 2 seeds @ $(date) ===" >> "$LOG"
$PY source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map "$MAP" --seeds 424242,467 --seconds 280 --backend laya \
  --refinery-at 30 --tag fs_model >> "$LOG" 2>&1
echo "=== ALL DONE @ $(date) ===" >> "$LOG"
