# 强制攻击失效根因修复报告（2026-10-08）

## 结论

强制攻击（含打建筑、打友军、打地面）在真实游戏中**完全失效**，根因是**两个叠加的断链**，均已修复：
① 并行会话的重构导致 `Unit.gd`/`Structure.gd` 编译失败——战场单位 script 全灭；
② `input_event` 的 Vector2 屏幕坐标被原样转发给要求 Vector3 的派单入口——右键单位**静默失败**。

用户从 Godot 编辑器 DEBUG 运行的 `G:/AIRTS/AI_RTS` 就是本工作的源码项目，**没有改错项目**。

## 根因与证据

### ① 编译期断链（单位 script 全灭）

运行时日志（复刻探针）：
```
Parse Error: Static function "find_drop_off()" not found in base
  ".../CollectingResourcesSequentially.gd"
Failed to compile depended scripts. ← Unit.gd        （所有单位）
Failed to compile depended scripts. ← Structure.gd   （所有建筑）
Failed to compile depended scripts. ← OreRefinery.gd
```
并行会话 00:46 把我的 `find_drop_off` 公开改名回退为 `_find_drop_off_for`，
而 `AutoGatheringResources.gd:69` 的**静态调用**在编译期解析函数名 → 本脚本解析失败
→ 依赖链上 Unit.gd / Structure.gd 全部 "Failed to compile depended scripts"
→ 战场上所有单位和建筑的 script 都是死的 → 订单下发无人执行（坦克完全不动）。

**修复**（`source/match/units/actions/AutoGatheringResources.gd`）：
满车守门改为**本地实现** `_has_completed_refinery_assignment()`（5 行只读检查，
与 CollectingResourcesSequentially 的交货点口径一致），彻底消除跨脚本编译期依赖，
此后并行会话再怎么重构那个文件名都不会再连锁崩。

### ② Vector2 → Vector3 类型断链（右键单位静默失败）

复刻探针（真实条件：Godot `input_event` 传 Vector2 屏幕坐标）：
```
input_event 后信号次数=1 模式='ForceAttack'   ← 信号发了，controller 没派单
```
对比实验：把同样的 emit 改成传 Vector3 → 立刻派单成功、伤害 80→71。
**根因**：`Targetability._on_input_event` 把 `click_position`（Vector2）原样转发给
`MatchSignals.unit_targeted`，而 `UnitActionsController._on_unit_targeted(unit,
target_position: Vector3)` 声明 Vector3 → 形参类型不匹配，回调静默失败。
`Selection.gd` 的维修/出售路径犯了一模一样的错。

**修复**（`source/match/units/traits/Targetability.gd`、`Selection.gd`）：
转发前转成目标自身的世界坐标（`click_position if click_position is Vector3
else _unit.global_position`）。

## 最终验证（复刻探针，真实 Vector2 条件）

```
[CH] 信号发了 → controller 派单 → 模式退出
[CH] 坦克动作=ExplicitForceAttacking.gd
[CH] CC HP 80→71 已扣血✓（强制攻击己方指挥中心生效）
```

## 回归（`agent/runs/2026-10-08-force-attack/regression.log`）

| 套件 | rc | 说明 |
|---|---|---|
| tank-force-attack | **0** | 强制攻击全链路 |
| force-attack-friendly | **0** | 友军伤害 |
| traditional-command-hud | **0** | HUD 命令面板 |
| tank-move-fire | **0** | 移动开火 |
| strategic-chat-service | **0** | 战略聊天 |
| tank-ordinary-attack | 1 | **既有失败**（此前已 stash 基线归因） |
| worker-gather | 1 | **既有失败**（本轮已 stash 基线归因：不含本次改动同样 3 条失败） |
| ore-refinery | — | **既有失败**（此前已归因：夹具/在途改动） |

## 共享工作区风险

- 并行会话正在编辑 `CollectingResourcesSequentially.gd`（00:46~01:02 多次改写），
  本次未触碰该文件；本地守门实现使我方不再受其函数名重构影响。
- 诊断探针已全部清理（`_ForceAttack*`、`_PickRay*`、`_Heavy*`、`_StrategicPrebattle*`）。

## 回退方式

```bash
git checkout -- source/match/units/actions/AutoGatheringResources.gd \
  source/match/units/traits/Targetability.gd source/match/units/traits/Selection.gd
```
