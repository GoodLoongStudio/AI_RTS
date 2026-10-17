# 建筑导航净空统一（矿车卡基地/矿场）实施计划

## Overview

用户反馈：矿车在主基地（command_center）与矿场（ore_refinery）附近被卡住。只读诊断（2026-10-08）结论：同一栋建筑存在 4 套不一致的边界，navmesh 最松，路径拐点落在推出层/RVO 的禁区里。本计划实施经用户确认的 A+B+C+D 四项：

- A：建筑 carve 外扩可配置余量，并按碰撞形状挖洞；所有引用 carve 净空的口径同步。
- B：建筑 MovementObstacle 关闭 RVO avoidance（保留 affect_navigation_mesh）。
- C：停滞确认后的"穿过己方/盟友建筑"受限脱困模式；修 `_give_up_commitment` 可达即无限重置。
- D：建筑放置最小间距（贴紧 / 可通行二选一，中间区间禁止），玩家蓝图与 AI 自动选址同源。
- 顺带：评估首次烘焙固化开局建筑、≥256 大图不重烘。

## Current State Analysis

矿车（Worker）Movement.radius=1.36，推出层要求离建筑表面 `max(1.36, 视觉hull≈1.26)+0.1-0.25 = 1.21m`；navmesh agent_radius=0.9。

| 距中心(m) | navmesh 洞边 | 推出层 | RVO(建筑障碍) | 贴合判定 |
|---|---|---|---|---|
| 矿场（盒 3.8×3.87，carve 圆 r=1.935） | 2.80–2.84 | 面 3.11 / 角 3.92 | 3.30 | 3.80 |
| 基地（圆柱 r=3.48） | 4.31–4.38 | 4.69 | 4.77–4.84 | 5.34 |

- `Unit.gd:787-797`：契约是 navmesh 只作粗通道，推出层兜底。
- `Worker.tscn:45-48`：path_desired 0.3 / path_max 0.31 小于 0.31–1.1m 的口径差 ⇒ 到不了拐点 / 反复重寻路。
- 盒形建筑（矿场、兵营、车厂、机场）全部用内切圆 carve，角点露出圆外。
- `GodotStructurePlacementWorldPort.Overlaps` 只禁止 AABB 相交，没有最小间距 ⇒ 1.8–2.4m 的"假通道"。
- `Movement._give_up_commitment` 可达即 `_recovery_rounds = 0`，永久循环；窄口只认 Box，软穿行需 ≥2 友军。

## Implementation Strategy

1. 权威来源：carve 余量是 `MovementObstacle.carve_margin_m`（默认值取 `Constants.Match.Terrain.Navmesh.STRUCTURE_CARVE_MARGIN_M`）；所有净空计算读该节点属性，不另抄常量。
2. 挖洞几何：圆形建筑 = radius + 余量；盒形建筑 = 碰撞形状轮廓沿自身轴外扩余量（`carve_from_collision_bounds=true`）。
3. B 只关 avoidance，不改 carve/推出层；改前用运行时探针确认建筑障碍确实影响 RVO 安全速度。
4. C 只在已确认停滞的脱困状态机里进入，不进正常移动帧；开关关闭时推出层逐项等价。
5. D 在 C# 放置端口统一判定；AI FindAutoSpot 走同一 Evaluate。
6. 复现探针：基地与矿场贴近摆放（假通道间隙）+ 多矿车往返交货，统计卡住秒数/次数、穿行次数、交付次数，改前改后同夹具对比。

## Implementation Steps

1. 基线：定向回归 20 项 + 复现探针（改前）。
2. 实验：obstacle 旋转是否作用于 vertices；建筑 avoidance 是否参与 RVO。
3. A：MovementObstacle / 场景 / carve_clearance_of / CarveBoundsOf / production_spawn_spot / Overlay。
4. B：MovementObstacle 关 avoidance。
5. C：Movement 新脱困模式 + 放弃上限。
6. D：放置间距规则 + 蓝图反馈 + AI 选址验证。
7. 顺带项评估。
8. 回归、复现探针（改后）、重烘耗时、闭环报告。

## Timeline

- 阶段 1（基线+实验）：当日
- 阶段 2（A/B/C）：当日
- 阶段 3（D + 回归 + 报告）：当日

## Risk Assessment

- 盒形 carve 历史上曾在"建楼中途"场景卡住打转（当时推出层是包含圆）；现推出层已是贴形，需 movement-recovery 复验，不过则仅保留矿场。
- 外扩余量会让步兵绕建筑更远、窄缝更早封死；属于预期产品变化。
- D 会让部分紧凑摆法失效；阈值需按最大地面单位半径定，可能需产品取舍。
- C 引入短时视觉重叠（≤0.46m）；敌方建筑排除。
- 共享工作区大量未提交改动，编辑前记录 hash，不回滚他人改动。

## Success Criteria

- 复现探针：卡住次数（≥3s 无位移的移动中窗口）改后显著下降（目标 0），交付次数不降。
- MovementPushEquivalence 0 failure；navigation-stability、movement-recovery、ore-refinery、放置相关测试与基线相比不新增失败。
- dotnet build rc=0。
- 重烘耗时记录，改后不显著增加。

## Progress Tracking

- ✅ 1 基线回归 + 复现探针：定向 20 项 14 通过（失败 ore-refinery、worker-gather、spawn-point-regression、rule-ai-expansion、rule-ai-economy-query、vehicle-factory-worker-production，均为改前既有）；`_RefineryJamProbe` gap2 交付 11 / 建筑旁卡住 13，gap4 交付 12 / 建筑旁卡住 12 / 穿模 6 帧（最小 -0.24m）。
- ✅ 2 实验：obstacle 旋转作用于 vertices；改前建筑障碍确实参与 RVO（单车掠过基地安全速度有偏转）。
- ✅ 3 A：`STRUCTURE_CARVE_MARGIN_M = 0.6`；方盒建筑改 `carve_from_collision_bounds`。洞边离碰撞表面实测：margin 0 时 0~0.8m，margin 0.6 时方盒 ≥1.35、主基地 ≥1.25、炮塔 ≥1.30（均 ≥ 矿车推出层 1.21）。
- ✅ 4 B：`STRUCTURE_AVOIDANCE_ENABLED = false`（挖洞建筑不参与 RVO），并补了 B 暴露的 3 处配套修复，见偏差 11。
- ✅ 5 C：己方建筑脱困 0.6s / 冷却 1.5s / 半径降到 0.9；MovementPushEquivalence 5959 项 0 失败。放弃上限**只做诊断不判失败**（见偏差 4）。
- ✅ 6 D：`BlocksPassage`（Seal 2.4m / Pass 5.6m）；`_StructureGapRuleProbe` rc=0：两轴禁区均为间隙 2.4~5.7m（0.1m 步长），AI 连续选址兵营/车厂/机场/矿场 4/4 成功。
- ✅ 7 顺带项：见偏差记录 6–8，只记录不改。
- ✅ 8 回归/探针/报告：最终定向 20 项 15 通过，失败 5 项均为基线既有且断言集合与基线一致（rule-ai-expansion 由失败转通过）；dotnet build rc=0；Core 放置 8/8、施工 12/12；副官 pytest 13/13。复现探针（最终代码，各 4 次）：gap2 交付 20/20/21/21、建筑旁卡住 9/12/10/14；gap4 交付 19/21/20/19、建筑旁卡住 11/13/14/16；最小表面间隙 ≥ -0.18m（仅脱困模式内）。报告：`agent/reports/closed-loop/2026-10-08-navigation-clearance.md`。

### 偏差记录

1. **交货落点**（计划外新增）：2.0m 缝里的穿模根因是交货落点选在两楼之间的楔形缝口。新增 `UnitMovementUtils.structure_approach_point`（carve 轮廓外 16 点采样、避开其他洞边），`MovingToUnit` 优先使用；`structure_approach_enabled` 静态开关供探针模拟改前。
2. **RVO 超长步截断**（计划外新增）：B 之后 RVO 给出超长朝内速度，推出层作用在超长步上导致沿弦线切进主基地（中心 -0.98m）。`_on_velocity_computed` 改为先 `limit_length(_interim_speed)` 再推出。
3. **并发代理改动**：`UnitPlacementUtils.production_spawn_spot` 已被其他会话改为 `max(edge, obstacle.carve_extent_max()) + agent_radius`，与本计划一致，保留其改法未覆盖。
4. **放弃上限（产品取舍，未按原方案落地）**：最初"可达但连续 3 轮无进展且附近无友军 ⇒ Unreachable"，movement-recovery 稳定出现假 Unreachable：wall-detour 单车绕墙时距离先变大，3 轮"无进展"后被判死（实测坦克在 (21.75,3.29) 距目标 11m）；放宽到"12m 内无任何同域单位"仍命中。改为到第 3 轮只记 `give_up_limit` 并打印 `[MOV][放弃上限]`，继续重试。真正被己方建筑钉死的情况交给 C 的脱困 + 交货落点；"可达即无限重试"本身保留。
5. **C 开关**：用 `Movement.structure_pass_enabled` 静态变量（非导出属性），探针/等价测试可整体关闭。
6. **Worker `path_max_distance` 0.31→0.8**：探针各 4 次对比无收益（gap2 交付均值 12.75 vs 14，gap4 14 vs 13.25，建筑旁卡住略多），**不改**。
7. **首次烘焙固化**：terrain 用 `SOURCE_GEOMETRY_GROUPS_EXPLICIT`，首次烘焙后清空组、几何并入 `_map_geometry`；但 `Match._ready` 先烘焙再 `_setup_players/_setup_player_units`，开局建筑不在首烘里，被固化的只有地图静态障碍。风险低，不改。
8. **≥256 大图**：不烘焙、不重烘；地面单位 `_skip_navigation_server()` 自行关 avoidance，所以 B 在大图上无回归；大图建筑本来就没有洞，仍靠推出层，另立专项。
9. **D 的近似**：候选建筑按 footprint 半径的轴对齐方形、既有建筑按碰撞 AABB 算间隙，没有考虑候选旋转；飞机厂短边方向邻接采样间隙约 2.74m 会被拒（其他角度可用）。
10. **重烘耗时**：改前改后主线程约 0.1ms、异步总耗时约 133ms，无变化。
11. **B 的配套修复**（先尝试回退 B，再按数据恢复）：
    - 回退 B（建筑重新参与 RVO）后 movement-recovery override 场景坦克被两座主基地之间的窄口 + 人群锁死，40s 不到达（2/2 复现）⇒ B 必须保留。
    - B 暴露的根因 1（既有缺陷）：`MovingToUnit` 作为采集/交货子动作时 `_unit.action` 是父动作，`Moving._exit_tree` 不 stop ⇒ 到达后仍追旧落点。改为 `_finish("Arrived")` 先 `stop()` 再 `ended`。
    - 根因 2：被动移动检测按 RVO 安全速度判，推向楼的速度被推出层整段抵消、单位没动也算"被推着走"⇒ 采集计时永久暂停。改为按本帧真实平面位移判。
    - 根因 3：没有移动任务时 RVO 被动推挤的方向覆盖 face_towards。改为无 `_committed_target` 且有待执行朝向时不随推挤转。
    - 修完后 `_WorkerGatherDiag` 默认配置 0.95s 出矿。
    - 以下为回退 B 时的对照数据（保留作记录）：B 让 worker-gather 稳定新增 2 条失败（矿车出生在主基地洞内，被重叠友军的 RVO 分离速度往楼里推、推出层顶回，车身每帧跟速度转、清掉 face_towards，采集朝向门槛永远不过；`_WorkerGatherDiag` 只开回建筑 RVO 即 0.8s 出矿）。只按真实位移转车身的修法无效（来回 0.13m 也算位移），已撤回。`_RefineryJamProbe` 在完整修复上单开建筑 RVO（各 4 次）：gap2 交付 13.25 vs 14、建筑旁卡住 6.25 vs 6.75；gap4 交付 13.25 vs 13.25、建筑旁 8.5 vs 7；穿模 0 次（B 开时 4m 缝 2/4 次各 23~24 帧、最小 -0.18m），最小表面间隙 ≥0.82m。A 的外扩已把主基地洞边推到 4.98m，超出 RVO 障碍圈 4.77~4.84m，B 要解决的洞边偏转基本被 A 消除 ⇒ 默认保留建筑 RVO，B 做成常量开关。

## Related Files

- `source/match/MatchConstants.gd`
- `source/match/units/traits/MovementObstacle.gd`
- `source/match/units/traits/Movement.gd`
- `source/match/units/{OreRefinery,Barracks,VehicleFactory,AircraftFactory,CommandCenter}.tscn`、`Worker.tscn`
- `source/match/utils/UnitMovementUtils.gd`、`UnitPlacementUtils.gd`
- `source/match/units/actions/ReturningToBase.gd`
- `source/match/debug/CollisionVolumeOverlay.gd`
- `source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs`（及放置契约）
- `source/match/TerrainNavigation.gd`
- `tests/automated/_NavCarveRotationLab.gd`、`tests/automated/_RefineryJamProbe.gd`（新增）
- `source/match/units/actions/MovingToUnit.gd`
- `source/csharp/Application/Construction/StructurePlacementContracts.cs`、`StructurePlacementService.cs`
- `source/match/players/human/StructurePlacementHandler.gd`、`assets/translations/match.csv`
- `source/adjutant_coordinator/graph/placement.py`
- `tests/automated/_StructureCarveEdgeProbe.gd/.tscn`、`tests/automated/_StructureGapRuleProbe.gd/.tscn`、`tests/automated/_WorkerGatherDiag.gd/.tscn`（新增）

---

# 第二轮（2026-10-08）

## Overview

用户选定 4 项，按序执行：① 排查 5 项既有失败测试（判真缺陷/测试过时）；② 主基地南侧矿车对向互挤；
③ 卡住重试改回硬上限（按 navmesh 剩余路径长度/路径点进度）；④ `LeavesBlockingGap` 按实际旋转 OBB 算间隙。

## Implementation Steps / Progress Tracking

| # | 项 | 状态 |
|---|---|---|
| 1a | ore-refinery 判定与处理 | ✅ 测试过时（夹具），已修，单跑 0 失败 |
| 1b | worker-gather 判定与处理 | ✅ 测试过时（三层），已修，单跑 0 失败；另登记真实缺陷 D-R2-1 |
| 1c | spawn-point-regression | ✅ 夹具改为坦克，终局 0 失败 rc=0 |
| 1d | rule-ai-economy-query | ✅ 判定：间歇失败，断言未改。终局仍 1 失败 |
| 1e | vehicle-factory-worker-production | ✅ 真实口径分裂，不改 catalog，终局仍 3 失败 |
| 1f | core 生产 3 / 平衡 24 | ✅ 已跑：ProductionService 3、BalanceConfig 24。不改配置 |
| 2 | 南侧对向互挤 | ✅ 车道错开落点。交货略升，建筑旁卡住未下降 |
| 3 | 硬上限 | ✅ 路径进展 + 45s / 3 轮。movement-recovery rc=0 |
| 4 | OBB 间隙 | ✅ 探针 0 失败；AI 四座都放下；dotnet build rc=0 |
| 5 | 终局回归 | ✅ 20 项 17 通过。失败：expansion、economy-query、vehicle-factory |

## 第 1 项判定记录

### ore-refinery —— 测试过时（夹具选点），非游戏缺陷

- 现象：「近点采空后矿场仍应有可采矿点」「矿场换点目标必须是仍有资源的那颗」两条红；基线（第一轮改前）同样红，与导航改动无关。
- 证据（逐 3s 存量追踪）：远矿候选 (53,8) 离网格 3.8m，夹具允许 ≤5.4m；落地后被 MovementObstacle「对齐导航面」拉回 (49.2,8)，距矿场 17.0 → **13.2m**，反而比近矿（14.0m）近。工人按承重设计「就近自选采集」先把 4000 的远矿采空（10 趟），近矿 120 原封不动，采空时已无矿可换。自检 `_nearest_ore == near_ore` 在对齐生效前执行，没拦住。
- 处理（`tests/automated/OreRefinerySmokeTest.gd`）：`_walkable_ring_spot` 的远矿分支改为与近矿同口径「在网格上（≤0.6m）且走得通」；生成远矿后等 0.5s 再做自检（读对齐后的位置）。断言未改、未放宽。修后远矿落 (19,8)、17.0m，近矿 3s 采空，换点断言通过。
- 另：r2-a 中出现过一次「矿点存量必须被真实采掉（272360 → 272408）」，此后未复现，记为再生时序偶发，最终回归复核。

### worker-gather —— 测试过时（三层叠加），另发现真实缺陷 D-R2-1

1. **B 矿已淘汰**：统一货币（2026-09-14）后账户只登记 A，B 交货被丢弃；基线 3 条红（交付/清零/完成）的直接原因。→ 改用 A14，`resource_b` → `resource_a`。
2. **采集批量化**：`CollectingResourcesWhileInRange` 按 `TARGET_FILL_SECONDS=2s` 反推每 tick 搬运量（容量 400 ⇒ 每 tick 24），存量 2 的矿第一下就采空，「暂停时矿未空 → 再次右键恢复」时序不成立（改 A14 后 7 条红即此）。→ 夹具存量设 60（多于一批、少于一车），期望交付从写死 `+2` 改为 `+初始存量`（语义不变：耗尽后一次交完）。
3. **交货点口径**：2026-09-30 起 `find_drop_off` 只认已指派的完工矿场，不再回主基地；TestAllUnits 没有矿场 ⇒ 满载后 `NoDropOff` 结束、带货站桩。→ 夹具在 (26,30) 生成完工矿场，容量 0（不主动接管、不打断 Stop/恢复时序），工人挂指派标记。
4. 加矿场后仍卡：工人困在 (11.5,15.3) 不动 10s。**D-R2-1（真实缺陷，第一轮前已存在）**：矿点 `MovementObstacle` 是 `affect_navigation_mesh=false`、RVO 半径 1.2（10-01 碰撞体优化按 RA3「地面资源」语义退出烘焙，但没撤 RVO）。导航网格认为两矿之间能走，RVO 却把重叠/过窄的两颗矿当实墙 ⇒ 路径从 A14–B5（圆心 2.2m）缝里穿，RVO 安全速度以 ~10m/s 指向主基地，推出层原样推回，死锁。legacy（第一轮全关）同样复现 ⇒ 非本轮引入。正式地图矿点最近间距：多数 ≥5.2m，`map_36` 为 **2.83m**（间距 < 2×1.2+工人直径 2.72 ≈ 5.1m 即可能触发）。
   - 夹具处理：移除统一货币后已不存在的 B5（理由写在测试注释里）；移除后 0 失败，但工人在主基地与 A15 之间仍有约 3s 停顿后才脱困（同一缺陷的轻度表现）。
   - 游戏侧未改：可选修法①矿点也退出 RVO（与"地面资源"导航语义一致、开销最低，但单位会从矿石模型上穿过 = 可见穿模）；②矿点恢复 carve（10-01 为解决"矿点采不到"刻意撤掉）。两者都改玩法/视觉，留给用户拍板。

### spawn-point-regression —— 测试夹具产品过时

- 现象：`C1 入队生产 Worker.tscn 应被接受`，回执 `ProductNotAllowed`。基线同样红。
- 权威 catalog（`demo.balance.v1.json` 的 `worker.allowedProducerUnitTypeIds`）是 `command_center`。车厂不能产矿车，所以旋转车厂的出生几何断言从未执行。
- 处理：C1/C5 改为车厂允许生产的坦克。距离、正脸方向、连续不重叠的数值断言未放宽。C3 矿场赠车仍测矿车。

### rule-ai-economy-query —— 间歇失败，断言未改

- 基线与第一轮终局：唯一工人在 10s 窗口结束时仍是 `Constructing`，采集断言失败。
- r2-b 单跑曾 0 失败（工地做完后进入采集）。终局 20 项里再次失败，同一条断言。
- 不放宽「必须开始采集」。失败模式与基线相同，不是本轮把断言改绿。

### vehicle-factory-worker-production —— 真实口径分裂，本轮不改 catalog

- 测试与 HUD、手册、未提交的 `EconomyController._try_produce_worker` 按 2026-09-28 要求车厂产矿车、主基地拒绝。
- 已提交 balance、`CommandCenterWorkerProductionSmokeTest`、`RallyPointSmokeTest` 仍是主基地产矿车。基线同样两条红。
- 把生产者改成车厂会让 rally-point / 主基地冒烟变红，属于平衡迁移。用户要求平衡配置大范围改动先不动，本轮不改 JSON、也不把这条测试改成「主基地可以造」来变绿。

### core 生产 / 平衡配置

- 只报告，不改配置。结论在跑完 `AI_RTS.Core.Tests` 后写入闭环报告。

---

# 第三轮（2026-10-09）

## Overview

两件事：① 己方矿车迎面挤住，先定位再加开销最低的让行或排队；② 矿车生产者从主基地改到车厂，并让规则 AI 在点火之后能建车厂再产矿车。

## 诊断

45 秒、缝 2m、3 车。卡住 10 次里：落点重叠 7、去程回程交叉 2、单独卡住 1、对向速度死锁 0。建筑旁的点都挤在主基地南侧。第二轮的车道错开没有把提交目标拉开到 2.2m 以外。

## 做法

同一玩家、同一矿场的返程队列只放一辆去交货落点。后车在当前位置横向错开 3m 并再远离矿场 4m 等待，交完才放行。只在进入/离开返程时登记，移动中不扫描。没有独立盟友名单，队列按所属玩家拆开；其他玩家不进队列，半径不缩小。

## 数据（3 车 × 90 秒 × 4）

| | gap2 交货 | gap2 建筑旁卡住 | gap2 穿模 | gap4 交货 | gap4 建筑旁卡住 | gap4 穿模 |
|---|---|---|---|---|---|---|
| 第二轮 | 21/23/22/20 | 11/14/17/10 | 有，最深 -0.175 | 21/22/21/21 | 18/14/13/15 | 有，最深 -0.18 |
| 第三轮 | 17/17/18/20 | 0/3/2/2 | 0 帧，最深 +0.28 | 18/18/18/20 | 3/2/2/3 | 0 帧，最深 +0.28 |

建筑旁卡住明显下降，不再加第二套机制。交货大约少 3 次，是排队把返程串行化的代价。

## 矿车生产者

`demo.balance.v1.json` 的 worker 生产者改为 `vehicle_factory`。成本 200、工时 180 不动。出生点和集结点走车厂原有队列。主基地拒绝入队。规则 AI 在矿场点火完成前不建车厂；车厂完工后才发矿车生产请求。

## 回归

定向 20 项 19 通过。失败仍是 rule-ai-economy-query（工人在窗口结束时仍是 Constructing，断言未放宽）。vehicle-factory-worker-production、rally-point、主基地拒绝入队、movement-recovery、推出等价 5959/0、间隙探针、四方向贴边均为 rc=0。放置 core 8/0。平衡 24 与生产部署 3 未改。重烘主线程约 0.11ms，异步约 125–142ms。

## 服务半径退出（2026-10-09）

服务半径不再决定矿场是否接管、是否指派、满载能否交货。无命令的矿车只自动采集该玩家当前看得见的矿，满载交给水平距离最近的己方已完工矿场。不要求事先接管这颗矿或这辆车。玩家的移动、攻击、停止仍优先。同一矿场同时只放一辆去交货落点，这条排队保留。车厂生产矿车、主基地拒绝矿车订单，也保留。

`serviceRadiusMeters` 从 demo 与 adjutant-e2e 两份平衡表和 C# schema 里删除。运行时不再把它写回 `service_radius_m`。脚本上的导出还在，但接管、寻矿、交货都不读它；测试把它设成 1 米，用来抓住「又把它当门槛」的回归。界面没有服务半径圈。

布局 36、矿在矿场外 30.9 米：无人机先把这颗矿探进现有视野后，观察 71.3 秒。人类矿车日志交货 12 次，同时朝落点走的满载车最多 1 辆，没有再因半径停住。ore-refinery、worker-gather 均为 rc=0。

## 无人机开局视野（2026-10-09）

无命令矿车仍只采 `FogOfWar.player_can_see` 看得见的矿。上一局要等无人机飞到矿旁 4.6 米，是因为无人机自己的视野盖不住出生点到最近矿的距离，不是服务半径。这次只加无人机视野，不揭露全图，不改交货排队，不改车厂产矿车。

视野来自平衡表单位类型 `drone.sightRangeMeters`，运行时写到 `Unit.sight_range`。`player_can_see` 用 `sight_range_against`（基准视野加双方半径）再加已有的 2 米补偿。无人机半径 1.2 米，矿点半径 1.2 米，所以有效圆心距是 `sightRangeMeters + 4.4`。主基地、矿场仍是 20，侦察机仍是 24。

出生点用 `Transform3D.translated(Vector3(-2, 0, -2))`，偏移加在原点上，不随出生点旋转。五张已生成地图、每个出生点的无人机到最近矿：

| 地图 | 四个出生点（米） | 最远 |
|---|---|---|
| 36-1846106761 | 31.63 / 36.25 / 30.38 / 29.25 | 36.25 |
| 39-655312406 | 31.45 / 31.37 / 29.71 / 36.45 | 36.45 |
| 47-903520021 | 30.12 / 31.07 / 32.72 / 32.49 | 32.72 |
| 8-561215132 | 29.68 / 26.44 / 30.71 / 37.08 | 37.08 |
| 8-608324557 | 29.89 / 35.08 / 29.54 / 35.25 | 35.25 |

改前视野 20，有效距离 24.4 米，上面每一颗最近矿都在圈外。改后 `demo.balance.v1.json` 与 `adjutant-e2e.balance.v1.json` 的无人机视野为 36，有效距离 40.4 米。最远的 37.08 米还剩约 3.3 米，其中包含原有的 2 米补偿，避免贴边看不见。

布局 36 种子 1846106761 的真实对局：开局采样时无人机停在出生点（2 秒位移 0），视野 36，最近矿 ResourceA4 在 36.25 米，该玩家已经看得见。主基地到同一矿 33.5 米，主基地自己看不见。其后观察墙钟 71.2 秒，人类交货 13 次，同时朝同一矿场落点的满载车最多 1 辆。`fog-of-war-sight-range` 测的是缺视野兜底，不锁无人机的 20，rc=0，断言未改。
