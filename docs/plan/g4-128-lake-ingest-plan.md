# G4 大湖 128×128 重生 Implementation Plan

## Overview
把 seed16 大湖从 512×512 整条 G1–G4 重生成成 128×128，台地降到 6 座，坡口加宽到 12m，并挂进自定义对局。不永久改全局 512 契约，避免打坏现有 G1 库和测试。

## Current State Analysis
- 现行评图 `16-0-7d337ce8be`：`map.size = 512×512`，高度场 1025²，作者碰撞 652，水面 269，真机约 2 FPS。
- 游戏“大地图锁”门槛是 `map.size >= 256`。128 走小图路径：烘焙导航、保留 Walk 碰撞、不开表现锁。
- `GeneratedTerrain` 语义跨度写死 512；G4 掩码边长写死 1025。只改 `W=128` 却保留这两处，网格负担几乎不降。
- 闸门模块在 import 时绑定 `W/H/GRID_*`，必须先 `apply_map_extent(128)` 再 import gates。

## Implementation Strategy
1. `contract.apply_map_extent(128)` 只作用于本次进程。
2. 专用脚本重跑 G1→G2（6 座台地、12m 坡口、缩小湖/河尺度）→G3→G4 `natural`。
3. 高度/掩码边长改为 `(W*2+1)=257`；`semantic_span=128`，`world_scale_m=1`。
4. 新 `map_id` 写入 `MatchConstants.MAPS`。

## Implementation Steps
1. 加 `apply_map_extent` 与 `tools/regen_large_lake_128.py`
2. 导出与 `GeneratedTerrain` 对齐可变语义跨度
3. 跑 G1–G4 并装机
4. 挂菜单、更新冒烟路径

## Timeline
本轮生成并挂菜单；用户再进大湖看帧率和台地/坡道。

## Risk Assessment
- 四家 + 12m 边距挤在 128m 上，G2 可能多次 `NoTerrainCandidate`，需放宽湖面积/障碍带。
- 128 会烘焙导航；碰撞体必须明显少于 512 图。
- 不改全局 `contract.W`，避免 512 库和测试一起坏。

## Success Criteria
- `map.size` 为 128×128，高度场边长 ≤ 257
- 台地 6 座，坡口标称 12m
- 菜单能选新大湖，开局可操作

## Progress Tracking
- ✅ 计划
- ❌ 128 正式 G2 搜空湖/河，未装机
- ✅ 改走 256×256，见 `g4-256-lake-ingest-plan.md`

## Related Files
- `RTS_Map_Tool/rtsmap/contract.py`
- `RTS_Map_Tool/tools/regen_large_lake_128.py`
- `RTS_Map_Tool/rtsmap/gates/g4_export.py`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/MatchConstants.gd`
