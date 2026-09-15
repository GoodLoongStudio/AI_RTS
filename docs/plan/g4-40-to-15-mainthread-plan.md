# G4 进局 40→15 帧与多线程 Implementation Plan

## Overview
活局刚进大约 40 帧，过一会儿掉到 15 帧（副官口甚至采到 11 帧）。机器是 12 核 / 24 线程 + RTX 3080。本轮只砍主线程上随时间变重的空导航查询，不砍材质、不降 3D 缩放、不把玩法脚本“拆到 24 核”。

## Current State Analysis
- 2026-09-15 活局 `op=perf`：`fps=11`，`process_ms≈166`，`physics_ms≈83`，`physics_objects=0`，`draw_primitives≈45k`，`units=8`，`gpu` 侧绘制远未打满 3080。
- Godot 日志已写明 `WorkerThreadPool: 24 threads`。工作线程在烘导航、粒子、部分渲染提交；**GDScript / 场景树 / 单位移动必须在主线程**。
- 生成大图已经跳过 Recast，但 `Movement` 仍继承 `NavigationAgent3D`：
  - `_ready` 把单位挂到空导航图上；
  - `_finish_navigation_initialization` 随后给每个地面单位发一小段 `move()`；
  - 工人开始采集后持续移动；
  - 每帧 `_on_velocity_computed` → `_is_moving_actively()` → `get_next_path_position()`，在空图上重查路径。
- `Navigation._ready` 在 `await Match.ready` 之后仍调用 `_setup_static_obstacles()`，给空域/地面各挂一块覆盖整张 512 图的避障多边形。Match 就绪越晚，掉帧出现得越晚，正好对上“刚进 40、过一会 15”。
- `project.godot` 没有 `physics/3d/run_on_separate_thread`。乱开物理分线程会让 GDScript 和物理线程同时改节点，属于竞态，不是“用满 24 核”。

## Implementation Strategy
1. 逻辑地形 / 边长 ≥256 的生成图：不要注册整图 Navigation 避障。
2. 同一条件下：关掉 `NavigationAgent3D` 内部物理、摘掉导航图；`_is_moving_actively` 只看逻辑目标，禁止再调 `get_next_path_position()`。
3. 地面仍走禁行格 + 高度采样；空中只做 XZ 平移，不查空网格。
4. `op=perf` 补 GPU 名、物理步频、静态避障数量，方便确认 3080 在等主线程而不是在画。
5. 不改材质、不改网格精度、不降 `scaling_3d_scale`、不开物理分线程。

## Implementation Steps
1. 本计划文档
2. `Navigation.gd`：`_ready` 与 `setup` 共用跳过条件
3. `Movement.gd` / `MovementObstacle.gd`：摘导航代理，停空查询
4. `DebugControlServer.gd`：perf 观测
5. 冒烟脚本 + 无头验收

## Timeline
改完必须重新进 G4 大湖。当前还开着的对局吃不到热改。

## Risk Assessment
- 地面单位点到对岸仍停岸边，没有绕湖 A*（与现有逻辑地形契约相同）。
- 小图（非生成高度场、边长 <256）仍走 Recast + RVO，行为不变。
- 空中单位在大图上改为直线飞，暂不查空域网格；高度先保持当前 Y，不写死穿高台的全局平面（贴地离地高度另立专项）。
- 旧对局必须重开。

## Success Criteria
- 无头 `PASS: g4 large lake playable`
- 新进局待单位开始走动后，`physics_ms` 应从数十毫秒落到个位数量级
- 帧率不应再随“单位开始采集/走动”从约 40 掉到约 15
- `op=perf` 能读到 GPU 名；`nav_static_obstacles=0`
- **带窗口活局**：256 大湖走动/采集后主线程 `process_ms` 稳定在可玩区间（目标 ≥40 FPS，不能再掉到十几帧）

## Progress Tracking
- ✅ 计划
- ✅ 跳过整图避障
- ✅ 摘掉空导航代理
- ✅ perf 观测
- ✅ 无头冒烟
- ✓ 带窗口活局验收（DCS `--play-map` + `op=perf`）
- ✓ 修侧栏 SCRIPT ERROR / 规则 AI 128 点盲扫 / 迷雾视口每帧重绘
- ✓ 拆 physics_ms：脚本计时 + 2D 物理 + `op=physics_isolate` 活局 A/B
- ✓ 根因：生产完成每物理步对空导航做 24 环径向查询（`production_runtime_us≈60ms`）
- ⏳ 出兵改禁行格 + 部署退避后，再开一把确认走动/采集/出兵后 ≥40 FPS

## Related Files
- `AI_RTS/source/match/Navigation.gd`
- `AI_RTS/source/match/units/traits/Movement.gd`
- `AI_RTS/source/match/units/traits/MovementObstacle.gd`
- `AI_RTS/source/net/DebugControlServer.gd`
- `AI_RTS/tools/verify_g4_large_lake_playable.gd`
