# AI 系统规划：规则 AI 升级 + LLM AI 副官（供复核）

> 合并说明（2026-08-30）：本文由原 `规则AI智能化改造-plan.md`、`服务器Agent与局服-yyp_test-plan.md` 两份合并而成，内容不变、结构重排，以本文为唯一口径。原 `规则AI智能化改造-plan.md` 仍在仓库，已加作废横幅指向本文，不再维护；`服务器Agent与局服-yyp_test-plan.md` 已删除。

## Overview（先读我：这是两套系统）

本文合并了项目里两套互不相同的 AI 的规划，供复核。**不要把它们混淆：**

| | **Part A：规则 AI** | **Part B：LLM AI 副官** |
|---|---|---|
| 是什么 | `SimpleClairvoyantAI`——纯规则决策的对局参与者，占空槽位 | `RemoteLLMPolicy` 网关——LLM 驱动的「副官」，给人类玩家出主意/代管 |
| 跑在哪 | 权威 Match 进程内（只在服务器思考，客户端 `is_client_puppet()` 早退） | 局服本机回环上的独立网关进程，HTTPS 出站调远程大模型 |
| 改什么 | 行为策略层（6 个 GDScript 控制器） | 工具 Schema、决策调度、Trace、部署 |
| 状态 | 计划已过一轮外部评审（2026-08-30） | 未实施（G0–G4 全部待做） |

两套系统共用同一权威命令入口（`UnitCommandService` / `CommandRuntime`）和同一查询设施（`WorldQueryRuntime`），都不得绕过 issuer 所有权校验。部署同机（腾讯云 Ubuntu），cgroup 隔离。

---

# Part A：规则 AI 智能化改造

## A.0 Overview

给另一位 AI / 同事核对用的改造设计，不是操作手册。

**目标：** 把 `SimpleClairvoyantAI` 从「静态数量维持」改造成「会扩张经济、会主动进攻、会补兵回防」的规则 AI，体感对齐红警 3 简单~中等难度 AI 的下限：**会扩矿、会主动打、会补兵、不站桩、不白送**。

**硬约束（与现有架构的契约）：**
1. 不碰模拟层权威性——AI 产出的命令仍必须全部经 `RuleAiCommandGateway` 进入 `CommandRuntime`，服务器权威、客户端傀儡的联机架构不动（见 `docs/plan/联机Demo-plan.md`）。
2. 不打破战争迷雾查询约束——rule AI 的一切信息必须来自 `WorldQueryRuntime` 的标准查询会话，禁止直接读场景树 Node。
3. 信息对等原则：AI 只允许比玩家多知道「开局出生点位置」这类玩家本来就能看到的公共知识，不允许迷雾内实时信息。
4. 全部行为参数上 `SimpleClairvoyantAI` 的 `@export`，为难度分级与自动化测试留口。

**改动范围：** 主要是 6 个策略层 GDScript 文件 + `WorldQueryRuntime.cs` 一次只读扩展 + 新增 3 个自动化测试。模拟层零改动（含 Phase 2 备选方案 B：审核核实 attack-move 指令在模拟层已存在，见 Phase 2）。

## A.1 Current State Analysis（读码结论，行号以当前 HEAD 为准）

### 架构现状

```
SimpleClairvoyantAI (Player 子类, 157 行)
 ├─ EconomyController        (250 行)  0.5s 轮询
 ├─ OffenseController        (400 行)  0.5s 轮询
 │   └─ AutoAttackingBattlegroup × N (259 行/个)
 ├─ DefenseController        (144 行)  0.5s 轮询（代码写作 1/60*30）
 ├─ IntelligenceController   (137 行)  0.5s 轮询
 └─ ConstructionWorksController (64 行)  0.5s 轮询，给无人施工的蓝图派工人
控制器 → resources_required 信号(优先级 HIGH/MEDIUM/LOW) → 主脑仲裁 → provision
命令出口：每个控制器持 RuleAiCommandGateway（C#, Move/Halt/Attack/Construct/
          PlaceStructure/EnqueueProduction/Gather —— 网关未暴露 AttackMove；
          但 CommandRuntime 已有 GroundAttackMoveUnits/EntityAttackMoveUnits，
          人类玩家 HUD「移动并攻击」在用，见 Phase 2 备选方案 B）
信息入口：WorldQueryRuntime 标准会话（GetOwnForces / ScanCircle /
          GetOwnEconomy / GetBattlefieldBounds；InspectOwnEntity 在运行时存在，
          但规则 AI 目前未使用，仅查询层自测在用）
权威守卫：SimpleClairvoyantAI._ready(): is_client_puppet → set_process(false)
```

### 五个结构性缺陷（"笨"的根源，均有代码证据）

| # | 缺陷 | 证据 |
|---|------|------|
| 1 | 经济封死：全场 1 基地 3 工人，永不开分矿 | `SimpleClairvoyantAI.gd` 默认 `expected_number_of_ccs=1`、`expected_number_of_workers=3`；`EconomyController._enforce_number_of_ccs` 只做「数量维持到 1」 |
| 2 | 兵力上限 8 | `expected_number_of_battlegroups=2 × units_in_battlegroup=4`；`OffenseController._is_units_production_allowed` 超编即停 |
| 3 | 进攻=站桩响应 | `AutoAttackingBattlegroup._refresh_combat`：只打 `VisibleNow` 敌人 → 无则走向 `LastKnown` 敌结构 → **连 LastKnown 都没有就地待机**。从不主动推进、无目标价值评估、残编不撤退 |
| 4 | 侦察无消费者 | `IntelligenceController` 仅让无人机沿固定航点巡逻（`_build_patrol_waypoints`），产出情报无任何下游 |
| 5 | 防御无响应 | `DefenseController` 只维持 1 反坦克塔 + 1 防空塔的「存在性」（`_enforce_number_of_ag_turrets/_aa_turrets`），无受袭响应逻辑 |

对比 RA3：其 AI 的下限是固定开局 build order + 持续扩矿 + 按比例出兵 + 周期性进攻波。上述 1/2/3 恰好全部缺失，因此体感"连红警 3 都不如"。

## A.2 Design（按阶段，每阶段独立可验证）

### Phase 1 — 经济解封（EconomyController.gd）

- `_enforce_number_of_ccs` 从「数量维持」改为**条件触发扩张**：
  - 触发条件（全部满足才请求建新 CC）：`CC 数 < max_command_centers` 且 `GetOwnEconomy` 余额 ≥ `expansion_resource_threshold` 且 现有 CC 的工人已饱和（无 idle worker 可分配）。
  - 选址：用 `ScanCircle` 找「距现有 CC 最远且资源簇未饱和」的落点（resource 实体在查询中的 kind/字段名实现时核对 `WorldQueryRuntime.cs` 的 field 映射）。
- 工人目标数改为按基地数缩放：`worker_target = CC 数 × workers_per_command_center`。
- 新增 `@export`：`max_command_centers=3`、`workers_per_command_center=6`、`expansion_resource_threshold`（占位值，需实测 `BalanceConfigRuntime` 的产出曲线后定）。
- **依赖说明**：扩张蓝图的施工由现有 `ConstructionWorksController` 自动派工人完成（本文件不改动）；注意它有「任工地已有建造者即整轮 return」的短路，一次只侍候一个工地，多工地并行时第二个要等前一个完工——扩张场景需验证这点不阻塞分矿建造。

### Phase 2 — 进攻主动性（AutoAttackingBattlegroup.gd，信息源涉及 1 次查询扩展）

**信息源（评审点 A）：** 敌方出生点作为公共知识注入。两个候选方案：
- 方案 A1（推荐）：`WorldQueryRuntime` 新增只读查询 `GetSpawnPoints(sessionId)`——出生点本来就是玩家开局可见的公共信息，对 AI 是同等信息，不算迷雾违规；改动小、语义干净。（审核注：当前并无任何向人类玩家展示敌方出生点的 UI，「玩家本来就能看到」是 RTS 惯例意义上的前提，评审时需把这个惯例说定，或顺手在小地图/开局镜头补展示。）
- 方案 A2：Match 开局时由 IntelligenceController 把敌方出生点写入其内部记忆并当作 LastKnown 使用。零查询层改动，但把「公共知识」伪装成「侦察成果」，语义脏，且侦察被歼会丢失出生点信息（荒谬）。
- **不采用**：解除迷雾约束让 AI 直接看实时敌军——违反硬约束 2/3。

**行为改动（`_refresh_combat`）：** `ATTACKING` 态下的目标链改为：
1. 延续当前目标（现状保留）；
2. `VisibleNow` 敌人按新价值序（Phase 4）选取；
3. `LastKnown` 敌结构（现状保留）；
4. **新增兜底：向敌方出生点 `Move`**——用现有 `Move` + 0.5s 刷新重评估模拟 attack-move（行进途中每轮刷新发现 `VisibleNow` 敌人立即转 `Attack`）。任何状态下编组都不允许静止待机。（真正的 attack-move 模拟层已实现，见备选方案 B，此处是网关层缺口的权宜实现。）

**备选方案 B（单独评审，本 plan 默认不做）：** 在 `RuleAiCommandGateway` 暴露 `AttackMove`。**审核核实：模拟层无需改动**——`UnitCommandService.GroundAttackMove/EntityAttackMove`、`CommandRuntime.GroundAttackMoveUnits/EntityAttackMoveUnits`、联机转发（`NetCommandProxy`/`NetSync`）均已实现并在生产，人类玩家 HUD 已在用「移动并攻击」。因此 B 的真实代价 = 网关加暴露方法 + AI 逻辑切换，不再「动权威模拟层」；收益：移速中遇敌自动交战、免掉 0.5s 重评估延迟。若 Phase 2 上线后观察到「风筝拉扯导致编组来回摆动」再升级；由于代价已降至网关层，评审也可考虑将 B 直接提为首选。

### Phase 3 — 兵力与波次（SimpleClairvoyantAI.gd + OffenseController.gd + AutoAttackingBattlegroup.gd）

- 参数：`expected_number_of_battlegroups` 2→3、`expected_number_of_units_in_battlegroup` 4→6（`@export` 默认值）。
- 残编撤退：`AutoAttackingBattlegroup` 新增 `RETREATING` 态——成员存活 < `retreat_threshold`(0.5) 时全员 `Move` 回集结点（主 CC 位置，`GetOwnForces` 查询）；`OffenseController` 将残编不计入战斗力、停止其生产配额占用，直至重新满编转回 `ATTACKING`。
- 波次节奏：满编即出击（现状）保留；损失由现有 `_number_of_additional_units_required` 补足逻辑自然形成「打光→补满→再出击」的攻击波。

### Phase 4 — 目标价值（AutoAttackingBattlegroup.gd）

- 目标选择从「最近优先」改为「价值序 + 同权重取近」：`Worker(采集车) > 生产建筑(工厂/CC) > 防御塔 > 其他结构 > 其他单位`。kind 字段查询结果已携带（`entity.get("kind")`），权重表做成常量。
- 集火机制（`_current_target_id` 延续）现状已满足，保留。

### Phase 5 — 防御响应（DefenseController.gd，与 OffenseController 协同）

- 每 0.5s 对每个己方建筑 `ScanCircle(defense_radius)`（半径占位 40m，实测调）；发现 `VisibleNow` 敌人 → 通过主脑（两个控制器同为 `SimpleClairvoyantAI` 子节点，直接方法调用即可，无需新基础设施）请求 OffenseController 派**最近的非撤退编组**回防至受威胁点。
- 威胁解除判定：连续 `threat_clear_rounds`(3) 轮无敌人 → 编组恢复原任务。为防抖动，回防请求带 30s 最短执行时间。

### Phase 6 — 兵种配比（OffenseController.gd）

- 出兵从「每工厂固定一种」改为按权重轮转：primary:secondary = `unit_ratio`=2:1（`@export`）。实现点是 `_provision_unit` / `EnqueueProduction` 的类型选择处。
- （可选，P2）克制转型：`IntelligenceController` 增加 `get_enemy_composition_summary()`（`VisibleNow`+`LastKnown` 的 kind 直方图），OffenseController 刷新时读取并微调权重。注意这要求 Intelligence 首次真正产出情报——是缺陷 4 的顺手修复。

### Phase 7 — 难度分级（SimpleClairvoyantAI.gd）

- `@export enum Difficulty {EASY, NORMAL, HARD}` → 参数表覆盖：`workers_per_command_center`、`expected_number_of_battlegroups/units_in_battlegroup`、`retreat_threshold`、开局第一波出击延迟（4/3/2 分钟；注意：现有代码没有此参数，需在 Phase 2/3 先新增 `first_wave_delay`，Phase 7 只做按难度覆盖）。
- **收入倍率（RA3 式资源作弊）明确列为非目标**：需动 `EconomyRuntime`/资源账户，跨入模拟层且不公平感强。若未来要做，单独开 plan 评审。

## A.3 实现顺序与验证

顺序：1 → 2 → 3 → 4 → 5 → 6 → 7，每阶段一个可对局验证的增量。

自动化（沿用 `tests/automated/RuleAi*SmokeTest.gd` 既有模式，headless + 世界查询断言）：
- 新增 `RuleAiExpansionSmokeTest.gd`：模拟 5 分钟后 AI `CC ≥ 2`、`worker ≥ 10`（P1）。
- 新增 `RuleAiAggressionSmokeTest.gd`：编组满编且无可见敌人时，编组中心到敌方出生点的距离应满足「终点显著小于起点」（不建议断言逐 tick 单调递减——寻路绕行会引入抖动，易误报）；任意时刻编组中心速度不得长期为 0（P2/不站桩）。
- 新增 `RuleAiDefenseSmokeTest.gd`：AI 建筑受击后 T+3s 内有编组成员进入威胁半径（P5）。
- 回归：现有 `RuleAi*SmokeTest` 全绿；联机 Demo 本机双进程验收不回归（AI 命令仍全走网关，对账应无 diff）。

对局验证（以图交付）：每阶段跑一局 人 vs AI，出录屏/截图 + 服务器 headless 10 分钟稳定性对账。

## A.4 Risks

1. **快照带宽（最大风险）**：AI 作战单位 8 → 18+，10Hz 全量快照（`NetSync` 每 6 帧广播）体积上升。注意：`godot-rts-terrain/tools/bandwidth_budget.py` **不在当前仓库**（上游仓路径，工作区内不存在），上线前需先把该工具迁过来或以其他方式复算带宽预算；必要时再评估 AI 单位聚合/降频（不在本 plan 内）。
2. **服务器 CPU**：轮询频率不变（0.5s）、实体数 ×2~3；但 Phase 5 改为「每个己方建筑一次 `ScanCircle`」，查询次数随建筑数线性增长（每 tick 约 10+ 次），是「频率不变」没覆盖的新负载，部署后观察 headless 帧耗时确认；压力过大时可改为「以主基地为中心一次大半径扫描」。
3. **会话边界纪律**：新增信息（出生点）必须走 `WorldQueryRuntime` 正规会话。这是评审重点——任何「为了方便直接 get_node 读敌军」的实现都应被拒。
4. **「移动+重评估」模拟 attack-move 的代价**：Phase 2 的兜底在敌人撤退拉扯时可能出现编组来回摆动；观察对局，必要时升级为备选方案 B（代价已降至网关层暴露，见 Phase 2）。
5. **数值依赖**：`expansion_resource_threshold`、`defense_radius` 等阈值依赖 `BalanceConfigRuntime` 实测产出/射程曲线，本文占位值均需标定后回填。

## A.5 Non-goals

- 不做 ML / 行为树框架重写（现有「信号 + 资源请求 + 命令网关」架构承载力足够）。
- 不动模拟层权威性、确定性与联机协议。
- 不做收入作弊；不新增任何迷雾外实时信息。

## A.6 附：涉及文件清单

| 文件 | 行数 | 改动类型 |
|------|------|----------|
| `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd` | 157 | 参数、难度、控制器间消息仲裁 |
| `source/match/players/simple-clairvoyant-ai/EconomyController.gd` | 250 | P1 扩张与工人缩放 |
| `source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd` | 259 | P2 兜底推进、P3 撤退态、P4 目标价值 |
| `source/match/players/simple-clairvoyant-ai/OffenseController.gd` | 400 | P3 波次、P5 协同、P6 配比 |
| `source/match/players/simple-clairvoyant-ai/DefenseController.gd` | 144 | P5 威胁检测 |
| `source/match/players/simple-clairvoyant-ai/IntelligenceController.gd` | 137 | P2 出生点消费、P6 情报输出（可选） |
| `source/match/players/simple-clairvoyant-ai/ConstructionWorksController.gd` | 64 | 不改（P1 依赖：扩张蓝图的施工派工，需验证多工地短路逻辑） |
| `source/csharp/GodotAdapter/Queries/WorldQueryRuntime.cs` | — | P2 只读扩展 `GetSpawnPoints`（方案 A1） |
| `tests/automated/RuleAi{Expansion,Aggression,Defense}SmokeTest.gd` | 新增 | 阶段断言 |

---

# Part B：服务器 LLM AI 副官网关 + 局服（yyp_test）

## B.0 Overview

同一台腾讯云 Ubuntu（4 核 8G / 约 12 Mbps）跑两件事，代码一律签出 **`yyp_test`**：

1. **Agent 工具 / LLM 网关**：策划文档里的 RemoteLLMPolicy 与工具 Schema，不跑 Godot 编辑器。
2. **游戏权威进程（后上）**：2–4 人 Demo 的 Godot Linux dedicated；对局事实只在这里。

两者用 **本机回环上的版本化 DTO** 连接。大模型不碰场景树、不改血量、不读迷雾外真值。API Key 只在服务器环境变量，不进 Git。

## B.1 Current State Analysis

### 策划已冻结的约束（必须遵守）

来源：`策划文档_AI副官系统.md`、`AI副官_下一阶段开发训练与评测规格.md`、`AI副官_权限与情报规则_P0.md`、`程序重构_AI操作点与受限观察方案.md`。

| 要求 | 对部署的含义 |
|---|---|
| 游戏系统提供合法事实，LLM 只理解/判断/提议 | 网关不能写 Godot Node；只能调查询和 `CommandRuntime` |
| 迷雾外敌军真值不得给 AI | 网关只用 `QuerySourceKind.Agent` 会话，禁止 `OmniscientDebug` |
| Human / RuleAI / LLM 共用权威命令服务 | 联机后命令仍进现有 `UnitCommandService`，多一个 issuer |
| `RemoteLLMPolicy` 只做 Observation→工具 Schema→Intent | 独立进程，超时/失败降级 ScriptedPolicy |
| API Key 不进仓库、不进 Trace | systemd `EnvironmentFile`，Trace 只记 provider/model/prompt_version |
| 禁止 LLM 逐帧微操 | 网关按决策调度调用，不跟 60Hz |
| 进入正式 LLM 对局前要能 Headless + ScriptedPolicy | 服务器先能无头跑场景，再接真模型 |
| P0 战术托管：Move/Attack 等可自动，生产/科技禁止 | 工具表按权限矩阵裁剪 |
| 玩家手动优先于 AI | 局服取消冲突 Intent，网关不得覆盖 |

代码侧已有：`WorldQueryService`（`GetOwnForces` / `ScanCircle` / …）、`QuerySourceKind.Agent`、`IBudgetedWorldQueryService`（边界已留、未做扣费）、对局联机层（`NetSession`/`NetSync`，见 `联机Demo-plan.md`）。还没有：RemoteLLMPolicy、工具 Schema 运行时、决策调度、Episode Trace 落盘、Agent 的 DTO 联机链路（网关未部署，见 B.7）。

### 不要部署到这台公网机的东西

- Godot **编辑器** + `addons/godot_mcp` 公网监听。MCP 文档写明：远程访问必须单独安全评审并认证。编辑器还要显示/GPU，4 核 8G 会被吃光。
- Cursor 本机 MCP（9080）原样映射到 0.0.0.0。
- 把 LLM 推理模型装在这台 8G 上（`LocalModelPolicy` 是以后的事；P1 只用一个远程 Provider + Mock）。

### Git 现状

本机当前分支是 `yyp_test`，跟踪的是 `origin/yyp_map`（HEAD 随提交漂移：本文写作时 `8581a30`，2026-08-30 审核时已走到 `7d438a2`，勿把哈希当准）。远端不一定已有 `yyp_test` 这个名字。服务器绑定该分支前需要：把 `yyp_test` **推到 origin**（或你们实际有写权限的 fork），服务器只 `fetch` + `checkout yyp_test`。（2026-08-30 更新：服务器实际改用「本地 git bundle 增量 + SFTP 上传 + 服务器 pull」部署，origin 直推待凭据打通，见 B.7。）

## B.2 Implementation Strategy

一台机器、一个仓库目录、三个 systemd 单元，CPU/内存用 cgroup 隔开，避免 Agent 把局服卡死。

```text
测试同学 Windows 客户端
        │ UDP（以后，游戏口）
        ▼
[airts-game]  Godot 4.7.1 Mono dedicated / headless     绑定 127.0.0.1 工具口 + 公网 UDP
        │ HTTP/JSON 或 Unix socket，仅 127.0.0.1
        │ ObservationEnvelope / ProposedIntent / Feedback（带 schema_version）
        ▼
[airts-agent]  RemoteLLMPolicy 网关
        │ HTTPS 出站
        ▼
远程大模型 Provider（一个即可）

[airts-sync]  定时 git fetch origin yyp_test && 校验后重启（人工或 webhook）
仓库路径：/opt/airts   分支：只允许 yyp_test
```

**工具表（Agent 允许调用的，对应已有查询 + 命令，不是 MCP）：**

- 观察：`GetOwnForces`、`GetOwnEconomy`、`ScanCircle`、`InspectOwnEntity`、`GetBattlefieldBounds`（字段按 Agent 会话裁剪）。
- 意图：与 P0 矩阵一致的 Move / Attack / AttackMove / Hold / Retreat / Stop / 姿态与开火；生产、科研、改任务目标不出现在工具里。
- 网关把 LLM tool call 变成 `ProposedIntent`，局服 Validator 再决定执行或拒绝；拒绝原因对模型走过滤后的 Feedback，原始 `UnitNotFound` 不回传以免探雾。

**联机时：** 每个真人玩家一个 `QuerySessionGrant(Source=Agent, Observer=该玩家)`。语音/文字从客户端发到局服，局服带上玩家 ID 转给网关。网关无玩家身份则拒绝。

**和 2–4 人 Demo 的关系：** 局服可以晚于网关。第一期 Agent 可以对 **单机 headless / 战役切片** 调工具（满足策划「先 Scripted + Headless」）。多人 UDP 就绪后，同一网关接到权威 Match，不用换工具 Schema。（已就绪：联机权威服已上云，见 `docs/plan/联机Demo-plan.md`。）

## B.3 Implementation Steps

1. ⏳ **Git 钉死 yyp_test**：origin 上出现 `yyp_test`；服务器 deploy key 只读该仓；`git checkout --force yyp_test`；禁止在服务器上改文件当正式源。
2. ⏳ **目录与密钥**：`/opt/airts`、`/etc/airts/agent.env`（Provider endpoint、模型 ID、timeout、prompt_version）；防火墙默认拒绝，只出站 443 + 入站 22 / 以后 UDP。
3. ⏳ **工具合同落地（先 Mock）**：把现有 `IWorldQueryService` + `UnitCommandService` 封成带 `tool_schema_version` 的 JSON；`MockPolicy` 与 `ScriptedPolicy` 能在 headless 场景走完「观察→意图→校验→Trace」。不接真 LLM 也算 Agent 工具部署成功。
4. ⏳ **RemoteLLMPolicy**：一个 Provider；异步、超时、解析失败 → 确定性 fallback；Trace 记 token/延迟，不记 Key、不记隐藏真值。
5. 🔶 **局服进程**：Linux `dedicated_server` 导出；对网关只绑 `127.0.0.1`；对玩家以后绑 UDP。cgroup：局服预留约 3 核 / 5G，网关 1 核 / 1–1.5G。（局服进程已上云运行——源码 headless 而非导出包，见联机 Demo plan；Agent DTO 链路未接。）
6. ⏳ **联机接上**：2–4 人 Match 里按玩家签发 Agent 会话；HUD 文字进同一条链（语音识别可仍在客户端，只把文本上传）。
7. ❌ 公网 Godot MCP、在 8G 上跑本地大模型、多 Provider、像素控制。

## B.4 Timeline

| 阶段 | 服务器上看见什么 | 依赖 |
|---|---|---|
| G0 | `/opt/airts` 在 `yyp_test`，能 `git pull` | 远端分支 + 部署密钥 |
| G1 | Mock 工具 + headless 一局 Trace | 不必联机、不必真 LLM |
| G2 | 真 Provider，战役/切片里副官能问能下已有命令 | G1 + Key |
| G3 | 无头局服 + 2–4 人 UDP | `docs/plan/联机Demo-plan.md` |
| G4 | 每人一个副官会话 | G2 + G3 |

## B.5 Risk Assessment

| 风险 | 缓解 |
|---|---|
| Agent 阻塞 tick | 网关异步；局服绝不 `await` LLM |
| 工具把迷雾打穿 | 只签发 Agent 会话；评测真值另一通道，不进 Policy |
| `yyp_test` 与 origin 脱节 | 服务器拒绝手改；只快进该分支 |
| 4G 内存被 .NET + Godot + Python 挤爆 | 先 G1 量 RSS；局服与网关分 cgroup |
| MCP 暴露公网 | 不装编辑器、不端口转发 9080 |
| API 费用 | 事件驱动调用，禁止每帧；超时降级规则 AI |
| 无 GitHub 写权限推不出 `yyp_test` | 用有权限的远端，或管理员建 `yyp_test` |

## B.6 Success Criteria

- 服务器 `git rev-parse --abbrev-ref HEAD` 恒为 `yyp_test`。
- 不接 LLM 时，headless + Mock/Scripted 能对 `IWorldQueryService` 走完一局并写出 Trace（策划 P0 门槛中与部署相关的部分）。
- 接 LLM 后，模型只能通过工具表观察/提议；非法 Intent 被 Validator 挡住且游戏不崩。
- 游戏进程与网关可独立重启；Key 不在仓库。
- 未把编辑器 MCP 绑到公网 IP。

## B.7 Progress Tracking

- ✅ SSH 可达（Ubuntu 22.04.5，4 核 / 7.6G / 178G 盘）
- ✅ 轻量 Hermes Agent v0.20.6 已装（中国镜像 `res1.hermesagent.org.cn`，无浏览器/无捆绑 skills）；路径 `/home/ubuntu/.local/bin/hermes`
- 🔶 远端 `yyp_test` + 服务器只读签出 → 实际以「本地 git bundle 增量 + SFTP 上传 + 服务器 pull」部署（2026-08-30 起运转，脚本在 `临时文件夹/`）；origin 直推 `yyp_test` 仍待凭据打通
- ⏳ Mock 工具合同 + headless Trace
- ⏳ RemoteLLMPolicy 单 Provider
- 🔶 局服 dedicated + 本机 DTO → 局服进程已上云运行（联机 Demo 权威服，UDP 24567，systemd 托管），但 Agent DTO 链路未接，网关未部署
- ⏳ 2–4 人与每玩家 Agent 会话
- ❌ 公网 MCP / 本地大模型

## B.8 Related Files

- `docs/策划文档/策划文档_AI副官系统.md`
- `docs/策划文档/AI副官_下一阶段开发训练与评测规格.md`
- `docs/策划文档/AI副官_权限与情报规则_P0.md`
- `docs/程序文档/程序重构_AI操作点与受限观察方案.md`
- `docs/程序文档/程序协作_Godot_MCP集成.md`
- `source/csharp/Application/Queries/WorldQueryContracts.cs`（`QuerySourceKind.Agent`）
- `docs/plan/联机Demo-plan.md`（联机架构 + 部署）
