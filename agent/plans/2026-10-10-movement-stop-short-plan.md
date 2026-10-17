# 移动层任务：矿车"停在矿外 4~8.5m 不采"（末段推进 / committed target 高度）

- 建立日期：2026-10-10
- 来源：矿车「第一次采矿绕道并停下」回归排查（报告
  `agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.md`）
- 归属：**移动层**（`source/match/units/traits/Movement.gd` + `maps/generated/GeneratedTerrain.gd` 占用格/寻路），
  与当前未提交的"窄缝穿模 / 逻辑地形 A*"WIP 同源
- 状态：待接手（采集侧已排除，见 §5）

## 1. 现象

单车 + 单矿 + 显式采集单，在**布局 36** 上矿车会停在离矿心 **4.09~4.50m** 处不动
（45 秒无位移、无状态迁移），`units_adhere`（阈值 3.06m）恒假 ⇒ **cargo 恒 0，永远不采**。
同一颗矿、同一来向，**923 发布分支能开到 1.70m 并采满 400**。

（另有一颗矿 `ResourceA2` 最近可站距离 **7.89m**，属"资源被放在 solid 格上"，见 §6 的另一条任务。）

## 2. 一键复现（不改任何游戏逻辑）

```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
# 失败样本
$env:DSH_PROBE_MAP='36'
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 5000 `
  res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn -- --debugport 24701
# 对照样本（同夹具、能贴到 2.72m 并开始采）
$env:DSH_PROBE_MAP='47'
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 5000 `
  res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn -- --debugport 24701
```

- 夹具：`agent/runs/first-trip-detour-b/_StopShortProbe.tscn`（脚本同名 `.gd`，零游戏逻辑改动）
- 已存档日志：`agent/runs/first-trip-detour-b/probe.stopshort-map36.log`（失败）、
  `probe.stopshort-map47.log`（对照）
- 隔离工程：`G:\AIRTS\tmp_ftd_probe`（当前工作区源码 + **仅一行** `Movement.gd:2609` 解析修正）。
  需要 base（未含矿车补丁）对照时用 `G:\AIRTS\tmp_ftd_base`。

## 3. 已定位到的两条硬结论（夹具实测）

| 观测 | 布局 36（失败） | 布局 47（正常） |
|---|---|---|
| 目标矿占用格 / 最近可站距离 | **solid** / 0.40m | 可走 / 0.00m |
| `project_ground(矿)` | `(33.537, **2.699**, 246.446)` | — |
| committed target | `(34.134, **4.763**, 245.405)` | `(263.383, **2.368**, 132.172)` |
| raw target | `(34.134, **2.699**, 245.405)` | — |
| 冻结时内部状态 | `logic_path size=1 i=0`、**`stuck=1`**、**`repath_attempts=0`**、`rec=""` | 未冻结 |

1. **committed target 的 Y 比 raw/地面高 2.07m**（XZ 只差 0.6m）。车停在 3.06m 贴合圈之外，永远贴不上。
   正常样本里 committed Y 与地面一致 ⇒ 优先查"目标落进 solid 格 / 斜坡时的地面高度取样或 clamp"分支。
2. **末段航点消费不掉时没有兜底**：`_logic_stuck=1` 而 `_logic_repath_attempts=0`、`_recovery_mode=""`
   —— 既没有 repath 也没有 unstick，永久站桩。参考 `Movement.gd` 的
   `_logic_advance_waypoint()` / `_fail_as_unreachable()` / `_advance_recovery()`。

## 4. 验收判据

夹具输出满足任一即算修好（两图都要跑）：

- 布局 36：出现 `[STOP][COLLECT]` 且 `cargo` 增长到 400（不再出现 `[STOP][FREEZE]`），或
- 若仍出现 `[STOP][FREEZE]`，则 `dOre ≤ 3.06`（`units_adhere` 阈值）；
- 布局 47 不回归：仍能 `dOre ≤ 3.06` 并采满 400。

回归要求：改动 `Movement.gd`/`GeneratedTerrain.gd` 后，按仓库约定跑
`config/full_regression_suite.json` 的 navigation 类别（至少 `MovementRecoverySmokeTest`、
`NavigationStabilitySmokeTest`、`GeneratedPathMonitorTest`），并先读
`skills/airts-performance-optimization/SKILL.md`（移动层是每帧热点）。

## 5. 边界：**采集侧已经试过且被证伪，不要再往那边兜底**

三种采集侧兜底都在真实 Match 上证伪并回滚（详见报告 §9.1/§10.1）：

| 实验 | 做法 | 结果 |
|---|---|---|
| D | 选矿阶段跳过"没有可站点的矿" | 停车距离 8.5m → 4.1m，**仍不采** |
| E | 用逻辑地形 A* 复核"路径末点是否落在贴合距离内"再选矿 | 能换矿，但仍停 4.01m，**仍不采** |
| F | 给采集/到达加"按最近可走点放行"的范围 | 对 `reach=7.89m` 的矿等于**从 8.5m 外采矿**（不可接受） |

结论：**采集侧不存在正确阈值**；`reach=0.40m` 的那颗矿路是通的，是移动层没走到。

## 6. 同一批排查里发现的另一条任务（建议单开）

**资源被放在不可走格上**：布局 36 的 `ResourceA2` `is_ground_blocked(矿点)=true`、
最近可站距离 **7.89m** ⇒ 任何地面矿车理论上都够不到它。
建议在生成/放置链路加判据：资源格必须 `is_ground_blocked == false`（或落地时把该格 stamp 成可走）。
证据：`agent/runs/first-trip-detour-b/probe.reach-map36.log`（报告 §10.2 表格）。

## 7. 矿车侧已修好的部分（本次不重复做）

矿车链路的三处修复（隔离副本 `G:\AIRTS\tmp_ftd_probe`，补丁
`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.patch`）与本任务正交：

- 矿场只接管**空闲**车（不再顶掉玩家/自选的采集单）；
- 赠车**立刻**点火自选采集（不再"出厂空闲 → 等矿场派报到令"）；
- 采集接近落点回到 923 口径（以车来向为基准 + 压在矿半径内 + 缓存落点）。

验证：单车首交 8.3s、双车同矿首交 7.0s、矿场接管 0 次、5+5 个套件 base/patched 逐条一致。
