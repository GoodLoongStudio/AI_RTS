# 给逆向研究 Agent 的执行提示词

你现在负责对本机只读安装 `D:\Red Alert 3` 做技术研究，目标是学习成熟 RTS 的电脑玩家、编组/微操、寻路/队形/避障和性能组织方式，为 `G:\AIRTS\AI_RTS` 提供原创设计输入。你不是要复制 RA3 代码，也不是要把猜测写成结论。

## 先读并遵守

```text
G:\AIRTS\AI_RTS\AGENTS.md
G:\AIRTS\AI_RTS\skills\airts-workspace-boundaries\SKILL.md
G:\AIRTS\AI_RTS\skills\闭环验证工作法.md
G:\AIRTS\AI_RTS\skills\AI_RSI自校验循环.md
G:\AIRTS\AI_RTS\skills\airts-performance-optimization\SKILL.md
G:\AIRTS\AI_RTS\agent\manifest.json
G:\AIRTS\AI_RTS\agent\plans\2026-10-11-ra3-ai-pathfinding-research.md
```

## 硬边界

1. `D:\Red Alert 3` 只读，不能改名、覆盖、打补丁、注入、联网修改或删除文件。
2. 提取物、反编译工程、二进制 dump、原始资源留在 `D:\RA3_RE_Research`，不要写入 AIRTS。
3. AIRTS 本轮只写研究计划、提示词和闭环报告；不要未经新计划修改游戏代码。
4. 不得把 OpenSAGE、EA Schema 或字符串命中直接称作 RA3 运行时实现。
5. 不要为了“让测试通过”降低 AIRTS 的碰撞、射程、速度、视野、模拟或画质。

## 任务顺序

### 1. 固定身份

核对并记录：

```text
D:\Red Alert 3\RA3.exe
D:\Red Alert 3\Data\ra3_1.12.game
D:\Red Alert 3\RA3_chinese_t_1.12.SkuDef
D:\Red Alert 3\Data\Core12.big
D:\Red Alert 3\Data\MapsMultiplayer.big
```

对真实游戏本体输出 SHA-256、文件大小、版本、PE machine/位数、入口 RVA、image base、节区、导入 DLL、导出数。注意 `RA3.exe` 可能只是启动器，不能把它当游戏本体。

### 2. 复核官方资料

使用本地：

```text
D:\RA3_RE_Research\refs\CnC_Modding_Support\Red Alert 3\Schemas
```

提取带文件和行号的证据，至少覆盖：

- `AIPersonalityDefinition.xsd`
- `AIStateDefinition.xsd`
- `AITeamTemplate.xsd`
- `AIMicroManager.xsd`
- `AssetTypeLocomotorTemplate.xsd`
- `AssetTypeGameObject.xsd`
- `PathfindingCheckType.xsd`

输出这些字段的语义：团队/单位 idle、目标保持、目标排序、撤退、编组人数、力量优势、战斗中招募、距离排序、SimpleAttack/FlankAttack、QuickDoesPathExist、WaitForFormation、CloseEnoughDist、Turn/Acceleration/Braking、Radius/PathfindDiameter/FormationWidth/FormationDepth/PathPriority/DodgeSafetyDistance。

### 3. 做静态二进制分析

优先顺序：

1. 若本机有 Ghidra：用 `analyzeHeadless` 建立独立 project，不在 RA3 目录写入；导入 `ra3_1.12.game`，选择 32-bit x86，分析后用字符串交叉引用定位 AI/移动函数。
2. 若无 Ghidra：使用 `pefile`、`lief`、`capstone` 完成 PE、导入/导出、ASCII/UTF-16 字符串、指针引用和反汇编窗口记录，并明确写 `Ghidra unavailable`。
3. 不要先反编译整个程序；从以下锚点开始：

```text
AIMicroManager
AIMicroManager.cpp
AISimpleAttackTactic.cpp
AIFlankAttackTactic.cpp
AITacticManager
AITargetManager
AITeamTemplate
LocomotorTemplate
Formation
RVO
avoidance
```

每个候选记录：文件偏移、VA/RVA、所在节、命中上下文、交叉引用、函数边界、伪代码/汇编、证据等级和未确定处。类型名或编译路径只能证明模块存在，不能证明该函数被某个对局调用。

### 4. 做动态研究（能安全重复时才做）

只使用离线/本地可重复入口。固定版本、地图、难度、玩家数和录像/日志路径。观察并记录：

- 生产到编组的时间、最小/最大团队规模、混编规则。
- 团队是否会持续补充、是否允许战斗中招募、距离排序和队形等待。
- 团队整体 idle 与单单位 idle 的再下令阈值。
- 目标失效、不可达、目标死亡、基地受袭、受伤和撤退后的状态转移。
- 窄路、桥、建筑、不同速度单位的路径、转弯、刹车、倒车、队形保持。
- 1/2/3 个电脑玩家时的帧时间 p50/p95/p99、模拟速度和命令延迟。

无法稳定运行时只写 `not-yet-verified`，不使用 AIRTS 的行为代替 RA3 证据。

### 5. 映射到 AIRTS

只读检查：

```text
G:\AIRTS\AI_RTS\source\match\players\simple-clairvoyant-ai\SimpleClairvoyantAI.gd
G:\AIRTS\AI_RTS\source\match\players\simple-clairvoyant-ai\*Controller.gd
G:\AIRTS\AI_RTS\source\match\players\simple-clairvoyant-ai\AutoAttackingBattlegroup.gd
G:\AIRTS\AI_RTS\source\match\units\traits\Movement.gd
G:\AIRTS\AI_RTS\source\match\TargetAcquisitionGrid.gd
G:\AIRTS\AI_RTS\source\csharp\GodotAdapter\AI\RuleAiCommandGateway.cs
```

制作表格：

```text
RA3 概念 | 证据等级 | AIRTS 入口 | 当前差距 | 可吸收设计 | 风险/门禁
```

重点回答：

- AIRTS 是否把战略、团队、微操和移动执行混在一个循环里。
- 如何用共享只读快照让多个 AI/副官共享观察结果。
- 如何用有界团队 idle/单位 idle 重下令修复“一次只走一个单位一小段”。
- 如何分离视觉包围盒、逻辑半径、寻路直径、队形宽深、攻击距离和视野。
- 如何把纯数据目标评分/队形计算放到 worker，而让 SceneTree、授权和命令提交留在主线程。
- 如何避免 RVO 和静态推出重复遍历，且不靠缩碰撞盒或关闭模拟。

## 输出格式

写入：

```text
G:\AIRTS\AI_RTS\agent\reports\closed-loop\2026-10-11-ra3-ai-pathfinding-research.md
```

报告必须包含：

1. 执行时间、机器/工具版本和只读边界。
2. RA3 本体身份、hash、PE 摘要。
3. 证据分级表：`measured`、`official-schema`、`static-binary`、`dynamic-observation`、`open-source-reference`、`inference`、`not-yet-verified`。
4. RA3 AI 分层、编组、微操和寻路结论。
5. 每条结论对应文件/行、地址、日志或录像；没有证据就标未验证。
6. RA3→AIRTS 映射和建议实施顺序。
7. Ghidra/动态对局/线程内部实现的阻塞项，不许掩盖。
8. 本轮没有修改代码的说明。

## 完成判据

- 关键结论至少有两种互相独立的证据，或明确标注单一证据。
- Schema 设计字段、二进制模块存在、动态行为三者不能互相冒充。
- OpenSAGE 只用于解释通用 A*、网格、路径拉直等算法，不得写成 RA3 原码。
- 没有 Ghidra 或动态对局时，状态必须是 `needs-review`/`blocked`，不能是 complete。
