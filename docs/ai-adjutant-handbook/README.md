# AI 副官战略手册（AI Adjutant Handbook）

面向 Hermes 副官在 AI_RTS 中的**战略决策实现**。本手册不是理论综述：每一章都直接约束下一轮决策——读什么数据、满足什么条件才下令、什么绝对不做、失败后怎么恢复。

## 目录与阅读顺序

| 顺序 | 文件 | 内容 | 什么时候读 |
|---|---|---|---|
| 1 | [01-principles.md](01-principles.md) | 决策原则：回执三分法、PendingAuthority 语义、拒绝分类 | 每次开工/交接后先读 |
| 2 | [02-opening-and-economy.md](02-opening-and-economy.md) | 开局摸底与经济（工人 / 采集 / 扩产能） | 第 1 轮 + 每轮生产/工人管理器 |
| 3 | [03-scouting-and-intel.md](03-scouting-and-intel.md) | 侦察与情报（锁定协议 / 阶段推进阈值） | 每轮侦察管理器 |
| 4 | [04-production-and-army.md](04-production-and-army.md) | 生产与军队（producer 选择 / 队列空闲判定 / 规模上限） | 每轮生产/军队管理器 |
| 5 | [05-combat-defense-retreat.md](05-combat-defense-retreat.md) | 战斗、防守、撤退（优先级链 / 止损线） | 每轮交战管理器 |
| 6 | [06-command-protocol.md](06-command-protocol.md) | 命令协议与回执字段速查（status / produce / 回执字段表） | 对任何字段/语法不确定时 |
| 7 | [07-player-facing-status.md](07-player-facing-status.md) | 面向玩家的状态汇报措辞 | 每轮输出复盘文字时 |

**阅读顺序 = 表格顺序。** 01 章是其余所有章节的前置：先理解 `accepted=true` 与 `PendingAuthority` 的区别，再谈任何决策。

## 一页速查

### 每轮决策循环

```
CTL status lite=true
  → 依次过：生产 → 工人 → 侦察 → 军队 → 交战 → 复盘（各产出 0~2 条增量指令）
  → 每条命令只认回执：accepted=true 才算接受；PendingAuthority 只是"已转发"
  → sleep 5 → 下一轮
```

### 回执语义表（最重要的 8 行）

| 回执字段 | 含义 | 下一轮该做什么 |
|---|---|---|
| `accepted=true`（配合 `ok=true`） | 命令已被权威逻辑接受 | 正常记账、继续，**不重发** |
| `status=PendingAuthority` | 命令已转发给服务器，**尚未确认** | 等下一次 status 验证效果，**不要立即重复下单** |
| `ProductNotAllowed` | 生产建筑与产品不匹配 | 换正确类型的 producer（指挥中心≠车辆工厂） |
| `InsufficientResources` | 资源不足 | 本轮改做零成本决策，攒钱 |
| `QueueFull` | 生产队列已满 | 不下单，等 `production.items` 清空 |
| `ProducerNotFound` | 找不到生产建筑 | 从 status 的 `production[]` 重新取名字 |
| `ok=false` + `reason` | 各类拒绝的统一出口 | 按 `reason` 换策略，**不盲目重试** |

完整字段与命令语法见 [06-command-protocol.md](06-command-protocol.md)。

### 三条不可违反的底线

1. **`accepted=true` 才表示命令已被权威逻辑接受**；`PendingAuthority` 只是"已转发"，不能当成功记账。
2. **生产必须选对 producer**：看 `production[].producer_type`，指挥中心只产工人、车辆工厂只产坦克，**不能混用**。
3. **战争迷雾下不能无限等待**：侦察没看到敌人不等于什么都不做，要按侦察进度、资源、军力、风险阈值做**阶段性决策**（见 03 章）。
