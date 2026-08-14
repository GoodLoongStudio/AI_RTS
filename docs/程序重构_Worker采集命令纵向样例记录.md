# Worker 采集命令纵向样例记录

## 1. 范围

`CMD-026B / ECO-002` 把 Worker 右键资源点接入公共命令、订单和统一 Stop 边界，同时暂时复用 Legacy GDScript 采集表现与数值。

本切片实现：

- 持续采集—返程—交付循环；
- 玩家明确指定唯一资源节点；
- 只有交付完成后玩家资源账户增长；
- Stop 暂停整个任务且不自动恢复；
- 再次右键资源点创建新 Gather 订单；
- 资源耗尽后完成最后一次交付并待机；
- Worker 死亡时未交付载荷丢失。

本切片不实现任务奖励、被动经济建筑、通用资源账户、施工暂停、自动采矿策略或自动寻找附近资源。

## 2. C# 公共边界

新增：

- `ResourceNodeId`：资源节点独立稳定身份，不把非单位资源伪装成 `UnitId`；
- `ResourceKind`：强类型 A/B 资源分类；
- `GatherResourcesCommand`；
- `UnitOrderKind.Gather`；
- 通用终态 `UnitOrderState.Completed`；
- `IResourceNodeRepository`；
- `IWorkerTaskPort`；
- `UnitCannotGather`、`ResourceTargetNotFound`、`ResourceDepleted`、`WorkUnavailable` 稳定错误码。

`GodotResourceNodeRegistry` 维护资源节点弱引用和 Metadata ID；`LegacyWorkerTaskPort` 把 Application 请求适配到 Worker 组合 Action。命令服务负责所有权、能力、资源可用性、部分成功和订单状态，GDScript 不决定公共回执。

## 3. Stop 与任务替换

Gather 活动时，统一 Stop 不调用普通移动/攻击 Stop 端口，而是调用 `IWorkerTaskPort.RequestSuspend`：

- 订单保持同一 `UnitOrderId` 并进入 `Suspended`；
- 组合 Action 留在 Worker 上；
- 当前资源目标、阶段和携带资源保留；
- 移动停止，采集计时器销毁，交付状态不推进；
- 不自动恢复。

玩家再次右键资源点会建立新 Gather 订单，旧暂停订单进入 `Cancelled`。普通 Move/ForceMove 同样可替换 Gather，Worker 携带资源不会被移动命令清空。

施工仍是独立 Legacy 任务。其阶段保留暂停尚未实现，因此当前 Stop 必须返回拒绝，不能伪装为成功；后续由 `ECO-004` 处理。

## 4. 资源耗尽与载荷

资源节点存量归零后退出场景，采集 Action 记录正常 `Completed` 原因：

- Worker 有载荷：先前往最近有效己方 CommandCenter，交付后完成订单；
- Worker 无载荷：立即完成订单；
- 完成后不查询其他资源节点，Worker 待机。

玩家账户仍由 Legacy `Player.resource_a/resource_b` 保存，但写入只发生在 `_transfer_collected_resources_to_player()` 交付点。Worker 在去程、采集中或返程死亡时，节点及其携带字段一起销毁，不会修改玩家账户。

未来 `ECO-001` 必须用通用资源交易边界替换该写入点，使 Worker 交付、任务奖励、被动经济建筑和退款共享账户服务；Gather 不能拥有玩家余额。

## 5. 自动验证

纯 C# 核心测试新增：

- Worker/Tank 混合批次返回 `PartiallyAccepted` 与 `UnitCannotGather`；
- 合法 Worker 获得独立 Gather 订单；
- Gather 期间 Stop 只调用工作暂停端口；
- 订单进入 `Suspended`，通用 Stop 端口不被误调用。

`WorkerGatherSmokeTest` 运行时覆盖：

1. 右键资源点产生 Gather 与 `Accepted`；
2. 取得载荷但未交付时玩家账户不增长；
3. Stop 后 2.3 秒内 Worker 不移动、载荷不增加、矿点不减少且无隐藏交付；
4. 再次右键创建新订单，旧订单 `Cancelled`；
5. 耗尽后最后交付使玩家 B 资源增加 2，订单 `Completed`，Worker 待机；
6. 第二个 Worker 携带 A 资源时死亡，账户不增长，订单 `UnitLost`。

2026-08-14 验证结果：纯 C# 18 项测试 0 failure；Godot Worker Gather、实体 ForceMove 与 Helicopter 命令回归均为 0 failure；C# 编译 0 警告、0 错误。Godot 退出时仍有已登记的 RID/ObjectDB 清理告警。

## 6. 人工验收

运行 `tests/manual/TestAllUnits.tscn`：

1. 选择矿石旁的 Worker，普通右键附近存量为 2 的 B 类矿石；
2. Worker 开始采集时，玩家资源不应立刻增长；
3. 采到第一份后点击传统 HUD“停止”，确认 Worker 完全暂停且不会自行恢复；
4. 再次右键同一矿石，Worker 应继续采完、返程并交付；
5. 交付后玩家 B 资源一次增加到 2；
6. 该矿耗尽后 Worker 留在待机状态，不自动前往其他矿点。

当前状态：代码与自动测试完成，等待人工验收。
