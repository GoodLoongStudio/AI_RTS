#!/usr/bin/env bash
# 散矿/矿场实机截图取证（§8.1 / §8.4）。必须带窗口，窗口移到屏幕外不抢前台。
# 排队在训练循环之后：渲染会抢 CPU，不能和 10Hz 采样的对局取证并行。
cd /g/AIRTS/AI_RTS || exit 1
export PYTHONIOENCODING=utf-8
export AIRTS_TEST_BASE=24609   # 第二段：与同机另一路会话（用 24569/24589）完全隔离
GODOT="/g/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
LOG=tools/_capture.log
echo "=== WAIT loop @ $(date) ===" >> "$LOG"
echo "(串行调用，无需等待)" >> "$LOG"
echo "=== capture @ $(date) ===" >> "$LOG"
"$GODOT" --path G:/AIRTS/AI_RTS --position -4000,-4000 --resolution 1280x720 \
   res://tools/capture_ore_scatter.tscn >> "$LOG" 2>&1
echo "=== CAPTURE DONE @ $(date) ===" >> "$LOG"
