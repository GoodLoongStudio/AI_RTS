# RA3 电脑玩家与寻路逆向研究计划

- 状态：`needs-review`（**S2 函数级静态分析完成；AI/寻路核心研究待继续**）
- 日期：2026-10-11
- 研究对象：`D:\Red Alert 3\Data\ra3_1.12.game`（只读）及其 `Core*.big` / `Maps*.big`
- 研究输出：`agent/reports/closed-loop/2026-10-11-ra3-ai-pathfinding-research.md`
- 执行提示词：`agent/prompts/2026-10-11-ra3-ai-pathfinding-research.md`

## 目标

在不复制 EA/Westwood 代码、资源或二进制实现的前提下，建立可复核的 RA3 电脑玩家、编组、微操、寻路、队形、避障和性能设计证据，并把成熟设计翻译成 AIRTS 可以独立实现的模块边界、数据契约和验证门禁。

最终交付必须回答：

1. RA3 的电脑玩家如何从人格/状态选择战略，再形成团队和微操命令。
2. RA3 如何处理编组、持续下令、空闲监控、目标保持、撤退、集火和队形。
3. RA3 的移动数据如何区分模型、逻辑半径、寻路直径、队形宽深、转向/加减速和避让安全距离。
4. 哪些证据来自官方 Schema，哪些来自静态二进制，哪些来自动态行为，哪些仍只是推断。
5. AIRTS 当前入口与这些概念如何对应，哪些能先做低风险原型，哪些必须先做性能/行为门禁。

## 非目标

- 不修改 `D:\Red Alert 3` 或其任何安装文件。
- 不把 RA3 的代码、模型、纹理、完整导出资产或反编译 dump 写入 AIRTS。
- 不把 OpenSAGE 的重实现称为 RA3 原始实现；它只能作为公开算法参考。
- 本轮不直接修改 AIRTS 游戏逻辑；落地改动需另建实施计划并经过闭环闸门。
- 不因缺少 Ghidra 就编造函数、线程、RVO 或 A* 的内部结论。

## 证据分级

| 等级 | 含义 | 可写成的结论 |
|---|---|---|
| `measured` | 本机命令/探针直接得到，可重跑 | 可以陈述具体数值、hash、退出码 |
| `official-schema` | EA C&C Modding Support 的 RA3 Schema | 可以陈述设计数据模型和公开字段语义 |
| `static-binary` | `ra3_1.12.game` 的 PE、字符串、导出、调试路径 | 可以证明版本包含相关类型/编译模块，不能单独证明控制流 |
| `dynamic-observation` | 真实 RA3 对局/重播中的记录 | 可以陈述玩家可观察行为，需记录版本和场景 |
| `open-source-reference` | OpenSAGE 等公开重实现 | 只能作为算法启发，不能归因给 RA3 |
| `inference` | 由多条证据推导 | 必须显式标注推断和替代解释 |
| `not-yet-verified` | 尚未完成或工具不可用 | 不得在摘要中写成事实 |

## 研究阶段

### S0：身份与基线

- 记录 RA3 launcher 与真实游戏本体的区别。
- 记录 `ra3_1.12.game` 版本、大小、SHA-256、PE 位数、节区、导入/导出和安装时间。
- 记录使用的 BIG4 提取器、提取目录和只读边界。
- 保存本次命令输出到 `agent/runs/`，报告引用绝对路径和时间。

### S1：官方数据模型

从 EA Schema 提炼以下表格，不复制大段源码：

```text
概念 | Schema 文件/行 | 字段 | 对 AI_RTS 的可吸收设计 | 风险
```

至少覆盖：

- `AIPersonalityDefinition`：开局、经济、科技、攻防偏好、敌人排序、扩张、反应式防御。
- `AIStateDefinition`：启发式、目标启发式、状态最大目标、路径可达检查、战术和结束行为。
- `AITeamTemplate`：最小/最大人数、单位类型上限、力量优势、释放优先级、战斗中招募、移动类型、距离排序、指定微操管理器。
- `AIMicroManager`：团队/单位空闲超时、目标保持、目标搜索、撤退、受伤拉回、集火、碾压、闪避、运输和驻军。
- `LocomotorTemplate`：可通行表面、LookAhead、转向半径、转向时间、加速/刹车、CloseEnough、倒车、WaitForFormation、路径切线朝向。
- `GameObject`：Radius、PathfindDiameter、PathPriority、FormationWidth/Depth、VisionInfo、DodgeSafetyDistance。

### S2：静态二进制证据

优先使用 Ghidra/其他反编译器；若工具不可用，先完成 PE/字符串/导出定位并标为部分完成。

检索并记录：

- `AIMicroManager.cpp`、`AISimpleAttackTactic.cpp`、`AIFlankAttackTactic.cpp`、`AITacticManager`、`AITargetManager`、`LocomotorTemplate`、`Formation`。
- AI 状态、团队模板、微操、路径检查、RVO/避障相关 RTTI/字符串/导出引用。
- 每个候选函数的地址、调用者/被调用者、伪代码截图或导出文本、可信度。

禁止把以下单独当作算法证明：类型名、文件路径字符串、OpenSAGE 代码、Schema 默认值。

### S3：动态行为

在 RA3 本体允许的离线/本地模式下做最小可重复场景；不修改安装目录。记录：

- 开局到首个生产、首个编组、首波出击的时间线。
- 4/8/16/32 单位编组的集结、队形、到达、掉队和再招募。
- 单位停滞、目标死亡、目标不可达、撤退阈值、基地受袭时的重新下令。
- 复杂地形、窄口、桥、建筑、混合速度单位的路径行为。
- 同一场景 1/2/3 个电脑玩家的帧时间、模拟速度和命令反应；不要只看平均 FPS。

若无法安全或稳定启动 RA3，状态写 `not-yet-verified`，不要用 AIRTS 截图代替 RA3 动态证据。

### S4：AIRTS 映射设计

建立：

```text
RA3 概念 | 证据等级 | AIRTS 当前入口 | 差距 | 建议原型 | 验收门禁
```

初始入口：

- `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd`
- `source/match/players/simple-clairvoyant-ai/*Controller.gd`
- `source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd`
- `source/match/units/traits/Movement.gd`
- `source/match/TargetAcquisitionGrid.gd`
- `source/csharp/GodotAdapter/AI/RuleAiCommandGateway.cs`
- `agent/reports/closed-loop/2026-10-07-rvo-push-bottleneck-handoff.md`

只提出模块化落地建议，不在本研究计划中修改代码。建议优先级：

1. `strategy state -> target heuristics -> team recruitment -> micro manager -> command gateway` 的分层。
2. 团队/单位 idle 监控和有界重下令，解决“一个单位走一小段就停”的问题。
3. 逻辑半径、寻路直径、队形宽深、视觉包围盒、攻击/视野分别建模。
4. 共享只读战场快照，后台只做纯数据决策，主线程授权和提交。
5. RVO/静态推出重复成本的分离实验；不得靠缩碰撞盒或关闭模拟换帧。

## 验证矩阵

| 层级 | 必须有 | 通过条件 |
|---|---|---|
| 文件身份 | PE/hash/版本/提取记录 | 命令可重跑，路径明确 |
| Schema | 文件和行号 | 每条设计结论有官方出处 |
| 静态逆向 | 工具版本、地址、交叉引用 | 至少一个 AI/移动候选函数有可复核控制流；否则标 blocked |
| 动态 RA3 | 场景、录像/日志、时间线 | 行为结论可重复，版本固定 |
| AIRTS 映射 | 入口和差距表 | 每项有实现边界和测试门禁 |
| 独立复核 | 另一个工具/人工复查 | 关键结论没有单一证据依赖 |

## 停止/升级条件

- Ghidra、调试符号或可重复 RA3 对局不可用：报告 `blocked` 的具体项，继续完成 S0/S1/S2 可做部分。
- 静态函数地址无法稳定映射：不猜函数签名，改为字符串/Schema/动态三角验证。
- 任何落地 AIRTS 方案触及移动、避障、碰撞、AI、性能、线程：另建实施计划，执行 S1 无头真实 Match 闸门后才能继续。

## 完成标准

- [x] 研究报告包含证据等级、hash、工具限制和未验证项。
- [x] 计划与提示词可被另一个 Agent 独立执行。
- [x] 至少一张 RA3→AIRTS 映射表完成（6 列 + 6 问回答 + 实施顺序）。
- [x] 没有把推断或 OpenSAGE 代码冒充 RA3 已证实实现（并撤回初版 RVO 字符串说法）。

## 执行记录（2026-10-11 完整执行）

- 报告：`agent/reports/closed-loop/2026-10-11-ra3-ai-pathfinding-research.md`（完整执行版）。
- 证据：`agent/runs/2026-10-11-ra3-research/`（s0/s2/s2b/s2c 的 JSON+日志）；脚本在 `D:\RA3_RE_Research\scripts\`（s0_identity.py、s2_static_analysis.py、s2b_vftable_units.py、s2c_context_dump.py，均可重跑）。
- S0 完成（含 4GB patch 1 字节差异证据）；S1 完成（7+ 份 Schema，全部带行号）；S2 完成到"PE/字符串/xref/vftable"级；S3 不做（无录像/无无人化入口，标 `not-yet-verified`）；S4 映射表完成。
- 状态保持 `needs-review`：阻塞项见报告 §8。本轮未修改 AIRTS 游戏代码。

## 执行记录续（2026-10-11 Ghidra 阶段）

- 修复 s2b/s2c（含 s2）stdout UTF-8 崩溃：三脚本加 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`，重跑 rc=0。
- 安装 **Ghidra 11.0.3**（`D:\RA3_RE_Research\tools\ghidra_11.0.3_PUBLIC`，官方 SHA-256 `2462a2d0…6761` 校验一致；JDK 17）；headless 导入 + 自动分析 414s 成功（项目 `D:\RA3_RE_Research\ghidra_projects\RA3_RE`）。
- 提取脚本 `D:\RA3_RE_Research\ghidra_scripts\DumpAiControlFlow.py` + `run_dump.cmd`：产出 `agent/runs/2026-10-11-ra3-research/ghidra/ghidra_control_flow.json`(**171 条函数记录**，881KB) + `decomp/*.c`(**171**，与 JSON 一一对应；首轮 3 个孤儿文件已隔离到 `decomp/_stale_first_pass/`)。
- 真实函数边界/调用者/伪代码/参数/CFG 见报告 §4.7：0x88A180/0x890030 本质为**析构函数**（初版"构造"判断已修正）；vftable 全槽解析；4 个 AI 管理器共享"deadline/isDue"调度接口；`AIStrategyManager` 析构按序销毁 Tactic/Target 两个 Manager；`AIMicroManager.cpp` 4 个函数定位（含第 2063 行断言）；DebugDisplay 家族为 **fprintf 占位符**，明确不称为算法实现。
- S2 中"Ghidra unavailable"、"函数边界为启发式"的表述已从报告主结论中移除（历史小节保留并标注）。

## 外部核验与修正（2026-10-11，Verifier）

- 外部核验复检结论（已逐项复现）：JSON 函数记录 **171**（此前报告行文误写"174"）；`decomp/*.c` 174 个中 3 个为首轮残留（`FUN_00abdd80`/`FUN_00abdda0`/`FUN_00abf400`，mtime 14:48 批次）；171 个中 50 个 ≤32B、39 个伪代码 ≤10 行（dtor/getter/空桩/包装为主，不等同"完整 AI"）；`AIMicroManager` 完整类方法表未找到；无动态验证与算法级还原。
- 本轮修正：3 个孤儿文件隔离到 `decomp/_stale_first_pass/`（decomp 根目录 = 171，与 JSON 一一对应）；报告新增 §4.7.9（提取规模/函数构成/防误读声明）；全文计数更正（含 §4.7.1/§10）；计划与报告状态口径统一为"**S2 函数级静态分析完成；AI/寻路核心研究待继续**"。
- 后续入口（未变）：在 `D:\RA3_RE_Research\ghidra_projects\RA3_RE` 上跑 `run_dump.cmd` 模式，扩展目标 VA 即可继续（如 AIMicroManager 定位、TacticManager 更新循环的顶层调用者上溯）。
