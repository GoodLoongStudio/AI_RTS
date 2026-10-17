#!/usr/bin/env bash
# 收尾链 3（每一步都单独落日志：这台机器上并行会话会按进程树清理，整链随时可能断，
# 断在哪一步要看得出来，不能像上一版那样"跑完了但没有任何中间痕迹"）。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609 PYTHONPATH=G:/AIRTS/AI_RTS/source
LOG=tools/_chain3.log
GODOT='/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
VENV='G:/AIRTS/临时文件夹/airts_laya_venv/Scripts/python.exe'
DATA='G:/AIRTS/tmp_logs/selfplay'
step() { echo "@@@ $* @ $(date +%H:%M:%S)" | tee -a "$LOG"; }

step "A 定向非退化回归 剩余 14 条"
python tools/run_targeted_godot_tests.py --godot "$GODOT" --ids \
runtime-placement,same-frame-overlap-placement,structure-repair-sell,repair-sell-targeting,net-structure-command-contract,worker-gather,economy-account,worker-engagement-policy,production-queue,command-center-worker-production,fog-of-war-sight-range,ore-refinery,ore-regeneration,multi-unit-command >> "$LOG" 2>&1
step "A exit=$?"

step "B Python 全套"
python -m unittest discover -s source/adjutant_coordinator/tests \
  -t source/adjutant_coordinator/tests 2>&1 | tail -25 >> "$LOG"
step "B done"

step "C 生成图真机截图（走实际游戏入口，不用裸挂场景）"
python source/adjutant_coordinator/deploy/selfplay_match.py --tag gen_shot --seconds 120 \
  --backend off --map res://source/match/maps/generated/16-0-2057e4a0b4/map_16-0-2057e4a0b4.tscn \
  --seed 7 --boot-budget 360 >> "$LOG" 2>&1
step "C exit=$?"

step "D 微调 ft_v27（只用 verified_result 样本）"
"$VENV" -m adjutant_coordinator.deploy.train_laya \
  --dataset "$DATA/loop27_teacher.trainable.jsonl" --dataset "$DATA/loop27_laya.trainable.jsonl" \
  --out "$DATA/ft_v27" --epochs 2 --device cuda --max-len 448 >> "$LOG" 2>&1
step "D exit=$?"

step "E 固定评测集对照 ft_v2 vs ft_v27"
for MODEL in ft_v2 ft_v27; do
  AIRTS_LAYA_MODEL="$DATA/$MODEL" "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
    --ab source/adjutant_coordinator/logs/format_ab_both_20260912.json --limit 60 \
    --out "G:/AIRTS/tmp_logs/loop27_eval_$MODEL.json" >> "$LOG" 2>&1
  step "E $MODEL exit=$?"
done

step "F 重渲染 §6 表"
python source/adjutant_coordinator/deploy/rerender_sweep.py \
  --tags fs_screen,fs_reg,fs_fill,fs_regen,fs_verify1,fs_precheck,loop27,gen_shot >> "$LOG" 2>&1

step "CHAIN3 DONE"
