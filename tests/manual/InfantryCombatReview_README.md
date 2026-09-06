# InfantryCombatReview 步兵战斗动画人工验收

真实战斗链路的步兵动画验收场景：真实 `Match`（`TestAllUnits.tscn`）、真实导航、
真实 `UnitCommandGateway` 命令、真实投射物（`ProjectileRuntime`）与命中结算。
单位为现有 `Infantry.tscn`（`Infantry_native_v3.glb` + `InfantryAnimationDriver`）。

## 运行方式

- 编辑器：打开 `G:\AIRTS\AI_RTS` 后直接运行 `tests/manual/InfantryCombatReview.tscn`（F6）。
- 命令行窗口模式：
  `G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe --path G:\AIRTS\AI_RTS res://tests/manual/InfantryCombatReview.tscn`
- 无头自检（逐个触发与按钮相同的处理函数，打印 SMOKE_PASS/SMOKE_FAIL 并带退出码）：
  `...console.exe --headless --path G:\AIRTS\AI_RTS res://tests/manual/InfantryCombatReview.tscn -- --smoke`

## 场景布置

- 左侧面板为验收操作区；右上角为游戏原有 HUD/小地图。
- 蓝方（Human）只有 1 名受检步兵，出生在 (10, 0, 2)。
- 红方（ReviewEnemy）：1 个靶子步兵 (12.3, 0, 2) + 1 辆爆炸用坦克 (16.3, 0, 2)。
- 基线场景原有单位（坦克/炮塔等）已全部停火隔离，不会干扰验收。
- 命中/开火均为真实投射物与真实伤害，**没有伪造动画**。

## 按钮说明（自上而下）

| 按钮 | 作用 | 备注 |
| --- | --- | --- |
| 重置场景 | 释放当前步兵/靶子/爆炸坦克并重新部署，清零开火计数 | 可连点，已做令牌防竞态 |
| 移动 | 对步兵下真实强制移动命令（左右交替 6m），看 Run 与位移 | |
| 射程外攻击与追击（调试：传送靶子） | 靶子传送到 (10, 0, 24)，步兵普通攻击 → 追击约 22m → 站定开火 | 传送仅为省去手动点选，命令链真实 |
| 停止并停火 | StopUnits + HoldFire，确认回 Idle 且不补播旧开火 | |
| 连续子弹命中（调试：提高步兵血量） | 靶子开火射击步兵（血量临时 50），观察每次命中重启 Hit | 调试血量，验收后重置 |
| 普通死亡（调试：步兵血量=0.25） | 靶子真实步枪击杀步兵，观察独立 Death 视觉播完、定格、清理 | |
| 致死爆炸（调试：步兵血量=1） | 手动经 `ProjectileRuntime.LaunchEntity` 发真实坦克炮弹，观察 HitHeavy 击飞、落地定格、方向与清理 | 炮口来自真实爆炸坦克 |
| 近景观察 开/关 | 在步兵附近生成跟随相机（可看清后坐、受击顿挫、击飞落地）；关闭回到战术相机 | 步兵阵亡时相机定格原位 |

## 状态面板

实时显示（0.2s 刷新）：步兵 HP/位置、当前 Action 脚本路径（含子动作）、
动画名/进度/播放速度、开火事件计数、靶子状态、最近命令回执（接受数）。
步兵阵亡后面板显示死亡视觉数量，并提示先重置。

## 验收要点清单

1. 待命 Idle 循环；移动/追击全程 Run，无 Run/Idle 闪切。
2. 追击中绝不出现 Fire；进射程刹停后的第一枪即播 Fire。
3. 连续射击每次都从 Fire 首帧重启；停火/冷却中不循环播放 Fire。
4. 连续中弹每次立刻重启 Hit；Hit 优先于 Fire，被打断的开火不补播。
5. 普通致死 → 独立 Death 视觉；致死爆炸 → HitHeavy 击飞且背向爆点；
   单位立即退出战斗，视觉播完定格约 1s 后自动清理，不残留碰撞。
6. 移动中开火保持 Run（当前 Fire 为全身站姿动画，属预期）。
7. 暂停/变速/反复重置不会让动画提前结束、卡死或重复播放（自动测试已覆盖暂停；本场景重点人工复核重置与连点）。

## 已知边界

- 标注"调试"的血量修改与靶子传送仅用于验收准备，不进平衡数值。
- 当前 Fire 为全身站姿动画，移动开火时保持 Run 是既定表现方案；
  如需移动射击的上身分层混合，属于动画资产/架构改动，交另一位开发者决策。
- 场景退出即全部释放；死亡视觉归属 Match，随场景卸载一并回收。
