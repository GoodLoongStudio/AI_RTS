# 02 开局与经济

## 目标

1. 开局 8 秒内完成摸底并进入决策循环；
2. **经济起点 = 建矿场**：矿场完工自动赠送一辆矿车（红警2 精炼厂口径），矿车由车辆工厂量产；
3. 资金不堆积：长期 > 8000 就扩产能，而不是压着钱。

## 经济链路（2026-09-28/30 口径，与旧版手册完全不同）

```
build 矿场(ore_refinery)  →  完工赠 1 辆矿车  →  矿场自动接管矿车（无需逐车下令）
车辆工厂(vehicle_factory) →  produce 矿车(worker)  →  附近矿场自动接管
矿车采满 → 只回矿场交货（主基地不收矿）→ 矿场交付入账
```

- **矿场是唯一交矿点**：主基地/其他建筑一律不收矿。
- **指挥中心不再生产矿车**：矿车只能由车辆工厂生产（对指挥中心下 Worker 单会得到 `ProductNotAllowed`）。
- **gather 的收入前提是矿场存在**：没有矿场时矿车会采满后**原地持货等待**（不是 bug），
  矿场建成接管后自动把囤矿交付并恢复循环。看到"矿车满载却没收入"，正确动作是建矿场，不是重发 gather。

## 输入数据

- `CTL status lite=true` → `counts.mine_by_type`：`worker`（矿车）数量、`CommandCenter` / `VehicleFactory` / `AircraftFactory` / `OreRefinery` 建筑数量；
- `balance.a`：当前资金（生产与建造条件的判断依据）；
- `production[]`：找 `producer_type=VehicleFactory` 的项，看 `items` 是否为空（车辆工厂队列空闲才补矿车单）；
- 全量 status（低频）：`resources[]` 矿点位置、矿车 `pos` 与 `action`、`construction[]` 在建工地（施工中不能开第二个工地）。

## 决策条件

| 条件 | 动作 |
|---|---|
| `counts.mine_by_type.OreRefinery == 0` 且资金 ≥ 矿场造价 | `build scene='res://source/match/units/OreRefinery.tscn' as_player=主人`（**不带 pos**，自动相邻放置） |
| 矿车数 < 4 且车辆工厂队列空闲（`production` 中 VehicleFactory 的 `items==[]`） | `produce unit=<车辆工厂名> scene='res://source/match/units/Worker.tscn' as_player=主人` |
| 存在空闲矿车且**已有矿场** | `gather units='[...]' kind=a as_player=主人`（满载自动回矿场交货，不要重发） |
| `balance.a > 8000` 且车辆工厂 < 3 | `build` 车辆工厂（不带 pos） |
| 无飞行器工厂且 `balance.a > 12000` | `build` 飞行器工厂（无人机/直升机的前置） |
| 资金长期 > 12000 且产能已满 | 优先再建车辆工厂扩产能 |

开局流程：`CTL status` → `match=false` 则 `start with_ai=true`（等 8 秒复查）→ 找 `human:true` 的主人 → 中途接管则**沿用**既有部队与建筑，不推倒重来。

## 不应该做什么

- **指挥中心不产矿车**：矿车订单只能发给 `producer_type=VehicleFactory`，坦克也只能发车辆工厂。发错得到 `ProductNotAllowed`（这是该错误的头号来源）。
- **不要给 build 手算坐标**：省略 `pos` 权威端自动相邻放置；相邻规则下"离既有建筑多远才算合法"只有权威端知道，自己算坐标大概率被拒。
- **不要把 `ConstructionInProgress` 当选址失败**：一次只能建一个，这是等待信号——等 `construction[]` 清空后**原样重发**，不要换坐标、不要连发。
- 不看 `production[].items` 就对同一车辆工厂重复 `produce`（排双份队列）。
- 把全部矿车拉去建造（采集断档，经济崩盘）；建造最多占用一半矿车。
- 矿车满载往返期间重发 gather（打断节奏）。
- 开局阶段反复 `start` 重开对局。

## 失败后的恢复策略

| 回执 | 处理 |
|---|---|
| `ProducerNotFound` | `production[]` 里重新找 `producer_type` 匹配的建筑名（建筑重建/换图后名字会变），用新名字重发一次 |
| `ProductNotAllowed` | producer 选错类型：矿车与坦克都走 `VehicleFactory`，本条命令不算失败重试 |
| `ConstructionInProgress` | **等待信号**：等当前工地完工（`construction[]` 状态变化）后原样重发，绝不换坐标重试 |
| `InsufficientResources` | 攒钱：本轮全部矿车 gather、零成本决策，下轮资金够再补单 |
| `QueueFull` | 生产建筑是单队列：等 `items` 清空再补单，期间做其他事 |
| `NoValidSite`（build 免坐标时） | 真没有合法落点（基地周围无可建地面/无已探明矿点）：换 `hint` 方位重试一次，仍失败记 blocked |
| 建造长时间不推进（hp 不涨） | 记录现场（建筑名/hp/工人数），继续其他管理器，不反复重派 |

## 对应的游戏控制命令或状态字段

- 命令：`build scene`（**省略 pos = 自动相邻放置**）、`gather units kind=a`、`produce unit=<车辆工厂> scene=<Worker.tscn>`、`status lite=true`、`sleep 5`。
- 字段：`counts.mine_by_type`、`balance.a`、`production[].producer_type` / `items` / `queue_size`、`construction[]`（在建工地）、回执 `accepted` / `status` / `reason` / `producer` / `queue_size`。
- 生产协议细节（队列空闲判定、PendingAuthority 处理）见 04 章。
