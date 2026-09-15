# G4 8FPS 再压 Implementation Plan

## Overview
真机已从 2 帧回到约 8 帧。副官口显示物理物体为 0，但 `process_ms≈150`、`physics_ms≈56`，治理器 `reason=no_effect` 且卡在 `scale=1.0`。本轮按“最简单最快”再砍一刀。

## Current State Analysis
- 2026-09-15 02:28 活局 `op=perf`：`fps=8~9`，`process_ms=148`，`physics_ms=56`，`physics_objects=0`，`draw_calls=174`，`units=8`。
- `Match._setup_subsystems_dependent_on_map` 又调用了 `Terrain.update_shape()`（为“防浮空”），大地图并不烘导航，trimesh 只烧物理。
- 治理器大地图锁只关阴影/雾，**不降 3D 缩放**；降画质被判定无效后又回到 full。
- 游戏着色器仍是 review 用的 `showcase_land.gdshader`：`performance_mode` 是 uniform，贵的分支不会被裁掉；还绑了 20 张 PBR。
- 视觉网格 257²、装饰约 79、镜头 `far` 盖整张 512 图。
- 无导航网格时 `Movement` 仍 `get_next_path_position` + 最多等 180 帧对齐。

## Implementation Strategy
1. 生成图彻底不建地形碰撞；物理 30Hz、每帧最多 1 步。
2. 运行时换超轻 unshaded 着色器，视觉网格再抽稀到 129²。
3. 大地图强制 `scaling_3d_scale=0.5`，非战略装饰直接隐藏。
4. 逻辑地形走直线 + 禁行格 + 高度采样，不再查空导航。

## Implementation Steps
1. 计划文档
2. Match / Terrain / Governor：去 trimesh、限物理、锁缩放
3. GeneratedTerrain：粗网格 + runtime shader + 藏装饰
4. Movement：逻辑地形直移
5. 无头冒烟

## Timeline
改完必须重新进 G4 大湖；当前还开着的对局吃不到热改。

## Risk Assessment
- 地形会更“块”、装饰变少；湖/岩/台地颜色仍按掩码区分。
- 地面单位点到对岸仍停在岸边，不绕湖。
- 小图不进这条。
- 离开对局恢复 60Hz 物理与追帧上限。

## Success Criteria
- 无头 `PASS: g4 large lake playable`
- 新进局 `physics_ms` 个位数，`process_ms` 明显低于 150
- 真机帧率明显高于 8

## Progress Tracking
- ✅ 计划
- ✅ 去 trimesh / 限物理 / 锁缩放
- ✅ 轻量着色与粗网格
- ✅ 逻辑地形直移
- ✅ 无头冒烟（129² 网格、runtime shader、禁行格仍对）
- ✅ 第二刀：逻辑侧保留（无 trimesh / 20Hz / 雾视口删掉 / 空导航不查）
- ✅ 用户否决砍材质：恢复 showcase_land、257² 网格、程序天空、3D 缩放 1.0
- ✅ 碰撞热路径：桥写入禁行格；移动只测下一步，不再每帧扫整段目标

## Related Files
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/Terrain.gd`
- `AI_RTS/source/PerformanceGovernor.gd`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/maps/generated/showcase_land_runtime.gdshader`
- `AI_RTS/source/match/units/traits/Movement.gd`
- `AI_RTS/tools/verify_g4_large_lake_playable.gd`
