# 任务计划：生产与建造速度统一 2 倍

- 状态：`complete`（报告：`agent/reports/closed-loop/2026-10-12-production-construction-speed-2x.md`）
- 创建时间：2026-10-12
- 负责人 Agent：Qoder
- 关联提示词：无（单轮平衡改动）

## 目标

玩家可观察的结果：同一条生产队列、同一座建筑工地的完成时间变为原来的一半（出兵、造建筑整体 2 倍速），资源造价、工效倍率（成长/同类建筑加成）、退款比例均不变。

## 非目标

- 不改矿车采集/精炼节奏（`collectionDurationMilliseconds`）。
- 不改单位移动速度、攻击冷却、视野、尺寸。
- 不改 `workPerTick` 权威口径（保持 1），避免与成长/同类建筑倍率判据（1.24 / 1.5 / 2.0）纠缠。
- 不重新导出 `打包版`（需用户明确要求）。

## 当前证据

- 权威来源：`config/balance/demo.balance.v1.json` 是唯一事实来源（`BalanceConfigLoader.cs:570` 注释），
  工期模型为 `duration(tick) = requiredWork / workPerTick`，物理 60Hz。
- 基线日志：`agent/runs/speedx2/`
  - `core-before.log`：`dotnet run --project ./tests/core/AI_RTS.Core.Tests.csproj` → 改动前已有 25 条红
    （Balance config 22 红 + Production service 3 红），属并发会话的在飞状态，非本任务引入。
- 相关代码：`ConstructionService.cs:187-259`（自动+工人工作量累加）、`:283-292`（退款按剩余比例，尺度无关）、
  `ProductionService.cs:208-266`、`ProductionQueue.gd:16-24`（HUD ETA 由 required_work 折算）。

## 权威口径

| 领域 | 权威来源 | 当前值 | 目标值/规则 |
|---|---|---:|---:|
| 平衡-生产工期 | `demo.balance.v1.json` → `productions[].requiredWork` | worker180/drone180/tank360/heli360/soldier120/truck240/apc300/heavy420/sniper120/rocketeer140 | 全部 ÷2 |
| 平衡-施工工期 | `demo.balance.v1.json` → `constructions[].requiredWork` | 200×7、machine_gun_turret 240 | 全部 ÷2 |
| 施工工效 | `constructions[].automaticWorkPerTick`、`unitTypes.worker.constructor.workPerTick` | 1 | 不变 |
| 生产工效 | `Unit.gd:156-159 refresh_production_work_rate()` | 1.0 基线 | 不变 |
| e2e 夹具镜像 | `config/balance/adjutant-e2e.balance.v1.json` | 与主表同值 | 同值同步 ÷2 |

## 改动范围

- 允许修改：两份 balance JSON 的 18 处 `requiredWork`；直接受影响的判据
  （`tests/core/BalanceConfigLoaderTests.cs` 工作量断言、`SameTypeEconomyRulesSmokeTest.gd` 帧阈值与注释、
  `AutomaticConstructionSmokeTest.gd` / `RefineryFreeMinerSmokeTest.gd` 注释）。
- 禁止修改：`workPerTick`、`cost`、尺寸/导航/射程、`source/csharp` 服务逻辑。
- 并发风险文件：`config/balance/*.json`、`source/csharp/Application/Configuration/BalanceConfig*.cs`、
  `tests/core/BalanceConfigLoaderTests.cs`、`tests/automated/Production*` 均已被其他会话标为 dirty；
  只按行精确替换 `requiredWork`，不整文件重写、不格式化。

## 验证矩阵

| 判据 | 方法 | 通过条件 |
|---|---|---|
| 配置被权威加载 | `dotnet build OpenRTS.sln` + loader 测试 | 0 编译错误；无 `平衡配置加载失败` |
| 施工 2 倍 | `AutomaticConstructionSmokeTest` 实测帧数 | 由基线 ~200 Tick 降到 ~100 Tick |
| 生产 2 倍 | `SameTypeEconomyRulesSmokeTest` / `ProductionQueueSmokeTest` | 队列打满帧数减半且仍 0 failure |
| 比例机制未坏 | `SameTypeEconomyRulesSmokeTest` 的 ×1.5、`GrowthModifiersSmokeTest` | 仍按倍率缩短 |
| 退款经济学未变 | `AutomaticConstructionSmokeTest` 退款场景 | 0 failure |
| e2e 镜像一致 | 两份 JSON `requiredWork` 逐值比对 | 18/18 相同 |
