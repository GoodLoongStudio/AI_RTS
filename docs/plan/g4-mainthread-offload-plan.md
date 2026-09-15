# 主线程减负（不是整局改成多线程游戏）Implementation Plan

## Overview
用户补了一句：不用 24 线程，**能用到 12 就够**。结论不变——卡的不是“线程开少了”。工作池已经有 24 个待命；对局里 8 个单位走直线，硬切 12 路只会更慢。12 路留给以后真正的纯计算（绕湖 A*、地图导入），主线程现在先把空导航废活卸掉。

## Current State Analysis
- 引擎是 Godot 4.7 .NET。场景树、GDScript、节点信号、几乎所有 `Node3D.global_position` 写入都绑定主线程。
- 日志已有 `WorkerThreadPool: 24 threads`。3080 走 Forward+，渲染提交本来就不在脚本里手写 24 路。
- 活局掉到 11–15 帧时：`physics_objects=0`、`draw_primitives≈45k`，3080 闲着；主线程在空导航图上查路。
- 乱开 `physics/3d/run_on_separate_thread`：GDScript 的 `_physics_process` 会和主线程同时碰节点，属于竞态，不是减负。

## Implementation Strategy
主线程减负分三层，由近到远：

1. **立刻（本轮）**：主线程不要做废活。大图摘掉 `NavigationAgent3D` 内部物理、不要整图 RVO 多边形、走动时禁止 `get_next_path_position()`。
2. **随后（专项）**：新的重活只走 `WorkerThreadPool` / C# `Task`，结果回主线程一次应用。候选：绕湖 A*、副官采样投影、地图导入。
3. **不要做**：把整个 Match 改成多线程 ECS、把单位移动拆到 24 个 GDScript 线程、为了吃核去开物理分线程。

## Implementation Steps
1. 本计划：写清“能卸 / 不能卸”
2. 落地空导航脱离（见 `g4-40-to-15-mainthread-plan.md`）
3. 以后每加一条热路径，先问：数据只读、结果可合并、不碰节点？是才进工作线程

## Timeline
第一层随 40→15 修复一起验收。第二层等有真实绕路/副官负载再开，不提前为了“看起来在用 24 核”而拆。

## Risk Assessment
- 把玩法脚本丢进线程：必现随机崩溃、单位瞬移、命令丢失。
- 物理分线程：和现有 Movement / 相机 / 副官口全部打架。
- 真要 24 核模拟，等于另写一套仿真核，Godot 只当显示器。那是新引擎项目，不是当前仓的重构。

## Success Criteria
- 主线程帧时不再被空导航吃掉
- `op=perf` 能看到 GPU 名和 `cpu_threads`
- 文档与代码都不再暗示“可以把整局改成多线程游戏”

## Other-AI review (2026-09-15)
- `project.godot` 曾打开 `physics/3d/run_on_separate_thread=true`。这不是 12 路玩法线程，只是多 1 条物理线程。活局 `physics_objects=0`，帮不上忙，已关掉。
- `UnitVisibilityHandler` 把间隔改到 0.20s：不是多线程，8 个单位可忽略，保留。
- 同一轮把 512 大湖战争迷雾视口又留着了。256 可以留，512 会再打回十几帧，已按尺寸拆开。

## Progress Tracking
- ✅ 架构结论入库
- ✅ 第一层减负（空导航脱离）已落地，无头冒烟通过
- ✅ 复查并关掉误开的物理分线程
- ⏳ 第二层工作线程任务：待有真实计算负载再开

## Related Files
- `AI_RTS/docs/plan/g4-40-to-15-mainthread-plan.md`
- `AI_RTS/source/match/Navigation.gd`
- `AI_RTS/source/match/units/traits/Movement.gd`
- `AI_RTS/source/net/DebugControlServer.gd`
