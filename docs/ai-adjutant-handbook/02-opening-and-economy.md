# 02 开局与经济

## 目标

1. 开局 8 秒内完成摸底并进入决策循环；
2. 工人数量恒定在 4~6，采集不断线；
3. 资金不堆积：长期 > 8000 就扩产能，而不是压着钱。

## 输入数据

- `CTL status lite=true` → `counts.mine_by_type`：`Worker` 数量、`CommandCenter` / `VehicleFactory` / `AircraftFactory` 建筑数量；
- `balance.a`：当前资金（生产与建造条件的判断依据）；
- `production[]`：找 `producer_type=CommandCenter` 的项，看 `items` 是否为空（指挥中心队列空闲才补工人单）；
- 全量 status（低频）：`resources[]` 矿点位置、工人 `pos` 与 `action`（判断空闲）。

## 决策条件

| 条件 | 动作 |
|---|---|
| `counts.mine_by_type.Worker < 4` 且指挥中心队列空闲（`production` 中 CommandCenter 的 `items==[]`） | `produce unit=<指挥中心名> scene='res://source/match/units/Worker.tscn' as_player=主人` |
| 存在空闲工人（无往返采集） | `gather units='[...]' kind=a as_player=主人`（满载自动往返，不要重发） |
| `balance.a > 8000` 且车辆工厂 < 3 | 用最近工人 `build` 车辆工厂 |
| 无飞行器工厂且 `balance.a > 12000` | `build` 飞行器工厂（无人机/直升机的前置） |
| 资金长期 > 12000 且产能已满 | 优先再建车辆工厂扩产能 |

开局流程：`CTL status` → `match=false` 则 `start with_ai=true`（等 8 秒复查）→ 找 `human:true` 的主人 → 中途接管则**沿用**既有部队与建筑，不推倒重来。

## 不应该做什么

- **指挥中心和车辆工厂不能混用**：坦克订单只能发给 `producer_type=VehicleFactory`，工人订单只能发给 `producer_type=CommandCenter`。发错会得到 `ProductNotAllowed`（这是该错误的头号来源）。
- 不看 `production[].items` 就对同一指挥中心重复 `produce`（排双份队列）。
- 把全部工人拉去建造（采集断档，经济崩盘）；建造最多占用一半工人。
- 工人满载往返期间重发 gather（打断节奏）。
- 开局阶段反复 `start` 重开对局。

## 失败后的恢复策略

| 回执 | 处理 |
|---|---|
| `ProducerNotFound` | `production[]` 里重新找 `producer_type` 匹配的建筑名（指挥中心重建/换图后名字会变），用新名字重发一次 |
| `ProductNotAllowed` | 说明 producer 选错类型：改用 `producer_type` 匹配的建筑，本条命令不算失败重试 |
| `InsufficientResources` | 攒钱：本轮全部工人 gather、零成本决策，下轮资金够再补单 |
| `QueueFull` | 指挥中心是单队列：等 `items` 清空再补单，期间做其他事 |
| build `OutOfBounds` / `NotVisible` | 换一个坐标重试**一次**，仍失败记入 blocked 转做其他事，绝不连发 |
| 建造长时间不推进（hp 不涨） | 记录现场（建筑名/hp/工人数），继续其他管理器，不反复重派 |

## 对应的游戏控制命令或状态字段

- 命令：`gather units kind=a`、`produce unit=<producer> scene=<Worker.tscn>`、`build units pos scene`、`status lite=true`、`sleep 5`。
- 字段：`counts.mine_by_type`、`balance.a`、`production[].producer_type` / `items` / `queue_size`、回执 `accepted` / `status` / `reason` / `producer` / `queue_size`。
- 生产协议细节（队列空闲判定、PendingAuthority 处理）见 04 章。
