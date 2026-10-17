# AI 副官 10 分钟观察：实际决策、问题与下一步

**完整采集已完成；验收状态 needs-review。** 本次正常创建单人练习房，只有一个指挥官、其他槽位空，启用真实 MiniCPM 战略 + Laya 战术 + LangGraph，连续记录 **600.000 秒墙钟**。程序经过 Main → Play → Loading → Match 菜单回调进入游戏，没有替换成测试 Match 或注入单位、金钱。

这是无头、command-level 的决策观察，未占用用户鼠标键盘，也未录制桌面。记录的是完整输入、可见输出/理由、程序采纳与拒绝、权威回执和世界状态；不记录或推测隐藏思维链。

## 先读这五个结论

1. **本局没有测到上下文超窗。** 39 次真实战略请求的输入为 **2,933–4,309 token**，输出请求上限 1,280；运行时模型实际上下文为 16,384。最大请求预算 4,309 + 1,280 = 5,589。这只覆盖本局单人练习，不证明复杂战况放得下或关键事实充分。
2. **战略层约 3 分 26 秒才首次正式采纳计划。** 7 次模型在 `current_plan=null` 时仍返回“维持当前计划”，其中 4 次进入 `no_active_plan`，3 次因控制权版本变化丢弃。不能把规则层持续发展当成模型战略已成立。
3. **经济停滞重复出现。** 余额从 10,000 降到 100，最后 **473.0 秒**持续为 100；终局自有 18 个实体，矿场完工 0、矿场交货 0、矿场建造任务 failed。程序却已将经济里程碑 M01 标为 done，并推进到 M06“持续施压”。
4. **模型知道任务异常，仍然维持过期计划。** `strategy-0028` 的输入 tick=9,557，活动计划有效期=4,480，矿场失败且零交货；模型回复：“当前计划仍有效，任务状态异常但未影响施压阶段目标，维持现有计划不变。”返回有效期仍为 4,480。这里同时有模型判断和程序有效期门禁的定位空间。
5. **一次战略失败直接伴随输出截断。** 请求 `max_completion_tokens=1280`，实际输出 512 token、`finish_reason=length`，JSON 尾部缺失；部署模型的 `num_predict=512`。是否参数覆盖还要单独验证，本次只能确认请求/响应不一致及截断事实。

## 记录覆盖

| 项目 | 本轮实测 |
|---|---|
| 墙钟观察 / 世界采样跨度 | 600.000 / 600.298 秒 |
| 世界样本 / 程序决策条目 / 命令回执 | 2078 / 54801 / 120 |
| 战略调用 | 39：成功返回 38，校验失败 1 |
| 战术调用 | 335：成功返回 333，异常 2；非空意图输出 82 次 |
| 实际 2B HTTP 请求 / 响应 / usage | 39 / 39 / 39；均为战略请求 |
| 正式战略采纳 / 首次采纳时刻 | 1 次 / 205.9 秒 |
| 模拟 tick | 597 → 12401；未更改模拟速度 |
| 最大相邻世界采样间隔 | 19.859 秒；有间隙，不能称逐帧连续观察 |
| 产品冻结文件 | 59 个源码/项目/DLL 文件前后 hash 一致 |

## 十分钟时间线

| 分钟 | 世界余额（首→末） | 末尾单位数 | 战略调用（成功 / 异常） | 战术调用（成功 / 异常） |
|---|---|---:|---|---|
| 0–1 | 10000 → 5050 | 11 | 5 / 0 | 0 / 1 |
| 1–2 | 5050 → 1300 | 16 | 1 / 1 | 10 / 1 |
| 2–3 | 1300 → 100 | 18 | 0 / 0 | 0 / 0 |
| 3–4 | 100 → 100 | 18 | 3 / 0 | 30 / 0 |
| 4–5 | 100 → 100 | 18 | 3 / 0 | 38 / 0 |
| 5–6 | 100 → 100 | 18 | 5 / 0 | 56 / 0 |
| 6–7 | 100 → 100 | 18 | 5 / 0 | 55 / 0 |
| 7–8 | 100 → 100 | 18 | 5 / 0 | 35 / 0 |
| 8–9 | 100 → 100 | 18 | 4 / 0 | 55 / 0 |
| 9–10 | 100 → 100 | 18 | 6 / 0 | 54 / 0 |

首个战略请求可能早于接管计时起点不足一秒；总数包含这个请求，分钟表按严格时间窗口统计。

## 三个可直接打开的典型案例

### 1. 没有活动计划，却要求维持

`strategy-0001` 至 `strategy-0007` 输入的 `current_plan` 都为 null，返回 maintain_current=true。3 次因 control_generation 变化丢弃，4 次落 `plan_hold:no_active_plan`。正常的规则任务确实在运行，但不等于已经有可维持的模型战略。

证据：[第 1 次输入](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0001.context.json)；[第 1 次输出](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0001.result.json)；[程序处理记录](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/runner-logs/archive_155d8310/decisions.jsonl)。

### 2. 计划过期、经济失败，模型仍判断有效

`strategy-0028` 输入已明确包含 `rule-build-ore_refinery=failed`、`refinery_constructed=0`、`refinery_delivered=0`、`first_delivery_done=false`。模型明确提到任务状态异常，仍维持“持续施压”。本例证明这些关键事实已经进入模型输入；尚未证明它为何给了这个判断，也未单独验证程序为何接受维持过期计划。

证据：[完整局势](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0028.context.json)；[可见判断](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0028.result.json)；[原始响应](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/http/0028-strategy.response.json)。

### 3. 输出预算不一致，JSON 在半截结束

`strategy-0008` 实际输入 3,684 token，远低于 16K。HTTP 200 后应用层验证失败；原始响应 `finish_reason=length`，completion_tokens=512，字符串停在 maintain_current 字段。输入上下文没有超窗，输出截断是这次校验失败的直接证据。

证据：[1,280 输出请求](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/http/0008-strategy.request.json)；[512 token 截断响应](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/http/0008-strategy.response.json)；[调用异常记录](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts.jsonl)。

## 战术侧在做什么

当前战术配置是 Laya，已加载 multilingual 模型至 CUDA。首个战术调用耗时约 99.7 秒并报 ModelTimeout，后续恢复。不能把“Laya 超时配置为 2 秒”当成包含首次模型加载的完整调用上限。

后续选择、置信度、对应单位/目标和实际输出意图逐次保留。最常出现的选择是：

| 动作 / 执行者 / 目标 | 次数 |
|---|---:|
| GAT / W1 / R14 | 333 |

完整索引：[tactics-decisions.md](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/tactics-decisions.md)。重复选择和空输出本身不能直接判错，需结合去重、已有意图、权威回执与世界变化。

## 定点优化顺序：依据与验收目标

| 优先级 | 需要定位的单一方向 | 本次证据 | 优化后重放目标 |
|---|---|---|---|
| P0 | 战略输出参数是否真正生效 | 请求 1,280，实际 512 且 length | 同等长计划完整返回，响应不截断；仍保留真实失败 |
| P0 | 无活动计划时维持 / 过期计划的门禁 | 7 次维持空计划；tick 9557 维持 expiry 4480 | 空计划不能假维持；过期计划不被当作有效 |
| P0 | 经济里程碑与真正交货闭环 | M01 done，但矿场 0、交货 0、余额长期 100 | 里程碑由完工和交货证据推进；失败能触发恢复 |
| P1 | 资金保留、支出优先级与经济失败重规划 | 资金耗尽，生产被反复 reserve_blocked | 经济未闭环前保留必要建造资源；失败反馈影响选择 |
| P1 | Laya 首次加载是否绕过调用超时 | 首次战术 99.7 秒，配置 2 秒 | 加载与推理耗时分列，有界失败且及时降级 |
| P1 | runner 收尾及观察工具告警 | 退出日志 0，真实 OS 15；启动探测/资源告警 | 自然 OS0，无残留；不能改写本轮红项 |
| 后续 | 复杂敌情下的上下文预算与事实充分性 | 本局只有一个玩家，最高 4309 token | 增加敌方/大部队后验证关键事实覆盖与选择依据 |

这里列的是下一轮可证伪方向，本轮没有实施策略修复。前一战略任务 champion 和连续未提升计数保持不动。

## 工装验证、运行限制与清理

- 静态 AST 检查 rc=0；HTTP 旁路独立资格检查 9/9、rc=0：请求/响应转发字节不变、无认证信息落盘、隐藏推理字段过滤、usage 保留。资格检查使用合成输入，不冒充游戏证据。
- 真实 600 秒启动器 rc=0；独立证据审计 **18/20，rc=2**。两项失败保留：runner 未自然退出；game stderr 非空。不能因此宣称全量回归或收尾通过。
- runner 写完归档并记录内部 exit code=0 后，45 秒仍未结束；只清理归属本轮的进程树，实际 OS 返回 15。游戏进程自然 OS0。[退出与强制清理原件](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/cleanup.json)。
- game stderr 包含启动时探测 current_scene=null 的工装错误，及退出时 43 ObjectDB / 9 resources 告警。启动探测已补空值防护，仅静态校验，未以该修正追认原局为绿。[game.stderr.log](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/game.stderr.log)。
- 观察期间有父租约 PermissionError 告警、4 次扫描超时，世界采样最大间隙 19.859 秒。这是记录的限制，不能由采样间隙反推游戏持续卡顿。
- 已核验本轮根进程不存在；隔离游戏/DCS/MCP/旁路端口无监听。现成模型服务 11434 保留，未关闭。[清理后复核](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/post-cleanup-process-audit.json)。
- 配置文件指向 11436，当时无服务。本轮复用 11434 的同名模型，确认开始及结束运行上下文均为 16K；端点替换显式记录，不测试默认启动器自动拉起模型。
- 第一局因 G: 路径暂不可访问在 414.497 秒中断，原件与恢复副本保留，未拼接进第二局。第二局证据写 C:，主工程仍是 G:/AIRTS/AI_RTS。
- 未做可见窗口截图、视频、鼠标 UI、全量玩法回归、跨图敌方测试，也没有外部会话复核。独立审计是分离实现的只读探针，不冒充另一位 AI 的评审。
- 新工具、计划、提示词和报告位于共享 dirty tree；59 个产品冻结文件一致，没有修改旧 runner / 策略 / 游戏代码。

## 完整阅读入口与重跑

- [自动生成总报告](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/report.md)：按分钟概览和逐次战略索引。
- [strategy-details.md](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/strategy-details.md)：每次战略返回的完整计划与可见理由。
- [tactics-decisions.md](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/tactics-decisions.md)：全部战术选择、输入帧和输出。
- [model-calls.md](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/model-calls.md)：实际模型 HTTP 输入、输出和 token 索引。
- [summary.json](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/summary.json)；[independent-evidence-audit.json](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/independent-evidence-audit.json)；[configuration-snapshot.json](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/configuration-snapshot.json)。
- [可重复运行的观察程序](G:/AIRTS/AI_RTS/tools/dev/adjutant_observe.py)；[重跑提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-15-adjutant-observation.md)。

```powershell
& 'D:/software/anaconda3/python.exe' -B -u 'G:/AIRTS/AI_RTS/tools/dev/adjutant_observe.py' observe --seconds 600 --model-port 11434
```

省略 --model-port 时使用独立本机模型服务及现有模型文件。每次创建新证据目录，不覆盖旧局。用户可在运行时继续使用电脑。
