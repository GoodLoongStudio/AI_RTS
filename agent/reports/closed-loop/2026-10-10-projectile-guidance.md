# 弹体追踪规则闭环报告

用户口径：除防空炮外，所有发射弹体取消追踪；坦克和重坦炮弹爆炸范围扩大。

实现位于当前开发工程 `G:/AIRTS/AI_RTS`。权威入口是 [ProjectileRuntime.cs](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Combat/ProjectileRuntime.cs:103)：只对武器 ID `anti_air_turret_rocket` 刷新目标位置，其他实体弹体使用发射快照落点。`WarheadDamageResolver.cs` 按冻结爆点和目标 footprint 判定普通直击弹，防止目标移出弹道后隔空命中。炮弹/火箭脚本在普通模式冻结 `_aim_point`，客户端回放传递 `tracks_target` 与目标路径。

坦克和重坦使用独立 `tank_cannon_splash` 弹头，半径由 2.5m 改为 4.0m；对地炮塔、火箭兵等继续使用 2.5m 的 `cannon_splash`。配置同步在 [demo.balance.v1.json](G:/AIRTS/AI_RTS/config/balance/demo.balance.v1.json:29) 和 [adjutant-e2e.balance.v1.json](G:/AIRTS/AI_RTS/config/balance/adjutant-e2e.balance.v1.json:29)。

验证结果：工作区目标检查 rc=0；`dotnet build OpenRTS.sln --no-restore --nologo` rc=0；JSON 解析和 `git diff --check` 通过。真实 Match 的 [ProjectileGuidanceSmokeTest 日志](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-guidance/round-02-targeted/projectile-guidance.log) rc=0，证明普通坦克炮弹目标横移后不追中、冻结落点 4.5m 内单位受 4m 溅射、防空炮移动空中目标仍命中。核心新增的普通脱靶与防空追踪测试均通过。

定向回归为 6/8 通过：`heavy-tank-howitzer`、`muzzle-discipline`、`tank-move-fire`、`sniper-rocketeer`、`unit-auto-attack` 和新指导探针通过；`projectile-lifecycle` 因火箭实伤 1.04 与旧断言配置值 1.0 不一致失败，`tank-ordinary-attack` 因旧 Stop 时序断言失败。全核心测试 rc=1，失败集中在共享工作树已有的生产服务和配置/迁移基线，新增两条弹道规则测试没有失败。详细记录在 [round-02 verification](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-guidance/round-02/verification.md)。

当前 candidate 状态为 `needs-review`，没有晋级 champion。真实联机客户端防空视觉追踪尚未用网络 Match 验证，也没有生成并打开可见窗口截图；因此这两项不能宣称通过。
