#!/usr/bin/env bash
# §6 的固定种子扫局：5 个筛查种子 + 10 局回归。串行、不与其他取证并发。
# 上一版有 3 局 rc=2，事后单跑复现证明是**同机另一路会话在跑 perfgrid/冒烟回归**
# 把引擎冷启动挤过了 50 秒预算——采集入口把"机器忙"报成"这局没结果"是假阴性，
# 所以：启动预算放宽到 240s（驱动默认），失败时把驱动输出尾部带进日志。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609   # 第二段：与同机另一路会话（用 24569/24589）完全隔离
LOG=tools/_sweep_all.log
MAP=res://source/match/maps/PlainAndSimple.tscn
DEP=source/adjutant_coordinator/deploy
BOOT=300

echo "=== PRECHECK 矿场留人闭环 @ $(date) ===" >> "$LOG"
# 资格判据改完 + 冷却加完之后，先用最短的一局确认"接管→交付"仍然成立，
# 再投入 15 局的扫局；否则万一改坏，浪费的是两小时。
python $DEP/selfplay_match.py --tag fs_precheck --seconds 220 --backend off \
  --map "$MAP" --seed 33 --refinery-at 30 --boot-budget $BOOT >> "$LOG" 2>&1

echo "=== SCREEN 5 seeds @ $(date) ===" >> "$LOG"
python $DEP/run_fixed_seed_regression.py --map "$MAP" --seeds 11,22,33,44,55 \
  --seconds 220 --backend off --refinery-at 30 --boot-budget $BOOT --tag fs_screen >> "$LOG" 2>&1
echo "=== REGRESSION 10 seeds @ $(date) ===" >> "$LOG"
python $DEP/run_fixed_seed_regression.py --map "$MAP" \
  --seeds 424242,467,1024,7777,31323,90210,55501,1234,8080,6006 \
  --seconds 300 --backend off --refinery-at 30 --boot-budget $BOOT --tag fs_reg >> "$LOG" 2>&1
echo "=== ALL DONE @ $(date) ===" >> "$LOG"
