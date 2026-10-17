# 给 DeepSeek Harness 的执行提示词：导航与窄通道通行优化

你在 `G:\AIRTS\AI_RTS` 工作。先读 `AGENTS.md`、`skills/闭环验证工作法.md`、`agent/manifest.json`，再读本文件与 `agent/plans/2026-10-02-navigation-narrow-passage-plan.md`。不要清理或回滚其他 Agent 的未提交改动。

## 问题

截图中的坦克位于建筑之间，视觉上只差一点可以通过，但当前逻辑把建筑当成包含圆，再叠加单位个人半径，导致空气墙/提前堵路。现有 `_obstacle_footprint_closest()` 不能只“写着存在”，必须在受控窄口阶段真正被调用并由截图、距离和订单终态证明。

## 必须先诊断

检查并在报告中引用：

- `source/match/units/traits/Movement.gd` 的导航回调、停滞恢复、`_push_out_of_static_obstacles()`、现有 `SOFT_PHASE`；
- `source/match/units/traits/MovementObstacle.gd` 的真实 vertices、碰撞 bounds、形状支持和导航 carve；
- 每个实际单位的 `CollisionShape3D` 类型/世界尺寸、`Movement.radius`、`MovementObstacle.radius`、近地视觉 hull；
- navmesh `agent_radius`、逻辑地形 `find_ground_path`、RVO `neighbor_distance/time_horizon`；
- 说明“碰撞检测形状”和“移动个人空间/RVO 半径”不是同一个语义。不要因为用户说“缩小碰撞盒”就永久改物理形状。

## 实现要求

1. 在 `Movement.gd` 增加独立 `narrow_pass` 状态机，不能复用/污染友军拥堵 `soft_phase`。
2. 只在主动移动且已经确认停滞/重寻路阶段尝试；只允许静态障碍几何候选，不允许敌军附近启用。
3. 形状准入必须满足：原包含圆会阻挡；Box/圆柱/胶囊/球的最近点计算显示下一步和短前视段仍有净空；单位真实地面碰撞半宽与近地视觉 hull 的较大值加至少 `0.10m` 后仍不相交。不得只看中心距离。
   当前第一阶段只允许矩形 Box 建筑进入窄阶段；圆柱/胶囊/球即使表面距离接近，也先走保守安全路径，除非后续有独立真实 Match 证据证明不会破坏绕行。
4. 窄阶段只缩小自身 `Movement.radius`/RVO个人空间，起步系数约 `0.80`，下限不得低于真实地面 hull + 0.10m；持续不超过 `0.65s`，冷却约 `1.5s`。新命令、停止、到达、不可达、异常和超时必须幂等恢复原值。
5. 不关闭 `avoidance_enabled`，不修改其他单位，不改攻击/选择/建造/命中用 `CollisionShape3D`。如果你认为必须临时修改物理形状，必须逐实例 `duplicate()`，不能修改共享 Shape3D 资源，并另外验证恢复、攻击命中、选择与建造重叠；默认优先不动物理形状。
6. 正常帧保持廉价圆形快速路径；只在恢复或窄阶段做形状查询。加入预算和统计日志，记录进入/拒绝原因、圆形与形状净空、缩放前后半径、持续时间、回退次数。
7. 对不支持的形状显式告警/统计并采用保守安全路径，禁止静默当成无障碍。

## 必须新增的验证

- 新增 `tests/automated/NarrowPassageSmokeTest.gd/.tscn`，必须实例化真实 `Match.tscn`，不能只在纯数学脚本里测。
- 夹具至少包含：
  - A：矩形建筑窄口，圆形安全半径会拒绝、真实形状 + 0.10m 净空可通过；
  - B：比真实 hull 更窄的通道，必须拒绝/绕行，不能穿墙；
  - C：普通空地短移动，验证没有因新状态机变慢或误触发；
  - D：新命令/停止在窄阶段触发，验证半径立即恢复。
- 探针输出 JSON，字段至少包括 `unit`, `shape`, `circle_clearance`, `shape_clearance`, `entered`, `restored`, `terminal_state`, `min_hull_gap`, `elapsed_frames`。
- 创建可见截图：模型、CollisionShape3D 包围盒、导航 carve、窄阶段有效边界分色；实际打开图片检查空气墙和穿模。
- 运行相关测试：`NavigationStabilitySmokeTest`、`LocalAvoidanceSmokeTest`、`MovementRecoverySmokeTest`、`UnitRadiusCoverageSmokeTest` 和新窄口套件；再按 manifest 跑全量回归。

## 禁止伪修复

- 不得把所有障碍全局改成贴盒、不许只改测试超时/到达容差、不许把 `Unreachable` 当成功。
- 不得永久把 Tank/HeavyTank 的碰撞形状缩小，不得关闭 RVO/导航或传送单位。
- 不得只看日志/JSON；必须开图查看截图。

## 交付

修改前先记录基线。完成后写 `agent/reports/closed-loop/2026-10-02-navigation-narrow-passage.md`，包含根因、文件、数值前后、运行命令和 rc、截图路径与人工观察、未验证项、是否存在并行工作区风险。未满足闭环时标记 `needs-review`，不要说“已完成”。
