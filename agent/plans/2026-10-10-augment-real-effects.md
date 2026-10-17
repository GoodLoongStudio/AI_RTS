# 战区补给真实加成

## 目标与口径

保留 `config/match_augments.json` 的 12 张卡牌及数值。选择后影响真实伤害、最大生命、采矿交付资金和视野；已有及新出生单位均生效，只作用于所属玩家，不重复叠加。

## 已确认基线

- 单机已有应用骨架，旧冒烟 rc=0，但随机选一张、只检查面板/倍率，不能证明每张卡的实际结算。
- `AugmentRuntime` 客户端不抽牌，无权威补给快照下行、无选择请求上行。
- `NetSync` 只同步当前 HP，未同步最大 HP；强化建筑客户端血条上限可能错误。
- `AugmentModifiers` 用普通 HP setter 重算，会错误触发受伤通知；`scope=unit` 未排除非战斗工人。

## 顺序与门禁

1. 加入逐卡真实 Match 探针，实测真实掉血、资金到账、视野边界与 HP 比例；记录基线。
2. 最小补丁：服务器权威选择与私有快照、已选卡出生继承、HP 无伤害更新与作用域、最大 HP 网络镜像。
3. 新进程重放旧加成/成长回归；两进程 ENet 验证选牌、幂等、拒绝非法/过期选择、断开清理。
4. 保存新鲜数据与日志；不抢用户焦点，不操作用户实例，不改发布包。

## 状态

2026-10-11：12 张卡的真实 Match 结算、成长叠乘、出生继承、ENet 权威选择及独立初始化/截止边界专项通过。编译 rc=0，GPU 专项日志干净。

20 项相关回归 runner rc=1：14 项 rc/marker 通过，仅 6 项日志也通过。全部失败保留原始证据，未逐项 A/B 归因；完整全量回归、连续玩家视频及公网未测。整体 `needs-review`，**不晋级全局 champion，不宣称游戏/发布完成**。

详细报告：`agent/reports/closed-loop/2026-10-11-augment-real-effects.md`。checklist/champion：`agent/runs/20261011-augment-effects-r5-growth/`。最终复跑入口 `tools/run_augment_verification.py --mode effects|network --out <new-directory>`；GPU 非干扰取证加 `--rendered`。
