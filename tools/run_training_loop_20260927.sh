#!/usr/bin/env bash
# 阶段 5 的一轮完整循环：采集 → 审计 → 微调 → 固定评测集对照（提示词 §5 阶段 5 顺序）。
# 双方同图同种子同平衡配置（`PlainAndSimple` + demo balance + seed 424242），
# 不这样就没法把"训练带来的差异"和"额外再生收入"分开。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609
DEP=source/adjutant_coordinator/deploy
DATA=G:/AIRTS/tmp_logs/selfplay
VENV="G:/AIRTS/临时文件夹/airts_laya_venv/Scripts/python.exe"
EVAL_SET=source/adjutant_coordinator/logs/format_ab_both_20260912.json
MAP=res://source/match/maps/PlainAndSimple.tscn
LOG=tools/_loop27.log
say(){ echo "=== $1 @ $(date +%H:%M:%S) ===" | tee -a "$LOG"; }

say "WAIT post-sweep checks"
echo "(串行调用，无需等待)" >> "$LOG"

say "① 采集 教师局 backend=model"
python $DEP/selfplay_match.py --tag loop27_t --seconds 300 --backend model --difficulty 0 \
  --map "$MAP" --seed 424242 --refinery-at 25 \
  --dataset $DATA/loop27_teacher.jsonl >> "$LOG" 2>&1

say "① 采集 学生局 backend=laya（当前 ft_v2）"
AIRTS_LAYA_MODEL=$DATA/ft_v2 python $DEP/selfplay_match.py --tag loop27_s --seconds 300 \
  --backend laya --difficulty 0 --map "$MAP" --seed 424242 --refinery-at 25 \
  --dataset $DATA/loop27_laya.jsonl >> "$LOG" 2>&1

say "② 审计样本（label_quality 升级到结果层，隔离无结果样本）"
python -m adjutant_coordinator.deploy.audit_dataset_samples \
  --dataset $DATA/loop27_teacher.jsonl \
  --result G:/AIRTS/tmp_logs/langgraph_recon/selfplay/result_loop27_t.json \
  --out $DATA/loop27_teacher.audited.jsonl \
  --trainable-out $DATA/loop27_teacher.trainable.jsonl >> "$LOG" 2>&1
python -m adjutant_coordinator.deploy.audit_dataset_samples \
  --dataset $DATA/loop27_laya.jsonl \
  --result G:/AIRTS/tmp_logs/langgraph_recon/selfplay/result_loop27_s.json \
  --out $DATA/loop27_laya.audited.jsonl \
  --trainable-out $DATA/loop27_laya.trainable.jsonl >> "$LOG" 2>&1

T_COUNT=$(wc -l < "$DATA/loop27_teacher.trainable.jsonl" 2>/dev/null || echo 0)
L_COUNT=$(wc -l < "$DATA/loop27_laya.trainable.jsonl" 2>/dev/null || echo 0)
echo "[loop] trainable: teacher=$T_COUNT laya=$L_COUNT" >> "$LOG"

say "③ 微调（只用 verified_result 样本）"
"$VENV" -m adjutant_coordinator.deploy.train_laya \
  --dataset $DATA/loop27_teacher.trainable.jsonl \
  --dataset $DATA/loop27_laya.trainable.jsonl \
  --out $DATA/ft_v27 --epochs 2 --device cuda --max-len 448 >> "$LOG" 2>&1

say "④ 固定评测集对照 base(ft_v2) vs ft_v27"
AIRTS_LAYA_MODEL=$DATA/ft_v2 "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
  --data "$EVAL_SET" --limit 60 --out G:/AIRTS/tmp_logs/loop27_eval_base.json >> "$LOG" 2>&1
AIRTS_LAYA_MODEL=$DATA/ft_v27 "$VENV" -m adjutant_coordinator.deploy.laya_p0_feasibility \
  --data "$EVAL_SET" --limit 60 --out G:/AIRTS/tmp_logs/loop27_eval_ft27.json >> "$LOG" 2>&1

say "⑤ 再采集（第 2 轮，用 ft_v27 当学生）"
AIRTS_LAYA_MODEL=$DATA/ft_v27 python $DEP/selfplay_match.py --tag loop27_r --seconds 300 \
  --backend laya --difficulty 0 --map "$MAP" --seed 467 --refinery-at 25 \
  --dataset $DATA/loop27_round2.jsonl >> "$LOG" 2>&1
python -m adjutant_coordinator.deploy.audit_dataset_samples \
  --dataset $DATA/loop27_round2.jsonl \
  --result G:/AIRTS/tmp_logs/langgraph_recon/selfplay/result_loop27_r.json \
  --out $DATA/loop27_round2.audited.jsonl \
  --trainable-out $DATA/loop27_round2.trainable.jsonl >> "$LOG" 2>&1

say "LOOP DONE"
