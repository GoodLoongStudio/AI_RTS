# 计划：残血单位/建筑的血条常显

- 建立：2026-10-10
- 用户口径（原话）：**「残血单位和建筑的血条要一直显示的」**
- **状态：已完成**（实现 + 测试 + 截图 + 相邻回归）；闭环报告：
  `agent/reports/closed-loop/2026-10-10-damaged-healthbar-persistent.md`
- 实际写入：`source/match/units/traits/HealthBar.gd`、
  `tests/automated/HealthBarFlickerSmokeTest.gd`（口径变更，改断言并说明）、
  新增 `tests/automated/DamagedHealthBarPersistentSmokeTest.gd/.tscn`、
  `config/full_regression_suite.json` 登记 `damaged-health-bar-persistent`。

## 1. 现状（改动前，读码结论）

`HealthBar.gd`：
- 默认隐藏；`hp_changed` 且**数值真变化**时 `_show_for_a_while()` → 显示并启动 **2.0s** 自动隐藏计时器；
- 选中期间常显（`_selected`），取消选中即隐藏（**不管是否残血**）；
- 计时器到点 `hide()`（不管是否残血）。

⇒ 受伤单位在 2 秒后血条消失；血少但不被继续打时看不到血条。

## 2. 目标口径

| 状态 | 期望可见性 |
|---|---|
| 满血、未选中 | 隐藏（仅受伤/治疗等数值变化后闪 2s，保留既有行为） |
| **残血（hp < hp_max）** | **常显**（不受 2s 窗口限制；取消选中也不隐藏） |
| 选中 | 常显（既有行为不变） |
| 修满/治疗到满血 | 回到"2s 窗口后隐藏" |
| **施工中的建筑** | **不算残血** —— 必须排除 |

**为什么必须排除施工中的建筑**：`Structure.mark_as_under_construction()` 故意把 hp 置 1，
再按施工进度 `1 + progress*(hp_max-1)` 递增（`Structure.gd:96`、`:108-112`）。
若按"hp < hp_max"直接判定，**所有在建建筑都会常显血条**（严重观感回归）。

## 3. 实现要点（最小改动，单一可见性入口）

- 新增 `_is_damaged()`：`hp/hp_max` 有值、**非施工中**、且 `hp < hp_max`。
- 新增 `_sync_visibility()`：`选中 or 残血 ⇒ show() + 停表`；否则"表停着 ⇒ hide()"。
- `_recalulate_bar_value()` 末尾调用 `_sync_visibility()`（覆盖"修满 ⇒ 允许隐藏"）。
- `_ready()` 末尾调用 `_sync_visibility()`（中途镜像到已受伤单位也正确）。
- `_on_unit_deselected()`：改为 `_sync_visibility()`（残血保持显示）。
- `_on_visibility_timer_timeout()`：选中/残血时不熄灭（兜底）。

## 4. 验证

1. `HealthBarFlickerSmokeTest`：**断言 2/3/4 属口径过期**（原口径要求"停血 2s 后自动隐藏/取消选中即隐藏"），
   按新口径更新并写清理由；断言 1（持续掉血不闪）保持。
2. 新增 `DamagedHealthBarPersistentSmokeTest`：真实 Match（`TestAllUnits`）
   - 单位（Tank）与**建筑（VehicleFactory）**各一条：满血隐藏 → 打掉 25% ⇒ 显示且**超过 2s 窗口仍在**、
     且自动隐藏计时器处于停止 ⇒ 修满 ⇒ 2s 窗口内隐藏；
   - 负例：`mark_as_under_construction()` 的建筑**不得**常显（窗口后必须隐藏）。
3. 既有 `EnemyHealthBarSmokeTest` 必须仍然 0 failure（敌方染红不受影响）。
4. 关键视觉改动：窗口化跑一次，把"残血单位 + 残血建筑 + 满血单位"同屏截图并**亲自打开查看**。

## 5. 回滚

只改 `HealthBar.gd`（一个文件）+ 测试文件；回滚方式写在闭环报告里。
