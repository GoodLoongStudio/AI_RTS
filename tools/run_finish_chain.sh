#!/usr/bin/env bash
# 收尾链：把昨晚被三件事打断的取证补完。
#   1) 定向非退化回归（上一版脚本里 bash 的反引号续行把 -TestId 参数拆坏，ps1 直接语法错，exit=127）
#   2) 散矿布局审计 + Python 全套（同样因为第 1 步崩了而没跑到）
#   3) §5 阶段 5 的审计/微调/评测（上一版用 `python -m adjutant_coordinator...` 但没设
#      PYTHONPATH，包根在 source/ 下，所以 ModuleNotFoundError；采集本身是成功的）
#   4) 带完整再生仪表的种子批次 + 补齐被夜间休眠打断的 4 粒回归种子
# 全程串行：真实对局与冒烟测试都吃 CPU，并发会污染 10Hz 墙钟采样口径。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609
export PYTHONPATH=G:/AIRTS/AI_RTS/source     # ← `-m adjutant_coordinator.*` 必需
LOG=tools/_finish.log
GODOT_PS1='G:\AIRTS\AI_RTS\tools\run_full_regression.ps1'
GODOT='/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
VENV='G:/AIRTS/临时文件夹/airts_laya_venv/Scripts/python.exe'
DATA='G:/AIRTS/tmp_logs/selfplay'
SELFPLAY_RESULTS='G:/AIRTS/tmp_logs/langgraph_recon/selfplay'
MAP='res://source/match/maps/PlainAndSimple.tscn'
TESTS='automatic-construction,structure-placement,runtime-placement,same-frame-overlap-placement,structure-repair-sell,repair-sell-targeting,net-structure-command-contract,net-infantry,worker-gather,economy-account,worker-engagement-policy,production-queue,command-center-worker-production,fog-of-war-sight-range,ore-refinery,ore-regeneration,multi-unit-command'

say() { echo "@@@ $1 @ $(date +%H:%M:%S)" | tee -a "$LOG"; }

say "1 定向非退化回归"
powershell -NoProfile -ExecutionPolicy Bypass -File "$GODOT_PS1" \
  -GodotExecutable "G:\\AIRTS\\godot_mono_471\\Godot_v4.7.1-stable_mono_win64\\Godot_v4.7.1-stable_mono_win64_console.exe" \
  -TestId "$TESTS" -SkipAudit >> "$LOG" 2>&1
say "1 exit=$?"

say "2 散矿布局审计"
"$GODOT" --headless --path G:/AIRTS/AI_RTS --script res://tools/audit_ore_layout.gd >> "$LOG" 2>&1
say "2 exit=$?"

say "3 Python 全套"
python -m unittest discover -s source/adjutant_coordinator/tests -t source 2>&1 | tail -25 >> "$LOG"

say "4 样本联表审计（label_quality 升到结果层）"
python -m adjutant_coordinator.deploy.audit_dataset_samples \
  --dataset "$DATA/loop27_teacher.jsonl" --result "$SELFPLAY_RESULTS/result_loop27_t.json" \
  --out "$DATA/loop27_teacher.audited.jsonl" --trainable-out "$DATA/loop27_teacher.trainable.jsonl" >> "$LOG" 2>&1
python -m adjutant_coordinator.deploy.audit_dataset_samples \
  --dataset "$DATA/loop27_laya.jsonl" --result "$SELFPLAY_RESULTS/result_loop27_s.json" \
  --out "$DATA/loop27_laya.audited.jsonl" --trainable-out "$DATA/loop27_laya.trainable.jsonl" >> "$LOG" 2>&1

say "5 微调 ft_v27（只用 verified_result）"
"$VENV" -m adjutant_coordinator.deploy.train_laya \
  --dataset "$DATA/loop27_teacher.trainable.jsonl" --dataset "$DATA/loop27_laya.trainable.jsonl" \
  --out "$DATA/ft_v27" --epochs 2 --device cuda --max-len 448 >> "$LOG" 2>&1
say "5 exit=$?"

say "6 固定评测集对照 base(ft_v2) vs ft_v27"
AIRTS_LAYA_MODEL="$DATA/ft_v2" "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
  --data source/adjutant_coordinator/logs/format_ab_both_20260912.json --limit 60 \
  --out G:/AIRTS/tmp_logs/loop27_eval_base.json >> "$LOG" 2>&1
AIRTS_LAYA_MODEL="$DATA/ft_v27" "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
  --data source/adjutant_coordinator/logs/format_ab_both_20260912.json --limit 60 \
  --out G:/AIRTS/tmp_logs/loop27_eval_ft27.json >> "$LOG" 2>&1

say "7 带完整再生仪表的 3 粒种子"
python source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map "$MAP" --seeds 44,13,77 --seconds 300 --backend off --refinery-at 30 \
  --boot-budget 360 --retries 2 --tag fs_regen >> "$LOG" 2>&1

say "8 补齐夜间被打断的 4 粒回归种子"
python source/adjutant_coordinator/deploy/run_fixed_seed_regression.py \
  --map "$MAP" --seeds 1024,424242,467,6006 --seconds 300 --backend off --refinery-at 30 \
  --boot-budget 360 --retries 2 --tag fs_fill >> "$LOG" 2>&1

say "9 重渲染 §6 表"
python source/adjutant_coordinator/deploy/rerender_sweep.py \
  --tags fs_screen,fs_reg,fs_fill,fs_regen,fs_verify1,fs_precheck >> "$LOG" 2>&1

say "FINISH DONE"
