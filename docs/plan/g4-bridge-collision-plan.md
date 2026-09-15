# G4 桥面碰撞与过桥站立 Implementation Plan

## Overview
过桥穿模：WalkB/RailC 碰撞在进局时被拆掉，逻辑移动又把单位吸到河床或写死的 1.25m，车体进了 1.30m 桥板。恢复桥面/护栏碰撞，并按可走板顶面站立。

## Current State Analysis
- 导出桥：可视桥面原点在 `deck_top≈1.30`，WalkB 盒顶 = `top`（主跨 1.30，端坡分级）。
- `_collect_bridge_rects` 记录 XZ 后把 WalkB `shape` 置空、layer=0。
- `_strip_leftover_map_physics` 再拆掉 Bridge 下剩余 StaticBody（含 RailC）。
- 大图单位 `collision_mask=0`，站立只靠 `project_ground`；硬抬 1.25 比桥面低 5cm，原点埋进板厚 0.93m 的实体。

## Implementation Strategy
- 采集时保留 WalkB/RailC 碰撞，只从 Recast 输入组摘掉（大图仍不烘导航）。
- `_strip_leftover_map_physics` 跳过 `WalkB*` / `RailC*` / `/Bridge`。
- 每块可走板记下未外扩矩形 + `deck_y`；`project_ground` / 点选射线用板顶，不用河床或 1.25。
- 寻路走廊仍可小幅外扩（0.45m），不恢复地形 trimesh，不打开物理分线程。

## Implementation Steps
1. ✅ 写本计划
2. ✅ 保留桥碰撞并记录板顶高度
3. ✅ `project_ground` / 点选打到桥面
4. ✅ 活局过桥：Y 升到 1.30 再下到对岸，clip=0

## Timeline
本轮一次做完并复测过桥。

## Risk Assessment
- 外扩过大：人站在桥侧水面却抬到桥高 → 高度只用板内/小外扩
- 恢复全图碰撞会打物理 → 只留桥，28 个盒子

## Success Criteria
- WalkB/RailC 进局后 shape 仍在、layer≠0
- 桥心 `project_ground` 的 Y 接近 1.30，不是河床或 1.25
- 过桥单位 Y 贴板顶，不沉进桥板

## Progress Tracking
✅ 采集与碰撞保留
✅ 高度吸附
✅ 验证：headless 桥心 y=1.30；活局过桥 clip=0

## Related Files
- `source/match/maps/generated/GeneratedTerrain.gd`
- `tools/verify_g4_large_lake_playable.gd`
