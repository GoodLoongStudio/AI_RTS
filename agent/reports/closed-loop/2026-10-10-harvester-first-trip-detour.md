# 矿车「第一次采矿绕道并停下」回归 —— 定位与修复（隔离副本验证）

- 日期：2026-10-10
- 任务来源：用户实报「矿车第一次采矿都要绕道这里停下来」+「923 版本原本采矿没问题」
- 状态：**根因已定位、最小修复已在隔离副本实现并通过真实 Match 探针验证；尚未落库**（等用户确认 + 仓库树当前不可运行，见 §6）
- 相关任务计划/提示词：本报告 §7

## 1. 结论（先看五条）

1. **「绕道 + 停下」的直接原因是矿场的"报到"接管令**：矿场建成后每 2s 一次 claim，
   把**已经在去采矿路上**的矿车抢走，改下一条 `request_legacy_move(报到点)`。
   报到点公式是「矿点 + 背向矿场方向 × (矿半径 + 车半径 + 0.4)」⇒ **落在矿点背面**
   （实测点积 = −1.00，且车出生点→报到点的直线离矿心仅 0.37m，必须绕过矿堆）。
   这条令是**纯移动**（`Unit.gd:318-323` → `Moving.gd`），移动一结束 `action` 变 null，
   于是车原地空转，直到下一次 2s 心跳才把自动采集挂回去。
2. **923 里同样存在这条报到令**（`_build_260923/source/match/units/OreRefinery.gd:131-141`），
   但它**不会接管正在采集的车**（`:121-128` 只认 `action == null` 或 `AutoGatheringResources.gd`），
   而且 923 开局就送 2 辆矿车（`Match.gd:685-699`）、玩家/副官的采集单是
   `CollectingResourcesSequentially` ⇒ 一律不可接管。**所以 923 的车第一趟不会被拦下。**
3. **当前工作区把口子放大了两处（均未提交）**：
   ① `_is_claimable` 扩到采集三件套（`OreRefinery.gd:400-423`）；
   ② 矿场完工赠车（`:107-145`）——新车出厂是**空闲**的，而 923 的车在玩家下令后就已经在采，
   于是当前版本**每辆车的第一个任务必是报到令**（「为什么都是第一次」）。
4. **第二层缺陷（会让人以为"采矿坏了"）**：采集接近落点 `矿半径 + 车半径×0.85 = 2.36m`
   （`MovingToUnit._resource_stand_position`），而移动层的到点容差是
   `arrive_radius = max(车半径, 0.35) = 1.36m` 叠加航点容差 `LOGIC_WAYPOINT_RADIUS_M = 1.6m`
   （`Movement.gd:389/782/821/955`）。**1.36 + 2.36 = 3.72m > 贴合阈值 3.06m** ⇒
   车可以"合法地"停在贴不上的位置，`CollectingResourcesSequentially` 反复重下同一点、永远贴不上。
   实测：布局 36 某矿停在离矿心 **5.35m**，cargo 恒 0（60s）；布局 47 第二趟停在 **3.58m** 卡死。
   923 的落点是「矿点 + 朝车方向 × **矿半径**」＝**压在矿体内部**，碰撞推出层把车顶在
   `矿半径+车半径`，最坏情况仍在贴合阈值内 ⇒ 从不失败。**这是"923 能采、当前采不到"的真身。**
5. **修复口径（3 处，全部对齐 923）**：矿场只接管**空闲**车；赠车**立刻点火自选采集**；
   接近落点改回**以车来向为基准 + 压在矿半径内**且**缓存**世界落点（禁止逐帧重算）。
   验证：布局 47 第一次采集 t=3.0s、**首次交付 8.3s**（修复前 11.7s）、
   连续 6 次交付/58s 无卡死，且矿场日志不再出现报到接管。

## 2. 基线（修复前，真实 Match 探针）

| 场景 | 现象 | 证据 |
|---|---|---|
| 当前工作区·布局 47（矿场赠车 → 第一次采矿） | t=2.0 矿场下报到令，把车从自选矿改派到**另一颗矿背面**；t=5.0 到位 1.86m；首次交付 11.7s；之后 7 次交付/70s | `agent/runs/first-trip-detour-b/probe.freeze.log` |
| 当前工作区·布局 36（不放矿场，纯自动采集） | 车停在离矿心 **5.35m** 来回抖 ±0.35m，**60s 内 cargo 恒 0（采不到）** | `probe.gonly.log` |
| 当前工作区·布局 36（矿场赠车） | t=1.7 报到令 → 目标在矿背面；车停在离矿心 **4.3m** 处抖动 150s，`delivered=0` | `probe.run1.log` |
| **923 发布分支·布局 36（同图同矿同方向）** | t≈2s 贴到 **1.70m**（=贴合阈值）→ `[GATHER] 到达资源点, 开始采集` → t≈4s **满载 400** | `probe.923-near.log` |
| 923 发布分支·布局 36（远距离出生） | 车原地不动（923 自动采集搜索半径只有 30m，矿在 34.5m 外） | `probe.923-gonly.log` |

923 基准工作区：`G:\AIRTS\临时文件夹\_build_260923`（分支 `build-260923-release`，HEAD `738d139`，工作区干净）。
隔离运行副本（不改任何仓库文件）：`G:\AIRTS\tmp_ftd_probe`（当前工作区源码 + **仅一行** Movement.gd 解析修正，见 §6）、
`G:\AIRTS\tmp_923_probe`（923 源码 + 从主工程复制的布局 36 地图）。

## 3. 修复内容（隔离副本内）

### 3.1 `source/match/units/OreRefinery.gd`
- 新增 `const CLAIMABLE_ACTIONS := []`，`_is_claimable()` 改为「只接管空闲车」；
  `GATHERING_ACTIONS` 保留不动（它管"在册工人要不要留名额"，与接管是两件事）。
- `_grant_free_miner()`：出生信号之后 `miner.call_deferred("request_legacy_start_auto_gather")`，
  让赠车**立刻**进入自选采集（赠车走 GDScript 出生链路，不经过 C# 生产命令，
  拿不到"默认侵略姿态"⇒ 不点火就会一直空闲，只能等矿场派报到令）。

### 3.2 `source/match/units/actions/MovingToUnit.gd`
- `_resource_stand_position()`：落点方向改为**以车自己的来向为基准**（同矿多车 ±35° 车道错开），
  取代原来的**世界轴四象限** `approach_slot(unit) % 4 * 90°`（与车从哪侧来无关 ⇒ 绕道）。
- 落点距离改回 `矿半径`（923 口径，压在矿体内），取代 `矿半径 + 车半径×0.85`（见 §1 第 4 条）。
- 落点**缓存**（`_stand_cache`）：本方法在 `_ready()` 与 `_on_movement_finished()`（未贴合重下）
  两处被调用，逐帧按"车当前位置"重算会让落点跟着车转 ⇒ 目标抖、永远贴不上
  （实测：车卡在离矿心 1.92m 处每帧重建 `MOVING_TO_RESOURCE`）。

回滚方式：三处各自是独立小块，逐个还原即回到修复前；`CLAIMABLE_ACTIONS` 恢复成
`GATHERING_ACTIONS` 即可回到"采集三件套都可接管"。

## 4. 验证（修复后，真实 Match 探针）

命令（隔离副本）：

```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 9000 res://tools/probe_harvest_loop_gen.tscn -- --debugport 24688
```

| 判据 | 修复前 | 修复后 |
|---|---|---|
| 赠车后是否空闲等指派 | 空闲 1.7s，随后被报到令接管 | **t=0 即自选采集**（`AutoGatheringResources`） |
| 矿场是否下报到令 | 是（`[REFINERY] 指派工人 … ore=(267.8,112.2)`） | **否**（`在册=0/4 无可接管工人…忙={AutoGatheringResources.gd: 1}`） |
| 第一次开始采集 | t=5.0s（且被改派到另一颗矿背面） | **t=3.0s**（车自己选的矿，未绕行） |
| 首次交付 | 11.7s | **8.3s** |
| 连续吞吐 | 7 次/70s | 6 次/58s（≈10s/趟，无卡死、无 `[FREEZE]`、无自愈刷屏） |
| SCRIPT ERROR | — | **0** |

日志：`probe.patched4-map47.log`（本报告主证据）、`probe.patched3-map47.log`（C2 之前的中间态，
用于定位"到点容差 > 贴合余量"这条因果）。

## 5. 未解决 / 未验证项

1. **布局 36 上"贴崖矿点"仍采不到（属移动层，不在本次矿车语义修复范围）**：第 3 轮已定位到证据级。
   - 现象：车开到离目标矿 **8.52m** 处停住不动（`committed target` 离车仅 1.04m）、`units_adhere` 恒假、
     cargo 恒 0；`[DIG]` 探针给出根因——**该矿点所在的逻辑地形占用格是 solid**
     （`is_ground_blocked(矿点)=true`，而车与 committed 落点都是 `false`），
     移动层于是把目标钳到最近可走处（钳掉约 7~8.5m），车永远进不了 3.06m 的贴合圈。
   - 对照：**923 发布分支在同一张图、同一颗矿、同一来向能开到 1.70m 并采满 400**
     （`probe.923-near.log`），说明 923 的移动层不把这种矿点判成不可达。
   - 结构原因（数值）：当前半径口径下车半径 1.36、矿半径 1.2 ⇒ 可站带 = [2.56m, 3.06m]，**只有 0.5m 宽**；
     而移动层到点容差 `max(车半径,0.35)=1.36m`、逻辑航点容差 1.6m、粗格 1.98m ⇒ 靠"走到点上"落进这条带子是碰运气。
   - **试过的缓解（补丁 D，已回滚）**：在 `AutoGatheringResources._is_available_resource` 里按贴合距离
     环采 8 点、跳过"站着也够不到"的矿。实测只把停车距离从 8.52m 改善到 **4.08~4.49m**（仍在 3.06m 外，
     仍不采集），且会改变选矿策略 ⇒ **不采纳**，已从隔离副本回滚（`AutoGatheringResources.gd` 与仓库现状一致）。
   - 建议归属：移动层任务（`source/match/units/traits/Movement.gd` + `GeneratedTerrain` 占用格），
     与当前未提交的"窄缝穿模/逻辑地形 A*"WIP 同源；可选修法：
     ① 采集目标不要被钳离矿点（让推出层决定最终落位）；② 收紧采集接近的到点容差（≤0.3m）；
     ③ 放宽采集贴合带（`ADHERENCE_MARGIN_M` 或按矿点半径给固定 slack）；④ 占用格不把矿点格判成 solid。
2. **仓库树内的回归套件没跑**（§6 阻塞）：第 3 轮改在**隔离副本**里跑，见 §7，结论是"与修复前逐条一致"。
3. 30m 服务半径/搜索半径是否恢复**未定**：923 有（30m），当前无（无半径 / 4096），
   属设计口径，需用户拍板；本修复未动。
4. 多车同矿、玩家右键采集单与矿场接管的交互**未做专门用例**（现有套件未覆盖该组合）。

## 6. 环境阻塞（必须记录）

- **仓库工作树当前无法启动**：`source/match/units/traits/Movement.gd:2609`
  是另一路**未提交 WIP** 引入的非法 GDScript
  （`var who := _unit.name if _unit != null else "?"`，Variant 推断报错），
  整个工程加载脚本即失败。**本报告全程没有修改仓库里的任何文件**；
  为跑探针，隔离副本里把这一行改成等价的 `var who: String = str(_unit.name) if _unit != null else "?"`。
- 因此 §4 的验证都在隔离副本内完成；**落库需要用户确认**（会碰到上面这份 WIP 文件所在的工作树）。

## 7. 第 3 轮补充：相关回归 A/B（隔离副本内完成）

仓库树因 §6 无法启动，因此建了两个隔离工程做 A/B：
`G:\AIRTS\tmp_ftd_base`（当前工作区源码）与 `G:\AIRTS\tmp_ftd_probe`（本轮修复），
两者都只做了同一行 `Movement.gd:2609` 等价修正。脚本：
`agent/runs/first-trip-detour-b/run_regression_ab.ps1`，日志：
`agent/runs/first-trip-detour-b/regression/{base,patched}-<套件>.log`。

| 套件 | base（修复前） | patched（修复后） |
|---|---|---|
| OreRefinerySmokeTest | rc=0，**0 failure** | rc=0，**0 failure** |
| RefineryFreeMinerSmokeTest | rc=0，0 failure | rc=0，0 failure |
| WorkerGatherSmokeTest | rc=1，**2 failure**（既有红） | rc=1，**2 failure（逐条相同）** |
| WorkerDeliveryRefineryOnlyTest | rc=0 | rc=0 |
| VehicleFactoryWorkerProductionSmokeTest | rc=0，0 failure | rc=0，0 failure |

- **逐条一致 ⇒ 本轮修复没有引入回归**；尤其 `OreRefinerySmokeTest` 仍 0 failure，
  说明"接管只针对空闲车"没有破坏既有的矿场接管用例。
- `WorkerGatherSmokeTest` 的 2 条红是**既有失败**（base 同红），断言内容是
  「耗尽后的最后交付应完成订单」「资源耗尽并交付后 Worker 应待机、不得自动寻找新矿」——
  属"矿点耗尽/待机语义"，与本次修复无关，**未改判据、未改断言**。

## 8. 第 3 轮补充：残余缺陷的取证命令

```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
# 深挖探针：打印动作目标矿 / 到矿距离 / 贴合判定 / committed 落点 / 占用格判定
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 3000 res://agent/runs/first-trip-detour-b/_GatherDigProbe.tscn -- --debugport 24691
```

关键输出（布局 36，修复后）：

```
[DIG] t=  3.2 act=AutoGatheringResources.gd sub=CollectingResourcesSequentially.gd ore=ResourceA2 dOre= 8.52 adhere=false dCommitted= 1.04
[DIG]      占用格: 车=false 目标矿=true 落点(committed)=false
```

日志：`probe.dig2-map36.log`（≈8.5m 停住）、`probe.patched5-map36.log`（补丁 D 实验：≈4.1m，仍不采）。

## 9. 第 4 轮补充：实验 E 与版本漂移

### 9.1 实验 E（逻辑地形 A* 复核选矿）——不采纳，已回滚

- 动机：布局 36 的贴崖矿点 `is_ground_blocked(矿点)=true`，移动层把目标钳到 8.5m 外，车永远贴不上。
- 做法：在 `AutoGatheringResources` 选矿阶段用逻辑地形的 `find_ground_path(from, to)` 复核
  "路径末点是否落在贴合距离内"，按距离就近取第一颗走得到的矿。
  **API 位置**：占用格对象挂在 Map 节点的 `water_occupancy` meta 上（与
  `MovementObstacle._logic_occupancy()` 同源），**不是** Map 节点自身 —— 第一次实现时踩过这一点
  （挂在 Map 节点上拿不到方法，过滤器静默失效）。
- 结果：过滤器确实生效（目标矿由 ResourceA2 换成 ResourceA），但车仍在离矿心 **4.01m** 处停住
  （`adhere=false`，阈值 3.06m；committed 目标离车 3.18m），**仍不采集**。
- 结论：**选矿侧兜底解决不了"停不到贴合距离"**，整段回滚（`AutoGatheringResources.gd`
  现与仓库版本逐字节一致）。残余缺陷定位在**移动层的到点判定/目标钳制**：
  同一颗矿、同一来向，923 分支能开到 1.70m 并采满 400。
- 证据：`probe.patchedE-map36.log`（过滤器未生效）、`probe.patchedE2-map36.log`（修好 API 位置后：换矿但仍停在 4.01m）。

### 9.2 版本漂移（落库前必读）

| 文件 | 仓库 mtime | 隔离副本 mtime | 影响 |
|---|---|---|---|
| `source/match/units/OreRefinery.gd` | 10-09 16:01:59 | 10-10 00:18（我改） | 仓库版本自副本建立后未变 ⇒ `.patch` 可直接应用 |
| `source/match/units/actions/MovingToUnit.gd` | 10-09 21:02:34 | 10-10 10:07（我改） | 同上 |
| `source/match/units/traits/Movement.gd` | **10-09 23:37:50** | 10-09 23:36:07 | **副本比仓库少 11 行**（另一路 23:37 新增 `_plant_ground_visual()`、`reset_physics_interpolation()`、`kept_scale`）⇒ 全部探针基于 23:36 版移动层 |

- 仓库 `Movement.gd:2609` 目前**仍是非法行**（`var who := _unit.name …`）⇒ 工作树仍无法启动，§6 阻塞仍然有效。
- 因此：本报告结论对**采集链路**（我改的两个文件 + 矿场判据）有效；对移动层行为的描述基于 23:36 版，
  落库/复核时若移动层已更新，需在新版上重跑 §4/§7 的探针与套件。

## 10. 第 5 轮补充：实验 F（地形感知采集范围）与矿点可达性实测

### 10.1 实验 F —— 不采纳，已回滚

思路：给采集链路一个"地形感知的够得着"判定（常规贴合 → 既有宽限 → **按逻辑地形最近可走点距离放行**），
落在 4 个文件：`UnitMovementUtils.units_can_collect/_reachable_stand_distance`、
`MovingToUnit._process/_on_movement_finished`、`CollectingResourcesSequentially` 的到达闸门、
`CollectingResourcesWhileInRange` 的采集 tick 闸门。

实测（布局 36，`probe.patchedF-map36.log` + `probe.dig3-map36.log`）：**无效**，因为放行所需的距离是荒谬的——
`ResourceA2` 的最近可走点距离 `reach=7.89m`，车停在 8.52m ⇒ 要让它"够得着"就得允许**从 8.5m 外采矿**
（边界距 ≈6m），玩法上不可接受。**整段回滚**（4 个文件均与仓库现状逐字节一致）。

### 10.2 矿点可达性实测（本轮最有价值的交接证据）

`agent/runs/first-trip-detour-b/probe.reach-map36.log`（布局 36 出生点最近的 4 颗矿）：

| # | 矿点 | 距出生点 | 最近可走点距离 `reach` | 矿点占用格 | 判定 |
|---|---|---|---|---|---|
| 0 | ResourceA2 | 33.65m | **7.89m** | **solid** | **矿点落在不可走地形上**（任何地面矿车都够不到） |
| 1 | ResourceA | 34.51m | **0.40m** | solid | 本身可达（可站到矿点旁 0.4m），**但移动层把车停在 4.01m 外** |
| 2 | ResourceA25 | 50.09m | 0.00m | 可走 | 正常 |
| 3 | ResourceA20 | 69.07m | 0.00m | 可走 | 正常 |

结论（本轮定性）：
1. **采集侧没有正确的阈值可用**：对 #0 只能靠"从 8.5m 外采"（不可接受），对 #1 车根本没走到可达位置
   ⇒ 任何采集侧兜底（实验 D/E/F 三种）都是错的。
2. 残余缺陷归**两处上游**：
   - **移动层执行**：#1 的 `reach=0.40m` 说明路是通的，但车停 4.01m 外（`committed` 距车 3.18m）——
     属移动层的到点判定/末段推进（未提交的移动层 WIP）。
   - **地图/矿点放置**：#0 落在 solid 格上（`is_ground_blocked(矿点)=true`、`reach=7.89m`），
     生成器不应把资源放在不可走格（或应把该格 stamp 成可走）。
3. 两个正常矿点（#2/#3）说明链路本身没坏——只是近处这两颗矿一颗放错、一颗走不到。

### 10.3 回滚后的复验（防止实验残留污染已验证状态）

- 逐文件比对：`UnitMovementUtils.gd` / `CollectingResourcesSequentially.gd` /
  `CollectingResourcesWhileInRange.gd` / `AutoGatheringResources.gd` 与仓库**逐字节一致**；
  仅 `OreRefinery.gd`、`MovingToUnit.gd` 保留 A/B/C 修复。
- 重跑布局 47 采集链（`probe.patchedABC-recheck-map47.log`）：赠车即自采、矿场不下报到令、
  **t=3.0s 开始采集、首次交付 8.3s**、随后正常往返 —— 与 §4 的结论一致。

## 11. 第 6 轮补充：多车 + 玩家式采集单复验（补上覆盖缺口）

场景（布局 47，真实 Match）：矿场完工赠车（Unit_3），再在旁生成 Unit_4，
两辆车对**同一颗矿**下 `request_legacy_gather`（与玩家右键采集在本地是同一个动作入口）。
探针：`agent/runs/first-trip-detour-b/_MultiWorkerProbe47.gd`，日志 `probe.multi-map47.log`。

| 断言 | 结果 |
|---|---|
| 矿场**不再接管已下采集单的车** | 全程 `assigned=0`；`[REFINERY-CLAIM] … 无可接管工人：工人=2 已被占用=0 冷却=0 忙={CollectingResourcesSequentially.gd: 2}`；`指派工人` 行 **0 次** |
| 同一颗矿两辆车都能贴上并采集 | t=4.2 两车同时 `adhere=true`（dOre **3.01 / 3.02**，阈值 3.06），cargo 264 / 336 → 立刻 400 / 400（修复 C 的 ±35° 车道生效） |
| 产出节奏 | 15s 内 **4 次交付**（累计 2000 矿），首交 **7.0s**（单车主基线 11.7s） |
| 稳定性 | **0 SCRIPT ERROR**，无长时卡死 |

对照意义：修复前 `_is_claimable` 把 `CollectingResourcesSequentially` 视为可接管 ⇒
这两张玩家采集单会被矿场顶成"到矿点背面报到"的**纯移动令**（正是用户报的"绕道 + 停下"）。

说明：探针设的 40s 轨迹被 `--quit-after` 帧预算掐断（日志尾部没有 `RESULT` 汇总行），
但上表所有关键行都在日志里；不影响结论。

## 12. 第 7 轮补充：移动层残余缺陷的**最小复现夹具**（可直接交接）

夹具：`agent/runs/first-trip-detour-b/_StopShortProbe.tscn`（脚本 `_StopShortProbe.gd`，**零游戏逻辑改动**）。
单车 + 单矿 + 显式采集单，逐 0.2s 打印采集目标、`adhere`、`committed target`、以及移动层内部状态
（`_logic_path/_logic_path_i/_logic_stuck/_logic_repath_attempts/_recovery_mode`）与占用格判定，
并在"位置冻结 ≥1.6s 且未贴合"时转储一次 `[STOP][FREEZE]`。

```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
$env:DSH_PROBE_MAP='36'   # 或 '47'：同一份脚本换图对照
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 5000 res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn -- --debugport 24701
```

**判"修好"的标准**：出现 `[STOP][COLLECT]` 且 cargo 增长；`[STOP][FREEZE]` 不再出现，或出现时 `dOre ≤ 3.06`。

### 12.1 两图对照（同一夹具、同一口径）

| 观测 | 布局 36（失败） | 布局 47（正常） |
|---|---|---|
| 目标矿 | ResourceA `(33.54,246.45)` | ResourceA2 `(264.52,131.80)` |
| 矿点占用格 / 最近可站距离 | **solid** / **0.40m** | 可走 / 0.00m |
| `project_ground(矿)` | `(33.54, **2.699**, 246.45)` | — |
| **committed target** | `(34.134, **4.763**, 245.405)` | `(263.383, **2.368**, 132.172)` |
| raw target | `(34.134, **2.699**, 245.405)` | — |
| 结果 | 停在 `dOre=4.09~4.50`、`adhere=false`、**cargo 恒 0**（45s） | `dOre=2.72`、`adhere=true`、**开始采集（cargo 96↑）** |
| 移动层状态（冻结时） | `logic_path size=1 i=0`、**`stuck=1`**、**`repath_attempts=0`**、`rec=""` | 未冻结 |

### 12.2 交给移动层的两条硬结论

1. **committed target 被抬高了 2.07m**：raw 目标 `y=2.699`（= 矿点自身/地面高度，`project_ground` 同值），
   而 committed 目标 `y=4.763`。XZ 只差 0.6m。车因此停在 4.09~4.50m 外，永远进不了 3.06m 的贴合圈。
   对照布局 47（正常样本）committed `y=2.368` 与地面一致 —— 怀疑是"目标落到 solid 格/斜坡时的
   地面高度取样或 clamp"分支出的问题，请优先看这条。
2. **卡住后不重试**：`_logic_stuck=1` 而 `_logic_repath_attempts=0`、`_recovery_mode=""` ——
   末段航点消费不掉时没有任何 repath/unstick 兜底，于是永久站桩（45s 无位移、无状态迁移）。

日志：`probe.stopshort-map36.log`（失败）、`probe.stopshort-map47.log`（对照）。

## 13. 第 8 轮补充：第二批回归 A/B（经济/生产/规则AI）与交接件

### 13.1 第二批 A/B（5 个套件，脚本 `run_regression_ab2.ps1`，日志 `regression/ab2-*.log`）

| 套件 | base（修复前） | patched（修复后） | 说明 |
|---|---|---|---|
| EconomyAccountSmokeTest | rc=1，**2 failure** | rc=1，**2 failure** | 既有红，逐条相同 |
| ProductionQueueSmokeTest | rc=0，0 failure | rc=0，0 failure | — |
| RallyPointSmokeTest | rc=0，0 failure | rc=0，0 failure | — |
| **RuleAiEconomyQuerySmokeTest** | rc=1，**1 failure** | rc=0，**0 failure** | base 失败断言原文：`FAIL: EconomyController 刷新后仍应保留暂停的 Gather，不得自动恢复`；patched 不再出现 |
| WorkerEngagementPolicySmokeTest | rc=0，0 failure | rc=0，0 failure | — |

- 累计 A/B 覆盖 **10 个套件**：9 个逐条一致（含 3 个既有红），1 个（RuleAi）由红转绿。
- **关于 RuleAi 那条：我没有改任何测试或断言**，也**不主张**这是"修好了 AI 经济刷新语义"——
  更可能是修复 B（赠车立刻点火自采）改变了用例的时序，使原本暴露竞态的顺序不再出现。
  按仓库约定（"不要把测试判绿当修复"）如实记录，若要定论需单独复跑多次确认稳定性。

### 13.2 交接件（本任务外延，已落盘）

- 计划：`agent/plans/2026-10-10-movement-stop-short-plan.md`
  （现象、一键复现、两条硬结论、验收判据、采集侧三条已证伪兜底的"不要做"清单、资源放错格的姊妹任务）
- 提示词：`agent/prompts/2026-10-10-movement-stop-short.md`
  （自包含：环境事实 / 隔离副本 / 复现命令 / 判据 / 边界 / 交付格式）
- 夹具：`agent/runs/first-trip-detour-b/_StopShortProbe.tscn`（`$env:DSH_PROBE_MAP` 切图）

## 14. 第 9 轮补充：`RuleAiEconomyQuerySmokeTest` 由红转绿的稳定性与机制

### 14.1 稳定性（各跑 3 次，脚本 `run_stability_ruleai.ps1`）

| 轮次 | base | patched |
|---|---|---|
| #1 | rc=1，1 failure | rc=0，0 failure |
| #2 | rc=0，0 failure | rc=0，0 failure |
| #3 | rc=1，1 failure | rc=0，0 failure |
| 汇总 | **2/3 红（不稳定）** | **3/3 绿** |

失败断言原文（仅出现在 base）：`FAIL: EconomyController 刷新后仍应保留暂停的 Gather，不得自动恢复`

### 14.2 机制（日志行号相关性，非猜测）

`RuleAiEconomyQuerySmokeTest` 的流程是：找 AI 的采集 Worker → `StopUnits` 让 Gather 进入暂停
→ 刷新后断言**暂停的 Gather 仍然存在且仍处于暂停态**。

| 日志 | `[REFINERY] 指派工人` 次数 | FAIL 位置 | 结果 |
|---|---|---|---|
| base run1 | **3 次**（Unit_3 / Unit_7 / Unit_6，行 282~284） | 行 288（**紧跟在三次指派之后**） | 红 |
| base run2 | 1 次（仅空闲的赠车 Unit_3） | 无 | 绿 |
| patched run1 | 1 次（仅空闲的赠车 Unit_3） | 无 | 绿 |

- 相关性明确：**base 多出来的那两次指派（正被 AI 用来采集的 Worker）** 出现在失败之前；
  矿场的"报到"接管令是 `request_legacy_move`，会**直接替换掉 Worker 当前的 action**
  （`Unit.gd:318-323`）⇒ 被暂停的 Gather 动作被顶掉、`is_task_suspended()` 断言随之失败。
- 修复 A（矿场只接管**空闲**车）正好去掉这两次指派 ⇒ patched 3/3 绿。
- 结论：这条既有红与本用户报的"第一次采矿被矿场顶掉"**是同一个根因**；本修复顺带消除它。
  （仍如实标注：断言原文说的是"不得自动恢复"，而实际机制是"被接管令替换"；两者可观察结果一致。）

## 15. 第 10 轮补充：修复 ↔ 923 语义对照、影响面审计、交付场景 A/B

### 15.1 逐条语义对照（落库评审用）

| 补丁 | 本次改动 | 923 发布分支的对应行为 | 影响面 | 验证出处 |
|---|---|---|---|---|
| A | `OreRefinery._is_claimable` 只接管**空闲**车（`CLAIMABLE_ACTIONS := []`） | 923 `:121-128` 只认 `action==null` 或 `AutoGatheringResources.gd`；**我们比 923 更严**（连"正在自选寻路"也不抢） | 只有矿场接管这一条路径；节奏仍是每 `claim_interval_s`=2s、容量 4 | §4、§11、§13.1、§14 |
| B | `_grant_free_miner()` 出生后 `call_deferred("request_legacy_start_auto_gather")` | 923 **没有赠车**（开局直接送 2 辆，靠玩家/副官采集单或矿场重挂）。等价的观感是"新车出厂即带采集意图" | 仅"矿场完工赠送的那一辆" | §4（t=0 即自采）、§11 |
| C | `MovingToUnit._resource_stand_position`：以车来向为基准 ±35° 车道、落点压进矿半径、**缓存**世界落点 | 923 `:20-26` = `矿点 + normalize(车−矿点) × 矿半径`（无车道、无缓存；车道是当前版本为"同矿多车不挤"新增的，故保留但改为相对来向） | **仅 `resource_units` 目标**（静态审计见 §15.2） | §4、§11（两车同矿均 `adhere=true`） |
| 附 | `Movement.gd:2609` 一行类型标注等价修正 | —（**不是修复**，只为让工程能启动） | 无行为变化 | 所有探针的能跑前提 |

### 15.2 影响面静态审计（`MovingToUnit`）

- `_resource_stand_position()` **只**在两个 `elif _target_unit.is_in_group("resource_units")` 分支被调用
  （`MovingToUnit.gd:24-26`、`:63-64`）；`_stand_cache` 只在该函数内读写。
- `MovingToUnit` 的其它使用方：**交付**（`CollectingResourcesSequentially._start_drop_move` →
  `MovingToUnit.new(_cc_unit)`，目标是 Structure）、**施工**（`Constructing.gd:51`）、
  **跟随**（`Following.gd:51`）、**通用靠近**（`Unit.gd:328-331`）。
  这些目标都不是 `resource_units`，仍走 `structure_approach_point` / else 分支 —— **与修复前逐字节相同**。
- 实验 F 的 `_reached_target` 放宽已回滚，`units_adhere` 判定保持原语义。

### 15.3 交付 / 矿场拥堵场景 A/B（`tests/automated/_RefineryJamProbe.tscn`）

| 观测 | base | patched |
|---|---|---|
| 交付次数 | 15 | 17 |
| FAIL / SCRIPT ERROR | 0 / 0 | 0 / 0 |
| 拥堵诊断 `[JAM] 卡住` | 有（该夹具本就是观测拥堵用，非断言） | 同类、量级相当 |

⇒ **交付链路无回归**，吞吐不降。日志：`regression/jam-base.log`、`regression/jam-patched.log`。

## 16. 第 11 轮补充：3 车同矿验证 + 落库防漂移自检（并因此修掉了补丁自身的两个缺陷）

### 16.1 3 车同矿（布局 47，`$env:DSH_PROBE_WORKERS=2` ⇒ 共 3 辆，全部下玩家式采集单）

| 观测 | 结果 |
|---|---|
| 矿场接管 | 全程 `assigned=0`；`无可接管工人：工人=3 已被占用=0 忙={CollectingResourcesSequentially.gd: 3}` |
| 三车同时贴合 | t=4.2 三车全部 `adhere=true`，dOre = **2.68 / 2.80 / 3.01**（修复 C 的 ±35° 来向车道在 3 车时仍成立） |
| 产出 | 三车均采满 400；**首次交付 6.9s**；~16s 内 6 次交付（3000 矿） |
| 稳定性 | 0 SCRIPT ERROR |

日志：`probe.multi3-map47.log`。

### 16.2 防漂移自检脚本（本轮的"工具"产出）

`agent/runs/first-trip-detour-b/check_patch_drift.ps1`：一条命令做四件事 ——
① `git apply --check`；② 逐文件打印仓库/隔离副本 sha 与 +/− 行数；
③ **把补丁真应用到临时副本，再与隔离副本逐字节比**（忽略行尾差异）；
④ 报告 `Movement.gd:2609` 阻塞是否仍在。当前输出结论：**可落库**。

### 16.3 它当场抓出的补丁自身两个缺陷（已修）

1. **绝对路径**：上一版补丁是用 `git diff --no-index <绝对路径> <绝对路径>` 生成的，
   头部是 `a/G:\AIRTS\AI_RTS\...` ⇒ `git apply --check` 直接 `error: invalid path`，**根本落不了库**。
   现改为"临时 git 仓库里生成相对路径补丁"（`a/source/...`）。
2. **编码往返**：用 PowerShell 字符串拼接 + `Set-Content` 写补丁，会让中文上下文行在
   `git` → PowerShell → 文件 的往返里被改写，`git apply` 报 `patch does not apply`。
   现改为 `cmd /c "git … diff > patch"`，**由 git 直接写文件**，不再经过 PowerShell 字符串。

修完后核对：`git apply --check` **PASS**；把补丁应用到临时副本后与隔离副本
**逐字节一致**（`OreRefinery.gd 39D5509304C8`、`MovingToUnit.gd 5C9DB353BFDC`；
仅行尾差异，因本仓库 `core.autocrlf=true` 而 `.gitattributes` 规定 `*.gd eol=lf`，仓库内落地为 LF）。

顺带修正：补丁现在**只含我的两个文件**；`Movement.gd:2609` 的一行等价修正**不属于补丁**，
按落库清单第 2 步单独手工执行（它只为让工程能启动，不是修复）。

## 17. 第 12 轮补充：**落库演练全链路**（落库 → 验收 → 回滚，真实跑过一遍）

脚本：`agent/runs/first-trip-detour-b/run_port_rehearsal.ps1`（在 `G:\AIRTS\tmp_ftd_base`
——即"仓库原文 + `Movement.gd:2609` 一行解阻塞"的副本——上执行；**不改仓库**）。
输出：`agent/runs/first-trip-detour-b/rehearsal/summary.log` 与同目录各套件日志。

| 步骤 | 命令（与真实仓库将执行的一致） | 实测结果 |
|---|---|---|
| 1. 记录回滚基准 | `Get-FileHash` × 2 | `OreRefinery.gd=237CCEFD110E`、`MovingToUnit.gd=1DDC1C944871` |
| 2. 落库 | `git apply <patch>` | **rc=0** |
| 3. 落库后内容比对 | 与已验证副本逐字比（忽略行尾） | 两文件**内容一致**（= 已验证状态） |
| 4. 关键套件 | `OreRefinerySmokeTest` / `RefineryFreeMinerSmokeTest` / `RuleAiEconomyQuerySmokeTest` | **rc=0 / 0 failure** × 3 |
| 5. 采集链探针（布局 47） | `probe_harvest_loop_gen` | **首次交付 8.3s**；`[REFINERY] 指派工人` **0 行**（不再被接管） |
| 6. 3 车同矿探针 | `_MultiWorkerProbe47`（`DSH_PROBE_WORKERS=2`） | `adhere=true` 采样 3（三车同拍贴合）、`assigned=0` 采样 9、交付 **6 次** |
| 7. 回滚 | `git apply -R <patch>` | **rc=0**，两文件 sha 回到基准（`237CCEFD110E` / `1DDC1C944871`） |

结论：**"落库 → 验收 → 回滚"整条链路已验证可执行**；用户点头后照抄
`agent/checklists/2026-10-10-harvester-port-checklist.md` 即可，无需再试错。

注：演练目录不是 git 仓库、不读 worktree 属性，`git apply` 会把 `MovingToUnit.gd` 写成 CRLF；
真实仓库有 `.gitattributes`（`*.gd text eol=lf`）故落地为 LF（与已验证副本逐字节一致）。
这属于**行尾差异**，内容与行为一致（第 3 步按忽略行尾比对为"一致"）。

## 18. 结项状态（第 12 轮）

- **已完成并在真实 Match 上验证**：根因（矿场"报到"接管令 + 采集接近落点的几何/到点容差）→ 最小修复 A/B/C →
  单车首交 8.3s、双车 7.0s、**三车 6.9s**（均无接管、无 SCRIPT ERROR）→ 10 个套件 A/B + 1 个套件稳定性复跑
  （3/3 绿，且定位到机制）→ 交付/拥堵场景 A/B → 三条采集侧兜底实验（D/E/F）全部证伪并回滚 →
  影响面静态审计 → 补丁可落库（自检 + 演练）。
- **交付物**：本报告；`.patch`（2 文件，可干净应用）；`agent/checklists/2026-10-10-harvester-port-checklist.md`；
  `agent/runs/first-trip-detour-b/check_patch_drift.ps1`（防漂移）、`run_port_rehearsal.ps1`（落库演练）、
  `_StopShortProbe`/`_GatherDigProbe`/`_MultiWorkerProbe47`（探针）、`regression/*`（A/B 日志）。
- **仍待用户决策（唯一阻塞）**：① 是否落库；② 是否允许修 `Movement.gd:2609`（他人 WIP 的一行，不修则工程起不来）；
  ③ 是否恢复 923 的 30m 选矿/搜索半径（设计口径，本修复未动）。
- **不属于本次但已备好交接件**：移动层末段推进（`plans/2026-10-10-movement-stop-short-plan.md` +
  `prompts/2026-10-10-movement-stop-short.md` + 夹具）；资源被放在 solid 格（同计划 §6）。
## 19. 已落库（2026-10-10，用户授权后）

用户答复：**① 落库 ② 允许 ③ 不恢复 30m 半径**。落库过程与验收见
`agent/reports/closed-loop/2026-10-10-harvester-landing-record.md`，要点：

- **落库时发现 A、B 已被并行会话自己实现**（`OreRefinery.gd:147` 赠车点火、`:411/:430` `CLAIMABLE_ACTIONS` 只认空闲车，
  语义与我方案一致），且用户授权修的 `Movement.gd:2609` **也已被他们改好**；
  `Movement.gd` 修好后仓库树恢复正常启动。
- 因此实际落库的是 **patch C**：`MovingToUnit.gd`（+37/−8）。
  `git apply --check`/`git apply` 均 rc=0；落库后 sha **`54869ADBC57D`**，与隔离副本已验证版本**逐字节一致**。
- **真实仓库树验收**：采集链首交 **8.3s**、`指派工人` 0 行；3 车同矿三车同拍 `adhere=true`、`assigned=0`、交付 6 次；
  `OreRefinerySmokeTest`/`RefineryFreeMinerSmokeTest`/`RuleAiEconomyQuerySmokeTest` 全部 **0 failure**；
  `WorkerGatherSmokeTest` 2 failure（既有红，与落库前逐条相同）；SCRIPT_ERROR 0。
- **回滚**（只回滚我这次落的 C，A/B 属于并行会话，不要动）：
  `git apply -R agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour-C-only.patch`
- 未做：未提交任何 commit；未恢复 30m 半径（用户选择）；移动层"末段停在矿外 4m"仍属另一条任务（交接件已备）。

## 20. 历史状态（落库前的结项快照）

- **已完成并在真实 Match 上验证**：根因（矿场"报到"接管令 + 采集接近落点的几何/到点容差）→ 最小修复 A/B/C →
  单车首交 8.3s、双车 7.0s、**三车 6.9s**（均无接管、无 SCRIPT ERROR）→ 10 个套件 A/B + 1 个套件稳定性复跑
  （3/3 绿，且定位到机制）→ 交付/拥堵场景 A/B → 三条采集侧兜底实验（D/E/F）全部证伪并回滚 →
  影响面静态审计 → 补丁可落库（自检 + 演练）。
- **交付物**：本报告；`.patch`（2 文件，可干净应用）与 `-C-only.patch`（本次实际落库的那一个）；`agent/checklists/2026-10-10-harvester-port-checklist.md`；
  `agent/runs/first-trip-detour-b/check_patch_drift.ps1`（防漂移）、`run_port_rehearsal.ps1`（落库演练）、`run_landing_acceptance.ps1`（落库后验收）、
  `_StopShortProbe`/`_GatherDigProbe`/`_MultiWorkerProbe47`（探针）、`regression/*`（A/B 日志）、`landing/*`（落库验收日志）。
- **不属于本次但已备好交接件**：移动层末段推进（`plans/2026-10-10-movement-stop-short-plan.md` +
  `prompts/2026-10-10-movement-stop-short.md` + 夹具）；资源被放在 solid 格（同计划 §6）。
- 落库前"仓库源文件一个未改"的取证：相关文件 mtime 仍为 `2026-10-09`、sha 与我开工时的基准一致
  （`OreRefinery.gd=237CCEFD110E`、`MovingToUnit.gd=1DDC1C944871`）；`git status` 的 ` M` 是其它会话此前的未提交改动，
  我新增的一切都在未跟踪目录 `agent/` 下。落库后仅 `MovingToUnit.gd` 因本次 patch C 而变化（sha `1DDC1C944871` → `54869ADBC57D`）。
