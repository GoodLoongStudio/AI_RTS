# 山脚边缘凹陷 Implementation Plan

## Overview
修掉山体外缘一圈“被咬/壕沟”的视觉：岩体最外圈 addon 为负，紧邻沉积扇却抬高，剖面先鼓再塌，低机位读成边缘凹陷。

## Current State Analysis
`tools/probe_mountain_foot_moat.py` 在 seed 16 / `16-0-7d337ce8be` 上实测：

- 岩体 `rd<1.5` 最外圈 **96.5% addon < 0**（中位 -0.43，最低 -0.80）
- 紧邻沉积扇 `ro<4` addon 中位 **1.86**（高度中位 2.38）
- 远沙地高度中位 **0.61**
- 权威高度剖面：沙地 0.61 → 扇 2.38 → **岩缘 0.53** → 再爬升

公式原因：`addon = h_rock - 0.6*logical_cell`。`rd≈0` 时 `edge_rise/core/base` 都接近 0，`h_rock≈0.5+fn_b`，减去 2.34 后外圈塌进平地以下；扇区仍按 `fan²*(0.7+fn*1.8+und)` 堆到 ~2m。中高频 `crag/face` 再沿缘挖牙。

不改 G2 `mountain_cover`（避免重跑 G3、堵走廊）。只改 G4 山体增量。

## Implementation Strategy
1. 岩体外 6 格单调保底：`rd=0` 接上扇区（≈2.2），向内升到与 `raw` 汇合，禁止再出现负 addon。
2. 沉积扇封顶并减弱 `und`，避免扇包高于岩缘。
3. `crag/face/rg3` 用内部权重门控，山脚只留 EDT 斜裙。
4. 不向外扩张 rock 掩码（扩张会把陡坡铺到可走沙地，恶化 `max_step_walkable`）。

## Implementation Steps
1. 改 `rtsmap/gates/g4_terrain_mountains.py` 的 `mountain_addon`
2. 用 `probe_mountain_foot_moat.py` 验收：外圈 neg% → 0，岩缘高度 ≥ 扇区
3. `regen_and_install_g4.py 16` 装机
4. 实机出 `g130_mountain_foot.png` 对照

## Timeline
单轮：改公式 → 量化 → 导出 → 出图。

## Risk Assessment
- 保底过陡：只作用在 G2 blocking 岩体上，崖壁边不进 `max_step_walkable`
- 扇区封顶过低：山脚沉积感变弱，可再把封顶调到 2.0
- 大尺度湾（solidity 0.72）仍在：那是 G2 掩码，本轮不填，避免堵路

## Success Criteria
- `rd<1.5` addon 负值比例 = 0
- 岩缘高度中位 ≥ 扇区高度中位（不再先鼓后塌）
- 山体峰从 81 世界米抬到约 110 世界米（addon max 19.7 → 27）
- 山脚图不再有一圈深色壕沟/牙缺口

## Progress Tracking
- ✅ 计划
- ✅ 改 `mountain_addon`
- ✅ 量化验收（外圈 neg% 0；高度 0.61→2.33→3.16 单调）
- ✅ 重导出装机（height_data md5 两端一致）
- ✅ 实机出图 `g130_*.png`（11/11）
- ✅ 再抬主项 1.4×（峰 27.4 语义米 / 110 世界米），山脚仍单调
- ✅ g131 装机出图（11/11；Godot 读到 PEAK=27.39）

## Related Files
- `RTS_Map_Tool/rtsmap/gates/g4_terrain_mountains.py`
- `RTS_Map_Tool/rtsmap/gates/g4_terrain.py`（调用侧，不改契约）
- `RTS_Map_Tool/tools/probe_mountain_foot_moat.py`
- `AI_RTS/tools/capture_generated_map_views.gd`
