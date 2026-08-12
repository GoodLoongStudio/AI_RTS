# Tank 战斗策略执行纵向样例记录

> 日期：2026-08-12  
> 范围：Tank 自动索敌消费 `EngagementStance` / `FirePolicy`，传统 HUD 灰盒控件；不包含 ForceAttack

## 1. 已实现行为

- `Aggressive`：在 `sight_range` 内自主索敌并追击，初版最大追击距离为 `2 * sight_range`；
- `Guard`：以 Match 权威 `GuardAnchor` 为岗位点，在岗位 `sight_range` 内迎击，目标脱离后返回岗位；
- `HoldGround`：不主动追击，只攻击已进入 `attack_range` 的目标；
- `HoldFire`：立即撤销当前自主攻击/追击，并停止自主索敌；
- `FireAtWill`：恢复按当前 EngagementStance 自主索敌；
- 策略切换会立即通知 Legacy 自动战斗 Action 重新评估，不等待下一轮轮询；
- 修复攻击者与目标水平位置重合时调用无效 `looking_at` 的问题。

## 2. GuardAnchor 更新规则

- 无移动订单时切换 Guard：立即记录当前位置；
- 玩家移动完成：记录实际到达位置；
- 玩家通过 HaltMovement 中断移动：记录中断时实际位置；
- 移动途中切换 Guard：岗位点暂时未确定，待移动完成或中断时写入；
- 切换为 Aggressive/HoldGround：清除 GuardAnchor。

岗位点保存在 Match 级 `InMemoryCombatPolicyStore`，HUD 和 Legacy Action 都只读取权威值。移动 Action 不自行持有岗位点。

## 3. HUD 灰盒交互

传统 HUD 新增：侵略、警戒、固守和停火/恢复开火按钮。按钮直接读取当前 Selection 中 Tank 的权威策略：

- 选中单位策略一致时显示对应按下状态；
- 混合策略 Selection 不伪造统一选中状态；
- 非 Tank 暂不进入本纵向样例；
- 按钮仍不绑定物理快捷键，等待统一按键管理类。

## 4. 当前临时配置

警戒半径暂用 `sight_range`，固守检测半径使用 `attack_range`，侵略最大追击距离暂用 `2 * sight_range`。这些值是纵向样例默认值，不是最终平衡数值；后续迁移到版本化数值配置。

## 5. 自动化验证

- `CSharpCommandSmokeTest`：策略轴独立保存与所有权；
- `TankCommandBridgeSmokeTest`：跨 Gateway 共享策略、GuardAnchor 创建及移动完成/中断更新；
- `TraditionalUnitCommandHudSmokeTest`：四种灰盒策略控件状态和回执；
- `TankCombatPolicySmokeTest`：HoldFire 不开火、恢复开火、HoldGround 不追击、Aggressive 追击/攻击；
- Campaign 回归：确认 Match 装配和战役流程未被新 HUD 与策略执行破坏。

Godot 无界面退出时的既有 RID/ObjectDB 清理提示仍单独登记，不计为本功能失败。

## 6. 手动验收建议

建议在至少含一辆己方 Tank 和一辆敌方地面单位的场景检查：

可直接运行 `tests/manual/TestCombatPolicies.tscn`。其中敌方 CommandCenter 位于 Tank 视野内、初始武器射程外，适合比较固守与侵略；目标被摧毁后重新运行场景即可复位。

1. 停火后不会继续追击或产生新伤害；
2. 恢复开火后按当前姿态重新行动；
3. 固守不会追击射程外目标；
4. 侵略会追击视野内目标，但不会无限追到地图另一端；
5. 警戒追击后能够返回岗位点；
6. 移动途中或停止后岗位点符合实际位置；
7. 多选不同策略 Tank 时，HUD 不错误显示统一策略。
