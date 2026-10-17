# RVO / 推出管道规模化优化设计计划

状态：needs-review；文档审计与方案设计已完成，产品优化未实施。

## 目标

复核 `agent/reports/closed-loop/2026-10-07-rvo-push-bottleneck-handoff.md` 的证据和推断，结合引擎官方文档、源码与成熟算法，提出保持画质、模拟频率和玩法的规模化方案。目标负载沿用原报告的 1000 单位 / 30 FPS，但本轮不承诺达到该指标。

## 写入范围

- 本计划。
- `agent/reports/closed-loop/2026-10-07-rvo-scalability-design-review.md`。
- `agent/prompts/2026-10-07-rvo-scalability-deepseek.md`。

不修改原报告、产品源码、测量器或长期 skill 的 measured 条目。工作区已有 872 条状态记录，保留所有他人改动。

## Checklist

- [x] 读取项目契约、RSI 与性能 skill。
- [x] 核对 Movement 文件 hash 与原报告一致。
- [x] 读取障碍注册、移动回调、现有索敌网格、压力探针与历史日志。
- [x] 查证 Godot 计时、避障与线程规则，比较规模化算法。
- [x] 区分历史 measured、本轮静态发现与未验证方案。
- [x] 完成修正后的架构、实验顺序和 DeepSeek 实施提示词。
- [x] 检查文档链接、内容与修改范围；明确未跑引擎/回归（静态文档验证 rc=0）。

## 已发现的证据缺口

1. 当前移动单位的 Movement 不注册到静态障碍组；必须记录真实组成员再判断 O(N^2)。
2. `_AiArmyStressProbe` 出生网格 `%20` 重复，1000 单位仅有 400 个不同坐标；异常重叠与正常军团负载分开。
3. 聚合 `_process/_physics_process` 不能排除脚本信号回调；Performance monitor 不能无依据相加。
4. 断开 velocity 回调停止位置落地且改变后续拥挤状态，不是只测 RVO 求解的等行为 A/B。

## 验证范围

文档-only：使用文件/hash、只读源代码、历史日志与网页原始资料核验。纯数据检查只验证夹具坐标重复，不代替真实 Match 性能。产品优化、截图、新 FPS、相关/全量回归和独立运行时复核由接手实施者完成。

## 已交付

- [复核报告与质变路线](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-07-rvo-scalability-design-review.md)。
- [DeepSeek 实施提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-rvo-scalability-deepseek.md)。
- 纯数据坐标检查 rc=0：1000 请求/400 输入坐标/600 额外重用请求/最多 3 次重用；实际运行时重叠未测。
- 未建立或晋级任何产品 champion，没有独立引擎验证；所有方案仍为候选。
- 收尾发现外部 Movement 版本已从 B4 变成 9690（新增帧句柄缓存、移除 R16 剔除），hash 保护 rc=1 与 no-index diff rc=1 如实记录在报告。未覆盖外部代码；文档验证仍 rc=0。接手实施须重核当前基线。
