# 任务计划：碰撞物件全面优化（RA3 口径）

- 状态：`in-progress`
- 创建时间：2026-10-01
- 负责人 Agent：主线（DeepSeek Harness）
- 关联提示词：`agent/prompts/collision-bodies-optimization.md`（待补）

## 目标

玩家在 F9 碰撞可视化下看到的每一个碰撞体（单位、建筑、炮塔、金矿、装饰物、地图静态体），
都与它的**本体**贴合、不制造拥挤与寻路堵塞；导航 carve 洞只在**确实需要阻挡**的物件上存在。

## 非目标

- 不改武器数值、经济数值、AI 行为。
- 不改地图生成器产出的墙体几何（只核对其尺寸是否贴合）。

## 当前证据

- 现象：所有单位逻辑半径曾是统一 2.0（缺省），炮塔被炮管撑到 3.3/3.0/3.0；金矿在 F9 里显示 4m 红洞。
- 基线截图/日志：`agent/runs/`（本轮：`_indep_colliders2.log`、`tmp_logs/rt3.log`）。
- 相关代码：`source/match/units/*.tscn`、`non-player/Resource*.tscn`、`MovementObstacle.gd`、
  `OreRefinery.gd`、`ReturningToBase.gd`、`debug/CollisionVolumeOverlay.gd`、
  `tests/automated/UnitRadiusCoverageSmokeTest.gd`。

## 权威口径

| 领域 | 权威来源 | 当前值 | 目标值/规则 |
|---|---|---|---|
| 视觉 | 场景 `Geometry` 分支 | 逐单位实测 AABB | 不动 |
| 碰撞 | 场景 `CollisionShape3D` | 建筑 Box / 炮塔·载具 Cylinder | 贴合本体；炮塔只算底座 |
| 逻辑/导航 | `Movement.radius`、`MovementObstacle.radius` | 见 `UnitRadiusCoverageSmokeTest` 两列表 | 避让半径与模型解耦；carve 只给真阻挡物 |
| 平衡 | `config/balance/*.json` `footprintRadiusMeters` | = 逻辑半径 | 与场景逐位一致 |
