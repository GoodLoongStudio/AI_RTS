# 移动 / 寻路 / 脱困优化（2026-09-11）

## Overview

针对玩家实测的三类问题做定向修复，不引入流场、编队或全局交通调度，也不让大模型负责脱困：

1. 多单位互相堵住（窄路、建筑之间）
2. 单单位卡在墙边、坡道、拐角
3. 回基地、采矿、出兵时堵在建筑附近

关键线索「手动往外点一下就能出来」被证实为**目标点非法 / 局部停滞后没有有界恢复**两类根因。

保留的既有链路：`NavigationAgent3D`、运行时导航网格、行为树（`source/match/units/actions/*`）、
命令链路（`UnitCommandGateway → CommandRuntime → UnitCommandService → LegacyMovementPort → Unit.gd → Action → Movement`）。

## 一、查明的根因（均有复现证据）

### 1. clamp 把目标点抬到网格表面高度，导致每次正常移动都被判 Unreachable

`Movement._clamp_to_reachable()` 用 `NavigationServer3D.map_get_closest_point()` 的结果整体替换目标点，
而该点的 y 是**导航网格表面高度**（本作地形网格 y≈0.6）。单位实际运动平面是
`网格高度 - path_height_offset`（地形单位 `path_height_offset = 0.6`，见 `Movement._align_unit_position_to_navigation`）。

于是 `target_position` 比智能体内部路径末端高了整整一个 `path_height_offset`，
`NavigationAgent3D.is_target_reachable()` **恒为 false**，`_classify_navigation_end()` 遂把
每一次正常到达都判成 `Unreachable`。

实测（`Tank`，空地 +2m）：修前 `state=Unreachable`、停在离目标 0.49m 处；修后 `state=Arrived`。
影响面：所有普通移动订单终态错误、`UnitActionsController` 弹出假「无法到达」、依赖
`movement_finished` 的动作（`MovingToUnit`/`FollowingToReachDistance`/`GroundAttackMoving`）反复重发。

### 2. 运行时重烘导航网格会清空正在使用的网格 → 全地图单位集体站桩

`TerrainNavigation._rebake()` 把异步烘焙直接写进 `region` 正在引用的 `NavigationMesh`。
Godot 在异步烘焙完成前会清空该资源的多边形，期间全地图 `map_get_path` 返回空
（实测：回基地指令发出后 `path_size=0`、单位 `pos` 连续 24 帧不动，指挥链路全部假死）。
任何建筑新建/拆除（`MovementObstacle` 入组 → `schedule_navigation_rebake`）都会触发。

### 3. 目标点落在障碍避让圈内 → 单位被 RVO 顶住原地打转

导航网格只表达「路径连通」，与 `NavigationObstacle3D` 的**避让半径**并不一致：
网格洞比避让圈小，于是"网格可达"的落点仍可能在避让圈里，单位顶在圈外寸步难行。
另外 `map_get_closest_point()` 对障碍只挖了一个洞，洞边各点到中心等距，吸附结果会**任意**落在
远端一侧——点建筑时单位会绕大半圈去建筑背面（经典坏手感）。

### 4. 旧停滞检测测的是「请求速度」，识别不出真正的停滞

旧实现按 `safe_velocity.length()` 判断，拥挤时正常减速会误判，而顶在墙角上请求速度仍是满值、
**永远检测不到**；同时 15 帧的固定侧移没有次数上限，`FollowingToReachDistance` 每次
`move()` 都会 `_reset_stability_state()` 把脱困进度清零。

### 5. 命令/测试链路里的其它缺陷（顺手修掉，否则回归不可信）

- `Moving._ready()` 在单位尚未登记进 `units` 组时创建 Action，`_unit` 为 null →
  解引用 Nil 抛 `SCRIPT ERROR` 且**永久站桩**（测试里表现为挂起）。
- 官方回归脚本 `tools/run_full_regression.ps1` 在本机（中文 Windows）恒假失败，任一测试都报
  `Expected marker was missing`；见第六节的证据与建议（本轮未改该脚本）。
- 多个冒烟测试在导航烘焙完成前就下命令，等于**什么都没测**（部分断言用
  `["", "Unreachable", "Cancelled"]` 判"完成"，`""` 直接算通过）。

## 二、改动清单

| 文件 | 改动 |
|---|---|
| `source/match/units/traits/Movement.gd` | ①`_clamp_to_reachable` 换算回运动平面；②新增 `_push_out_of_static_obstacles` 把落点推离避让圈（方向取「障碍中心→单位所在侧」，等价原 clamp 注释的"从自己一侧贴近"）；③用**基于推进的停滞检测 + 有界脱困状态机**替换旧 `STUCK_PREVENTION_*`；④`_repair_missing_path` 处理路径短暂为空；⑤同目标重复下发不打断脱困；⑥诊断计数 `recovery_stats` |
| `source/match/TerrainNavigation.gd` | 运行时重烘改为**双缓冲**：烘焙到副本，完成回调里原子换入 |
| `source/match/units/traits/MovementObstacle.gd` | 额外登记到**持久**障碍注册表（原 `terrain_navigation_input` 是「下次烘焙的输入」，每次烘焙后会被清空，不能当障碍清单用） |
| `source/match/MatchConstants.gd` | 新增 `DOMAIN_TO_OBSTACLE_GROUP_MAPPING` |
| `source/match/units/actions/Moving.gd` | 惰性解析单位/移动特质，`_exit_tree` 空安全；逐命令日志改为可开关（`debug_log_moves`，默认关） |
| `tests/automated/SmokeTestWarmup.gd`（新） | 冒烟测试预热：等 `units` 组就绪**且导航地图对该单位可用** |
| `tests/automated/MovementRecoverySmokeTest.gd/.tscn`（新） | 5 个场景验收（见下） |
| `tests/automated/MovementScaleSmokeTest.gd/.tscn`（新） | 50 / 100 / 200 单位规模与开销观测 |
| `tests/automated/*.gd`（23 个既有用例） | 接入 `SmokeTestWarmup`（原先在单位登记前下命令，等于空跑） |
| `config/full_regression_suite.json` | 补齐并行会话新增但未登记的场景（否则官方 runner 直接拒绝执行） |

### 脱困状态机（`Movement.gd`）

```
停滞判据（每 0.5s 一个窗口，按实例 id 错峰）：
  推进 = 明显更接近任务目标(≥0.35m) 或 沿路径消耗掉航点
  否则累计窗口 → 达到阈值即进入脱困
脱困阶梯（有界，最多 RECOVERY_MAX_ROUNDS 轮）：
  1) 重寻路（对同一目标重新查询路径，覆盖"重烘后路径陈旧"）
  2) 少量合法侧移 / 后退点（候选点必须落在网格上，取净空更好的一侧）
  3) 回到原任务目标继续推进
收敛：贴到力所能及的位置 → Arrived；导航层面确实不可达 → Unreachable；
      目标可达但被拥堵反复拖住 → **不清空任务**，重置轮数继续努力（避免假失败）
预算：每物理帧全局 8 次重寻路/候选探测；同目标重复下发零开销直接复用
```

## 三、测试

新增 `MovementRecoverySmokeTest`（本机实测，headless）：

| 场景 | 结果 |
|---|---|
| 单兵绕墙（20m 绕路，墙留 -z 缺口） | `Arrived`，8.2s，到达误差 0.49m |
| 窄口双向交会（缺口 ~3.4m，两车对穿） | 双方 `Arrived`，3.3s，交会后间距 5.7m |
| 集体回基地（8 工人回防同一基地） | 8/8 抵达基地 4.5m 内，最小间距 2.49m，2.3s |
| 行进中新建建筑（触发重烘） | `Arrived`，8.6s，误差 0.49m（修前：单位集体站桩） |
| 脱困/拥堵期间玩家改命令 | 新命令 `Arrived`，旧目标未复活，脱困状态被撤销 |

`MovementScaleSmokeTest`（对向交叉抢位，最恶劣拥堵；同一场景修前/修后对比）：

| n | 修前 Arrived | 修前 Unreachable | 修后 Arrived | 修后 Unreachable | 修后收敛耗时 | 修后帧耗时均值/峰值 | 重寻路 / 脱困侧移 |
|---|---|---|---|---|---|---|---|
| 50 | 0 (0%) | 50（全部假失败） | 50 (100%) | 0 | 35.1s | 6.5ms / 145ms | 175 / 126 |
| 100 | 0 (0%) | 100 | 100 (100%) | 0 | 42.9s | 4.4ms / 12.0ms | 935 / 671 |
| 200 | 0 (0%) | 200 | 200 (100%) | 0 | 80.0s | 8.3ms / 55.3ms | 3941 / 2212 |

修前是**每个单位都在物理上到达了、但订单被判 Unreachable**（根因 1）；修后 0 假失败、0 未收敛
（`budget_skips` 在 200 单位时 2749 次，说明每帧重寻路预算确实在限流——这是有意的，避免同帧数百次导航查询）。

**残留（未解决）**：200 单位最恶劣拥堵**没有死锁，但收敛慢**（80s；另有一次 90s 预算下 199/200）。
需要交通管理 / 流场 / 分层避免，本轮明确不做。帧耗时峰值在 headless 下也会到 145ms（疑似
导航解析/GC 尖峰），需要后续单独定位。

既有用例（同一批用例改动前后，条件一致）：

| 用例 | 修前 | 修后 |
|---|---|---|
| `NavigationStabilitySmokeTest` | 2~3 failures | **0** |
| `LocalAvoidanceSmokeTest` | 挂起超时（180s） | **0** |
| `TankReturnToBaseSmokeTest` | 7 failures | **0** |
| `WorkerGatherSmokeTest` | 13 failures | **0** |
| `AirEntityMoveSmokeTest` | 13 failures | **0** |
| `EntityForceMoveSmokeTest` | 挂起超时（180s） | **0** |
| `TankTacticalWithdrawSmokeTest` | 3 failures | **0** |
| `HelicopterCommandSmokeTest` | 3 failures | **0** |

### 实机端到端（真实对局）

`tests/manual/TestPlayerVsAI.tscn`（真地图 `PlainAndSimple` + 真 AI 对手 + 真命令链路）
headless 启动，用**只读结构化通道**观测（不模拟点击、不挪相机、不碰玩家视图）：

```
move receipt status=Accepted
travelled=8.30m  remaining=0.49m  final=(23.43, 11.0)
```

同一进程内 AI 侧工人正常采集（`[COLLECT] Unit_2 carried=43`），日志无 `SCRIPT ERROR`。

## 四、仍然存在 / 未完成（如实列出）

1. **200 单位最恶劣拥堵收敛慢**：一次跑出 200/200 用 80s，另一次 90s 预算内 199/200。
   需要交通管理/流场或分层避免，本轮明确不做。帧耗时峰值在 headless 下偶发 55~145ms
   （疑似导航解析/GC 尖峰），需后续单独定位。
2. **`tools/run_full_regression.ps1` 在本机仍无法判定通过**：见第六节，属既有缺陷，本轮未修。
3. **人工在真实客户端里的点击式验收未做**：按工作区约定「游戏窗口操作归 Codex / 用户」，
   本轮只用只读通道 + 独立进程验证；普通玩家可复现步骤见第五节。
4. 沿用的既有缺陷（本轮未动）：`TankCommandBridgeSmokeTest`（缺 `HUD/TraditionalUnitCommandHUD`）、
   `RallyPointSmokeTest` / `ProductionQueueSmokeTest`（经济账户未配置）、`WorldQueryRuntimeSmokeTest` /
   `RuleAiEconomyQuerySmokeTest`（C# 查询运行时返回 Nil）、`ProjectileLifecycleSmokeTest` /
   `InfantryAnimDriverSmokeTest`（`ProjectileRuntime.LaunchEntity` 缺失）、
   `HealthBarFlickerSmokeTest`（Variant 推断告警当错误）等——均已用「临时回退本轮改动」的方式
   确认与本次改动无关。

## 五、普通玩家可复现的测试步骤

1. 用 Godot 4.7.1 Mono 打开 `G:\AIRTS\AI_RTS`，F5 运行，正常入口开一局（单人 + AI）。
2. **绕墙**：框选 1 辆坦克，右键点建筑**正中间**。预期：单位贴到建筑**自己这一侧**的外沿后停下，
   不再绕到建筑背面，且不弹「无法到达」。
3. **窄口对穿**：在同一条窄口两侧各放 1 个单位，互相右键到对侧。预期：双方都到达，交错后不重叠。
4. **集体回基地**：框选 8 个工人，按 V（回基地）。预期：全部收敛到基地周围不同位置，不叠在一起。
5. **行进中盖楼**：让单位走一段长路，中途在它的正前方造一座建筑。预期：单位不会集体僵住，
   会绕行并继续抵达。
6. **脱困中改命令**：把单位派到拥堵处，随后立刻右键另一个空旷点。预期：立刻转头执行新命令，
   不会回旧目标、不会短暂抽搐。
7. **规模**：用调试端连续给 100~200 个单位下移动命令。预期：无假失败提示；数量越多收敛越慢
   （已知残留，见第四节）。

## 六、`tools/run_full_regression.ps1` 的本机缺陷（未修，附证据与建议）

现象：清单校验通过后，**所有** Godot 用例都报 `Expected marker was missing`，而退出码是 0。

证据：日志确实包含标记。例如 `air-entity-move.stdout.log` 长 1286 字节、UTF-8、含
`Air entity move smoke test completed: 0 failure(s)`，但 runner 读到的字符串只有 **82 字节**；
换用 .NET `Process` + `ReadToEndAsync` 后有一半用例恢复判定，说明问题出在
「`Start-Process` 的异步输出拷贝在 `WaitForExit` 返回时尚未落盘」，以及经由嵌套
`powershell.exe` 包装脚本继承的 stdout 管道会整段丢失。

建议（任一）：
- 用 .NET `ProcessStartInfo` + `RedirectStandardOutput` + 先启动 `ReadToEndAsync()` 再 `WaitForExit()`；
- 或让包装脚本自己把子进程输出写进日志文件（`1>`/`2>`）并在退出前关闭句柄，外层只读文件。

本轮为不越权改动他人工具，已把该脚本恢复原样，只保留已验证的
`config/full_regression_suite.json` 清单修补；测试结论由
`G:\AIRTS\tmp_logs\movement_recovery\run_tests.ps1`（直接 headless + 文件重定向，稳定）产出。

## Related Files

- `source/match/units/traits/Movement.gd`
- `source/match/TerrainNavigation.gd`
- `source/match/units/traits/MovementObstacle.gd`
- `source/match/units/actions/Moving.gd`
- `tests/automated/MovementRecoverySmokeTest.gd`
- `tests/automated/MovementScaleSmokeTest.gd`
- `tests/automated/SmokeTestWarmup.gd`
