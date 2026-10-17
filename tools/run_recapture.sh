#!/usr/bin/env bash
# 重出散矿/矿场实机图（生成图补了灯光、矿场底座压平之后）。等主链跑完再动，不抢 CPU。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8 AIRTS_TEST_BASE=24609
LOG=tools/_capture2.log
GODOT='/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
echo "=== WAIT finish chain @ $(date) ===" >> "$LOG"
while ! grep -q "FINISH DONE" tools/_finish.log 2>/dev/null; do sleep 20; done
echo "=== RECAPTURE @ $(date) ===" >> "$LOG"
"$GODOT" --path G:/AIRTS/AI_RTS --position -4000,-4000 --resolution 1280x720 \
   res://tools/capture_ore_scatter.tscn >> "$LOG" 2>&1
echo "=== RECAPTURE DONE @ $(date) ===" >> "$LOG"
