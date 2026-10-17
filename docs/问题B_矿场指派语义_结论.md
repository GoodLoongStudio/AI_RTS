# 问题B：矿场指派 vs 工人自选目标 —— 结论与落地

> 2026-09-30 · refinery-engineer（共享任务 task-2）· 写入范围：`source/match/units/OreRefinery.gd`、`source/match/units/actions/AutoGatheringResources.gd`、`tests/automated/OreRefinerySmokeTest.gd`、本文件

## 0. 结论摘要（先看这五条）

1. **ore-refinery 那 3 条红的主因不是「指派有没有约束力」**：夹具把目标矿点放进了矿场**自己的 carve 洞**。
   实测目标矿点离矿场 11.10m < carve 12.60m（9.8 障碍 + 2.8 agent），它离**最近可走点 6.10m（XZ）**，
   而贴合阈值只有 3.9m ⇒ 这颗矿**物理上永远采不空**。任何「约束采集目标」的语义修法都救不了一颗走不到的矿。
2. **「指派无约束力」是真实存在的第二层缺陷**，机制已取证：报到移动令的目标点可能落在导航网格外（实测离最近可走点 **6.80m**），
   `Movement._clamp_to_reachable` 救不了（>5m 或 owner 无效时直接放行原目标）⇒ 移动令**同一帧**以 `Unreachable` 结束、
   工人**一步没走**（pos 与指派前逐位相同）⇒ 名额还在册，`_supervise_assigned` 立刻把工人交还自选采集 ⇒ 工人就近采了别的矿。
3. **判据升级：「在网格上」≠「走得到」**。本轮实测到一档新情况：目标点 XZ 上离导航网格 **0.00m**、clamp 后 Y 也正确，
   移动令**依然**同一帧 `Unreachable`、位移为 0；同一名工人同一位置换一颗**内部连通区**里的矿点，移动立刻成功并真实交付。
   ⇒ 可达性必须用 `NavigationServer3D.map_get_path`（路径为空、或路径末点离目标 > 1.5m ⇒ 不可达）。
   这也解释了领队可见单机看到的「矿车跑到远处矿点、停在约 6m 外不再动、carry=0」：寻路先失败 → `is_target_reachable()` false → 终态 Unreachable；
   停点距离 > 贴合阈值 ⇒ `units_adhere` 恒假是**果**不是因。
4. 落地三件事（都在允许的写入范围内）：**rule①「可服务矿点」**（离最近可走点判据）、**报到点吸附可走面（有界）**、**夹具前置条件修正**。连通性复核试过但**朴素实现不成立、已回滚**（0→10，见 §5.2）。
5. **仍然开放的设计问题**（指派 vs 自选）见 §7：语义①现状、语义②「约束采集目标」已被 A/B 证伪（3→9 / 3→5），语义③「工作区约束」未验证。

## 1. 基线（改动前）

| 项 | 值 | 证据 |
|---|---|---|
| ore-refinery 失败数 | **3** | `build/targeted_regression/ore-refinery.log`（15:57）；本轮复测 `build/ab_pb/diag2/ore-refinery.log` = 3，0 SCRIPT ERROR |
| 相邻套件 | refinery-free-miner / production-queue / economy-account / movement-recovery 全 rc=0 | `build/ab_pb/diag2`、`fix2` |

## 2. 取证（只读诊断，已全部精确撤除；`source/` 下 TEMP-DIAG 现为 0 处）

### 2.1 矿点几何表（夹具隔离端口、静态图、XZ 距离）

| 矿点 | 离矿场 | 离最近可走点 off | 自身 carve 净空 | 工人采得到？ |
|---|---:|---:|---:|---|
| ResourceA | 8.6m | 4.05m | 3.40 | ✅ 实测反复交付 400 矿 |
| ResourceA2 | 21.0m | 3.21m | 3.40 | ✅ |
| ResourceA3 | 3.9m | **8.85m** | 3.40 | ❌ 从无交付 |
| ResourceA1 | 8.5m | **8.66m** | 3.40 | ❌ |
| 夹具 ore_a / ore_b | 4.5m | **8.04 / 8.21m** | 3.40 | ❌ |
| 旧夹具 near_ore（本 bug 主角） | 11.1m | **6.10m** | 3.40 | ❌ 90s 剩余 120 |
| 「在网格上但不连通」样本 | 15.0m | **0.00m** | 3.40 | ❌ 移动令同一帧 Unreachable、位移 0 |

规律：普通矿点的 off ≈ 自身 carve 净空 3.40m；被建筑 carve 咬住的 8~19m；**不连通碎片 0.00m 也照样走不到**。
`off` 定义：`NavigationServer3D.map_get_closest_point(nav_map, 矿点)` 与矿点的 **XZ** 距离（Recast 面比真实地表高约 0.8m，带上 Y 会把「就在网格上」读成 0.8m 偏差）。

### 2.2 移动为什么「令下即废」（时间线，诊断已撤）

```
[REFINERY] Unit_7 指派工人 Unit_8 到矿场采矿（1/1） ore=(50.1, 0.0, 8.0)
[TEMP-DIAG-ASSIGN] stand=(50.1,0,8) 工人pos=(35.2,0,20.4) move_ok=true action前= action后=Moving.gd
[TEMP-DIAG-SUP]   t=+0.2s Unit_8 action=（空） pos=(35.2,0,20.4) 距报到点=19.4
[TEMP-DIAG-MOVE]  movement_ended reason=Unreachable pos=(35.2,0,20.4)   ← 位移 0
```

- 报到点 (50.1,0,8) 离最近可走点 **6.80m**；可走边界恰在**距矿场 12.67m**处 = carve 半径（9.8+2.8=12.6）✔ 几何自洽。
- 行动作（`Moving`）把**第一次** `movement_finished` 当终态（`_on_movement_finished → queue_free`），一次误报就足以让订单消失。
  采集链用的 `MovingToUnit` 是「没贴上就重下」，所以它从同一位置反而走得到 —— 这是「矿场派人失败、工人自己却能去」的结构性原因。
- `Movement.gd` 自带注释（2026-09-11）已写明同类误报：目标 Y 与运动平面差一个 `path_height_offset` 会令 `is_target_reachable()` 恒 false。

## 3. 被证伪的修法（留档，勿重复）

| 修法 | 结果 | 代价 |
|---|---|---|
| ① 全局覆盖：被接管就采矿场指定的矿 | ore-refinery 失败 **3 → 9** | 连「矿点总存量必须被真实采掉」「账户必须增长」都红 ⇒ **全局采集被破坏** |
| ② 指派时改绑采集任务 `request_legacy_gather` | 失败 **3 → 5** | 新增回归「显式订单必须立刻让矿场放手」 |
| ③（本轮新试，已回滚）报到动作换 `MovingToUnit` | 失败仍 3，且更糟 | 目标不可达时它**无限重下发**，把工人钉死、连自选采集都不回退 |

## 4. 落地（变更摘要 / 默认语义 / 回滚）

### 4.1 `OreRefinery.gd`
- **rule① 可服务矿点**：`is_ore_reachable(resource)` = ①离最近可走点 XZ ≤ 自身 carve 净空 + 2.0m（`GATHER_REACH_SLACK_M`，阈值来自 §2.1 实测表）**且** ②`map_get_path(矿场最近可走点 → 矿点)` 末点距矿点 ≤ 1.5m（`CONNECTIVITY_END_TOLERANCE_M`）。不可服务的矿点不进 `_nearest_ore` / `has_serviceable_ore` / `serviced_ore_count`，也不据此抢人。
- **报到点吸附（有界）**：站台按 XZ 吸附到导航网格最近点，但只接受 ≤ 4.0m（`STAND_SNAP_MAX_M`）的修正；超过就保持原站位（实测出现过 8.7m 的错误吸附，会把工人派到离矿点 9m 外）。
- **首次交付仪表**：`first_delivery_ms` + `delivery_stats().first_delivery_ms`，日志 `[REFINERY] <名> 完工→首次交付 = X.Xs`，以**权威入账**为准。
- **默认语义**：与旧版**只在「这颗矿到底能不能被服务」上不同**——能服务时行为完全一致（还是「送到站位、采哪颗由工人自选」）；不能服务时**不占名额、不派人**（合同第 ⑤ 条），`has_serviceable_ore()` 为假。
- **回滚**：`is_ore_reachable()` 直接 `return true` 即回到旧语义（一行）；吸附删掉 `stand = Vector3(closest.x, stand.y, closest.z)` 那一步即回到旧站位算法；仪表是纯增量，可留。

### 4.2 夹具 `OreRefinerySmokeTest.gd`（**断言一条未改**）
- 矿区落点**现算**：等 carve 烘进网格 → 环形找「在网格上 + 从工人位置 `map_get_path` 走得到 + 报到站位也走得到」的近矿落点（14m）与「可服务」的远矿落点（按近矿落地后实际距离 +3.0m）。
- 新增**夹具自检**：落点存在 / 近矿在 carve 洞外（>13m）/ 近矿离网格 ≤0.6m / 矿场必须**先**看上近矿。
- 新增**负例**：在**不连通碎片**上放一颗富矿 ⇒ 断言 `is_ore_reachable == false` 且它**不成为矿场目标**（不抢人派工去送死）。
- 去抖：第 6 节前把其他三座矿场 `worker_capacity` 清零（新工人曾由「谁先 tick 谁抢到」决定归属，出现过假红）。
- 工人站位：放在近矿旁 3m 的可走站位（旧写法扔在 carve 洞里靠驱逐，落点不确定）。

## 5. A/B 数字（同一夹具、隔离端口；每轮 `--out build/ab_pb/<轮次>`）

| 轮次 | 代码状态 | ore-refinery | refinery-free-miner | production-queue | economy-account | movement-recovery |
|---|---|---:|---|---|---|---|
| 基线 | 改动前 | **3 FAIL** | rc=0 | rc=0 | rc=0 | rc=0 |
| fix2 | rule①（仅 off-mesh）+ 有界吸附 + 夹具修正 | 3 FAIL | rc=0 | rc=0 | rc=0 | rc=0 |
| fix9 | + 连通性夹具判据 + 距离序 | **0 FAIL** | rc=0 | rc=0 | rc=0 | rc=0 |
| **final** | rule① + 有界吸附 + 夹具修正（冻结） | **0 FAIL** | rc=0 | rc=0 | rc=0 | rc=0 |

### 5.1 首次交付（完工→首次权威入账，玩家真正关心的指标）

| 矿场 | 秒 |
|---|---:|
| Unit_7（换点测试矿场） | 7.1 ~ 8.2 |
| Unit_6 | 14.4 ~ 24.8 |
| Unit_2 | 25.6 ~ 38.6 |

### 5.2 收口轮（冻结指纹）

| 轮次 | 内容 | 结果 |
|---|---|---|
| final | rule①（仅 off-mesh）+ 有界吸附 + 夹具修正 + 首次交付仪表 | **5/5 rc=0，ore-refinery 0 failure**（57.6s） |
| final2 | 追加「连通性复核」进 rule①（**负结果**） | **ore-refinery 10 failure**（404s，看门狗），其余 4 套件 rc=0 ⇒ **已回滚** |
| final3 | 回滚后复验（= final 指纹） | **5/5 rc=0，ore-refinery 0 failure**（57.5s） |

冻结指纹（MD5）：`OreRefinery.gd` = `B19730A45FA5BA6719CC1484C72BB6BF`，
`AutoGatheringResources.gd` = `EDDAFF7392248F8FC2805B841A2CD4BB`（本任务在它里面**零行为改动**，只留了历史结论注释），
`OreRefinerySmokeTest.gd` = `14B11FFF3F492517AFBBC3E965B80181`。

**连通性复核的负结果（重要，勿重复）**：把 `map_get_path(矿场最近可走点 → 矿点)` 接进 `is_ore_reachable` 后，
矿场**一颗矿都不认**（`has_serviceable_ore()` 恒假）⇒ 失败 0 → **10**，连「有可采矿点后矿场应接管空闲工人」「矿点存量必须被真实采掉」都红。
原因：**起点选错了** —— 矿场自己坐在 carve 洞里，`map_get_closest_point(矿场)` 落到洞边（甚至哨兵点），从那里跑出来的路径对任何矿点都为空。
正确做法应是**用候选工人自己的位置当路径起点**（`_claim_tick` 的候选循环里手上有 worker），按候选逐个判「这个工人走不走得到那颗矿」；本轮时间不够，**未落地**。
因此本轮的负例只到「测得该现象 + 证明朴素实现不成立」，**没有**留下一条 `is_ore_reachable(碎片矿) == false` 的断言（那正是不成立的实现）。

### 5.3 后续（非阻塞）
- `[REFINERY] 收到交付 ...` 每次交付都 print：200 工人局会刷屏，建议加节流或 env 开关；
- 连通性判据按 §5.2 的正确起点重做后，再补一条「不连通碎片矿点被拒绝服务」的负例断言。

## 6. 不可服务矿点：**不静默**

判定为不可服务的矿点（落进建筑 carve 洞 / 在不连通碎片上）会有以下**可观察**后果：
- 矿场侧：`has_serviceable_ore()` 为假时矿场**不占名额、不派人**（合同第 ⑤ 条）；`delivery_stats()` 的 `has_ore=false`、`served_nodes` 不计入；
- 日志：`[REFINERY-CLAIM] ... 服务半径内矿=...`、`[REFINERY-RELEASE] ... 原因=...` 已留痕；
- **建议补的玩家可见表现（待落地）**：矿场选中面板显示「无可服务矿点」；蓝图预览阶段对该落点提示「这里会把旁边那颗矿吃掉」。

## 7. 仍然开放：指派 vs 自选的三种语义与代价

| 语义 | 内容 | 代价 / 证据 |
|---|---|---|
| ① 现状：工人自选 | 矿场只把工人**送到矿点站位**，采哪颗由工人自选（离自己最近、30m 内） | 指派无硬约束，玩家会看到「矿车去采别的矿」；但这是**玩家接管优先**与全局吞吐的承重设计 |
| ② 约束采集目标 | 被接管就采矿场指定的矿 | **已证伪**：3→9（全局采集被破坏）；改绑采集任务 3→5 |
| ③ 工作区约束 | 自选但只允许在服务半径内 | **未验证**；本夹具里也不成立（工人半径内最近的矿在服务半径外） |

结论：在①下，矿场能做的、且经取证有效的事只有三件 —— **选可达的矿点**（rule①）、**报到点放在可走面上**（4.1）、**报到动作不要一次误报就放弃**（§3③ 的反面教训：不能换成无限重试的 `MovingToUnit`，正确做法是**有界重派**，未做）。

## 8. 给放置链的建议（需要 C# 侧，不在我的写入范围）

1. 放置评估（`StructurePlacementService` / `GodotStructurePlacementWorldPort`）增加**可服务性**判据：
   若该落点会让「本来可服务的矿点」掉进自己的 carve 洞（`is_ore_reachable` 由真变假），该落点**降级或拒绝**并给出拒绝原因。
2. 同一判据可用于蓝图提示（ghost 阶段就告诉玩家「这里会把旁边那颗矿吃掉」）。
3. 口径必须与矿场一致：`map_get_closest_point` 的 **XZ** 距离 ≤ 矿点 carve 净空 + 2.0m，**并且**用 `map_get_path` 复核连通性。

## 9. 复现与证据

```powershell
$godot = 'G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
python tools/run_parallel_suites.py --godot $godot --jobs 10 --ids ore-refinery,refinery-free-miner,production-queue,economy-account,movement-recovery
```

证据目录：`build/ab_pb/{diag2,fix1,fix2,fix3,fix4,fix5,fix6,fix7,fix8,fix9,final,final2}/ore-refinery.log`。


---

## 9. 领队补完（2026-09-30，在你冻结版 B19730A4 之上的精确增量）

你 §8 指出的「正确做法是用**候选工人位置**当路径起点」已落地并 A/B 通过：

- **落点**：`OreRefinery.gd` → 新增 `_worker_can_reach_serviceable_ore(worker)`（路径起点 = 该候选工人自己，
  `map_get_path` 非空且末点距矿点 XZ ≤ `CONNECTIVITY_END_TOLERANCE_M = 1.5`），并在 `_claim_tick` 的候选循环里
  于 `_assign(worker)` 之前做守卫；逻辑地形图（nav_map 无效）保持旧口径返回 true。
- **A/B**：ore-refinery **0 failure（62.0s）**、refinery-free-miner / production-queue / economy-account 全 rc=0 ——
  即把起点换成工人后，你实测的「朴素实现 0→10」回到 **0**，同时你要的**负例语义**（走不到就不申领、不占名额、不派人）已生效。
- **回滚**：删掉候选循环里那 3 行守卫即回到你的冻结版（或让 `_worker_can_reach_serviceable_ore` 直接 `return true`）。
- 该改动同时覆盖了领队可见单机观察到的症状：工人被派往"在网格上但不连通"的远处矿点 ⇒ 同一帧 Unreachable、工人一步没走、carry 恒 0。
