# 06 命令协议与回执字段速查

## 目标

副官与游戏权威端点（DebugControlServer，TCP JSON 行协议，经 rts_ctl.py 封装）通信的**唯一语法参考**。语法以本章为准，绝不猜测 API。

## 输入数据

无（本章是被引用的协议规范）。

## 决策条件：命令语法总表

| 命令 | 语法 | 说明 |
|---|---|---|
| status | `python rts_ctl.py status lite=true` | 轻量战况快照（默认 lite），落盘 last_status.json |
| start | `python rts_ctl.py start with_ai=true` | match=false 时开局 |
| move | `python rts_ctl.py move units='["Unit_1"]' dest='[30,50]' as_player=主人` | units 是**数组**；dest 是 `[x,z]` |
| gather | `python rts_ctl.py gather units='["Worker1"]' kind=a as_player=主人` | 采集 |
| build | `python rts_ctl.py build units='["Worker1"]' pos='[10,10]' scene='res://source/match/units/VehicleFactory.tscn' as_player=主人` | pos 传 `[x,z]` 二元即可 |
| produce | `python rts_ctl.py produce unit='VehicleFactory1' scene='res://source/match/units/Tank.tscn' as_player=主人` | **`unit=` 指生产建筑**（与 move 的 units 数组不同，勿混淆） |
| attack | `python rts_ctl.py attack units='["Tank1"]' target='EnemyUnit5' as_player=主人` | target 必须是敌方单位名 |
| sleep | `python rts_ctl.py sleep 5`（在回复里作为工具调用） | 轮间隔；保持会话的必须工具调用 |

通用规则：每条命令都带 `as_player=<主人>`（主人 = status `players[]` 中 `human:true` 的玩家）；环境变量 `AI_RTS_ADJ_PORT`（daemon 注入）或 `AI_RTS_DBGPORT` 指定端口。

## 决策条件：status（lite=true）字段

```
match / local_player_name / outcome
balance.a, balance.b            # 我方资金
players[]: {name, human, a, b}  # human:true = 主人
counts: {total, mine, scouted_enemy, mine_by_type{...}}
production[]: {...}             # 见下
lite: true / full_vision
```

`production[]` 每项（服务器 `_production_snapshot`）：

```
producer: "VehicleFactory1"          # 下单用原名
producer_type: "VehicleFactory"      # 选 producer 的唯一依据
queue_size: 2                        # ==0 ⇔ 队列空闲
items[]: {item_id, producer_id, definition_id, state, completed_work, required_work, version}
last_command: {...}                  # 该建筑最近一条 produce 回执
```

## 决策条件：回执字段语义

| 字段 | 出现于 | 语义 |
|---|---|---|
| `ok` | 所有回执 | 顶层成败；false 必看 reason |
| `accepted` | build / produce | **true 才表示被权威逻辑接受** |
| `status` | build / produce | `Accepted` / `Rejected` / `PendingAuthority` / `ProductNotAllowed` / `InsufficientResources` / `QueueFull` / `ProducerNotFound` / `NoProductionQueue` / `DefinitionNotFound` |
| `reason` | 拒绝回执 | 人类可读原因，按它换策略 |
| `producer` | produce 回执 | 实际受理下单的建筑名 |
| `scene` | produce 回执 | 本次要生产的单位场景路径 |
| `queue_size` | produce 回执 | 下单后队列长度（判断是否接近满） |

### PendingAuthority 专节（最常见的误用点）

- **出现时机**：客户端侧只完成了转发（联机权威服模式下，命令需服务器确认）。回执形如 `{"ok": false, "accepted": false, "status": "PendingAuthority", "reason": "命令已发送，等待服务器确认..."}`。
- **语义**：已转发 ≠ 已接受 ≠ 已执行。
- **处理**：等待下一次 status 用事实验证（produce → `production[].items` 新条目；move → 坐标位移；build → 新建筑出现）。**不要立即重复下单**。连续 3 轮无任何事实变化才重发一次。

### 拒绝码处理表

| 拒绝码 | 典型原因 | 处理 |
|---|---|---|
| `ProductNotAllowed` | 指挥中心产坦克 / 车辆工厂产工人 | 按 `producer_type` 重选建筑（不是失败重试） |
| `InsufficientResources` | 资金不够 | 攒钱，本轮零成本决策 |
| `QueueFull` | 队列已满 | 等待 items 清空；全都满则扩产能 |
| `ProducerNotFound` | 建筑名失效 | 从最新 `production[]` 取名重发一次 |
| `NoProductionQueue` | 目标不是生产建筑 | 同上 |
| `DefinitionNotFound` | scene 路径错误 | 只用本章命令表中的 scene 路径 |
| `OutOfBounds` / `NotVisible`（build） | 位置非法/不可见 | 换坐标重试一次，仍失败记 blocked |

## 不应该做什么

- 不猜测参数名（units 数组 vs produce 的 `unit=`）；不省略 `as_player`。
- 不用全量 status 高频轮询；不把 `WaitingForTargets` 当移动中。
- 不在 PendingAuthority / 拒绝后盲目连发。
- 不把 raw 回执 JSON 直接转给玩家（用 07 章措辞）。

## 失败后的恢复策略

- `调用失败: ...`（TCP/超时）→ sleep 5 重试一次；仍失败转入等待链路恢复。
- 全量 status 超时 → 单位过多，改用 lite + 低频全量（只在选目标/派点时）。
- 命令回执与事实矛盾（accepted=true 但单位没动）→ 相信事实，按 PendingAuthority 的验证法复查。

## 对应的游戏控制命令或状态字段

本章全部内容。来源实现：`source/net/DebugControlServer.gd`（`_op_produce` / `_production_reason` / `_production_snapshot` / `_collect_status_lite`）与 `scripts/rts_ctl.py`。
