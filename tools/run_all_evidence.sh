#!/usr/bin/env bash
# 一条主链把 §6/§7 需要的取证按顺序跑完（不再用四个互相等标记的进程）。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609
echo "@@@@@ MAIN START $(date) @@@@" >> tools/_main_chain.log
bash tools/run_ref10_then_sweep.sh >> tools/_main_chain.log 2>&1
echo "@@@@@ SWEEP EXIT=$? $(date) @@@@" >> tools/_main_chain.log
bash tools/run_post_sweep_checks.sh >> tools/_main_chain.log 2>&1
echo "@@@@@ CHECKS EXIT=$? $(date) @@@@" >> tools/_main_chain.log
bash tools/run_training_loop_20260927.sh >> tools/_main_chain.log 2>&1
echo "@@@@@ LOOP EXIT=$? $(date) @@@@" >> tools/_main_chain.log
bash tools/run_capture_after_loop.sh >> tools/_main_chain.log 2>&1
echo "@@@@@ MAIN DONE $(date) @@@@" >> tools/_main_chain.log
