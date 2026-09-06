# 04 生产与军队

## 目标

1. 生产队列永不空：每轮检查所有生产建筑，空闲且资源够就按优先级补单；
2. producer 选择**零错误**：类型对、名字来自 status；
3. 军队规模受控（能指挥得动），按计划生产而不是有钱就造。

## 输入数据

`status lite=true` 的 `production[]`，每一项来自服务器生产快照：

| 字段 | 含义 |
|---|---|
| `producer` | 生产建筑名（下单时 `produce unit=<这个名>`） |
| `producer_type` | 建筑类型（选 producer 的**唯一依据**，不猜名字） |
| `queue_size` | 当前队列长度 |
| `items[]` | 队列明细：`definition_id`（在生产什么）、`state`、`completed_work` / `required_work`（进度）、`version` |
| `last_command` | 该建筑最近一条 produce 回执 |

配套：`balance.a`（资金条件）、`counts.mine_by_type`（现有军力）。

## 决策条件

### 队列空闲判定（从 `production.items` 判断）

- **`items == []`（等价 `queue_size == 0`）⇔ 队列空闲，可下单。**
- `items` 非空时看 `items[0]`：`completed_work / required_work` 是进度，`state` 是阶段——队列在推进就不要动它。
- 空闲且资源够 → 按优先级补单（工人 > 工厂 > 坦克 > 飞行器工厂 > 无人机 > 塔，见 SKILL 生产优先级表）。

### producer 选择（指挥中心 ≠ 车辆工厂，不能混用）

| 要生产的产品 | `producer_type` 必须是 |
|---|---|
| Worker（工人） | `CommandCenter`（指挥中心） |
| Tank（坦克） | `VehicleFactory`（车辆工厂） |
| Drone / 直升机 | `AircraftFactory`（飞行器工厂） |

流程：**先看 `production`，再选 producer**——从 `production[]` 里筛 `producer_type` 匹配且 `items==[]`（或资源紧张时优先最短队列）的建筑，用它 `producer` 字段的原名下单。

### 回执处理

- `accepted=true`（`ok=true`）→ 记账，`queue_size` 回执值同步进账本；
- `status=PendingAuthority` → **已转发未确认**：等待下一次 status，看 `production[].items` 是否出现新 `definition_id`；不要立即重复下单；
- 拒绝 → 按 reason 表（下）处理。

### 军队规模规划

- 接敌前坦克上限 **60**；达到上限停止产坦克，资源留给战损重建；
- 出击时机 = 坦克 ≥ 20 或 intel 显示敌军压境（行军纪律见 05 章）；
- 新坦克落地先去集结点攒着，**不许添油**。

## 不应该做什么

- `PendingAuthority` 期间重复下单（排双份）。
- 对非生产建筑、不存在的名字发 produce（`NoProductionQueue` / `ProducerNotFound`）。
- 无上限生产（v4 实测：385 辆坦克既调不动也拖垮端点）。
- `QueueFull` 时硬塞订单。
- 凭建筑名字猜类型（"Unit_7 看起来像工厂"是禁止的，只认 `producer_type`）。

## 失败后的恢复策略

| 回执 | 处理 |
|---|---|
| `ProductNotAllowed` | producer 类型与产品不匹配：回到 `production[]` 重新按 `producer_type` 筛选，本条不改策略不算重试 |
| `InsufficientResources` | 攒钱：本轮生产管理器空转，工人 gather 不停，下轮复查资金 |
| `QueueFull` | 该建筑本轮跳过；若所有工厂都满且资金雄厚 → 扩产能（build 新工厂） |
| `ProducerNotFound` | 名字失效（建筑被拆/重建）：从最新 `production[]` 取名，重发一次；没有可用建筑 → build 补建 |
| `NoProductionQueue` | 目标不是生产建筑：同上，按 `producer_type` 重选 |
| `DefinitionNotFound` | scene 路径写错：只用 06 章命令表中列出的 scene 路径 |
| 连续 3 轮 `PendingAuthority` 且 `items` 无变化 | 视为订单丢失，重发**一次**；再失败记录并跳过 |

## 对应的游戏控制命令或状态字段

- 命令：`produce unit=<producer名> scene='<res://.../Tank.tscn>' as_player=主人`、`build units pos scene`（扩产能）、`status lite=true`。
- 字段：`production[]`（`producer` / `producer_type` / `queue_size` / `items`）、回执 `accepted` / `ok` / `status` / `reason` / `producer` / `scene` / `queue_size`、`PendingAuthority`。
