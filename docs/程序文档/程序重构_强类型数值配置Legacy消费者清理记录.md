# 强类型数值配置 Legacy 消费者清理记录

> 日期：2026-08-15
>
> 状态：`ECO-007D` 已完成
>
> 前置：`ECO-007C` 已由项目负责人人工验收

## 1. 本轮结果

HUD、传统规则 AI 和自动测试已经改为通过 `BalanceConfigRuntime` 查询本局不可变 Catalog。以下旧字典已从 `MatchConstants.Units` 删除：

- `DEFAULT_PROPERTIES`；
- `PRODUCTION_COSTS`、`PRODUCTION_TIMES`、`PRODUCTION_QUEUE_LIMIT`；
- `CONSTRUCTION_COSTS`、`STRUCTURE_BLUEPRINTS`；
- `PROJECTILES`。

全仓运行代码与测试不再直接引用这些标识。历史设计文档中保留旧名称，用于解释迁移前问题和评审依据，不属于运行时消费者。

## 2. GDScript 查询边界

`BalanceConfigRuntime` 新增三个只读查询：

| 方法 | 消费者 | 返回内容 |
|---|---|---|
| `GetUnitDisplaySnapshot` | HUD Tooltip | 类型、HP、视野及当前单主武器显示值 |
| `GetProductionCost` | HUD、规则 AI、测试 | 总是包含 A/B 键的生产成本副本 |
| `GetConstructionCost` | HUD、规则 AI、测试 | 总是包含 A/B 键的施工成本副本 |

返回的 Godot Dictionary 是临时副本。GDScript 修改副本不会改变 Catalog，也不能覆盖 C# 生产、施工或战斗服务使用的权威定义。

## 3. HUD 与规则 AI

- 四类生产/建造菜单的 Tooltip 从 Catalog 读取 HP、伤害、攻击间隔和成本；
- Tooltip 继续保留迁移前 `damage * interval` 的疑似 DPS 公式，本轮不顺带改变玩家显示；
- `EconomyController`、`DefenseController`、`OffenseController` 的资源请求、到账断言和放置调用使用同一成本查询；
- StructurePlacement 的第四个 Legacy 成本参数仍为兼容形状，但运行时继续忽略它，实际扣款只信任 Catalog；
- 主菜单不再依赖旧字典枚举预加载路径；Match 的 asset manifest 在对局装配时验证并预加载所需 PackedScene。

## 4. 自动验证

- C# 构建：0 warning，0 error；
- 57 项纯 C# 测试通过、0 项失败；
- 配置冒烟增加 HUD 显示快照、Tank 生产成本和 CommandCenter 施工成本检查，0 failure；
- Tank 命令桥场景加载 HUD 后完成，0 failure；
- `TestPlayerVsAI.tscn` 无界面短时运行未出现脚本错误、未知配置、成本断言或 C# 异常；
- 全仓 `rg` 检查确认源码和测试不存在旧字典引用；
- C# 格式和 `git diff --check` 通过。

Godot 退出期 Navigation RID/ObjectDB 泄漏仍属于既有缺陷，不在本轮修改。

## 5. 人工验收建议

1. 依次选择 Worker、CommandCenter、VehicleFactory、AircraftFactory，检查所有建造/生产 Tooltip 正常显示；
2. 检查 HP、成本及攻击单位的伤害/攻击间隔显示与迁移前一致；
3. 分别生产 Worker、Tank、Drone、Helicopter，确认扣款、资源不足和退款正常；
4. 放置五类建筑并检查扣款、视野限制、施工和取消退款；
5. 运行玩家对传统规则 AI 场景，确认 AI 能请求资源、采集、建造、生产并进攻；
6. 检查 Godot 输出中没有未知 UnitType、Production、Construction 或 manifest 错误。

2026-08-15 项目负责人从 Main 进入自定义战斗并完成一局：传统敌人 AI 能正常运营、建造，胜利判定正常。结合 HUD、配置查询和自动回归证据，`ECO-007D` 验收完成；`ECO-007A～D` 及 `ECO-007` 总项结项。传统敌人 AI 的玩法细化留给后续独立分支。
