# 闭环验证报告：命令卡右键确认被提前取消

- 日期：2026-10-09
- 计划：`agent/plans/command-card-force-attack-withdraw-plan.md`
- 状态：`complete`
- 开发根：`G:/AIRTS/AI_RTS`
- 验证入口：Mono Godot `G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`，`--path G:/AIRTS/AI_RTS`
- 路径检查：`UnitActionsController.gd`、`tests/automated` 的 develop 检查均为 allow / rc=0

## 1. 目标与验收条件

选中重型坦克后，X 再右键己方车厂会强制攻击并造成伤害；Z 再右键地面会倒车战术后退。同一条右键确认通路上坏掉的指令一起修。立即生效的姿态/停火/停止移动若本来就能下发，则不改。

## 2. 根因

断点在输入，不在寻路，也不在友军过滤。

`UnitActionsController._unhandled_input` 在物理拾取之前，把任何非空指定模式的右键都当成取消，并调用 `set_input_as_handled()`。Godot 因此不再把这次点击交给 `Targetability._on_input_event` / `Terrain._on_input_event`。`unit_targeted` 和 `terrain_targeted` 都不会发出，命令网关不会收到订单。

玩家能看到的只有模式被清掉：侧栏写「已退出指定模式」，按钮从「取消强制攻击」变回「强制攻击」。坦克动作不变。这和截图一致：第一张按钮已是「取消强制攻击 [X]」（X 已进入选目标），第三张按钮回到「强制攻击 [X]」且状态为「已退出指定模式」。

修复前探针（右键落在空地上、已进入战术后退）：`targeting` 被清空，`terrain=0`，`orders=[]`，`feedback=[]`。

X / Z 热键本身能进模式。车厂是己方建筑也不构成拒绝：修复后 `ForceAttack` 状态为 Accepted，车厂 hp 32.0 → 29.4。`Movement.gd` 有未提交的寻路改动，本次没有改它，也没有回退。

## 3. 实施改动

| 文件 | 改动 |
|---|---|
| `source/match/players/human/UnitActionsController.gd` | `_unhandled_input` 只在维修/出售模式下用右键取消并吞掉点击。强制攻击、战术后退、强制移动、攻击移动、技能的右键继续交给拾取 |
| `tests/automated/CommandCardRightClickProbe.gd` | 新增窗口探针：重型坦克、真实视口右键、车厂与地面 |
| `tests/automated/CommandCardRightClickProbe.tscn` | 探针场景 |

## 4. 每条指令

| 指令 | 结论 | 依据 |
|---|---|---|
| 强制攻击 X + 右键车厂 | 已修 | 修复前右键无 `unit_targeted`、无订单。修复后 `ForceAttack` Accepted，动作 `ExplicitForceAttacking`，己方车厂掉血 |
| 战术后退 Z + 右键地面 | 已修 | 修复前右键清空模式且无订单。修复后 `TacticalWithdraw` Accepted，`_is_tactical_withdrawal=true`，1.2 秒位移约 3.6 米，同一次点击没有普通 `Move` |
| 强制移动 C + 右键地面 | 已修 | 与 X/Z 同一条被吞掉的右键。修复后 `ForceMove` Accepted，动作 `Moving` |
| 移动并攻击 A + 右键地面 | 已修 | 右键原先被吞掉。修复后 `GroundAttackMove` Accepted。A + 左键在修复前就能下发，修复后仍然 Accepted |
| 停止移动 | 正常，未改 | 按钮不走选目标右键。探针反馈 `HaltMovement` Accepted |
| 侵略 T | 正常，未改 | `EngagementStance=Aggressive`，Accepted |
| 警戒 Y | 正常，未改 | `Guard` |
| 固守 G | 正常，未改 | `HoldGround`。命令卡文案是「固守 [G]」，不是集结 |
| 撤回基地 V | 正常，未改 | `ReturnToBase` Accepted，动作 `ReturningToBase` |
| 停火 H | 正常，未改 | `FirePolicy=HoldFire`，Accepted |
| 清除集结 B | 正常，未改 | 选中车厂后 `ClearRallyPoint` Accepted。热键是 B，文案是「清除集结」 |
| 维修右键 | 正常，未改语义 | 右键仍退出维修模式，且不产生移动订单 |

源码键位以 `DefaultInputBindings` 和命令卡为准：侵略是 T，固守是 G，清除集结是 B。

## 5. 自动化验证

窗口探针（不要用 `--headless`，拾取需要视口）：

```text
Godot_v4.7.1-stable_mono_win64_console.exe --path G:/AIRTS/AI_RTS --resolution 1280x720 --position -4000,-4000 res://tests/automated/CommandCardRightClickProbe.tscn
```

结果：`Command card right-click probe completed: 0 failure(s)`，进程退出码 0。

| 命令 | rc | 标记 |
|---|---:|---|
| `TraditionalUnitCommandHudSmokeTest.tscn` `--headless` | 0 | `0 failure(s)` |
| `TankTacticalWithdrawSmokeTest.tscn` `--headless` | 0 | `0 failure(s)` |
| `TankForceAttackSmokeTest.tscn` `--headless` | 0 | `0 failure(s)` |
| `RepairSellTargetingSmokeTest.tscn` `--headless` | 1 | 仅最后的遮挡射线兜底两条失败；维修/出售模式本身没有 FAIL。该用例直接调用 `_try_structure_mode_from_ray`，本次没有改这个函数 |

## 6. 未改项与剩余风险

- 没有改 `Movement.gd`、采矿、视野、交货排队、无人机视野。`Movement.gd` 和 `TraditionalUnitCommandHUD.gd` 上已有的未提交改动保持原样。
- 没有 git commit。没有动打包版、工作区归档、`build/adjutant_runtime`。没有结束用户已打开的 Godot（PID 39676 / 45612）。
- 探针里的车厂在射程内（约 8 米，炮射程 40 米），所以坦克原地开火。射程外要先走近再开火，这条逼近仍走现有寻路；本次没有复现「命令已接受却被推出层吃掉」。
- 右键地面在这次探针里只产生一次 `terrain_targeted`，战术后退没有被第二次普通移动顶掉。若以后有代码在拾取之后再发一次地面信号，倒车仍可能被普通移动替换。
- `RepairSellTargetingSmokeTest` 的遮挡射线兜底在本次 headless 运行失败，和右键取消无关，没有顺手改。
