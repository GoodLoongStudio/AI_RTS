# DeepSeek Harness 执行提示词：世界尺度运行时审计与修复

你正在修改 `G:/AIRTS/AI_RTS`。本任务的目标不是把所有数字乘一个系数，而是修复尺寸更新后各个系统之间的真实口径断裂。

## 必读文件

1. `AGENTS.md`
2. `skills/闭环验证工作法.md`
3. `agent/manifest.json`
4. `agent/plans/2026-10-01-world-scale-runtime-audit-plan.md`
5. `agent/mcp/README.md`

你已经安装了 Godot bridge、Godot skill、Godot play 和 MCP 等插件，但插件能力不是事实来源。必须自己阅读当前代码、运行时探针和截图；不要被旧 Agent 的报告、旧提示词或插件自动推断带着走。

## 绝对禁止

- 不得把坦克假定为 9m；当前运行时探针测得坦克视觉模型约 2.57 × 1.75 × 3.80m。
- 不得把视觉长度、碰撞直径、Movement 半径、carve 外缘或建筑 footprint 混成一个“尺寸”。
- 不得给所有速度、射程、视野和特效统一乘一个全局系数。
- 不得在没有运行时证据的情况下修改 speed、range、sight、particle、explosion 或 click effect 数值。
- 不得只改 `.tscn` 视觉节点而不验证权威逻辑；也不得只改平衡 JSON 而不验证 HUD/AI/实际结算。
- 不得用改测试断言、降低阈值或屏蔽错误日志的方式让测试变绿。
- 不得重置、清理或覆盖其他 Agent 的未提交改动。

## 第一阶段：只读基线

开始先输出：

1. `git status --short`；
2. 本任务相关文件的 mtime；
3. 当前 Godot/MCP 进程和端口；
4. 当前尺寸探针、碰撞探针、移动/攻击/视野/特效相关测试；
5. 当前坦克、重坦、装甲车、运输车、步兵、一个建筑和一个炮塔的运行时数据。

先运行现有 `tests/automated/_SizeTableProbe.tscn`。如果步兵结果接近 0，说明蒙皮网格尚未就位或探针口径错误；先改探针为稳定的 Skeleton3D/运行时姿态包围盒，不得拿 0 当真实尺寸。

把本次运行的原始输出、JSON、截图放到 `agent/runs/<run-id>/`，并在 `baseline.md` 中记录命令和 rc。

## 第二阶段：建立审计表

对每个实体记录以下列：

```text
unit_type
visual_aabb_world_m
collision_shape_world_m
movement_radius_m
movement_obstacle_carve_bounds_m
construction_footprint_m
spawn_offset_m
rally_offset_m
muzzle_offset_m
speed_mps
attack_range_base_m
sight_range_base_m
effect_assets_and_world_bounds
source_and_probe
```

每个值必须标注来源：运行时测量、场景、平衡 JSON 或代码常量。无法测量就写 `unknown`。

## 第三阶段：修复几何和判定

依次检查：

1. `Geometry` 与真实模型 AABB；
2. `CollisionShape3D` 与模型底座/主体；
3. `Movement.radius`、`MovementObstacle.radius`、vertices、NavigationMesh.agent_radius；
4. 施工 footprint、相邻建造和白色建造范围；
5. 出生点、集结点、工人站位、炮口和弹道起点。

碰撞需要包围网格或明确的几何近似；不能为了方便把所有实体改成一个大圆。建筑、炮塔、移动单位的碰撞策略可以不同，但每种策略必须有探针和理由。

攻击距离必须先决定语义：当前 `Unit.gd` 有“基础距离 + 双方半径”的表面到表面补偿。检查并统一：

- 权威攻击判定；
- `AttackRangeIndicator` 显示；
- AI 索敌/追击；
- 强制攻击；
- HUD 和调试标签。

视野同理：区分基础视野圈与针对具体目标的有效可见距离，不要让 FogOfWar 圆圈和目标可见性悄悄使用两套无法解释的公式。

## 第四阶段：只按证据调整玩法数值

对速度、攻击距离、视野分别做可重复测试：

- 20m、40m 路线测移动耗时；
- 固定双方半径测“刚好能开火”的中心距；
- 固定观察者和目标半径测“刚好进入视野”的距离；
- 记录旧值、新值、观测、选择新值的理由。

如果当前值只是玩家主观觉得慢/近，先通过探针确认实际值和显示值是否不一致，再决定调参。不能把玩家感觉直接换算成模型缩放。

## 第五阶段：特效审计

至少检查并实测：

- `source/match/utils/SparklingAnimation.tscn`：采矿/闪光粒子；
- `source/match/units/projectiles/ShellExplosion.tscn`：炮弹/火箭爆炸；
- `source/match/units/projectiles/CannonShell.tscn`、`Rocket.tscn`、`RifleRound.tscn`：弹体、曳光、尾焰、飞行速度；
- `source/match/utils/MouseClickAnimation.tscn`：右键地面移动指示；
- `source/match/hud/CommandVisualizer.gd`：命令信标和路径；
- 炮口、命中、死亡、建筑爆炸、维修和建造特效。

所有特效记录：世界 AABB/半径、贴地高度、寿命、速度、透明度、锚点和是否继承父节点 scale。特效不能因为父节点迁移而意外放大或缩小两次。

## 第六阶段：验证与交付

每次精确编辑后立即做解析/构建校验。最终必须完成：

1. 相关 GDScript 校验和 `dotnet build OpenRTS.sln --no-restore --nologo`；
2. 真实 Match 运行时探针；
3. 可见 Godot MCP 截图，并实际打开图片检查；
4. 相关 Godot 回归套件和全量回归；
5. 至少一个独立探针/独立 Agent 复核；
6. `agent/reports/closed-loop/2026-10-01-world-scale-runtime-audit-report.md`。

报告必须明确区分：

- 已由运行时证据证明；
- 只完成代码但尚未截图；
- 发现的旧分支/并行 Agent 冲突；
- 尚未修复的问题；
- 可安全回滚的文件和命令。

如果无法完成闭环，停止并标记 `blocked` 或 `needs-review`，不要用“应该已经好了”收尾。
