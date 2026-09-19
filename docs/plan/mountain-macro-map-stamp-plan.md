# 山体不再印整张地图 Implementation Plan

## Overview
对局山体顶/缓坡仍能看见一张俯视地图（卫星宏图 + G2 轮廓）。把台顶材质锁回台地高度带，山体走岩石，不再用世界对齐宏贴图盖坡面。

## Current State Analysis
- `showcase_world_scale=1` 后 `p.y` 已是世界米：平地 0.6、台顶 8.1、山体 15–50。
- 运行时仍写 `ground_height=2.34`、`top_height=14.35`（旧 review 尺）。
- `top_m` 只有下限没有上限：高于约 13m 的平坦山体被当成台顶，再混入 `image25_macro_sand`（1800m 一张）。
- `rts_macro_albedo.png` 还带 G2 台地轮廓，不能再当宏图。

## Implementation Strategy
1. 锚点改回契约：地面 0.6、台顶 8.1。
2. 台顶只在台地高度带生效；更高处用岩石。
3. 世界对齐宏贴图不得混进山体/陡坡。
4. 不改高度场、几何、`map_id`。

## Implementation Steps
1. 本计划
2. `showcase_land.gdshader` 台顶带 + 山体禁宏图
3. `GeneratedTerrain.gd` 写入正确锚点并关闭对局宏图

## Timeline
本轮改着色；需重开对局才看得见。

## Risk Assessment
台地顶若被上界切太狠会变岩色。上界放在台顶 +1.5～+6m，台地 8.1m 不受影响。

## Success Criteria
- 山体顶是岩石，不是整张沙色卫星图
- 台地顶仍是干尘土
- 平地沙粒还在

## Progress Tracking
- ✅ 计划
- ✅ 着色器（台顶限高度带，山体禁宏图）
- ✅ 运行时锚点 0.6 / 8.1，对局关闭宏图

## Related Files
- `source/match/maps/generated/showcase_land.gdshader`
- `source/match/maps/generated/GeneratedTerrain.gd`
