# 地形贴图对齐单位精度 Implementation Plan

## Overview
生成图对局地面贴图按千米级宏图平铺，2m 级载具脚下几乎没有颗粒。把运行时地表改成按世界米平铺，使地面精度和单位匹配。

## Current State Analysis
- 对局 `GeneratedTerrain` 强制 `performance_mode=true`。
- 该分支只采样 `macro_albedo`，UV 为 `base_uv / 1800`（review 米）。
- 当前 G4 图 `world_scale=1` 时，`showcase_world_scale=1/3.90625`，整张 512m 图大约只重复 1 次宏贴图。
- 载具碰撞半径约 0.8–0.9m、可视长度约 2m；脚下相当于看一张卫星图的几个像素，读作糊成纯色。
- 完整 PBR 分支仍保留给 review；本轮不重开那条贵路径，避免把刚压下来的帧率打回去。

## Implementation Strategy
1. 新增 `ground_tile_meters`（对局 64 世界米），用 `world_xz = p.xz * showcase_world_scale` 采样，不跟 review 坐标绑死。
2. 性能模式：`image25_macro_sand` + `dirt_aerial` 按同一 `ground_tile_meters` 平铺。不用 `sand_uniform`（几乎无地景结构）。
3. 不改高度场、掩码、网格密度、导航与碰撞。

## Implementation Steps
1. 本计划文档
2. `showcase_land.gdshader` 性能模式改世界米平铺
3. `GeneratedTerrain.gd` 写入 `ground_tile_meters`
4. 对照截图验收：载具脚下能看出沙粒，远景仍是大色域

## Timeline
改完必须重新进对局；当前还开着的进程吃不到热改。

## Risk Assessment
- 平铺尺度按玩家指定 64m；若仍偏大/偏碎，只调 `ground_tile_meters`。
- 源图并不低清（宏沙 2048、航拍土 2048）；上一版看起来糊，是因为铺了几乎无结构的 `sand_uniform`。
- 多两次已绑定贴图采样，成本远低于关掉 `performance_mode`。

## Success Criteria
- 近景按约 64m 一张平铺（16m 太碎、200m 太糊）
- 湖/岸/台地/崖壁掩码上色不变
- 不重新打开完整 20 贴图分支

## Progress Tracking
- ✅ 计划
- ✅ 着色器按世界米平铺
- ✅ 运行时写入 tile 参数
- ✅ 改用有地景结构的贴图（宏沙 + 航拍土）
- ✅ 对局尺度改为 64m 一张
- ⏳ 重新进局验收

## Related Files
- `AI_RTS/source/match/maps/generated/showcase_land.gdshader`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/docs/plan/terrain-unit-texture-scale-plan.md`
