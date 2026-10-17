# RA3 电脑玩家与寻路逆向研究报告（完整执行版）

- 日期：2026-10-11（Asia/Shanghai，执行窗口见 §1.1）
- 计划：`agent/plans/2026-10-11-ra3-ai-pathfinding-research.md`
- 提示词：`agent/prompts/2026-10-11-ra3-ai-pathfinding-research.md`
- 研究对象：`D:\Red Alert 3`，版本口径为本机安装的 1.12（仅 1 字节 4GB patch，见 §2.3）
- AIRTS 工程：`G:\AIRTS\AI_RTS`
- 证据产物目录：`G:\AIRTS\AI_RTS\agent\runs\2026-10-11-ra3-research\`
- 逆向脚本目录：`D:\RA3_RE_Research\scripts\`（s0_identity.py / s2_static_analysis.py / s2b_vftable_units.py / s2c_context_dump.py）
- 状态：`needs-review`（**S2 函数级静态分析已完成；AI/寻路核心研究待继续**；无动态 RA3 对局，见 §4.7.9 与 §8）
- 本轮是否修改 AIRTS 游戏代码：**否**（只新增/更新研究计划、提示词、报告与 `agent/runs` 证据）

---

## 1. 执行环境与只读边界

### 1.1 执行时间、机器与工具

| 项 | 值 | 证据 |
|---|---|---|
| 执行时间 | 2026-10-11 14:01:48 起（首份证据 `s0_identity.json` 生成时刻） | `agent/runs/2026-10-11-ra3-research/s0_identity.json` |
| 主机 | `USER-20240810XL` | 同上 `host` 字段 |
| Python | 3.12.7 | 同上 `python` 字段 |
| pefile | 2024.8.26 | 同上 `pefile` 字段 |
| capstone | 5.0.7（`D:\RA3_RE_Research\python_deps`，pip --target，未写入 AIRTS） | `s2_static.log` |
| Ghidra | **11.0.3 已安装**（2026-10-11 下载安装，官方 SHA-256 校验通过，见 §4.7.1）；配 OpenJDK 17.0.18（JDK 17 为 11.0.x 要求版本） | `D:\RA3_RE_Research\tools\ghidra_11.0.3_PUBLIC\`；`ghidra_control_flow.json` |

### 1.2 只读边界

- `D:\Red Alert 3` 全程以 `rb` 只读打开，未改名/覆盖/打补丁/注入/删除任何文件（4GB patch 文件为本机既有状态，本轮未改）。
- 全部反编译产物、脚本、JSON、日志只写入 `D:\RA3_RE_Research\` 与 `G:\AIRTS\AI_RTS\agent\runs\2026-10-11-ra3-research\`。
- AIRTS 只更新：本报告、`agent/plans/2026-10-11-ra3-ai-pathfinding-research.md`（追加执行记录）、提示词（未改）。未修改任何游戏源码。
- 工程身份核对：`git rev-parse --show-toplevel` = `G:/AIRTS/AI_RTS`；`python tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/agent/reports/closed-loop` rc=0。

---

## 2. S0 身份与基线（`measured`）

### 2.1 目标文件身份

| 文件 | 大小 (bytes) | SHA-256 | 说明 |
|---|---|---|---|
| `D:\Red Alert 3\RA3.exe` | 2,694,656 | `8E115E0E66811014C876BD870920C7EB702E81C007E4FE33EF32FC02CD11CA7F` | 第三方启动器（VC8 构建，e_lfanew=0x110，machine=0x14c），**不是游戏逻辑本体** |
| `D:\Red Alert 3\Data\ra3_1.12.game` | 9,306,112 | `EC230C6AE1EAEE30B0B4FA6BA29D417C974ECAE46D6715DFBE786A815935C165` | **真实游戏本体**，与 `_4gb_patched.backup` 逐字节相同 |
| `...\ra3_1.12.game_4gb_patched.backup` | 9,306,112 | `EC230C6AE1EAEE30B0B4FA6BA29D417C974ECAE46D6715DFBE786A815935C165` | 与本体一致 |
| `...\ra3_1.12.game_4gb_unpatched.backup` | 9,306,112 | `4D75548863BB30175F03C24541A0C48385B50E3D32E914D9E8D1F8A084781E11` | 未打 patch 的原始备份 |
| `D:\Red Alert 3\RA3_chinese_t_1.12.SkuDef` | 116 | `6CB3DA883A88CEC465ABEE330281FA52C8831BBEFCE5C13723EBBC3B9D1AF36E` | `set-exe Data\RA3_1.12.game` |
| `D:\Red Alert 3\Data\Core12.big` | 4,032,298 | `2BFB6258FED3288EE49283BCD6F2B1A29DAC02B66D2E5D6465D53D2C3F64AA4C` | 1.12 增量数据包 |
| `D:\Red Alert 3\Data\MapsMultiplayer.big` | 197,558,901 | `4BF147FD175133FD63539C746E39F0CCB9EE9B16D830A1E4EEB7F6507AA4AB3C` | 多人地图包 |

证据：`agent/runs/2026-10-11-ra3-research/s0_identity.json` + `s0_identity.log`（可重跑：`python D:\RA3_RE_Research\scripts\s0_identity.py --out <json>`）。

### 2.2 启动器与游戏本体的区别（直接证据）

- `RA3_chinese_t_1.12.SkuDef` 全文 3 行：`set-exe Data\RA3_1.12.game` / `add-big Data\Maps12.big` / `add-big Data\Core12.big` / `add-config RA3_chinese_t_1.11.SkuDef` ⇒ **游戏逻辑在 `ra3_1.12.game`**，`RA3.exe` 只负责拉起它。
- `RA3.exe` PE 入口 RVA 0x10ba、2.6 MB 体积，属启动器规模；本体 `ra3_1.12.game` 有自定义节 `rts.ver` 和 8.1 MB 代码。

### 2.3 4GB patch 精确差异（`measured`，本轮新证据）

`ra3_1.12.game` 与 `_4gb_unpatched.backup` **全文件仅 1 字节不同**：

| 文件偏移 | 原始 (unpatched) | 当前 (game) | 含义 |
|---|---|---|---|
| `0x126` | `0x03` | `0x23` | PE COFF FileHeader.Characteristics：置位 `IMAGE_FILE_LARGE_ADDRESS_AWARE (0x20)` |

- 当前特征值 `0x123` = EXECUTABLE(0x2) + 32BIT(0x100) + LARGE_ADDRESS_AWARE(0x20) + RELOCS_STRIPPED(0x1)；未打 patch 为 `0x103`。
- **结论**：本机 1.12 本体除这 1 个标志位外与 EA 原版一致，因此本报告的全部静态结论可归因到官方 1.12 构建。

### 2.4 游戏本体 PE 摘要（`measured`）

| 项 | 值 |
|---|---|
| machine / PE type | `0x14c`（x86）/ `0x10b`（PE32） |
| image base / entry RVA | `0x400000` / `0xD398D`（与初版一致；注意初版读的是同一文件） |
| 链接器 | VC8（linker 8，MSVCR80/MSVCP80） |
| `.text` | RVA `0x1000`，virtual/raw size `0x7c6000`（≈8.1 MB） |
| `.rdata` | RVA `0x7c7000`，size `0xe4000` |
| `.data` | RVA `0x8ab000`，raw 0x2b000 |
| 自定义节 | `rts.ver`（RVA `0x931000`）、`.tls`、`.rsrc` |
| 重定位 | 无 `.reloc` 节（RELOCS_STRIPPED）⇒ 固定基址 0x400000，字符串按绝对 VA 引用，字节内搜索 xref 有效 |
| 导入 DLL | MSVCR80(165)、KERNEL32(152)、USER32(61)、WS2_32(36)、ADVAPI32(12)、IMM32(12)、d3dx9_35(9)、DSOUND(5)、ole32(5)、SHELL32(4)、SHLWAPI(4)、WINMM(3)、USP10(2)、d3d9(1)、GDI32(1)、XINPUT1_3(1)、MSVCP80(1)、NETAPI32(1) |
| 导出 | 498 项 |

导入表只证明链接了这些 DLL；**不能**据此推断 AI/寻路是否多线程（见 §8 阻塞项）。

---

## 3. S1 官方数据模型（`official-schema`，全部带文件+行号）

来源根：`D:\RA3_RE_Research\refs\CnC_Modding_Support\Red Alert 3\Schemas\`。
以下全部为 EA 官方发布的 RA3 XSD 设计数据模型；除明确标注外，**不声称**这些默认值等于实际运行值。

### 3.1 分层骨架：`xas:runtimeWrapper` 绑定（Schema→运行时类型的直接证据）

| Schema 类型 | 绑定运行时类型 | 文件:行 |
|---|---|---|
| `AIPersonalityDefinition` | `::AIPersonality` | `SkirmishAI/AssetTypeAIPersonalityDefinition.xsd:155` |
| `AIStateDefinition` | `::AIState` | `SkirmishAI/AssetTypeAIStateDefinition.xsd:362` |
| `AIStrategicStateDefinition` | `::AIStrategicState` | 同上 `:373` |
| `AIBudgetStateDefinition` / `AIBuildStateDefinition` | `::AIBudgetState` / `::AIBuildState` | 同上 `:405` / `:415` |
| `AIMicroManagerData` | `::AIMicroManager` | `SkirmishAI/AssetTypeAIMicroManager.xsd:22` |
| `AITargetingHeuristic` | `::AITargetHeuristic` | `SkirmishAI/AssetTypeTargetHeuristics.xsd:71` |
| `LocomotorTemplate` | `::LocomotorTemplate` | `AssetTypeLocomotorTemplate.xsd:112` |
| `GameObject` | `::ThingTemplate` | `AssetTypeGameObject.xsd:382` |

### 3.2 人格/战略（`AssetTypeAIPersonalityDefinition.xsd`）

- `:11-29` `AIEnemySortingType` 枚举：`NearestFirst_AllowTies` / `NearestFirst_BreakTies` / `Flat` / `StrongestFirst_AllowTies` / `StrongestFirst_BreakTies`（注释说明"基地对基地距离"与"单位+建筑总值"两种排序语义）。
- `:224-227` **按难度选择敌人排序**：Brutal/Hard `NearestFirst_BreakTies`、Medium `Flat`、Easy `StrongestFirst_AllowTies`。
- `:228` `EnemyResortingTime` 默认 15s（重新排序周期）。
- `:194` `SecondsTillTargetsExpire` 默认 15.0（目标过期时间）。
- `:197` `DefaultThreatFindRadius` 500；`:213` `ReactiveDefenseRadius` 1200。
- `:205-207` 科技门槛：`BuildTechEfficiencyThreshold` 0.5 / `BuildTechMinPowerAdvantage` 1.1 / `BuildExtraFactoryMinTime` 240s。
- `:208-212` 扩张：`ResourceNodeSearchRadius` 500 / `ResourceNodeValueRemainingForExpansion` 3000 / 炼油厂放置步进参数。
- `:214-223` 紧急管理器（断电/断收入/无主基地/被攻击/主基地危险）与工程师距离。
- `:238` `MaxStrategicTargets` 默认 32（战略目标上限）。
- `:244-247` Red Alert 专用机制：`RedAlertPowerAdvantage` 0.5 / `RedAlertIncome` 50 / `RedAlertProductionBuildings` 2 / `RedAlertAttackTime` 15s。
- `:252` `MaxWallDestroyTimeToCountAsGoThroughWalls` 1s（"能打穿墙"的招募判据）。

### 3.3 战略状态/目标/战术（`AssetTypeAIStateDefinition.xsd`）

- `:20-360` 状态启发式族（`HeuristicChoice`，`:319-360` 汇总 25+ 种）：Timer / Interval / PowerAdvantage / IncomeAdvantage / EnemyNearby / StructureOrHarvesterUnderAttack / OpeningMove / HarvesterCap / ResourceNodeShare / TechBuildingShare / Money / TimeSinceLastExpansion / IsBuilding / AllNearbyNodesFull / OpenNode / Garrison / **PathToTarget** / BridgeExists / ObjectOfTypeExists / CanBuildBuildingsOnSurface / ScriptedFlag / BeaconExists / StrategicDirective / RedAlert / LinearCombination。
- `:156-165` `AIStatePathToTargetHeuristic`：`Surface`、`ObjectTypeToUseForTest`、`LocomotorConditionToUseForTest`、`PathExists` ⇒ **状态级可达性测试**（与 §3.6 的 QuickDoesPathExist 配套）。
- `:291-317` `AIStateLinearCombinationHeuristic`：加权组合 ≥2 个启发式（weight 默认 0.5）⇒ 评分是可组合的线性系统。
- `:373-391` `AIStrategicStateDefinition`：`MaxTargets`(1) / `MaxRunningCopies` / `MaxInactiveCopies` / `PathfindingCheckType` / `CannotAttackTargetReaction` / 4 个反馈 Key。
- `:426-430` `StateTargetHeuristic`：目标启发式按 `Priority`（默认 10）排序，**高优先级先检查**。
- `:433-451` `Tactics` 枚举：`SimpleAttack` / `FlankAttack` / `DefenseAvoidanceAttack` / `SimpleSiege` / `Engineer` / `SimpleDefense` / `StaticDefense` / `ReactiveDefense` / `SimpleExpansion` / `ExactExpansion` / `Hunt` / `RoamingDefense` / `GarrisonBuilding` / `Scripted` / `NullTactic`。
- `:453-460` `TacticEndBehavior`：`RAMPAGE` / `DISBAND` / `RETURN_HOME_AND_DISBAND` / `PICK_NEW_TARGET`。
- `:462-490` `AIStateTactic`：`Targetless`、`DisbandAfterRetreatTeamSize`、`EndIfStateTurnsOff`、`AestheticsManagerPatrolIdleTime`(10s)、`Distance`(400)、`CombatLeashSlack`(1.5，防在拴绳边界来回弹)、`GatherWaypoint`、`UseTransports`、`UpdateTime`(1.0s)，并内嵌 ≤4 个 `TeamTemplate`。

### 3.4 团队模板（`SkirmishAI/AssetTypeAITeamTemplate.xsd`）

| 字段 | 行 | 语义 |
|---|---|---|
| `MinUnits`/`MaxUnits` | `:61-62` | 团队规模区间（`CreateUnits` `:42-47` 逐类型 Min/Max，最多 7 组） |
| `MinPowerAdvantage` | `:63` | 成队/行动所需最低力量优势 |
| `MaxTypesOfUnits` | `:64` | 混编种类上限 |
| `Priority` / `ReleaseType` | `:67-68` | 团队优先级（`:23-36` 注释"枚举顺序即优先级，低→高"，含 `HOTSPOT`/`SCRIPTED`）+ 释放策略（`ALWAYS_RELEASE`/`RELEASE_TO_PRIORITY`/`NEVER_RELEASE` `:15-21`） |
| `AlwaysRecruit` / `AllowRecruitUnitsInCombat` | `:69-70` | 持续招募 / **战斗中招募** |
| `RequireCanAttackTarget` | `:71` | 要求成员能攻击目标 |
| `MicroManager` | `:72` | **必需**引用一个 `AIMicroManagerData` ⇒ 团队必须绑定微操管理器 |
| `AllowedLocomotorTypes` | `:73` | `LAND/WATER/AMPHIBIOUS/AIR` 位标志（`:6-13`） |
| `SortByDistance` / `DistanceSortPoint` | `:74-75` | 距离排序开关 + 排序基准点（`TARGET_POINT` 或 `HOME_BASE`，`:49-54`） |
| `IsBaseDefenseTeam` / `BaseDefenseMaxDistance` | `:80-83` | 基地防御团队的专门语义（注释：其他多数字段被忽略） |

### 3.5 微操管理器（`SkirmishAI/AssetTypeAIMicroManager.xsd` + `AssetTypeAIMicroManagerStates.xsd`）

**空闲重下令（本提示词重点）**：

- `:35-41` 注释原文语义：*"If the team's center point has not moved more than this distance in this long, the team as a whole should be considered idle and given its orders again (assuming the team is not obviously busy e.g. in combat)."* ⇒ `MaxTeamIdleTime` 默认 **30s**、`MaxTeamIdleDistanceChange` 默认 **50.0**。
- `:43-46` 注释：*"If a unit has not moved more than this distance in this long, the unit is considered idle, even if it thinks it is doing something."* ⇒ `MaxUnitIdleTime` 默认 **10s**、`MaxUnitIdleDistanceChange` 默认 **50.0**。
- `:33` `UpdateTime` 默认 **1s**（微操的决策节拍）。
- `:39` 注释自述这条 idle 逻辑"本当属于 Tactic，为编码方便放在 MicroManager"。

**目标保持/搜索**：`:58-59` `TimeToKeepTargetMin/Max`（0s；注释：低难度延长以降低 AI 反应性）；`:52-54` `PassiveTargetSearchDistance` 400 / `EnemySearchDistanceVisionMultiplier` 1.25 / `MinTimeToKeepTempVisionRangeBonus` 10s；`:63` `RandomTargetScoreModifier`（低难度注入评分误差）；`:30` `IgnoreTargets` 过滤器。

**撤退/清剿**：`:65` `CleanupPowerAdvantage` 4.0；`:70-74` `RetreatPowerAdvantage` 0.25 / `RetreatMinDistanceFromBase` 900 / `RetreatMinDistanceToFallback` 500 / `RetreatSpeedBuffer` 0.75；`:76` `MaxDistanceFromTeamToIncludeInArmy` 600（掉队单位是否重新纳入军队）。

**集火/单点突击**：`:78-80` `AlphaStrikeTargetHealthPct` 0.5 / `AlphaStrikeTargetTimeToKill` 4.0 / `AlphaStrikeEngineerDistanceFromStructure` 200；`:82-83` 攻城缓冲。

**单位级行为开关**：`:85-86` 碾压；`:88-89` 驻军（150 距离）；`:93-94` `PullbackInjured`=true / 20% 血线拉回；`:96-99` `ReverseMove`、`DodgeThreats` + 反应时间区间；`:101-103` 特殊能力；`:108-110` `IsHarvesterManager`（专门采矿区回逻辑）；`:120` `FractionBlockedToDestroyWalls` 0.5。

**状态机枚举（`AssetTypeAIMicroManagerStates.xsd`）**：

- `:4-17` `MicroManagerState`：`ALPHA_STRIKE` / `RETREAT` / `COMBAT` / `CLEANUP` / `SIEGE` / `GATHER` / `OPEN_TARGET` / `HARVESTING` / `IDLE` / `DEMOLISH_WALL_OBSTACLE`。
- `:23-36` `MicroManagerUnitTask`：`AVAILABLE` / `CRUSHING` / `GARRISONING` / `CLEARING_GARRISON` / `REPAIRING` / `REVERSING` / `CONTROLLED_BY_SPECIAL_POWER` / `ACTIVATING_SPECIAL_POWER` / `DEPLOYING` / `DODGING`。

⇒ 官方设计里微操是**明确的状态机**（团队级状态 + 单位级任务），不是"每帧重算一遍"。

### 3.6 路径可达性（`Includes/PathfindingCheckType.xsd`）

- `:6-7` 注释：*"Before a unit can be recruited onto a team, it must be able to reach the target object or location."* ⇒ **招募前置可达性检查**。
- `:12` `QuickDoesPathExist`（必须真能到达）；`:15` `QuickDoesAttackPathExist`（只需能进入攻击范围）；`:18` `None`。

### 3.7 移动模板（`AssetTypeLocomotorTemplate.xsd`）

| 字段 | 行 | 默认 | 语义 |
|---|---|---|---|
| `Surfaces` | `:120` | `""` | 可行走表面（`GROUND/WATER/CLIFF/AIR/RUBBLE/OBSTACLE/IMPASSABLE/DEEP_WATER/WALL_RAILING/CRUSHABLE_*`，`:30-44`） |
| `LookAheadMult` | `:121` | 1.0 | 路径前视倍率 |
| `TurnTimeSeconds` | `:125` | 1.0s | 转向时间 |
| `SlowTurnRadius` / `FastTurnRadius` | `:127-128` | 0.0 | 慢/快转弯半径 |
| `TurnThreshold` | `:132` | 15d | 转向阈值角 |
| `AccelerationSeconds` / `BrakingSeconds` | `:134` / `:137` | 1.0s | 加速/刹车时间 |
| `MinTurnSpeed` | `:138` | 1.0 | 转向时的最低速度比例 |
| `FormationPriority` | `:147` | `MELEE_1` | 队形优先级：`LocoF` 枚举 `NO_FORMATION / CAVALRY_1..3 / MELEE_1..3 / RANGED_1..3 / ARTILLERY_1..3`（`:68-84`）——按**战斗角色**分派队形 |
| `MaxTurnWithoutReform` | `:157` | 360d | 超过该转向需重新编队 |
| `CloseEnoughDist` | `:178` | 1.0 | 到达容差 |
| `CanMoveBackward` / `CanReverseMove` / `ReverseMoveSpeed` | `:187-189` | false/false/75% | 倒退与倒车速度 |
| `WaitForFormation` | `:209` | false | **等待队形**再走 |
| `BackingUpSpeed` 等 5 项 | `:223-227` | 75%/… | 让路倒车参数 |
| `TurnWhileMoving` / `ClampOrientationToPathTangent` / `ReorientIfTurnTooSharp` / `BrakeBeforeReorienting` | `:232-235` | true/false/false/false | 行进转向、朝向贴合路径切线、急转重定向、重定向前刹车 |
| `MaxOverlappedHeight` | `:169` | 1e+37 | 允许重叠的高度语义（分层） |

### 3.8 实体属性（`AssetTypeGameObject.xsd`）

| 字段 | 行 | 默认 | 语义 |
|---|---|---|---|
| `FormationWidth` / `FormationDepth` | `:467-468` | 1 / 1 | 队形占用宽×深（Design 类） |
| `PathfindDiameter` | `:496` | -1 | 寻路直径（Engineering 类，独立于视觉/逻辑半径） |
| `PathPriority` | `:502` | 25 | 路径优先级（谁让谁） |
| `VisionInfo`（元素/类型） | `:420` / `:649-659+` | — | `VisionRange` / `ShroudClearingRange` / `ShroudClearingHeight` / `VisionSide&Rear` 百分比 / `VisionBonus*` ⇒ 视野独立建模 |
| `ProjectedBuildabilityInfo.Radius` | `:369-370` | 0 | **建造投影半径**（证明"Radius"一词至少还承载建造语义，与移动半径无关） |
| `SkirmishAIInformation` | `:566-616` | — | 挂在实体上的 AI 信息块 |
| `DodgeWithUnits` | `:581` | — | 注释：*"Tells the MicroManager which units should try to dodge this object"* |
| `OutOfRangePenalty` | `:596-599` | 1.3 | 注释直接引用实现函数：*"Used by **AIMicroManager::DetermineTargetsFocusFire** to worsen the score of targets out of range of their attacker"* |
| `DodgeSafetyDistance` | `:608` | 300.0 | 威胁闪避安全距离 |
| `OverrideInner/OuterDistanceToTarget` | `:609-613` | — | 注释：寻路到目标默认检查"武器 min range 圆 / max range 圆"，可覆盖 ⇒ **攻击寻路是到攻击范围圆，不是到本体** |
| `CanFireUpCliffs` / `DoesSecondaryDamage` | `:614-615` | false/false | 射击地形语义 |

### 3.9 目标启发式排序（`SkirmishAI/AssetTypeTargetHeuristics.xsd`）

- `:10-42` `TargetingHeuristicType`：`EnemyStructure` / `FriendlyStructure` / `EnemyUnit` / `FriendlyUnit` / `UnderAttackBy` / `Enemy*CloseToShore` / `NeutralGarrison` / `EnemyGarrison` / `Expansion` / `TechBuilding` / `Bridge` / `Beacon` / `Crate` / `Help` / `Husk` / `Point` / `UnpackBuildingPlacement` / `NamedObject` / `Waypoint` / `Team`。
- `:45-54` `AITargetSortType`：`Distance` / `ThreatToGround` / `ThreatToAir` / `ThreatToWater` / `Random` / `ClosestToEnemy`。
- `:80-104` 其余：`HeuristicType`、`SortType`(默认 Distance)、`Vital/ForbiddenKindOf`、`Vital/ForbiddenObjectStatus`、`HighestPriorityEnemyPlayersOnly`、`ThreatFinderRange`、`SearchRange`(1500)、`UnderAttack`、`RequireUniqueTarget`（同一目标一次只给一个使用者）、`MinDistanceFromEnemy`。

### 3.10 字段语义速查（提示词点名项）

| 提示词点名 | 证据位置 | 一句话语义 |
|---|---|---|
| 团队/单位 idle | MicroManager `:40-46` | 团队中心 30s/50m、单单位 10s/50m 无位移 ⇒ 重下令 |
| 目标保持 | `:58-59` | `TimeToKeepTargetMin/Max` 锁定当前目标，防评分抖动 |
| 目标排序 | Personality `:11-29,224-228` + TargetHeuristics `:45-54` | 敌人按距离/强度排序（分难度），目标按 Distance/ThreatTo*/Random/ClosestToEnemy 排序 |
| 撤退 | MicroManager `:70-74` | 力量优势 0.25 + 距基地 900 + 回撤距离 500 + 速度缓冲 0.75 触发撤退 |
| 编组人数 | TeamTemplate `:61-62` | `MinUnits`~`MaxUnits`，可逐类型配比（`CreateUnits` ≤7） |
| 力量优势 | TeamTemplate `:63` | `MinPowerAdvantage` 门槛 |
| 战斗中招募 | TeamTemplate `:70` | `AllowRecruitUnitsInCombat` |
| 距离排序 | TeamTemplate `:74-75` | `SortByDistance` + `TARGET_POINT`/`HOME_BASE` |
| SimpleAttack/FlankAttack | AIStateDefinition `:435-436` | 战术枚举成员；`:453-460` 结束行为 |
| QuickDoesPathExist | PathfindingCheckType `:12` | 招募前快速可达性检查 |
| WaitForFormation | Locomotor `:209` | 出发前等待队形 |
| CloseEnoughDist | Locomotor `:178` | 到达容差 1.0 |
| Turn/Acceleration/Braking | Locomotor `:125,134,137` | 1.0s/1.0s/1.0s |
| Radius/PathfindDiameter/FormationWidth/FormationDepth/PathPriority/DodgeSafetyDistance | GameObject `:369,496,467,468,502,608` | 6 个独立量，分属建造/寻路/队形/优先级/闪避语义 |

---

## 4. S2 静态二进制分析（`static-binary`；pefile/capstone + Ghidra 11.0.3 两级证据）

方法：`D:\RA3_RE_Research\scripts\s2_static_analysis.py`、`s2b_vftable_units.py`、`s2c_context_dump.py`。
产物：`agent/runs/2026-10-11-ra3-research/s2_static.json`、`s2b_vftable.json`、`s2c_context.json`（含 `.log`）。
限制先行：**字符串/类型名只证明模块或符号存在，不证明被某局调用；无 Ghidra ⇒ 未还原控制流、调用图、线程模型**。

### 4.1 编译单元（`.cpp`）族：`BF_RA3_QABUILD_EALA-BUILD20` 内部路径

183 个唯一 `.cpp` 字符串保留在 `.rdata`，全部带完整构建路径 `C:\BF_RA3_QABUILD_EALA-BUILD20\RA3\code\SageEngine\source\...`。AI/移动相关的直接命中（VA 为绝对地址）：

| 编译单元（节选） | VA | 反映的模块结构 |
|---|---|---|
| `...\gamelogic\skirmishai\AIMicroManager\AIMicroManager.cpp` | `0xC603A9` | 微操管理器独立模块 |
| `...\gamelogic\skirmishai\AIStrategyManager\AITacticManager\AITacticManager.cpp` | `0xC60EEC` | 战术管理器 |
| `...\AIStrategyManager\AITacticManager\AITactic.cpp` | `0xC5EAB2` | 战术基类 |
| `...\AIStrategyManager\AITargetManager\AITargetManager.cpp` | `0xC601A2` | 目标管理器 |
| `...\AITargetManager\AITargetHeuristics\AITargetHeuristicFriendlyStructure.cpp` / `FriendlyUnit` / `Point` | `0xC5FF94`/`0xC6004C`/`0xC60104` | 目标启发式是逐类实现的插件族 |
| `...\gamelogic\skirmishai\AIUnitBuilder\AIUnitBuilder.cpp` | `0xC609B0` | 单位建造器（与战略/战术分开） |
| `...\gamelogic\pathfinder\pathfinder_path.cpp` | `0xC18DFA` | 寻路实现编译单元 |
| `...\gamelogic\ai\States\FollowWaypointPath.cpp` | `0xC514F9` | 移动执行状态机 |
| `...\gamelogic\object\Update\AIUpdate.cpp` / `AIUpdate\WanderAIUpdate.cpp` / `AnimalAIUpdate.cpp` | `0xC46A60`/`0xC4E740`/`0xC4E6C0` | 单位级 AI 更新（与小队 AI 分开） |
| `...\Behavior\StrafeAreaTargetChooser.cpp`、`NotifyTargetsOfImminentProbableCrushingMux.cpp`、`MovementSpecialPower.cpp` | `0xC302D8`/`0xC489B8`/`0xC4DFA4` | 侧移/碾压通知/移动类特殊能力 |
| `...\GameClient\SkirmishAISupport\SkirmishAIFeedbackManager.cpp` / `SkirmishAIInTroubleMonitor.cpp` | `0xC64050`/`0xC64A48` | AI 反馈与"陷入困境"监控 |

⇒ 与 §3 的 Schema 分层完全同构：`skirmishai` 下有 `AIStrategyManager`（Tactic/Target）、`AIMicroManager`、`AIUnitBuilder` 三个兄弟模块；移动执行由 `ai\States\FollowWaypointPath.cpp` 类状态机承担；寻路由 `pathfinder` 独立实现。

### 4.2 vftable 解析（控制流级证据）

`.rdata` 中定位到 2 组、4 张表（写入点 = 构造函数 `mov dword ptr [esi], <vftable>`）：

| 表 | VA | 槽数 | 写入点（构造/析构） |
|---|---|---|---|
| AITacticManager 主表 | `0xC5F3D0` | 11 | `0x88A193`（构造 `0x88A180` 内）、`0x8A70FC` |
| AITacticManager 副表 | `0xC5F3EC` | 4 | `0x88A18C`、`0x8A70F5` |
| AITargetManager 主表 | `0xC5F6D8` | 11 | `0x890045`、`0x89D388` |
| AITargetManager 副表 | `0xC5F6F4` | 4 | `0x89003E`、`0x89D381` |

两个类的表结构同构：
- 槽 0 都是 **adjustor thunk**（`sub ecx, 4`，`0x88A1F0`/`0x8900C0`）⇒ 多重继承（副对象借用主表尾部）；
- 副表 4 项与主表末 4 项**逐项相同**（0x88F940/0x5FF8A0/0x88A1E0/0x8D3FE0 与 0x89D4B0/0x5FF8A0/0x8900B0/0x8C9FB0）⇒ 主/副 vfptr 是同一函数集的两个视角；
- 两表各含 1 个 **返回类名字符串的虚函数**：`0x88A1E0: mov eax, 0xC5F3FC; ret`（返回 `"AITacticManager"`）、`0x8900B0: mov eax, 0xC5F704; ret`（返回 `"AITargetManager"`）⇒ AI 类型系统带名称反射；
- `0x5FF8A0: ret` 为共享空实现 stub。

汇编窗口与完整槽位见 `s2b_vftable.json`（每槽含 `slot_va / func_va / 前 6 条反汇编`）。
**未确定处**：槽函数语义未逐一还原（无 Ghidra）；"返回类名"函数的虚表位置不代表接口全貌。

### 4.3 字符串交叉引用（12 条，`s2_static.json`）

| 锚点字符串 | 字符串 VA | 引用点 VA | 引用处指令 | 候选函数起点（启发式） |
|---|---|---|---|---|
| `AISimpleAttackTactic` | `0xC5E9D4` | `0x8805E1` | `mov eax, 0xC5E9D4` | `0x8805E0`（`mov eax, imm32; ret` = 类名 getter） |
| `AIFlankAttackTactic` | `0xC5E9AC` | `0x8805B1` | `mov eax, ...` | `0x8805B0`（同上） |
| `AITacticManager` | `0xC5F3FC` | `0x88A1E1` | `mov eax, ...`（在 `0x88A1E0`） | `0x88A180`（vftable 写入 + 向量清理，**构造/析构**） |
| `AITargetManager` | `0xC5F704` | `0x8900B1` | `mov eax, ...`（在 `0x8900B0`） | `0x890030`（vftable 写入，**构造**） |
| `AITeam`（前缀命中） | `0xC5FD5C` | `0x8A8B81` | `mov eax, ...` | `0x8A8B80`（Ghidra 阶段确认该字符串实为 **`"AITeamMaker"`**，见 §4.7.6；`"AIStrategyManager"` 在 `0xC5FD94`） |
| `AIPersonality` | `0xC169A0` | `0x653718`/`0x666352` | `push 0xC169A0` | `0x6536A0`/`0x6661F0`（全局单例访问 + 虚调用） |
| `AIPersonality` | `0xC185B4` | `0x682916` | `push ...` | `0x681E00` |
| `AIPersonality` | `0xC5F590` | `0x88BAAB` | `push 0xC5F590; push eax; call 0x482B50` | `0x88BAA0` |
| `Formation` | `0xBEE2F4` | `0x545814` | `push 4; push edx; push 0xBEE2F4; call eax` | `0x545800`（经虚调用传参，疑似日志/断言） |
| `MicroManager` | `0xC09760` | `0x5B7BF9` | `push ...` | `0x5B7AF0` |
| `TeamTemplate` | `0xC5BD18` | `0x84E721` | `mov eax, ...` | `0x84E3E0` |

函数起点均为**填充扫描启发式**（`cc/90` 对齐后首个字节），不是 Ghidra 验证的函数边界。

### 4.4 关键字符串族（存在性证据）

| 族 | 样本（VA） | 说明 |
|---|---|---|
| 战术枚举（二进制实存） | `0xBDE68F`：`…DefenseAvoidanceAttackEngineerExactExpansionFlankAttackGarrisonBuildingHunt` | 与 Schema `Tactics` 枚举（§3.3 `:433-451`）一致的连续字符串 ⇒ Schema 与二进制互证 |
| 战术类名 | `SimpleAttackTactic`(`0xC5E9D6`)、`FlankAttackTactic`(`0xC5E9AE`)、`FlankAttackTactic.cpp`(`0xC604E7`)、`ReactiveDefenseTactic`(`0xC5E922`) | 每个战术是可实例化类型 |
| 战术运行状态字段 | `ReactiveDefenseTactic_IsRunning`(`0xC61022`)、`ReactiveDefenseTactic_FrameNextRun`(`0xC61046`) | 战术自带 运行中/下帧运行 状态（调度式执行，非每帧） |
| 微操状态/任务 | `MicroManagerData`(`0xBD00FE`)、`MicroManagerStore`(`0xC106E9`)、`MicroManagerDebugDisplay should never be called directly…`(`0xC09760`) | 微操数据/存储/调试占位符 |
| 团队属性 | `teamAvoidThreats`、`teamAggressiveness`、`teamAttackCommonTarget`、`teamMaxInstances`（`0xC11064` 一带） | 团队级参数字符串（与 MicroManager 的规避/集火对应） |
| 威胁系统 | `ThreatMeter`(`0xBD1143`)、`ThreatFinder: %s`(`0xC072F0`)、`ThreatFinderName`(`0xC111DE`) | ThreatFinder 是真实子系统（对应 Schema `ThreatFinderRange`/`DefaultThreatFindRadius`） |
| 移动状态机 | `FollowWaypointPathStateMachine`、`UnitAIFollowWaypointPathState/AsTeamState/ExactState`、`JetAIAttackMoveFollowWaypointPathState`、`UnitAIAttackMoveFollowWaypointPathState`、`AIFollowWaypointPathStateAndEvacuate`（`0xC4FC8C`–`0xC59799` 一带） | 移动执行 = 状态机族，区分 单机/成队/精确/Jet/攻击移动 变体 |
| 小队状态机 | `SquadState`(`0xC51A1C`)、`SquadStateMachine`(`0xC549F2`) | 另有 Squad 级状态机 |
| 队形助手（数据模板族） | `FormationAssistant`/`FormationAssistantTemplate`/`RowDefinition`/`CellContainer`/`UnitDefinition`/`FormationSelectionTemplate`（`0xBD1C7C`–`0xBD1D08`） | 队形由**行/单元容器/单位定义**的数据模板驱动（对应 GameObject `FormationWidth/Depth`） |
| 寻路系统 | `PathfindSystem`(`0xBEEA2E` 存档 chunk 名、`0xC1085F` 子系统名)、`PathfindSystemNORMAL - DEFAULT/extend COLLISION FREE QUICK/...`(`0xC18E58` 一带)、`PathfindSettings`(`0xBD03E8`)、`PathfindLayerEnum`(`0xBEE334` 属性类型)、`PathfindPortalBehaviourModuleData`(`0xBCC748`) | 寻路是命名子系统，有设置块/图层枚举/门户行为模块 |
| 序列化消息中的符号 | `LocomotorSet::xfer - template %s not found`(`0xC2E22C`/`0xC474B0`) | 运行时代码路径保留函数名（xfer=序列化） |
| 表面枚举 | `crushable_wall crushable_obstacle wall_railing deep_water bridge_impassable impassable obstacle rubble cliff water`(`0xC18742`) | 与 Locomotor `Surfaces` 枚举（§3.7 `:30-44`）互证 |

### 4.5 负面结论（本轮修正，重要）

对全部 9.3 MB 映像做了无过滤字节搜索：

| 关键词 | 命中 | 结论 |
|---|---|---|
| `RVO` / `Reciprocal` / `VelocityObstacle` / `ORCA` / `steering` / `steering` / `navmesh` / `flocking` / `separation` / `Funnel` / `StringPull` / `Repath` / `Recalc` / `AStar` / `focusfire` | **全部 0** | **不能声称 RA3 使用 RVO/ORCA/转向/拉直等具体算法或命名**；本提示词初版报告的"RVO 字符串 4 处命中"在本轮**无法复现**，按证据纪律撤回该说法 |
| `avoidance`（小写全词） | 0 | 同上 |
| `Avoid`（大写前缀） | 2（`AvoidanceAttack`、`AvoidThreats`） | 仅是战术名/团队参数名，不是避障算法证据 |
| `A*` 的 `.text` 命中 9 处 | 均为指令字节巧合（如 `41 2A` = inc ecx 片段） | **不能**作为 "A* 算法" 的字符串证据 |
| RTTI 结构（`.?AV`/`.?AU`） | 0 | 本体已剥离 RTTI 结构；类名只以普通字符串（§4.4）存在 |
| `PathfindDiameter` / `MaxTeamIdleTime` / `MaxUnitIdleTime` / `WaitForFormation` / `CloseEnoughDist` / `PathfindingCheckType` 字段名 | 0 | Schema 字段名未以字符串保留在二进制（资产已编译） |

⇒ 本报告对"RA3 内部避障实现"的唯一定位是：**模块级**证据（`pathfinder_path.cpp`、`PathfindSystem`、`FollowWaypointPathStateMachine`）与**接口级**证据（Schema 的 `DodgeSafetyDistance`、`PathfindDiameter`、`PathPriority`、`DodgeWithUnits`）。具体算法 = `not-yet-verified`。

### 4.6 证据等级说明（防止三源互相冒充）

- §3（Schema）= 设计数据模型，**不证明**运行时行为。
- §4.1–4.5（pefile/capstone）= 模块/类型/符号存在 + 表指针/xref，**不证明**控制流。
- §4.7（Ghidra）= 函数边界/调用者/伪代码/CFG 级控制流，**仍不证明**某局调用频率与实际参数取值；伪代码类型为反编译恢复形式。
- §5（动态）= 未完成（`not-yet-verified`），**不用** AIRTS 行为代替。
- 三源互证关系已显式标注（例如：Tactics 枚举 Schema↔二进制双证；idle 阈值仅 Schema 单证）。
- OpenSAGE 等公开重实现：本报告**未使用**它作为任何 RA3 结论的证据（§4.5 的负面结论与它无关）；它们只能解释通用 A*/网格/拉直算法模式，不得写成 RA3 原码。

### 4.7 Ghidra 11.0.3 函数级控制流证据（本轮新增；含真实函数边界/调用者/伪代码/参数/CFG）

#### 4.7.1 工具安装与项目（`measured`）

| 项 | 值 |
|---|---|
| Ghidra | 11.0.3 PUBLIC（`ghidra_11.0.3_PUBLIC_20240410.zip`，412,949,687 B） |
| 官方 SHA-256 | `2462a2d0ab11e30f9e907cd3b4aa6b48dd2642f325617e3d922c28e752be6761`（release notes 声明值与本地 `Get-FileHash` **一致**） |
| JRE | OpenJDK 17.0.18（Ghidra 11.0.x 要求 JDK 17） |
| 导入 | `analyzeHeadless ... -import "D:\Red Alert 3\Data\ra3_1.12.game"`，AutoImporter 自动选 `Portable Executable (PE)` + `x86:LE:32:default:windows` |
| 自动分析 | 414 秒，`Analysis succeeded` + `Save succeeded`；项目 `D:\RA3_RE_Research\ghidra_projects\RA3_RE`（含 176 MB `db.1.gbf`） |
| 提取脚本 | `D:\RA3_RE_Research\ghidra_scripts\DumpAiControlFlow.py`（postScript，Jython 2.7），`run_dump.cmd` 以 `-process -noanalysis` 运行 |
| 产物 | `agent/runs/2026-10-11-ra3-research/ghidra/ghidra_control_flow.json`（881 KB，**171 条函数记录**）+ `decomp/*.c`（171 个，与 JSON 一一对应）；首轮分析遗留的 3 个孤儿文件已隔离到 `decomp/_stale_first_pass/`（见 §4.7.9） |

环境坑（已排除，供复跑者）：`-cspec win32` 不被支持（须让 PE loader 自选）；脚本抛异常时 `analyzeHeadless` 仍返回 rc=0，**必须检查 stderr 是否有 Traceback**；`GhidraScript.getReferencesTo` 返回 Java 数组而非迭代器；bat 出错会 `pause` 挂住隐藏窗口（清理本轮 cmd 进程后重跑）。**函数创建说明**：vftable 槽函数只被数据引用、不被 CALL，自动分析不会建函数；提取脚本对目标地址执行 disassemble + `CreateFunctionCmd`（写入研究项目，不触碰游戏文件），JSON 中以 `function_created_by_script` 标记。

#### 4.7.2 提取方法（严格表述边界）

本轮 Ghidra 输出三类信息，级别不同、不得混用：
1. **函数边界/调用者/被调用者/基本块（CFG）**：Ghidra 数据库级事实（`Function.getBody()`、`getReferencesTo`、`BasicBlockModel`）。
2. **伪代码与参数推断**：Ghidra 反编译器的输出（未运行 Decompiler Parameter ID 分析器，签名为反编译即时推断；`__thiscall/__fastcall` 与 `undefined4` 等是恢复形式，不是原始源码类型）。
3. **字符串/表指针**：仅证明绑定或数据内容，**不单独称为算法**。

#### 4.7.3 目标一：`0x88A180`（AITacticManager 析构，真实函数边界）

- 边界：entry `0x88A180`，body `0x88A180–0x88A1DC`，**93 字节 / 8 个基本块**（Ghidra 原生函数，非脚本创建）。
- 调用者（2）：`0x88F943`（在 scalar deleting destructor `0x88F940` 内）、`0x8B07AE`（在 `FUN_008B0790` 内，见 4.7.6）。
- 参数推断：`void __fastcall FUN_0088a180(undefined4 *param_1)`（ECX = this 指针；无返回）。
- 伪代码（Ghidra 原文，行号引用 `decomp/FUN_0088a180_0088a180.c:13-47`）：

```c
piVar1 = (int *)param_1[3];               // this+0xC  = 指针数组 begin
*param_1 = &PTR_FUN_00c5f3ec;             // this+0   := vftable 0xC5F3EC
param_1[1] = &PTR_FUN_00c5f3d0;           // this+4   := vftable 0xC5F3D0
if (piVar1 != (int *)param_1[4]) {        // this+0x10 = 数组 end
  do {
    if ((undefined4 *)*piVar1 != 0) {
      (***(code ***)(undefined4 *)*piVar1)(1);   // 对每个元素虚调用 [0](this,1)
    }
    piVar1 = piVar1 + 1;
  } while (piVar1 != (int *)param_1[4]);
}
param_1[7] = &PTR_LAB_00be8a78;           // 重置成员 vfptr 为基类表
if (param_1[3] != 0) { FUN_00416830(param_1[3]); }  // operator delete(数组)
param_1[1] = &PTR_LAB_00c5ee28;
*param_1 = &PTR_LAB_00be8a78;
```

- 控制流结论（`static-binary` 控制流级）：该类**持有一个指针数组（begin=+0xC, end=+0x10）**，析构逐个虚删除元素后释放数组。数组元素预期实现 `vtable[0](this,1)`（= adjustor thunk → scalar deleting destructor 模式，与之配套的 `0x88A1F0: sub ecx,4; jmp 0x88F940` 即为元素删除 thunk）。
- **不声称**：数组元素的类型、个数、产生规则（未还原）。

#### 4.7.4 目标二：`0x890030`（AITargetManager 析构）

- 边界：entry `0x890030`，body `0x890030–0x8900AC`，**125 字节 / 7 块**（Ghidra 原生）。
- 调用者（2）：`0x89D4B3`（scalar dtor `0x89D4B0` 内）、`0x8B07B6`（`FUN_008B0790` 内）。
- 参数推断：`void __fastcall FUN_00890030(undefined4 *param_1)`。
- 伪代码要点（`decomp/FUN_00890030_00890030.c`）：

```c
*param_1 = &PTR_FUN_00c5f6f4;             // this+0 := 0xC5F6F4（4 槽表）
param_1[1] = &PTR_FUN_00c5f6d8;           // this+4 := 0xC5F6D8（11 槽表）
param_1[2] = &PTR_Manager_SetNextRevision_00c5f6a0;  // this+8 := 0xC5F6A0
if (param_1[6] != 0) { (***(code ***)param_1[6])(1); param_1[6] = 0; }  // 删除 this+0x18 成员
FUN_005c7050(param_1[0x10]);               // this+0x40 成员的清理
param_1[9] = &PTR_LAB_00be8a78;
puVar1 = param_1[7];
if (puVar1 != 0) {
  if (puVar1[-1] == 0) { FUN_00416830(puVar1 + -1); }  // 头带标记的数组释放
  else { (**(code **)*puVar1)(3); }
}
FUN_0086b8a0();                            // 基类清理
param_1[1] = &PTR_LAB_00c5ee28; *param_1 = &PTR_LAB_00be8a78;
```

- 控制流结论：类**有 3 个 vfptr 位置（+0/+4/+8）**、至少一个被虚删除的成员（+0x18）、一个带清理函数的成员（+0x40）、一个"带头标记的数组"（+0x1C）。`0xC5F6A0` 表首项 = `0x5B8550`（`ret 4` 桩；该地址同时是导出 `?Manager_SetNextRevision@AptRenderItem@@QAEXPAV1@@Z` 的 rva 目标——导出表中多个不同 Apt 方法名共享桩地址，说明该导出块存在**多名字共享桩**现象）。
- **未确定处**：`0xC5F6A0` 表的语义（为何 TargetManager 的 +8 指向一张首项为 Apt 相关桩的表）——需要更多交叉引用才能定性；不得为它编造"AI 算法"解释。

#### 4.7.5 vftable 全槽解析（6 张表，槽 → 函数 → 语义）

**AITacticManager**（`0xC5F3D0` 11 槽；`0xC5F3EC` = 其尾部 4 槽，供 +0 的 vfptr 使用）：

| 槽 | 目标 | 反编译语义（伪代码见 `decomp/`） |
|---|---|---|
| 0xC5F3D0 | `0x88A1F0` | adjustor thunk：`sub ecx,4; jmp 0x88F940`（8 B） |
| 0xC5F3D4 | `0x893020` | `void f(this, byte v){ *(byte*)(this+0x1C) = v; }` — **布尔字段 setter** |
| 0xC5F3D8 | `0x893050` | `*(int*)(this+0x24) = *(int*)(TheGlobal+0x50) + *(int*)(this+0x20);` — **deadline = now + interval** |
| 0xC5F3DC | `0xB663C0` | `mov al,[ecx+0x1C]` — 布尔字段 getter（与 setter 同字段） |
| 0xC5F3E0 | `0x88A200` | `return *(uint*)(this+0x24) <= *(uint*)(TheGlobal+0x50);` — **isDue（到期判断）** |
| 0xC5F3E4 | `0x5FF8A0` | 共享空桩（`ret`；Ghidra Function-ID 误标 `GetHashSize`，非真实语义） |
| 0xC5F3E8 | `0x8D6DD0` | **逐战术更新**：调 `FUN_008A71E0()`；遍历 `+8..+0xC` 指针数组，对每个元素顺序调用 `FUN_008D3D50`、`FUN_008C95A0`；再检查成员 `[+4]+0x90` 非空则调 `FUN_008D0390` |
| 0xC5F3EC | `0x88F940` | **scalar deleting destructor**：调 `0x88A180`（析构），`if (flag&1) FUN_00416830(this)`（operator delete） |
| 0xC5F3F0 | `0x5FF8A0` | 共享空桩 |
| 0xC5F3F4 | `0x88A1E0` | **类型名 getter**：`return "AITacticManager";`（仅字符串返回，无其他逻辑） |
| 0xC5F3F8 | `0x8D3FE0` | 批量收集/应用：循环遍历 `+0xC..` 数组，按 `*(this+4)+…` 标志分流（一个分支逐元素调用 `FUN_0088F880`，另一分支 `FUN_008D3EB0` 结果非空则 push 到 `+0x10..+0x14` 的容器）；尾部经 `[param_1]` vtable 槽 `+0x18/+0x20` 回写 |

**AITargetManager**（`0xC5F6D8` 11 槽；`0xC5F6F4` = 尾部 4 槽）：

| 槽 | 目标 | 语义 |
|---|---|---|
| 0xC5F6D8 | `0x8900C0` | adjustor thunk → `0x89D4B0`（scalar dtor） |
| 0xC5F6DC | `0x555ED0` | `*(byte*)(this+0x24) = v` — 布尔 setter |
| 0xC5F6E0 | `0x8900D0` | `*(int*)(this+0x2C) = now + *(int*)(this+0x28)` — deadline |
| 0xC5F6E4 | `0xA81660` | `return *(byte*)(this+0x24)` — 布尔 getter（与 0x555ED0 同字段） |
| 0xC5F6E8 | `0x8900E0` | `return *(uint*)(this+0x2C) <= now` — isDue |
| 0xC5F6EC | `0x5FF8A0` | 空桩 |
| 0xC5F6F0 | `0x8C9F80` | 顺序调用 `FUN_008BD910(); FUN_0089D590(); FUN_008BE3F0(param)` — reset/清理链 |
| 0xC5F6F4 | `0x89D4B0` | **scalar deleting destructor**（→ 0x890030） |
| 0xC5F6F8 | `0x5FF8A0` | 空桩 |
| 0xC5F6FC | `0x8900B0` | **类型名 getter**：`return "AITargetManager";` |
| 0xC5F700 | `0x8C9FB0` | **xfer（序列化）**：构造 `0x301` 标志，经参数对象的 vtable `+0x18/+0x20/+0x58/+0x6C` 逐字段传输；按 `(param_1+4)[1]` 位标志走两条路径——其一以 **0x2CC 步长**遍历 `[+0x1C]` 数组并逐元素调 vtable `+0x20`，随后重置 `+0x38/+0x3C/+0x40/+0x44/+0x48` 一组字段 |

**AIUnitBuilder**（`0xC5F474` 11 槽；`0xC5F484` = 其内部 7 槽视图；两表均本轮由槽内容反推并确认）：

| 槽 | 目标 | 语义 |
|---|---|---|
| 0xC5F474 | `0x88B040` | adjustor/转发（体：调用 `0x890790`） |
| 0xC5F478 | `0x5FF8A0` | 空桩 |
| 0xC5F47C | `0x88B030` | **类型名 getter**：`return "AIUnitBuilder";` |
| 0xC5F480 | `0x880A60` | xfer：经 vtable `+0x18/+0x20/+0x6C/+0x64` 传输 this+8/+0x18/+0x20 |
| 0xC5F484 | `0x890790` | **析构本体**：重置 vfptr 为 0xC5F484/0xC5F474；释放 `+0x38`、`+0x28` 两个成员；`if (flag&1) delete this` |
| 0xC5F488 | `0x885AE0` | `*(byte*)(this+0x10) = v` |
| 0xC5F48C | `0x8A8BF0` | `*(int*)(this+0x18) = now + *(int*)(this+0x14)` — deadline |
| 0xC5F490 | `0x544F10` | `return *(byte*)(this+0x10)` |
| 0xC5F494 | `0x88B050` | `return *(uint*)(this+0x18) <= now` — isDue |
| 0xC5F498 | `0x5FF8A0` | 空桩 |
| 0xC5F49C | `0x8D7380` | （未逐行展开） |

#### 4.7.6 目标三：`0x8B0790` —— AIStrategyManager 析构（父对象证据）

- 边界：`FUN_008B0790`，435 B 伪代码；`__thiscall(undefined4 *this, byte flag)`。
- 伪代码要点（`decomp/FUN_008b0790_008b0790.c`）：

```c
*param_1_00 = &PTR_FUN_00c5fd78;      // +0 := 0xC5FD78
param_1_00[1] = &PTR_LAB_00c5fd68;    // +4 := 0xC5FD68
FUN_008A8AB0();                        // 第 1 个成员清理
FUN_0088A180();                        // ← AITacticManager 析构（4.7.3）
FUN_00890030();                        // ← AITargetManager 析构（4.7.4）
param_1_00[3] = &PTR_LAB_00be8a78;
...
if ((param_1 & 1) != 0) { FUN_00416830(param_1_00); }   // operator delete
```

- 身份确认（`measured`）：其 vftable 之后紧跟字符串 **`"AIStrategyManager"`（`0xC5FD94`）**；`0xC5FD5C` 处的字符串实为 **`"AITeamMaker"`**（此前 capstone 扫描的 `"AITeam"` 锚点命中即该词前缀，§4.3 表述已按此修正）。
- 其表 β `0xC5FD78` 槽 6 = `0x8D1020`，而 `0x8D1020` 是 **引用 `AITacticManager.cpp` 路径字符串的函数 `0x8D0300` 的唯一调用者** ⇒ 管理器族的创建/初始化路径。
- **控制流结论**：存在一个持有并**按序销毁** `AITacticManager` + `AITargetManager` 的父对象（与 §4.1 的 `skirmishai\AIStrategyManager\{AITacticManager,AITargetManager}` 目录结构一致）。

#### 4.7.7 跨类模式（本轮最强的结构性结论）

对四个类逐一反编译后，虚函数表呈现**同一套"管理器接口"**：

| 能力 | AITacticManager | AITargetManager | AIUnitBuilder | AIStrategyManager |
|---|---|---|---|---|
| 类型名 getter（返回类名字符串） | `0x88A1E0` | `0x8900B0` | `0x88B030` | （表后字符串，getter 未定位） |
| 布尔字段 set/get | `0x893020`/`0xB663C0`（+0x1C） | `0x555ED0`/`0xA81660`（+0x24） | `0x885AE0`/`0x544F10`（+0x10） | 同 UB：`0x885AE0`/`0x544F10` |
| deadline / isDue | `0x893050`/`0x88A200` | `0x8900D0`/`0x8900E0` | `0x8A8BF0`/`0x88B050` | 同 UB：`0x8A8BF0`/`0x88B050` |
| xfer（序列化） | （未定位） | `0x8C9FB0` | `0x880A60` | （未定位） |
| 析构 / scalar dtor | `0x88A180`/`0x88F940` | `0x890030`/`0x89D4B0` | `0x890790`/`0x88B040` | `0x8B0790` |
| 每拍更新 | `0x8D6DD0`（遍历 tactic 数组） | `0x8C9F80`（三段清理链） | （未定位） | （未定位） |

两个可直接陈述的机制（`static-binary`，控制流级）：
1. **统一时间调度接口**：`deadline = *(TheGlobal+0x50) + interval` 与 `isDue = deadline <= *(TheGlobal+0x50)` 成对出现，`TheGlobal+0x50` 被四处以上共同读取 ⇒ 全局模拟时钟驱动的"下次运行时刻"调度。**AIUnitBuilder 与 AIStrategyManager 复用同两个函数指针**（`0x8A8BF0`/`0x88B050`）⇒ 它们共享同一基类实现；Tactic/TargetManager 的对应函数字段偏移不同（+0x20/+0x24 与 +0x28/+0x2C），是各自实现或不同基类布局。
2. **析构树**：`AIStrategyManager → {FUN_008A8AB0 成员, AITacticManager, AITargetManager}`。

#### 4.7.8 目标四：`AIMicroManager` 相关字符串 → 真实函数（用户点名）

`AIMicroManager.cpp` 路径串（`0xC60340`）的 6 处 `PUSH` 引用落在 4 个函数内，4 个函数全部完成边界/调用者/伪代码提取（**不含玩法语义**，见本节末）：

| 函数 | 边界 | 调用者 | 伪代码要点 |
|---|---|---|---|
| `FUN_008C5850`（1218 B，49 块） | `0x8C5850` | 10 个（`0x8C5D20/0x8C5DD0/0x8C5F30/0x8C6370/0x8C9730/0x8CDF20` 等） | 内含 `FUN_00600B10(值A, 值B, "…AIMicroManager.cpp", 0x80F)` —— **Sage 断言模式（文件+行号 2063）**；前置检查两个对象标志位（`param_2[0x26]>>1`、`[obj+0xD0]>>22`）；**遍历侵入式链表**（`head=this+0xA0`，next=`FUN_00B74A10`，哨兵 `this+0x9C`）按 ID（`+0xDC`）比较；用全局时钟计算时间并写入 `FUN_008B39F0(...)` 返回的结构（`{id, time}`）；随后有**结果码 0/1/3/5 的分支返回**（配合 `FUN_0083AC60`/`FUN_0083AEE0` 的判定，`FUN_00880E90(0x210/0x211/0x214/0x20D)` 记录不同分支） |
| `FUN_008C6440`（819 B，43 块） | `0x8C6440` | 2 个（`0x8CE590`、`0x8CDA30`） | `*param_2 = 3;`（写状态码）；`FUN_008A5CF0(...)` 返回结果码，按 `0/1/2/3` 分支调用 `FUN_008974F0`/`FUN_00897420`/`FUN_00889180`；出现 `iVar5 < 0x19`（<25）的类型索引与 `iVar5 == 5` 特判 → **按单位类型索引的分派** |
| `FUN_008B8040`（1402 B，39 块） | `0x8B8040` | 9 个（`0x8D31B0/0x8D31E0/0x8D3250/0x8D32C0/0x8D32E0/0x8D3300` 等小包装函数） | 守卫 `[this+0x18]+0xAA` 字节为 0 直接返回；`FUN_004E0270(0x32)` 查询；遍历 `this+0x1BC` 的容器；大量 float/`memmove` ⇒ 统计/聚合型函数 |
| `FUN_008D5D90`（1895 B，91 块） | `0x8D5D90` | 1 个（`0x8D8990`） | 大函数：`memmove` + 多个子系统调用（`FUN_008CC5F0/0x8A4DB0/0x86C6C0/0x86F030/0x8A1AF0/0x8967F0`），含容器操作 |

**严格表述**：以上只说明"这些函数编译自 `AIMicroManager.cpp`（含第 2063 行的断言）且其控制流已还原到上表程度"；**不等于**已经还原了"idle 重下令/目标评分/撤退"等玩法算法——这些仍需把函数与其调用上下文、字段语义进一步对齐后才能陈述。此外，**`AIMicroManager` 的完整类方法表（vftable/方法集）仍未找到**（该类在二进制中没有可搜索到的类名字符串，无法像三个 Manager 那样按"表后字符串 + GetName getter"模式定位），当前获得的只有 4 个 `.cpp` 关联函数 + 资产类型名（`AIMicroManagerData`）+ 单例名（`TheAIMicroManagerStore`）。

**同族发现（占位符，非算法）**：`*DebugDisplay should never be called directly...` 字符串共 **10 个**（`StatDebugDisplay`、`SkirmishAIDebugDisplay`、`SkirmishAIUnitBuilderDebugDisplay`、`ConquerMetricsDebugDisplay`、`AIBaseDebugDisplay`、`MicroManagerDebugDisplay`、`ObjectRegistryDebugDisplay`、`AnimDebugDisplay`、`NetworkDebugDisplay`、`UnitTargetingDebugDisplay`，VA `0xC094DF–0xC09918`）。其中三个的引用函数 `FUN_005B7AF0`/`FUN_005B7B50`/`FUN_005B7BE0` 反编译后全部是**同构 fprintf 占位符**（`if (file) { fprintf(分隔行); fprintf("…placeholder…"); fflush; }`），签名 `(undefined4, undefined4, FILE*)`。**它们是 release 版禁用直接调用的统计显示桩，不是 AI 实现。**

#### 4.7.9 提取规模与函数构成（外部核验后的修正，防止误读）

2026-10-11 外部核验对本节产物做了逐项复检，结论与修正如下（`measured`）：

| 核验项 | 结果 |
|---|---|
| JSON 函数记录数 | **171**（此前报告行文中的"174 个函数"系笔误，已修正） |
| `decomp/*.c` 文件数 | 174 → **171**（与 JSON 一一对应）。首轮分析遗留的 3 个孤儿文件（`FUN_00abdd80`/`FUN_00abdda0`/`FUN_00abf400`，mtime 均为首轮 14:48，第二轮 14:50 未再产出）已移入 `decomp/_stale_first_pass/` 隔离，不再计入 |
| 小函数占比 | 171 个中 **50 个 ≤32 字节**（来源：vftable_slot 22 / caller_of 26 / explicit_va 2），**39 个伪代码 ≤10 行** |

**函数构成（防误读声明）**：这 171 条记录的多数是**析构函数、adjustor thunk、布尔 set/get、deadline/isDue、空桩（`0x5FF8A0`）、转发包装、fprintf 占位符**——它们用于证明"这些类存在、接口形状如何、谁销毁谁"，**不能等同于"已反编译出完整 AI"**。当前明确**尚未**完成（保持 `not-yet-verified`）：

- `AIMicroManager` 的完整类方法表（§4.7.8）；
- RA3 的具体寻路算法、避障算法、线程模型、编组逻辑、目标评分、撤退逻辑（无一处已被本报告还原到可陈述程度）；
- 任何动态对局验证（§5）。

**准确状态口径**：**S2 函数级静态分析已完成；AI/寻路核心研究待继续；报告整体 `needs-review`。**

---

## 5. S3 动态研究评估：`not-yet-verified`（不启动游戏的理由）

提示词要求"能安全重复时才做"。本轮评估与处置：

| 检查项 | 结果 |
|---|---|
| 录像回放入口 | 未找到任何 `.rep`/录像文件；无 `Documents\Red Alert 3\Replays`、无 `D:\Red Alert 3\Replays`；`AppData\Roaming\Red Alert 3\` 仅有 `AdCache/Maps/Profiles`（无 Replays） |
| 无人化入口 | `RA3.exe` 为第三方启动器（`settings.xml` 有 `LockCursor/RemoveBorder/LaunchRa3Windowed` 等），无命令行批处理/回放脚本接口证据 |
| 运行代价 | 启动需 GPU 全屏窗口 + 交互式 skirmish 配置；会打断用户当前使用（违反本仓库"非干扰模式"纪律），且无可重复的自动化取样路径 |
| 处置 | **不启动游戏**；S3 全部条目标 `not-yet-verified`，不用 AIRTS 探针替代 RA3 证据 |

因此以下提示词项保持未验证：生产到编组时间线、4/8/16/32 单位集结/队形/掉队、停滞/目标死亡/不可达/撤退阈值再下令、窄口/桥/混合速度路径行为、1/2/3 电脑玩家的帧时间 p50/p95/p99 与命令延迟。

---

## 6. RA3 结论汇总（每条 ≥1 证据，双证者标注）

| # | 结论 | 证据 1 | 证据 2 | 等级 |
|---|---|---|---|---|
| C1 | RA3 电脑玩家是五层流水线：人格 → 战略状态/启发式 → 战术 → 团队模板 → 微操管理器；移动/寻路独立于决策层 | Schema 绑定 `::AIPersonality/::AIState/::AIMicroManager`（§3.1） | 编译单元树 `skirmishai\{AIStrategyManager,AIMicroManager,AIUnitBuilder}`（§4.1） | `official-schema` + `static-binary` |
| C2 | 状态选择由 25+ 种可加权组合的启发式驱动（含金钱/产能/扩张/驻军/路径存在/桥梁） | `AIStateDefinition.xsd:319-360`、LinearCombination `:291-317` | —（单证） | `official-schema` |
| C3 | 战术是带结束行为（RAMPAGE/DISBAND/RETURN_HOME_AND_DISBAND/PICK_NEW_TARGET）与调度状态的可实例化类型 | `AIStateDefinition.xsd:433-460` | 二进制战术类名 + `ReactiveDefenseTactic_IsRunning/_FrameNextRun`（§4.4） | `official-schema` + `static-binary` |
| C4 | 团队是有界实体：人数区间、混编上限、力量优势门槛、优先级/释放策略、距离排序、战斗中招募；**必须绑定微操管理器** | `AITeamTemplate.xsd:56-84` | 二进制 `team*` 参数串（§4.4） | `official-schema` + `static-binary` |
| C5 | 微操是显式两状态机：团队状态（COMBAT/RETREAT/GATHER/SIEGE/ALPHA_STRIKE/…）+ 单位任务（DODGING/GARRISONING/REVERSING/…），决策节拍 1s | `AIMicroManagerStates.xsd:4-36`、`AIMicroManager.xsd:33` | —（单证） | `official-schema` |
| C6 | 空闲重下令有 **团队/单位两级**阈值（30s/50m 与 10s/50m），注释自述"重下令的假设是不在忙" | `AIMicroManager.xsd:35-46` | —（单证） | `official-schema` |
| C7 | 目标保持（TimeToKeepTargetMin/Max）+ 低难度注入随机评分误差 + 集火按射程外惩罚（`AIMicroManager::DetermineTargetsFocusFire`）| `AIMicroManager.xsd:56-63` | `GameObject.xsd:596-599` 注释引用实现函数名 | `official-schema`（双文件） |
| C8 | 招募有前置可达性检查，分"真到达"与"只需进入攻击范围"两档 | `PathfindingCheckType.xsd:6-18` | —（单证） | `official-schema` |
| C9 | 撤退由力量优势 0.25 + 距基地/回撤距离 + 速度缓冲复合判定；受伤拉回 20% | `AIMicroManager.xsd:70-74,93-94` | —（单证） | `official-schema` |
| C10 | 移动语义拆分：TurnTime 1s / Accel 1s / Brake 1s / CloseEnoughDist 1 / WaitForFormation / 倒车 75% / 路径切线贴合，且定位为独立 `LocomotorTemplate` | `LocomotorTemplate.xsd:112-235` | `LocomotorSet` 模块/序列化消息（§4.4） | `official-schema` + `static-binary` |
| C11 | 队形有两套数据：实体级 `FormationWidth/Depth` + 行/单元模板（FormationAssistant 族）；行进队形按战斗角色（CAVALRY/MELEE/RANGED/ARTILLERY）分派 | `GameObject.xsd:467-468`、`LocomotorTemplate.xsd:68-84,147` | 二进制 `FormationAssistant*` 模板族（§4.4） | `official-schema` + `static-binary` |
| C12 | 寻路是命名子系统（PathfindSystem/PathfindSettings/PathfindLayerEnum），实现编译单元 `pathfinder_path.cpp`；"到达圆"默认是武器射程圆 | `GameObject.xsd:609-613`（注释） | §4.1/§4.4 二进制证据 | `official-schema` + `static-binary` |
| C13 | 移动执行是状态机族（FollowWaypointPath* + SquadStateMachine），区分单机/成队/精确/Jet/攻击移动 | §4.4 类名族 | §4.1 `ai\States\FollowWaypointPath.cpp` | `static-binary`（双来源但同级） |
| C14 | 威胁评估是真实子系统（ThreatMeter/ThreatFinder）| §4.4 | `Personality.xsd:197,213`、`TargetHeuristics.xsd:91` | `static-binary` + `official-schema` |
| C15 | RA3 内部避障算法（RVO/ORCA/转向力/流场等）**未证实**；`DodgeSafetyDistance`/`DodgeWithUnits`/`DodgeThreats` 只是设计接口 | §4.5 负面结论 | — | `not-yet-verified` |
| C16 | RA3 内部线程模型未证实；PE 导入表与字符串均不足以判断 AI/寻路是否多线程 | §2.4、§4.5 | — | `not-yet-verified` |
| C17 | 四个 AI 管理类（AITacticManager/AITargetManager/AIUnitBuilder/AIStrategyManager）具备统一的"管理器接口"：类型名 getter、布尔字段 set/get、`deadline=now+interval`/`isDue` 时间调度、xfer、析构；`AIStrategyManager` 析构按序销毁 Tactic/Target 两个 Manager | §4.7.5/4.7.7 反编译 | §4.7.6 调用图 | `static-binary`（控制流级） |
| C18 | `AITacticManager` 持有一个 tactic 指针数组并逐元素虚删除；其每拍更新函数遍历同一数组依次调用元素方法 | §4.7.3/4.7.5 伪代码 | `FUN_008C95A0` 的调用者=0x8D6DD0 循环体（调用图） | `static-binary`（控制流级） |
| C19 | `AIMicroManager.cpp` 至少 4 个函数已定位到真实边界与调用关系，其中 `FUN_008C5850` 内含该文件第 2063 行(0x80F) 的断言调用；语义未对齐到玩法条目（保留为未验证） | §4.7.8 | — | `static-binary`（模块归属级）+ `not-yet-verified`（玩法语义） |
| C20 | `*DebugDisplay` 系列共 10 个字符串，其中 3 个的引用函数是同构 fprintf 占位符；**任何 DebugDisplay 字符串与统计显示相关，不是 AI 算法实现** | §4.7.8 | §4.4 旧记录（表述修正） | `static-binary`（控制流级） |

---

## 7. RA3 → AIRTS 映射（完整 6 列）

AIRTS 入口行号为 2026-10-11 本轮只读核对结果（抽查确认：`AutoAttackingBattlegroup.gd:9/44`、`Movement.gd:390/1723`、`RuleAiCommandGateway.cs:128-133`、`AiCadence.gd:12-16`）。

| RA3 概念 | 证据等级 | AIRTS 当前入口 | 当前差距 | 可吸收设计 | 风险/门禁 |
|---|---|---|---|---|---|
| 人格→战略状态→战术 分层 | `official-schema`+`static-binary` | `SimpleClairvoyantAI.gd:136/199/262/341`（参数注入、资源仲裁、难度档、战场扫描）+ 5 个 Controller | 没有显式"战略状态"对象与状态→任务的契约；微操散落在 3 个控制器（`AutoAttackingBattlegroup.gd:593`、`EconomyController.gd:381`、`IntelligenceController.gd:109`） | 引入只读 `StrategicState`（阶段/威胁/兵力）与"状态只产生有界任务、不直接逐单位下令"的契约 | 涉及 AI 行为，需 S1 无头真实 Match + 旧功能轨迹；禁止一次重写 |
| 战术类型 + EndBehavior | `official-schema` | `AutoAttackingBattlegroup.gd:3`（`FORMING/ATTACKING/RETREATING`） | 只有 3 态；无 RAMPAGE/DISBAND/RETURN_HOME 之类的结束语义枚举化 | 把编组状态扩展到显式枚举，并把"结束后行为"作为参数而非硬编码 | 行为回归风险：需保持现有撤退/重返滞回（`:7-15`） |
| 团队模板（人数/混编/优先级/释放） | `official-schema` | `OffenseController.gd:792-883`（建组/刷新/销毁）、`AutoAttackingBattlegroup.gd:160`（attach） | 无 `MinPowerAdvantage`、无混编上限、无释放优先级；成员表每拍重建（`AutoAttackingBattlegroup.gd:172-174`） | 给编组加模板参数（规模区间/种类上限/优先级）；力量优势先做成"可配置门槛"而非硬编码 | 改变编组行为，需对 200 秒真局站桩场景回归（引用 `:32-43` 的历史实测） |
| 团队/单位两级 idle 重下令 | `official-schema` | 团队级有：`AutoAttackingBattlegroup.gd:9`（12s 卡住）+ `:44`（10s 目标无进展）；单单位级散在 `Movement.gd:1723`（停滞→重寻路，不重下令） | **没有 per-unit idle 时间/位移 → 重下令**的语义；RA3 的 30s/10s 参考值未落任何地方 | 把"编组中心 30s/50m"与"单单位 10s/50m 无位移 ⇒ 局部重派"做成两级可配置阈值；重派时带 reason 计数 | 移动/命令链关键补丁：单补丁 + 无头真局 + `MovementPushEquivalence` 等价门禁 |
| 目标保持 / 集火惩罚 | `official-schema` | `AutoAttackingBattlegroup.gd:77`（`_current_target_id`）、`:44-46`（推进判据 3m） | 无"目标最短保持时间"；无"射程外扣分"（RA3 `OutOfRangePenalty` 1.3） | 目标切换加保持窗口；目标评分加"射程外惩罚"项 | 评分改动会改变战斗结果，需要战斗回归样本 |
| QuickDoesPathExist 招募前置 | `official-schema` | `AutoAttackingBattlegroup.gd:374`（`_is_target_making_progress`） | 只做事后"够不到就忽略"，没有事前快速可达性检查 | 招募/下令前用导航快速查询过滤不可达目标（保持"快速"语义） | 依赖导航查询成本；须先测查询预算（`Movement.gd:390` 已有全局预算=6/帧） |
| Locomotor 拆量（Turn/Accel/Brake/CloseEnough/倒车） | `official-schema`+`static-binary` | `Movement.gd` 现有导航速度/转向/`arrive_radius`（`:791-792`） | 无逐单位 locomotion profile；到达容差 = `max(radius, 0.35)` 与逻辑半径**耦合** | 引入只读 `UnitMobilityProfile`（纯数据），把"视觉/逻辑半径/寻路直径/队形宽深/攻击距离/视野"分列 | **硬不变量**：`Movement.radius`/`MovementObstacle.radius`/carve/footprint 语义不得合并（闭环工作法附录） |
| WaitForFormation / 队形宽深 | `official-schema` | 无队形槽位；编组 Move 是同一目标点（`AutoAttackingBattlegroup.gd:592-593`） | 无 formation 概念（只有"到达同一目的地"） | 先做"到达后散布/占据槽位"的可选模式，再考虑行进队形 | 队形=移动关键补丁；禁止用缩碰撞盒/关闭避让换效果 |
| 微操状态机（COMBAT/RETREAT/…/DODGING） | `official-schema` | 部分语义散落：撤退（`AutoAttackingBattlegroup.gd:66`）、忽略目标（`:63-65`）、防御召回（`OffenseController.gd:495-510`） | 无显式状态机与单位任务枚举；"为什么不动"没有状态标签 | 给编组/单位加轻量状态标签 + reason，便于诊断"停住"（呼应 `:32-43` 的站桩复盘） | 纯诊断+标签，低风险；但需与现有超时共存 |
| ThreatFinder/威胁评估 | `official-schema`+`static-binary` | `SimpleClairvoyantAI.gd:341`（battlefield_scan）、`Movement.gd:3010+`（流实验） | 威胁是即时计算，无独立威胁子系统/缓存 | 把威胁评估做成"快照上的纯数据计算"，供多个 AI/副官共享 | 性能任务：读性能 skill，先测快照收益再谈 worker |
| 共享只读快照 | （设计推断）`inference` | `TargetAcquisitionGrid.gd:34/38/80`（每 Match 一张网格、每物理帧索引、查询侧错峰）+ `WorldQueryRuntime.cs:309-347`（每 AI 独立 session）+ `GodotWorldObservationRepository.cs:82-106`（每秒一帧共享快照） | 规则 AI 各自扫描（`SimpleClairvoyantAI.gd:341-359` 按物理帧缓存全图扫描）；副官另走一条路（`DebugControlServer.gd:1704-1758` 自建扫描） | 明确"共享只读快照（版本号）→ 各 AI 独立决策视图"的契约，避免各扫全图 | 影响面大：必须按 RSI 单补丁循环；不得把 SceneTree 搬线程 |
| 命令契约（稳定 ID/授权/主线程） | `inference`（AIRTS 现状） | `RuleAiCommandGateway.cs:19-50`（issuer 绑定）、`:74-75`（稳定 ID Move）、`:128-133`（可见敌授权）、`:284-295`（调用时校验 issuer） | **无 command_version**：编组只能靠 `_current_target_id` + 超时诊断"停滞" | 给每次命令加 `team_id/command_version/target_id/issued_at_sim_ms/reason`（纯增量字段） | 命令 DTO 变更需同步 C# 回执与测试 |
| 管理器时间调度（deadline/isDue + 每拍遍历更新） | `static-binary`（控制流级，§4.7.7） | `AiCadence.gd:12-16`（0.5s 基础间隔按电脑数缩放）与各 Controller 的 Timer（`EconomyController.gd:17,115`、`OffenseController.gd:20,198` 等） | AIRTS 每个 Controller 各自持有 Timer，无统一的"下次运行时刻"契约；RA3 的 4 个 Manager 复用同一组 `deadline=now+interval`/`isDue` 虚函数 | 把各 Controller 的节流收敛为统一的"next_run_at + is_due"纯数据字段（行为不变、仅结构化），便于诊断与对齐 RA3 语义 | 结构重构仍是 AI 行为敏感改动：节奏变化会直接改变对局节奏，需人机对照与无头真局回归 |
| 寻路/避障性能维护 | `measured`（AIRTS 历史报告） | `2026-10-07-rvo-push-bottleneck-handoff.md:12-16,97,104-112`（断开 `velocity_computed` ⇒ −58%；回调 135.8µs×303≈41ms/tick） | 1000 单位 0.6 FPS；200 单位仍 257ms（R16 后） | RA3 的启示仅到"减少重复遍历/团队级决策/受限频率"层面（其内部算法未证实）；AIRTS 候选方向 A–E 已有清单 | **必须**保留玩法/画质，等价性门禁 0 failure；不许用 RA3"老引擎也一样慢"当借口 |

### 7.1 提示词 6 个重点问题的直接回答

1. **AIRTS 是否把战略、团队、微操和移动执行混在一个循环里？**
   不是单一循环，但**契约缺失**：战略/参数在根节点（`SimpleClairvoyantAI.gd:136/199/262/341`），编组在 `OffenseController.gd:792-883`/`AutoAttackingBattlegroup.gd:170-260`，逐单位微操散在三个控制器（Battlegroup `:593`、Economy `:381`、Intelligence `:109`、ConstructionWorks `:105`），移动执行独立在物理 tick（`Movement.gd:413/1723/2776`）。RA3 的对照：微操有独立 Manager + 1s 节拍 + 两状态机（C5/C6 证据）；AIRTS 缺的是"谁在什么状态下、以什么节拍、对哪些单位、带什么 reason 下令"的显式契约，而不是缺类。
2. **如何用共享只读快照让多个 AI/副官共享观察结果？**
   已有半件基础设施：`TargetAcquisitionGrid.gd`（每 Match 一张、每物理帧 O(N) 迁移、查询侧 167ms 错峰、不做阵营过滤）+ `GodotWorldObservationRepository.cs:82-106`（每物理帧一帧的进程级快照）+ 每 AI 的 session（`WorldQueryRuntime.cs:309-347`）。缺口在**上层**：规则 AI 仍各自做全图扫描（`SimpleClairvoyantAI.gd:341-359`），副官又自建一套（`DebugControlServer.gd:1704-1758`）。建议以"快照版本号（snapshot_id）+ 只读视图"为契约，让三方共用同一代观察，各建各自的 LastKnown 记忆（`WorldQueryService.cs:247-279` 已按 session 存）。
3. **如何用有界团队 idle/单位 idle 重下令修复"一次只走一个单位一小段"？**
   先纠正一个事实：AI 不是"一次只走一个单位"，而是**全场共享的每物理帧导航预算**把大部队串行化——`Movement.gd:390` `LOGIC_PATH_BUDGET_PER_FRAME := 6`（static，跨单位共享，`:394-395`），另有 `RECOVERY_BUDGET_PER_FRAME := 8`；且命令回执未做重试（`AutoAttackingBattlegroup.gd:592-593,574-576`）。RA3 的对照设计（C6）是**团队中心 30s、单单位 10s 无位移即重下令**，即在"预算受限 + 命令可能被拒"的现实下，用 idle 不变量兜底，而不是发一次命令就等。建议：(a) 保留预算（防帧尖峰）但增加"队列化路径请求 + 空闲不变量"；(b) 单单位 idle 触发局部重派（重走/换点），团队 idle 触发整组重评（与现有 12s 卡住检测 `AutoAttackingBattlegroup.gd:9` 合并，避免双套阈值互相打脸）；(c) 每条重派带 reason 计数，供真局取证。
4. **如何分离视觉包围盒、逻辑半径、寻路直径、队形宽深、攻击距离和视野？**
   RA3 的做法是在数据模型上分列（§3.7/3.8），而且注释里反复强调语义边界（如 `DodgeSafetyDistance` 300 与 `PathfindDiameter` -1 互不相干）。AIRTS 现状：`Movement.radius`（=NavigationAgent3D.radius，RVO/到达用）、`MovementObstacle.radius`（仅保守回退/预筛）、carve（碰撞顶点+margin 0.6+navmesh agent_radius 0.9）、footprint（`footprintRadiusMeters`→放置圈）**已经分开**，但缺一个只读聚合 profile 供 AI/队形/寻路读取。建议新增纯数据 `UnitMobilityProfile`（visual_ground_hull（运行时测量）/logic_radius/pathfind_diameter/formation_w/h/turn_time/accel/brake/close_enough/reverse/dodge_safety），**只读**，不改动任何现有权威源；`arrive_radius=max(radius,0.35)` 之类的耦合逐项评审。
5. **如何把纯数据目标评分/队形计算放到 worker，而让 SceneTree、授权和命令提交留在主线程？**
   AIRTS 已有的边界正好对应：查询返回纯数据（`GodotWorldObservationRepository` 快照、`WorldQueryContracts.cs:140-145`），命令必须过 `RuleAiCommandGateway`（issuer 校验 + 可见敌授权 + 稳定 ID），AI 拿不到 Godot Node（`RuleAiCommandGateway.cs:320-333` ToStablePlacement 把 Node 剥成 ID）。建议：worker 只允许消费"不可变快照 + 版本号"做评分/队形/候选路径，产出"命令意图列表"回主线程，由 Gateway 授权/提交；取消语义用版本号（丢弃过期结果）。注意：目前"主线程"只是注释口径（`QueryPerfCounters.cs:6-9`），没有运行时断言——上 worker 前先把这条做成可验证门禁。
6. **如何避免 RVO 和静态推出重复遍历，且不靠缩碰撞盒或关闭模拟？**
   AIRTS 已量化：`_on_velocity_computed`（`Movement.gd:2776`）→ `_push_out_of_static_obstacles`（`:1372`）是主因（断开回调 −58%，`2026-10-07-rvo-push-bottleneck-handoff.md:97/104-112`）；预剔除 R16 已拿到 −40%。RA3 侧**没有**可迁移的算法证据（§4.5），但有可迁移的**组织模式**：(a) 决策与执行分离、微操有节拍（C5）；(b) 团队级决策减少逐单位重复（C4）；(c) 移动状态机化（C13），到点/等待队形是显式状态而不是每帧重算。落地上优先做 handoff §8 的候选 A（消除 RVO 与推出的重复避让，需等价门禁 + 产品批准）与 B（单次访问次数上限），RA3 不能作为"某算法已被验证"的依据。

### 7.2 建议实施顺序（全部走 RSI 单补丁循环，未实施）

1. **P0 诊断契约（低风险）**：命令/重派带 `team_id/command_version/target_id/issued_at_sim_ms/reason` 字段 + 编组状态标签；不改行为，先让"为什么不动"可取证。门禁：日志/回执测试 + 一条真局回放。
2. **P1 两级 idle 重下令**：按 C6 语义实现"团队 30s/50m、单单位 10s/50m"可配置阈值与局部重派，与现有 12s/10s 判据合并去重。门禁：无头真实 Match（站桩场景正向 + 正常推进反向）+ `movement-recovery`/`local-avoidance` 套件 + `MovementPushEquivalence`。
3. **P2 UnitMobilityProfile（只读聚合）**：把 6 类量聚合成只读数据源，逐项核对现有权威源，不合并语义。门禁：逐单位探针读数 vs 现状一致（`_RuntimeColliderCheck.tscn` 思路）+ 尺寸相关套件。
4. **P3 共享快照 + 副官/多 AI 复用**：以 snapshot_id 为契约减少各自全图扫描。门禁：3 个 AI 局的帧时间与行为对照（读性能 skill）；改线程必须另立计划。
5. **P4 移动/避障性能候选 A/B**：沿用 handoff 清单，先消除重复遍历再谈 worker。门禁：等价性 0 failure + 帧时间 p50/p95 + 模拟速度。

---

## 8. 阻塞项（不许掩盖）

| 项 | 状态 | 说明 |
|---|---|---|
| Ghidra 函数级反编译 | **已完成（本轮解决）** | Ghidra 11.0.3 安装 + SHA-256 校验 + 自动分析 + dump 脚本，函数边界/调用者/伪代码/CFG 见 §4.7；capstone 阶段的"启发式边界"表述仅在 §4.3 历史小节保留 |
| 函数调用图 / 控制流还原 | **部分完成** | 目标函数及其直接调用者/被调用者已还原（§4.7）；间接/相对引用与跳转表仍有限；vtable 分发导致的"无直接调用者"函数（如类型名 getter、isDue）已按 vtable 归属标注 |
| AIMicroManager 类的完整方法集 | `not-yet-verified` | 该类的类名字符串不存在（只有资产名/路径/单例名），未像三个 Manager 一样完成 vftable 定位；已定位 4 个 .cpp 函数（§4.7.8） |
| AI/寻路核心研究（算法级） | `not-yet-verified` | 本报告**尚未**还原 RA3 的具体寻路算法、避障算法、线程模型、编组逻辑、目标评分或撤退逻辑；当前证据止于"类/接口/析构树/时间调度模式"层（§4.7.9）。外部核验确认此口径 |
| RA3 动态对局采样 | `not-yet-verified` | 无录像文件、无无人化入口、需交互全屏（§5）；**不用 AIRTS 证据代替** |
| RA3 内部线程模型 | `not-yet-verified` | PE 导入表（KERNEL32 等）与字符串都不能证明 AI/寻路线程划分 |
| RA3 具体避障/寻路算法（RVO/ORCA/A*/拉直） | `not-yet-verified`（并有负面证据） | `RVO`/`avoidance`/`ORCA`/`steering`/`navmesh` 等 0 命中（§4.5）；只有子系统名与设计接口 |
| 编译资产完整解码（`*.manifest/.bin`） | `not-yet-verified` | `D:\RA3_RE_Research\ra3-re\extract\` 有 Core10/11/12 提取物；本轮未建立完整字段解码器 |
| 队列/预算类内部量（RA3 侧） | `not-yet-verified` | Schema 的 1s/30s/10s 是数据默认值；实际运行调度频率不可见 |

---

## 9. 与 13:07 初版的差异（更正记录）

| 项 | 初版 | 本轮完整执行 |
|---|---|---|
| `RVO`/`avoidance` 字符串命中 | 称"4 处命中" | **撤回**：无过滤全文件搜索 0 命中；`.text` 的 "A*" 为字节巧合（§4.5） |
| 身份 | 未提 4GB patch | 补 1 字节 `0x126` LAF patch 证据与 unpatched 备份 hash（§2.3） |
| Schema 证据 | 无行号 | 全部带 `文件:行号`（§3） |
| 静态证据 | 仅字符串命中表 | 增加编译单元族、vftable 槽表、xref 指令级表、战术枚举/状态字段族（§4） |
| 映射表 | 4 列 | 6 列 + 6 个重点问题直接回答 + 实施顺序（§7） |
| 动态 | 未评估 | 给出评估过程与不启动理由（§5） |
| Ghidra | `Ghidra unavailable`（§4.5 负面结论基于字符串扫描） | **11.0.3 已安装并分析完成**：函数边界/调用者/伪代码/CFG 全量提取（§4.7）；`AITeam` 前缀误判修正为 `AITeamMaker`；`0x890030` 等的"构造"初判修正为**析构**（反编译行为） |
| s2b/s2c 脚本 | print 在 GBK 控制台崩溃（`UnicodeEncodeError: 'gbk'`） | 三个脚本统一加 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`，重跑 rc=0（JSON 产物不变，log 以 UTF-8 写入） |
| Ghidra 产物计数与措辞 | 行文"174 个函数"、产物写 862 KB | **外部核验后修正**：JSON = **171 条函数记录**（881 KB）；`decomp/*.c` = 171（一一对应），首轮 3 个孤儿文件隔离到 `_stale_first_pass/`；新增 §4.7.9 明示小函数占比与"不等于完整 AI"边界 |

---

## 10. 验证记录

| 检查 | 结果 |
|---|---|
| `git rev-parse --show-toplevel` | `G:/AIRTS/AI_RTS` |
| `check_workspace_target.py --mode develop`（报告目录） | rc=0 `allow` |
| RA3 目录只读核对 | 已完成（全部 rb 打开） |
| S0/S2/S2b/S2c 脚本可重跑 | 是；产物与日志在 `agent/runs/2026-10-11-ra3-research/`（`s0_identity.json/.log`、`s2_static.json/.log`、`s2b_vftable.json/.log`、`s2c_context.json/.log`） |
| 关键结论双证核对 | C1/C3/C4/C7/C10/C11/C12/C14 双证据；其余单证已标注（§6） |
| AIRTS 侧行号抽查 | `AutoAttackingBattlegroup.gd:9,44`、`Movement.gd:390,1723`、`RuleAiCommandGateway.cs:128-133`、`AiCadence.gd:12-16` 均与描述一致 |
| AIRTS 游戏源码修改 | **未做**（diff 仅限本报告、计划文件、agent/runs 证据） |
| Godot / `dotnet build` / 全量回归 | 未运行：本研究无代码候选，不需要产品回归 |
| RA3 Ghidra 分析 | **已运行**：Ghidra 11.0.3（SHA-256 校验通过），自动分析 414s + dump 脚本（stderr 空、rc=0），产物 `ghidra_control_flow.json`(881KB, 171 条) + `decomp/*.c`(171，与 JSON 一一对应) |
| RA3 动态对局 | 未运行，见 §5/§8 |
| 外部独立核验（2026-10-11，用户提供） | 逐项复检确认：JSON=171（非 174）、孤儿 .c 3 个（mtime 首轮 14:48）、`≤32B`=50、伪代码 `≤10 行`=39、"完整 AI 还原"不成立。本轮据此完成修正：隔离孤儿文件、修正计数、增加 §4.7.9、状态口径改为"**S2 函数级静态分析完成；AI/寻路核心研究待继续**" |
| candidate/champion 晋级 | 不适用；本轮无产品候选 |

## 11. 下一轮建议

1. ~~准备 Ghidra 并恢复调用图~~ **已完成**（§4.7）。深化方向（按价值排序）：(a) 在 Ghidra 里给已定性的函数/表批量重命名（AITacticManager::dtor、AITargetManager::isDue 等），再跑一轮"谁调用 `0x8D6DD0`（TacticManager 每拍更新）"以拿到更新循环的顶层入口；(b) 用 xref 全量搜索 `0xC5F6A0` 表（TargetManager +8 的第三表）与 `TheAIMicroManagerStore`(`0xC106E4`) 的使用点；(c) 对 `FUN_008C5850`/`FUN_008C6440` 的调用者链继续上溯，直到与实际玩法概念（目标/微操/撤退）建立可复核映射。
2. 若用户允许，准备一台可交互环境的"最小离线 skirmish + 手动录像"流程，固定地图/难度/电脑数后采样 §5 未验证清单；任何不可重复的观察一律 `not-yet-verified`。
3. 把 §7.2 的 P0→P1 拆成 AIRTS 实施计划（`agent/plans/`），按 RSI 单补丁闸门执行；先 P0（纯诊断）再 P1（行为改动）。
4. 编译资产解码（`globals`/`static` 系）只作为独立研究线，不与产品计划混排。

## 12. 回滚方式

本轮只更新 3 份 Markdown（本报告、计划执行记录、提示词未改）+ `agent/runs/2026-10-11-ra3-research/` 证据文件；不触碰 `D:\Red Alert 3`、`D:\RA3_RE_Research` 已有提取物、AIRTS 游戏源码或其他会话未提交改动。如需撤销，仅删除本报告与 runs 证据目录并把计划状态恢复为 `needs-review` 即可。
