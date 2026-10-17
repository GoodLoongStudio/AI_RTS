# 任务计划：命令卡强制攻击与战术后退无反应

- 状态：`complete`
- 创建时间：2026-10-09
- 负责人 Agent：Cursor
- 关联提示词：用户对局报告（选中重型坦克，X 后右键车厂无反应，Z 战术后退无反应）

## 目标

选中重型坦克后，X 再右键车厂会下达强制攻击并开始转向/开火；Z 再右键地面会按既有定义执行战术后退。同一右键确认通路上确实坏掉的指令一并修复。

## 非目标

- 不改采矿、视野、交货排队、无人机视野
- 不回退寻路/推出层改动，除非探针证明命令已被接受后被移动层吃掉
- 不改打包版、工作区归档、`build/adjutant_runtime`
- 不 git commit

## 当前证据

- 现象：第一张截图命令按钮为「取消强制攻击 [X]」（已进入强制攻击选目标）；第三张按钮回到「强制攻击 [X]」，侧栏状态为「已退出指定模式」，坦克没有攻击车厂。
- 复现步骤：选中重型坦克 → X → 右键车厂；再按 Z。
- 代码假设：`UnitActionsController._unhandled_input` 在物理拾取之前把任意指定模式的右键当成取消并 `set_input_as_handled()`，强制攻击/战术后退/强制移动/攻击移动的右键确认到不了 `unit_targeted` / `terrain_targeted`。
- 既有冒烟测试直接 `emit` 信号或调用网关，绕过这条输入通路，所以会是绿的。

## 权威口径

| 领域 | 权威来源 | 当前规则 |
|---|---|---|
| 强制攻击目标 | `TraditionalUnitCommandHUD` 提示与 `begin_force_attack_targeting` | 右键单位或地面确认；友军目标允许，按友伤倍率结算 |
| 战术后退 | `TacticalWithdrawing` + `Movement.tactical_withdraw` | 右键地面指定目的地，有倒车能力的单位倒车沿路径前往 |
| 维修/出售 | `RepairSellTargetingSmokeTest` | 左键确认，右键退出 |
| 立即命令 | `DefaultInputBindings` + HUD | 侵略 T、警戒 Y、固守 G、撤回基地 V、停火 H、清除集结 B、停止移动无热键 |

## 改动范围

- 允许修改：`UnitActionsController.gd`，必要时 `Terrain.gd`（只处理右键双发），以及一条新的命令卡右键探针
- 禁止修改：采矿/视野/交货、`Movement.gd`（除非探针证明命令已接受后被吃掉）、HUD 上已有的未提交显示名改动
- 并发风险文件：`Movement.gd`、`TraditionalUnitCommandHUD.gd` 已有未提交改动，本任务不覆盖

## 验证矩阵

- 探针：选中重型坦克，X + 右键车厂，订单为 ForceAttack 且车厂掉血或坦克朝车厂开火
- 探针：Z + 右键地面，订单保持 TacticalWithdraw 且 `_is_tactical_withdrawal` 为真、位置向目的地变化
- 同一探针核对 C / A / 停止移动 / 姿态 / 停火 / 清除集结
- 相关既有冒烟：`TraditionalUnitCommandHudSmokeTest`、`RepairSellTargetingSmokeTest`、`TankForceAttackSmokeTest`、`TankTacticalWithdrawSmokeTest`

## 风险

- 右键地面若 `_unhandled_input` 与物理拾取各发一次 `terrain_targeted`，第一次战术后退会被第二次普通移动顶掉
- 车厂是己方建筑，强制攻击必须走友伤，不能被敌我过滤静默丢掉

## 结果

根因是 `UnitActionsController._unhandled_input` 把选目标右键提前取消。修复后窗口探针 0 failure。报告：`agent/reports/closed-loop/command-card-right-click-2026-10-09.md`。
