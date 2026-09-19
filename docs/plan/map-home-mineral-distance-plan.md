# 主基地家里矿距离 Implementation Plan

## Overview
所有现有地图的主基地（出生点 / 指挥中心）到家里矿（ResourceA 主矿簇）过远。工人开局走太久。本轮不重生成 G2–G4，只把每家主矿簇沿水平面拉近基地，并收紧 G3 以后的 near 资源距离带。

## Current State Analysis
- PlainAndSimple 从 50×50 扩到 100×100 后，四角主矿约 17–20 m（原先约一半）。
- G4 生成图契约 `near_path_range=(8,13)`，家里矿约 9–11 m，仍偏远。
- BigArena 约 7–10 m，接近目标，但仍按同一规则校正。
- 指挥中心碰撞半径 1.8 m、障碍 2.0 m；工人刷在出生点局部 ±3 m；矿障碍约 0.6 m。过近会叠进基地。
- 点击/寻路仍走真实碰撞，不绑 `Y=0` 无限平面。本轮只改 ResourceA 的 XZ，保留原 Y。
- 扩张矿、侧翼矿必须留在原位，不能整图所有矿都往家里吸。

## Implementation Strategy
1. 解析每张 `source/match/maps/**/*.tscn` 的 SpawnPoints 与 ResourceA。
2. 每颗矿归最近出生点。距离 ≤22 m 的算主矿簇；不足 2 颗时取最近 2 颗。
3. 整簇平移（保持簇内相对位置与 Y），使簇质心到出生点约 7.5 m；单矿不低于 6.0 m；XZ 夹在地图边距内。
4. 不重跑 G2–G4。只改 G3 默认 `near_path_range` 为 (6, 9)，`res_spawn_dist` 仍为 6 m，避免新图再刷到 8–13 m。
5. 大厅清单以外的生成图一并改，避免以后打开开关又是远矿。

## Implementation Steps
1. 本计划
2. 量清 21 张图每家最近矿距离
3. 脚本改写所有地图 tscn 主矿 Transform3D 原点 XZ
4. 收紧 `contract.py` / `g3_content.py` 注释
5. 复测量确认主矿 ≈7.5 m、扩张矿未动

## Timeline
本轮一次改完现有场景与后续生成默认值。

## Risk Assessment
- 生成图平移后矿可能略偏出土台：只做数米级平移，Y 不改；主矿原本就在 home 台地。
- 误吸扩张矿：22 m 截断 + 每家只动主簇，侧翼/分矿不动。
- 矿叠进指挥中心：单矿下限 6 m（与 G3 `res_spawn_dist` 一致）。
- 历史 mapgen 文档仍写 8–13 m：只改生效契约，不改旧计划正文。

## Success Criteria
- PlainAndSimple 四家主矿簇质心约 7.5 m（原 ~18 m）
- G4 `16-0-1ca6e21aa1` 四家 near 矿质心约 7.5 m（原 ~10 m）
- 扩张/侧翼矿坐标不变
- 新生成默认 near 路径带为 6–9 m，出生点净空仍 ≥6 m

## Progress Tracking
- ✅ 计划文档
- ✅ 量清现图（PlainAndSimple 主矿约 17–20 m；生成图约 9–11 m）
- ✅ 改写全部 21 张地图 tscn（主矿 6–8.5 m，扩张矿未动）
- ✅ 收紧 G3 `near_path_range` 为 (6, 9)
- ✅ 复测：无主矿 >8.51 m，脚本二次 dry-run 不再改写

## Related Files
- `AI_RTS/source/match/maps/PlainAndSimple.tscn`
- `AI_RTS/source/match/maps/BigArena.tscn`
- `AI_RTS/source/match/maps/generated/**/*.tscn`
- `AI_RTS/tools/mapgen/rtsmap/contract.py`
- `AI_RTS/tools/mapgen/rtsmap/gates/g3_content.py`
- `AI_RTS/tools/pull_home_minerals.py`
