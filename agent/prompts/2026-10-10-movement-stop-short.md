# 提示词：接手"矿车停在矿外 4~8.5m 不采"（移动层）

把下面整段交给一个编码 Agent（在自己的上下文里执行）。它自包含：环境事实、复现命令、判据、边界都在里面。

---

## 任务

修掉 RTS 游戏里的移动层缺陷：**地面单位（矿车）在布局 36 上会停在离目标矿心 4.09~4.50m 处不动**，
`units_adhere`（阈值 3.06m）恒假，采集动作永远进不了 COLLECTING（cargo 恒 0）。
同一张图、同一颗矿、同一来向，**923 发布分支能开到 1.70m 并采满 400**，所以这是回归。

## 环境事实（先看，别踩坑）

- 主工程：`G:\AIRTS\AI_RTS`（分支 yyp_test，工作区有大量未提交改动）。
- **主工程当前无法启动**：`source/match/units/traits/Movement.gd:2609` 有一行非法 GDScript
  （`var who := _unit.name if _unit != null else "?"`，Variant 推断在本工程被当错误）。
  未经用户同意不要改这一行。
- 因此取证一律在**隔离副本**里做（它们是当前工作区源码 + 上述那一行的等价修正）：
  - `G:\AIRTS\tmp_ftd_probe`：含矿车侧修复（本任务无关，但行为已验收）
  - `G:\AIRTS\tmp_ftd_base`：不含矿车侧修复（做 A/B 用）
- Godot：`G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`
- 任务计划（含全部证据与判据）：`agent/plans/2026-10-10-movement-stop-short-plan.md`
- 报告（本缺陷的来龙去脉）：`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.md` §10/§12

## 第一步：复现（必须先把现象跑出来）

```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
$env:DSH_PROBE_MAP='36'      # 失败样本
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 5000 res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn -- --debugport 24701
$env:DSH_PROBE_MAP='47'      # 对照：应当 dOre≈2.7 并开始采
& $godot --headless --path G:\AIRTS\tmp_ftd_probe --quit-after 5000 res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn -- --debugport 24701
```

夹具会打印 `[STOP]` / `[STOP][FREEZE]`，冻结时转储移动层内部状态
（`_committed_target`、`_raw_target`、`_logic_path/_logic_path_i`、`_logic_stuck`、
`_logic_repath_attempts`、`_recovery_mode`）与占用格判定。

## 已定位线索（请从这里开始查，不要从"放宽采集范围"入手）

1. 失败样本里 **committed target 的 Y 比 raw target / 地面高 2.07m**
   （raw `y=2.699` = `project_ground(矿)` 同值；committed `y=4.763`，XZ 只差 0.6m）。
   正常样本（布局 47）committed Y 与地面一致。⇒ 查逻辑地形目标的**地面高度取样 / clamp** 分支。
2. 冻结时 `_logic_stuck=1` 但 `_logic_repath_attempts=0`、`_recovery_mode=""`
   ⇒ 末段航点消费不掉时**没有任何 repath/unstick 兜底**。

## 验收判据

- 布局 36：`[STOP][COLLECT]` 出现且 cargo 增长到 400；或 `[STOP][FREEZE]` 出现时 `dOre ≤ 3.06`。
- 布局 47：不回归（`dOre ≤ 3.06` 且采满 400）。
- 回归：至少跑 `MovementRecoverySmokeTest`、`NavigationStabilitySmokeTest`、`GeneratedPathMonitorTest`
  （`config/full_regression_suite.json` 的 navigation 类别），报 rc 与 failure 数。
- 性能：改动移动层前先读 `skills/airts-performance-optimization/SKILL.md`，不要引入逐帧按单位相乘的扫描。

## 明确不要做

- **不要**放宽采集/贴合范围来"让它够得着"：三种采集侧兜底（跳矿、A* 复核选矿、按最近可走点放行）
  都已实测证伪并回滚，见计划 §5；对 `reach=7.89m` 的矿等于允许从 8.5m 外采矿。
- **不要**顺手改矿场接管语义或赠车逻辑（那部分已修好并有独立验收）。
- **不要**改 `Movement.gd:2609`（他人未提交 WIP 的一行）以外的无关代码；不要动他人未提交工作。

## 交付

闭环报告写到 `agent/reports/closed-loop/`，必须包含：改动文件、复现命令、两张图的夹具前后对照、
回归套件 rc、残留风险。
