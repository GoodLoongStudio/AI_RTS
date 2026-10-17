#!/usr/bin/env bash
# 收尾链 2：定向 Godot 非退化回归 → Python 全套 → 微调 → 固定评测集对照。
# 等"重出图"跑完再动（全程串行，不抢 CPU/显存）。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609
export PYTHONPATH=G:/AIRTS/AI_RTS/source
LOG=tools/_chain2.log
GODOT='/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
VENV='G:/AIRTS/临时文件夹/airts_laya_venv/Scripts/python.exe'
DATA='G:/AIRTS/tmp_logs/selfplay'
TESTS='automatic-construction,structure-placement,runtime-placement,same-frame-overlap-placement,structure-repair-sell,repair-sell-targeting,net-structure-command-contract,worker-gather,economy-account,worker-engagement-policy,production-queue,command-center-worker-production,fog-of-war-sight-range,ore-refinery,ore-regeneration,multi-unit-command'
# net-infantry  timeout 300s 且与本轮改动无关（步兵联机同步），先不占额度；
# 需要时单独补跑，不混进这张表里当"跑过了"。

echo "=== WAIT recapture @ $(date) ===" >> "$LOG"
while ! grep -q "RECAPTURE DONE" tools/_capture2.log 2>/dev/null; do sleep 20; done

echo "@@@ 1 定向 Godot 非退化回归 @ $(date)" >> "$LOG"
python tools/run_targeted_godot_tests.py --godot "$GODOT" --ids "$TESTS" >> "$LOG" 2>&1
echo "@@@ 1 exit=$?" >> "$LOG"

echo "@@@ 2 Python 全套 @ $(date)" >> "$LOG"
python -m unittest discover -s source/adjutant_coordinator/tests \
  -t source/adjutant_coordinator/tests 2>&1 | tail -30 >> "$LOG"

echo "@@@ 3 微调 ft_v27 @ $(date)" >> "$LOG"
"$VENV" -m adjutant_coordinator.deploy.train_laya \
  --dataset "$DATA/loop27_teacher.trainable.jsonl" --dataset "$DATA/loop27_laya.trainable.jsonl" \
  --out "$DATA/ft_v27" --epochs 2 --device cuda --max-len 448 >> "$LOG" 2>&1
echo "@@@ 3 exit=$?" >> "$LOG"

echo "@@@ 4 固定评测集对照 @ $(date)" >> "$LOG"
for MODEL in ft_v2 ft_v27; do
  AIRTS_LAYA_MODEL="$DATA/$MODEL" "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
    --ab source/adjutant_coordinator/logs/format_ab_both_20260912.json --limit 60 \
    --out "G:/AIRTS/tmp_logs/loop27_eval_$MODEL.json" >> "$LOG" 2>&1
  echo "@@@ 4 $MODEL exit=$?" >> "$LOG"
done

echo "@@@ 5 重渲染 §6 表 @ $(date)" >> "$LOG"
python source/adjutant_coordinator/deploy/rerender_sweep.py \
  --tags fs_screen,fs_reg,fs_fill,fs_regen,fs_verify1,fs_precheck >> "$LOG" 2>&1

echo "@@@ CHAIN2 DONE @ $(date)" >> "$LOG"
