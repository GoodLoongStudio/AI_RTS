# 建筑卡单位：根因与修复（2026-10-12）

## ✅ 已确证的真因（两条，同一处口径错误）

**"到位容差"在两个层里不是同一个定义**，导致驱逐链最后一步被吃掉：

| 层 | 代码 | 认为的"到达"半径 |
|---|---|---|
| 移动层（实际判到达） | `Movement.gd:844` `arrive_radius = max(movement.radius, 0.35)` | **1.84m**（坦克） |
| 规划层（留多少余量） | `ArriveToleranceOf()` 只读 `target_desired_distance` | **0.15m**（坦克） |

两者差 **1.69m**。规划层以为"留 0.15 就够"，把落点算到离建筑 3.87m；
移动层却在距目标 1.84m 内就判"到达"，于是单位停在离建筑 **2.27m** ——
仍在 hull-to-hull 要求的 3.43m 以内，**人还压在楼里**。

实测证据（`tests/automated/_IndepVerifyDisplacementTarget.gd`，读移动层自带的
`_terminal_events`，不需要在产品代码里加 print）：

```
[DISP] accepted=true 建筑=(46.96,0.6,28.0)
[DISP] 最终：距建筑 2.27m，Movement 目标距建筑 3.87m
  [TERM] reason=Arrived tick=40 终态目标距建筑=3.87 停下时距建筑=2.27 距终态目标=1.60
      unit.radius=1.84 movement.radius=1.84 ⇒ arrive_radius=1.84 | target_desired_distance=0.15
```

⚠ 另一个坑：`radius` 在运行时是 **1.84**，而 `Tank.tscn` 里写的是 **1.288**（另有缩放）。
按 tscn 数字算余量必然偏小。

## 修复（已落地并验证）

`GodotStructurePlacementWorldPort.cs`：

1. `ArriveToleranceOf()` 改为与移动层**同源**：取 `max(target_desired_distance, max(movement.radius, 0.35))`。
2. 新增 `HullSlackMeters = 0.5f` 取代原来写死的 `+0.15f`：规划用圆形半径，
   验收用**地面 hull**（2026-10-01 用户定的口径），沿轴 hull 可比圆半径大 ~0.26m
   （炮塔圆 1.38 / 沿轴 hull ≈1.64），只留 0.15 会差最后 3cm 仍然贴着楼。

验证：`[DISP] 最终：距建筑 3.40m → （加 HullSlack 后）通过`；
`StructurePlacementSmokeTest` **2 failures → 1 failure**，
"被覆盖的友军应移动到建筑 footprint 外并待命"这条**已转绿**。

## ❌ 两个被实测否证的假设（不要重复走）

1. **`STRUCTURE_STAMP_RADIUS_SCALE 0.85 → 1.0`**（"禁行圆比楼本身还小，A* 能穿楼"）：
   算术上确实成立（每对建筑/单位少 1.7~2.9m），但**改完对结果零影响**：
   `_RefineryJamProbe` gap=2 仍是 `卡住=3 / 171.2s / 最小间隙 1.72`，
   `StructurePlacement` 仍是 2.27m。已回退，只在常量上留了注释说明。
2. **给 `is_ground_blocked` 传单位半径**（让 `_logic_unstick_if_blocked` 看得见楔住）：
   数字确实"变好"了（jam 卡住 3→0、间隙 1.72→9.56），但那是**把正常的贴边 adjacency
   误判成卡住**——工人交付/施工本来就要站到 `R + r` 以内。属于掩盖症状，已回退。

教训：第 2 条一开始被我当成重大进展写进报告，是 A/B 回退后才暴露出因果搞反了。
**任何"指标变好"都要先问它是不是把判定条件改宽/改窄了。**

## 回归对照（证明我的改动没有引入失败）

`tools/run_targeted_godot_tests.py` 跑 19 个移动/建造/采集相关套件：
10 通过、9 失败。把 C# 改动**回退 + 重编译**后，其中 7 个 `rc=1` 的套件
（building-occlusion-fade、economy-account、movement-recovery、worker-gather、
ground-attack-move-arrival、movement-push-equivalence、tank-ground-attack-move）
**失败情况完全一致** ⇒ 全部是先于本改动存在的既有失败，不是我引入的回归。
另 2 个 `rc=-9`（air-entity-move、entity-force-move）是被杀（超时/内存），属环境。

## ⚠ 目标在脚下变了：余量口径仍不对

修好"到位容差同源"后实测：被驱逐单位 **2.27m → 3.97m**（改善 1.70m），
`RuntimePlacement` 转绿。但同一条断言的**要求值同时从 3.43m 涨到 4.64m**
（`Unit.gd` 17:15 被另一会话改过运行时缩放），于是仍然差 0.67m。

⇒ 只要余量继续从**圆形 `radius`** 推导，而验收用**地面 hull**，
每次改单位尺寸都会重新错开。真正的收尾（下一步该做）：

**把驱逐余量的来源改成 hull 本身**，与验收同一口径。
验收侧的实现是 `StructurePlacementSmokeTest._ground_half_along()`：
遍历 `find_children("*", "GeometryInstance3D", true, false)`，取世界变换后的 AABB 角点，
跳过 `pt.y - origin.y > 0.6` 的高处顶点，再对**指向对方的方向**做点积取最大。
过滤名单：`Selection / Highlight / Targetability / HealthBar / RallyPoint`
（这些是 UI 件，算进去会把余量撑到离谱）。

落地时有两个必须注意的点（本轮踩到）：

1. **规划期建筑还没实例化**。`PlanDisplacements(center, structureRadius, overlapping)`
   只拿到 `footprint.Radius`（圆形）。要拿建筑 hull，得从 prototype 实例化一次量出来
   （测试自己也是 `TurretScene.instantiate()` 读半径再 `free()`），
   或者把 hull 预计算进 `CirclePlacementFootprint`。**别在每次候选评估里现实例化**，
   那是放置热路径。
2. **方向是变量**。验收用的是"指向对方"的有向 hull 投影，而驱逐候选在环上转；
   稳妥做法是取该节点 XZ 上的**最大半程**作为保守上界，再与圆形半径取 max，
   保证任何方向都不会欠空。

这样单位尺寸再怎么改，余量都不会再和验收脱钩
（符合仓库"权威口径只允许一个来源"的硬约束）。


## 当前四套件状态（本改动生效后）

| 套件 | 会话开始时 | 现在 |
|---|---|---|
| RuntimePlacement | 1 红 | **0 绿** |
| StructurePlacement | 2 红 | 2 红（nav 初始化时序 1；驱逐距离 3.97/4.64，尺寸变更把要求抬高） |
| OreRefinery | 3 红 | 1 红（经济两条已绿：`首车等待 15s`、`收到交付`×4） |
| SpawnPoint | 3 红 | 3 红（B2 与 `infm`×2，均为独立问题） |


| 失败 | 状态 |
|---|---|
| `StructurePlacement`：地表导航图应在放置评估前完成初始化 | 1 红，未查（导航图初始化时序，与本案无关） |
| `SpawnPointRegression`：B2 被驱逐单位 2.63 / D scale=2、3 出生点距离算成 `infm` | 待本次重跑确认（B2 与本案同族，可能已一起转绿；`infm` 是独立的算式问题） |
| `OreRefinerySmokeTest`：夹具自检"矿场周围应有可采矿落点" | 该图可走面边界问题；**经济两条已转绿**（`首车等待 15s`、`收到交付`×4） |
| 5 FPS 视频回看 | 未做；`record_playtest.py` 依赖 cv2，四个 venv 都没装，且需真实前台窗口 |


## 一句话根因

寻路给建筑画的"禁行圆"**比建筑自己的碰撞体还小 15%**，而且**完全不加通行单位自身的半径**：

```gdscript
// source/match/maps/generated/GeneratedTerrain.gd:168-169
const STRUCTURE_STAMP_RADIUS_SCALE := 0.85
const STRUCTURE_STAMP_RADIUS_MIN := 1.15
func _structure_stamp_radius(radius): return maxf(radius * 0.85, 1.15)
```

不相撞所需的净空是 `建筑半径 + 单位半径`；寻路却只挡 `0.85 × 建筑半径`。
**差额 = 0.15 × 建筑半径 + 单位半径**，实测每一对都在 1.7–2.9 米。

## 实测差额表（`tests/automated/PathFootprintClearanceSmokeTest.gd` 输出，现在必红）

| 建筑 × 单位 | 禁行圆 | 不相撞需要 | 差额 |
|---|---|---|---|
| 车辆工厂 × 矿车 | 3.03 | 4.76 | **1.73** |
| 车辆工厂 × 中型坦 | 3.03 | 5.20 | **2.17** |
| 车辆工厂 × 重型坦 | 3.03 | 5.69 | **2.66** |
| 指挥中心 × 重型坦 | 4.23 | 7.10 | **2.87** |
| 矿场 × 矿车 | 2.92 | 4.63 | **1.71** |
| 对地炮塔 × 中型坦 | 1.17 | 3.02 | **1.85** |

⇒ A* 可以合法地规划一条让车体**穿进建筑碰撞体** 2 米多的路径。单位撞上去后被物理挤出，
停在墙角——这就是用户截图里矿车卡在车厂角上的形态，也解释了
`StructurePlacementSmokeTest` 的 `实测 2.55 m，需要 > 3.79 m`。

## 为什么没有第二道防线（三个都已实测确认）

1. **大图（≥256m，即所有 512m 实战图）没有 navmesh**：
   `Navigation.setup()` 与 `TerrainNavigation._ready()` 在
   `should_skip_runtime_navigation(map)`（`map.size >= 256`）时直接 return，
   还 `_disable_navigation_regions()`。所以 `MovementObstacle` 发出的
   `schedule_navigation_rebake` **在大图上没有任何接收者**。
   建筑对导航的唯一表达，就是上面那个逻辑栅格禁行圆。
2. **建筑不参与 RVO 避障**：`_RefineryJamProbe` 实测
   `RVO 探针：建筑 avoidance=false 近处样本=0 最大偏转=0.0°`。
3. **停滞自愈进不去**：`_RefineryJamProbe` 在 gap=2/6/10/14 四档结果**完全相同**
   （`交付=0 卡住次数=3 全部 drop_overlap 卡住秒数≈126~171`），
   而引擎自己的 `stall_detections / repaths / escapes / pocket_escapes` **全为 0**。
   ⇒ 说明这不是"楼挨太近"，而是足迹不足导致的必然穿模；且一旦卡住不会自愈。

## 修复规格（不要直接放大魔数）

**不能**只把 `0.85` 调大。它当初是为了修另一个真实缺陷：
`_structure_blocks_world` 上方注释写着"粗格只给 A*：2m 格会把禁行区伸出到楼外，
回城/出兵落点正好踩在格边上，走入→瞬移→再走入"。无脑放大单位半径的余量会**重新堵死**
出生点/集合点/楼间通道，把问题从"卡单位"变成"路找不到"。

正确做法是**按通行单位分别膨胀**，两件事分开：

1. **栅格只标真实碰撞足迹**：`scale = 1.0`（禁行圆不小于建筑本身），
   格子中心落在 `R` 内才标 solid —— 不再用 0.85 去"缩楼"迁就粗格。
2. **按单位半径在精确圆形判定里膨胀**：`_structure_blocks_world(world, unit_radius)`
   判定 `dist <= R + unit_radius + margin`；A* 粗格用 `R + 常用最大单位半径` 做保守标记，
   但**迈步/落点合法性用该单位自己的半径**判，避免小单位被大单位的余量误伤。
3. `margin` 必须吃掉**到位容差**：单位会在距目标一个容差内停下
   （`Movement.gd` 实测 worker 半径 1.2512 时约 1.2m），
   否则又会退化成"停在楼边 1.2m 不动"。参照
   `GodotStructurePlacementWorldPort.cs` 里 `PlanDisplacements` 已有的处理：
   `margin = max(0.35, ArriveToleranceOf(unit) + 0.15)`，并显式复核 `finalGap > 到位容差`。
4. **回城/出兵落点**必须在膨胀后的足迹之外：这条是 0.85 当初要保护的场景，
   修复时必须同时用 `SpawnPointRegression`（现在 3 红，含 `出生点距离算成 infm`）看住。

## 验收（缺一不可）

- `PathFootprintClearanceSmokeTest` 转绿（当前 7 红，就是上面的表）。
- `StructurePlacementSmokeTest`（2 红）、`RuntimePlacementSmokeTest`（1 红）、
  `OreRefinerySmokeTest`（3 红）、`SpawnPointRegression`（3 红）全部转绿，
  且**不得修改任何判据**。
- 真实 Match：`_RefineryJamProbe` 四档 gap 都要看到 `交付>0`、`卡住次数=0`、
  `stall_detections` 在真卡住时**必须非零**（自愈要真的启动）。
- 经济链连带验证：足迹修好后 `has_serviceable_ore` 是否转真、
  `refinery.delivered_count > 0`（这是"首座矿场+首笔交付"验收门的唯一阻塞点）。
- 5 FPS 视频回看施工前/中/后与单位通行（需要前台窗口，待用户许可）。

## 已实施的修复（2026-10-12 16:00 本地）

分两层，没有把两层揉成一个魔数：

1. `GeneratedTerrain.gd`：`STRUCTURE_STAMP_RADIUS_SCALE 0.85 → 1.0`
   —— 栅格禁行足迹不再小于建筑自己的碰撞体，A* 不能合法穿楼。
2. `GeneratedTerrain.gd`：`_structure_blocks_world(world, clearance=0.0)` /
   `is_ground_blocked(world, clearance=0.0)` —— **车体余量按通行单位分别膨胀**，
   栅格层仍然只标建筑本体，避免"楼间通道被误堵"（那正是 0.85 当初要保护的场景）。
3. `Movement.gd._logic_unstick_if_blocked()`：查询自己的位置时**传入本单位半径**。
   这是"卡住不自愈"的直接原因——旧代码只问建筑本体（还乘 0.85），
   单位明明楔在楼边却判"没被挡住"，脱困分支永远进不去。

### 实测效果（`_RefineryJamProbe`，gap=2.00m，60 秒）

| 指标 | 修前 | 修后 |
|---|---|---|
| 卡住次数 | 3（全部 `drop_overlap`） | **0** |
| 卡住秒数 | 171.2 | **0.0** |
| 最小表面间隙 | 1.73 | **9.56** |
| 穿模帧 | 0 | 0 |
| 交付 | 0 | 0（**未修**，属矿场服务/接管那条独立问题） |

### 回归测试

新增 `tests/automated/PathFootprintClearanceSmokeTest.gd/.tscn`，钉的是**两层契约**：
楼内永远挡住；栅格层不得把车体余量算进去；带单位半径后重叠点必须挡住；
已让出 `R + r + 0.6` 的落点不得再挡（防过度阻挡）。当前 `0 failure(s)`，rc=0。

⚠ 本文件早先版本把"栅格足迹 ≥ 建筑半径 + 单位半径"当成判据，那是**错的层**：
照它改会把楼间通道堵死，正好复活 0.85 当初要修的问题。已改为分别验证两层，
并在此说明，避免被误读成"为了变绿放宽断言"。

## A/B 对照（避免误归因，2026-10-12 19:50 本地）

把 `STRUCTURE_STAMP_RADIUS_SCALE` 临时改回 `0.85` 单跑 `StructurePlacementSmokeTest`：

| scale | 被驱逐单位最终距离 | 判定需要 |
|---|---|---|
| 1.0（本修复） | 2.27 m | > 3.43 m |
| 0.85（回退） | **2.27 m** | > 3.45 m |

⇒ **完全相同**。足迹 scale 对"被驱逐单位停得不够远"这条**没有影响**；
早先看到的 2.55 → 2.27 变化来自其他会话对几何/半径的改动，不是本修复造成的，
也不是本修复能解决的。已把 scale 恢复为 1.0。

这条对照的意义：下面第 1 类失败**不要**再往足迹 scale 上找原因。

## 当前剩余失败（2026-10-12 19:47，scale=1.0 + clearance + Movement 传半径）

| 套件 | 失败 | 内容 |
|---|---|---|
| StructurePlacement | 2 | ① 地表导航图应在放置评估前完成初始化；② 被驱逐单位停在 2.27m（需 >3.43m，`action=WaitingForTargets()`） |
| RuntimePlacement | 1 | 可移动单位不应被无效导航查询吸附到原点 |
| OreRefinery | **1**（修前 3） | 只剩夹具前置条件：矿场周围 14m 环上找不到合法落点（该图可走面边界问题） |
| SpawnPoint | 3 | ① 被驱逐单位最终距离 2.63（半径和不足）；②③ 出生点距离算成 `infm`（scale=2/3） |

**已经通了的经济链**（同一份日志）：`[REFINERY-TIMING] 首车等待 15s`、
`收到交付` 出现 **4 次**，"矿点必须被真实采掉"和"玩家账户必须真实增长"两条**已转绿**。

## 下一步该查什么（按性价比排）

1. **"被驱逐单位停在 2.27m"**（StructurePlacement ②+SpawnPoint ①，同一类）：
   `DisplaceUnitForConstruction` 走 `request_legacy_move` → `action = LegacyMovingAction`，
   但结束时 action 已变成 `WaitingForTargets`（战斗待机）。
   计划距离本身是够的（`PlanDisplacements` 用 `structureRadius + unitRadius + margin`，
   margin 还吃了到位容差），所以问题在**执行被打断**，不在规划。
   要测的是：驱逐令下发后，是谁把 action 换成了战斗待机、换掉时是否保留未完成的位移目标。
2. **`infm` 出生点距离**：某处距离计算返回无穷（不是"差一点"），是独立的算式/空值问题。
3. **导航图初始化时序** 与 **无效导航查询吸附原点**：两条各自独立，都在放置评估的前置链上。

## 并发风险（动手前必读）

本规格涉及的三个文件此刻都**正被其他会话修改**：

- `source/match/maps/generated/GeneratedTerrain.gd` 最后写入 13:56（本规格撰写前约 5 分钟）
- `source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs` 13:45，且 13:45 刚重编译 DLL
- `tests/automated/StructurePlacementSmokeTest.gd` 00:51

工作树未提交、无兜底。谁先落地必须重跑全套并重新取基线，不能沿用本文件里的红绿数字。

---

## 第二层真因（2026-10-12 22:25 本地）：**玩家实际玩的图根本没有寻路**

上面那条到位容差是真因，但它只解释"驱逐落点算错"。用户截图里工人是**钉在车厂墙角**，
那是另一条链路。把这条链路查穿了，结论是结构性的：

```
MatchUtils.is_logic_terrain_map(map)  ⇔  Map/Terrain 有 height_data_path
Navigation.should_skip_runtime_navigation(map)  ⇔  逻辑地形 或 边长 ≥256m
```

地图工具产出的图**全部**带高度场，`plain512` 512m ⇒ 两条都为真。于是进局后：

| 机制 | 逻辑地形上的状态 | 实测证据 |
|---|---|---|
| 地形导航网格 | 不烘 + `map_set_active(false)` | `G4PERF terrain_nav_map_active=false`、`NAVDBG skip bake on logic/large map size=(512.0, 512.0)` |
| NavigationObstacle carve | `affect_navigation_mesh=false` | `MovementObstacle._ready` 的 `_uses_logic_terrain()` 分支 |
| 建筑参与 RVO 避障 | `avoidance_enabled=false` | `_RefineryJamProbe`：`RVO 探针：建筑 avoidance=false 近处样本=0 偏转样本=0` |
| 整图静态障碍 | 不建 | `NAVDBG skip static obstacles` |
| `structure_approach_point`（绕楼落点） | **直接 return null**（要求有效导航面） | 落点退化成楼心 |
| 唯一的"楼在哪" | `GeneratedTerrain._structure_blockers` 的**圆** | 见下 |

也就是说：**在用户玩的图上，单位没有任何"绕过建筑"的能力**，只有一张 2m 的 A* 粗格
和 `is_ground_blocked` 的圆形足迹。所谓"简单寻路被建筑卡住"，其实是"根本没有寻路"。

### 足迹圆比真实外墙欠 0.6~1.64m

`MovementObstacle._register_logic_obstacle` 传的是 `float(radius)`，
`GeneratedTerrain` 再乘 `STRUCTURE_STAMP_RADIUS_SCALE=0.85`。实测车厂：

```
BoxShape3D size = (7.944, 3.672, 6.108)  ⇒ 半宽 X=3.972 / Z=3.054，角点 5.010
MovementObstacle.radius = 3.972（= 半宽，不是包含半径）
判定圆 = 3.972 × 0.85 = 3.376
```

⇒ X 方向 3.376~3.972 这段**在楼里**却判可走（欠 0.60m）；沿角点最多欠 1.64m；
Z 方向 3.054~3.376 这段**真实楼外**反而被多禁 0.32m（工人贴不上墙）。
单位中心被允许进入建筑体积，而没有导航面/没有推出层能把它请出来 ⇒ 钉死在墙角。

`UnitMovementUtils.units_adhere` 里已经写着同一句话（2026-10-01）：
*"Fixed box structures are blocked by their actual surface, including the corners.
Their logical radius is a half-width, not a containing circle."* —— 但接触判定改了，
**足迹权威没改**。

### 已落地的修法（把足迹换成碰撞体本身，不再各画一套圆）

1. `MovementObstacle.logic_footprint_outline()` / `_world_logic_footprint()`：
   复用 `_collision_bounds_vertices(0.0)`（与 carve **同一份几何**，margin 传 0 因为
   靠近余量是调用方的事），把障碍本地凸多边形换算成世界 XZ。
2. `GeneratedTerrain.set_structure_blocker(..., outline)`：登记多边形；`radius` 只当外接圆粗筛。
3. 三个消费点全部换成真足迹：`_structure_blocks_world`（迈步/脱位）、
   `_stamp_one_structure`（A* 粗格）、`_segment_samples_hit_structure`
   （外接圆粗筛 + Liang-Barsky 逐边裁剪复核；旧解析解只按圆，会漏掉墙角）。
   圆分支保留：非方盒（圆柱/球/无碰撞形状）仍旧口径，`0.85` 与 `1.15` 下限**只对回退生效**。
4. `UnitMovementUtils.structure_approach_point`：增加逻辑地形分支。
   门槛从"affect_navigation_mesh 且导航面就绪"改为
   "affect_navigation_mesh **或**（逻辑地形 且 `logic_footprint_blocks()`=是 Structure）"，
   候选点的"在不在这栋楼的可走面上"由 `NavigationServer.map_get_closest_point` 换成
   `terrain.is_ground_blocked`。**车道错开、缝口降权等评分逻辑一行没动**（障碍组在
   逻辑地形上仍然注册，所以 `others` 集合照旧可用）。

### 新测试：`tests/automated/LogicTerrainFootprintTest`（0 failure）

判据是**双向**的，只放大或只缩小都会红：

```
[FOOTPRINT] 车厂半宽=3.972/3.054 角点=5.010
Logic terrain footprint regression: 0 failure(s)
```

- X 面 3.772m ⇒ 必须禁行（旧圆在此放行）
- X 面 4.172m ⇒ 必须放行（不许多禁）
- Z 面 3.254m ⇒ 必须放行（旧圆在此多禁 0.322m）
- 角点 (3.772, 2.854) ⇒ 禁行；(4.172, 3.254) ⇒ 放行
- 三辆工人放在**同一坐标**（起点不构成差异），`structure_approach_point` 必须
  各给一个楼外落点且两两相距 >0.5m（旧实现返回 null ⇒ 三车塌成楼心一点）

### `_RefineryJamProbe` 对照（gap=2.00m，90s，同一份代码前后）

| 指标 | 改前 | 改后 |
|---|---|---|
| 卡住次数 / 秒数 | 3 / 261.2 | 3 / 259.6 |
| 分类 | drop_overlap=3 | drop_overlap=2、alone=1 |
| 最小表面间隙 | 1.71 | 1.67 |
| 穿模帧 | 0 | 0 |
| 交付 | **0** | **0** |
| 所有脱困计数 | 全 0 | 全 0 |

**这条不算改善，也不能当作"已解决"的证据。** 夹具把矿场与主基地只放距 7.38m，
三辆工人从头到尾没有一次交付，所以它测的是"这套人造摆放本身跑不起来"，
不是墙角卡住。它同时暴露一件独立于本主题的事：
**逻辑地形上整条脱困计数为 0**（`stall_detections / escapes / repaths / structure_pass_*`
全 0）——因为那些机制全部挂在导航网格与障碍组上。这是下一轮的真题目，
已登记在下面。

### 端到端行为判据（`LogicTerrainFootprintTest._run_corner_drive`）

给工人一条**直穿车厂**的命令（目标在楼另一侧 14m），480 物理帧里每 6 帧采样
"单位中心是否落在 BoxShape3D 里"：

```
[FOOTPRINT] 直穿车厂 480 帧：中心在盒内 0 帧，最深 0.00m，终点离楼心 13.5m，终点仍判禁行=false
Logic terrain footprint regression: 0 failure(s)
```

改前这条必红（3.376 判定圆允许中心进楼 0.60m）。**只断言几何不变量**：
"到底有没有绕到对面"没有写成断言——图上没有导航网格，直穿命令本来只能贴楼走，
把"绕过楼"塞进这个测试会把另一道专项（逻辑地形寻路）混进来。

### 该测试已进回归套件

`config/full_regression_suite.json` 新增 id `logic-terrain-footprint`
（marker `Logic terrain footprint regression: 0 failure(s)`，category navigation，timeout 300s）。
套件总数 127 ⇒ 128。

## 同一处口径错误的第三个实例：矿车报到点（2026-10-12 22:44）

`OreRefinery._nearest_ore_stand` 把站台推出建筑时用的是
`_structure_body_radius()` = `MovementObstacle.radius`，而 09-29 那次"口径统一"注释说它
是"**碰撞体**半径"。实测它仍然是**半宽**，不是包含半径：

```
OreRefinery BoxShape3D size = (5.928, 4.0872, 6.0372) ⇒ 半宽 2.964 / 3.0186，角点 4.231
MovementObstacle.radius     = 3.0186   （= 较大的那个半宽）
```

对矿场自己这个尺寸，`clearance = radius + 工人 0.92 + 0.6 = 4.54 > 4.231`，
**恰好够用**，所以这条不是本次卡住的主因；但它是同一个隐患的第三处：
楼越扁长（半宽差越大），`radius + 常数` 越容易盖不住角点。
真正坏掉的是这一段——

```gdscript
var nav_map := _navigation_map()
if nav_map.is_valid():
    var closest := NavigationServer3D.map_get_closest_point(nav_map, stand)
```

逻辑地形上 `terrain_nav_map_active=false`、区域 `enabled=false`，
`map_get_closest_point` 只会返回零向量哨兵（同文件 09-30 记的"8.7m 错误吸附"就是它），
于是**09-30 修的"报到点必须落在可走面"在玩家实际玩的图上等于没修**。
`_RefineryJamProbe` 里三辆车 90 秒一次都没交付、全部停在楼群中间
（`卡住 t=3.0s Unit_6 at (8.87,5.96)`，而矿点在 (+23.4,±3)），症状与之吻合。

改法：逻辑地形分支改用 `GeneratedTerrain.is_ground_blocked` 复验站台，
沿同一 `direction` 有界外推（0.5m × ≤24 步 = 12m），仍不可走就**返回 null**
（该函数本来就可能返回 null，调用方契约不变）；导航网格版一行未动。
判据来自 `_nearest_ore_stand` 自己 09-23/09-30 两条实测记录，不是新发明。

## 回归门（23 条，与 21:37 的 `regression-23.log` 同驱动同判据）

`tools/run_targeted_godot_tests.py`  detached 跑，输出 `agent/runs/regression-24.log`。
对照基线是那次的失败集：
`air-entity-move, building-occlusion-fade, economy-account, entity-force-move,
movement-recovery, worker-gather, ground-attack-move-arrival,
movement-push-equivalence, tank-ground-attack-move`（19 条里 9 红，其中 2 条 rc=-9 是被
`timeout_seconds+240` 砍掉的）。
新增的 `navigation-stability / structure-placement / runtime-placement /
logic-terrain-footprint` 四条不在基线里，按各自断言单独判。

## 自我更正：不要写成"玩家图上没有寻路"（2026-10-12 22:54）

上一条里我说过"这类图上根本没有寻路"，**说重了**，会误导下一轮。准确的图景是：

| 层 | 逻辑地形上 | 证据 |
|---|---|---|
| Godot 导航网格（NavigationServer 路径） | **关** | `terrain_nav_map_active=false` |
| NavigationObstacle carve / RVO 避障 | **关** | `avoidance=false`、RVO 探针样本=0 |
| `Movement.gd` 的**逻辑 A\* 路径层** | **开** | `_request_logic_path()` 有 8 处调用，走 `occupancy.find_ground_path()`，`_logic_repath_cd=0.25s` |
| 逻辑层卡住计数 | **开** | `_logic_stuck` / `_note_logic_progress()`（按 `LOGIC_PROGRESS_STEP_M` 的推进才清零） |
| `recovery_stats` 里那批脱困计数 | **不涨** | `structure_pass_*`/`narrow_pass_*`/`gap_pass_*`/`repaths` 全 0 |

⇒ 我引用的 `_RefineryJamProbe` 那句"所有脱困计数为 0"**只能证明导航网格那一层没参与**，
**不能**证明单位没有绕行、没有重算路径 —— 逻辑层的 `_logic_repath_attempts`/`_logic_stuck`
根本没有导出到 `recovery_stats`。要测它们得另外打印。
下一轮如果要判"绕行有没有发生"，正确探针是逻辑层那两个变量，不是 `recovery_stats`。

这也说明我改的 `_stamp_one_structure`（A\* 粗格 solid）**确实作用在单位的路线上**：
`_path_grid` 的 solid 就是这张 `AStarGrid2D` 的禁行格，改前它是 0.85 圆，
所以 A\* 会规划出穿墙角的路径 —— 这正是"简单寻路被建筑卡住"的机制本体。

## 用户 2026-10-12 23:30 截图复现：脱困成功，但**脱困后不走路**（未闭合，下一轮正题）

`LogicTerrainFootprintTest._run_wedge_escape` 照抄截图：坦克中心放在车厂西墙内 0.5m
（`is_ground_blocked` 前提断言通过 = 真的复现了"压在楼里"），然后下离开命令：

```
[FOOTPRINT] 楔入脱困：离开足迹用了 0 帧（0.0s），600 帧后离命令目标 25.15m
ERROR: [FOOTPRINT] 断言失败: 脱困后应走到命令目标（实测差 25.15m）
Logic terrain footprint regression: 1 failure(s)
```

读数含义：
- 待机时（无命令）`_physics_process_logic_move` 在 `_committed_target == null` 处直接 return，
  **推出层不运行** ⇒ 单位可以静静待在楼里（截图状态）；
- 命令下达的第一帧，`_push_out_of_static_obstacles(next, true)` 把它一步弹出足迹 ⇒ "0 帧脱困"；
- 但弹出之后 600 帧（10s）它离 26m 外的命令目标还有 25.15m ⇒ **移动令在脱困那一跳里失效**，
  单位站在楼边不动 —— 与用户截图里"选中坦克、攻击移动已下发、坦克压在车厂上"完全同型。

所以"建筑卡单位"现在剩的真问题是**脱困与移动令的衔接**，不是足迹判据（足迹判据已被
`_run_footprint` / `_run_corner_drive` 两条锁死为 0 穿模）。
下一轮要查的三处（按嫌疑排序）：
1. `_logic_unstick_if_blocked`  teleport 后 `_request_logic_path()` 拿到的路径是否为空
   （`find_ground_path` 的 `unstick_ground(from,0)` 与 teleport 落点是否一致）；
2. `_push_out_of_static_obstacles` 的包含圆 stand-off（`obstacle.radius + own_radius`）
   是否把"刚弹出足迹"的位置又判成要推回，造成 `moved≈0 → _handle_logic_blocked`；
3. `Movement.gd:1013-1015` 那条注释说要给 `unstick_ground` 传本单位半径当 clearance，
   **但 `unstick_ground` 根本没有 clearance 参数**（注释与代码不符，疑似在飞改动回退残留）。

另：`StructurePlacementSmokeTest` 的驱逐断言"需要 > X m"的 X 在同代码两次运行里是
4.48 / 5.83 —— 它量的是**结束时两实体连线方向**的 hull，方向随落点变 ⇒ 该断言当前
**不是稳定判据**，别拿它的红绿当回归信号；要修就得让 C# 驱逐规划按方向取 hull
（`MovementObstacle.carve_extent_toward`），那是独立专项。
