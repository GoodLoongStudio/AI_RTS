# G4 大湖进局可玩 Implementation Plan

## Overview
G4 大湖 seed16 进局后看不见地形、小地图失效、帧率约 2。对准每帧还在跑的东西：全屏雾片、269 块水面、706 个作者静态碰撞，以及物理追帧螺旋。

## Current State Analysis
- 2026-09-15 真机副官口 `op=perf`：`fps=2`，`physics_ms=61`，`process_ms=161`，`draw_calls=180`，`units=8`，治理器 `large_map_lock=true` 且 `reason=no_effect`（降画质没用）。
- 地图 tscn 有 **706** 个 `Collision/Solid*`。只把 `shape.disabled=true` / `collision_layer=0` 时，节点仍在 PhysicsServer。Godot 默认最多追 8 个物理步：一步 60ms × 8 ≈ 500ms → 锁死 2 FPS。
- `GeneratedTerrain._ready` 早于兄弟节点 `Collision` 进树；进树前改的 layer 会被场景文件覆盖。必须 `remove_child` + `free()`。
- 269 块水面只 `visible=false`，节点和渲染对象还在。
- 装饰 `visibility_range_end=620`，512m 图上几乎永不剔除。
- 大地图已铺静态预览，但 `MinimapViewport` 仍 `UPDATE_ALWAYS`。
- 台地高差 8m 已拍板，不改台地。

## Implementation Strategy
1. 进树立刻关掉全屏雾片和迷雾视口。
2. 立刻 **free** 作者碰撞和水面片，不要只 disable / hide。
3. 大地图把 `Engine.max_physics_steps_per_frame` 降到 2，打断追帧螺旋。
4. 静态小地图时冻结 SubViewport。
5. 装饰可视距离收到约 100m；大地图锁强制关 MSAA。
6. 高度场/掩码用绝对路径；湖色画在地形着色器上。

## Implementation Steps
1. `Match._enter_tree`：关雾、限制物理追帧
2. `Match` / `GeneratedTerrain`：free `Collision/*` 与 `WaterBody/*`
3. `Minimap.gd`：静态预览后 `UPDATE_DISABLED`
4. `PerformanceGovernor`：大地图锁强制 `MSAA_DISABLED`
5. 无头冒烟：水面/碰撞剩余 0

## Timeline
本轮对准 2 FPS 根因；用户必须重新进 G4 大湖（旧对局进程改不到）。

## Risk Assessment
- 大地图地面单位没有作者盒碰撞，本来 `collision_mask=0`，点击走平面回退。
- 小图不进这条清理。
- 离开对局恢复默认物理追帧上限。

## Success Criteria
- 进 G4 大湖能看见河/湖/台地
- 侧栏顶部是地图预览
- 真机 `op=perf`：`physics_ms` 降到个位数，`fps` 可操作（不再锁 2 帧）
- 无头脚本 `PASS: g4 large lake playable`
- 水面只着色：地面单位不能走进水、不能在水上建造；桥面可走

## Progress Tracking
- ✅ 计划（按真机 2 FPS 重写根因）
- ✅ 进树关雾 / 删除作者碰撞与水面 / 限制物理追帧 / 冻结小地图视口
- ✅ 无头冒烟（`PASS`：水面 269 已删、Collision/Solid* 652 已删、剩余 0）
- ✅ 水面改逻辑禁行（掩码查询，不建水面碰撞）
- ✅ 地形碰撞改为禁行格 + 高度采样，生成图不再建 trimesh / WalkB 物理
- ✅ 8 帧后再压：去 trimesh、30Hz 物理、runtime unshaded、装饰隐藏、3D 缩放 0.5
- ⏳ 用户必须重新进 G4 大湖验收（当前还开着的对局吃不到热改）

## Related Files
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/hud/Minimap.gd`
- `AI_RTS/source/PerformanceGovernor.gd`
- `AI_RTS/source/net/DebugControlServer.gd`
- `AI_RTS/tools/verify_g4_large_lake_playable.gd`
