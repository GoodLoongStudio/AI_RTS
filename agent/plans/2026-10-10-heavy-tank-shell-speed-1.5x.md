# 重型坦克炮弹速度 ×1.5

用户口径：重型坦克的炮弹速度 ×1.5。

## 权威来源

`source/match/units/projectiles/HeavyCannonShell.tscn` 根节点
`metadata/flight_speed_mps`（10.0 → 15.0）。已核验：

- `ProjectileVisuals.PROJECTILE_BY_UNIT_SCENE` 把 `HeavyTank.tscn` 映射到该场景；
- `config/godot/*.assets.v1.json` 的 `weaponAssets` 只记 `projectileScenePath`，不含速度；
- `config/balance/*.balance.v1.json` 的 `heavy_tank_cannon` 只有伤害/冷却/射程/弹头，不含弹速；
- `ProjectileRuntime.cs` 只 `Instantiate` 场景，不注入速度；
- `CannonShell.gd` 的 `FLIGHT_SPEED_MPS := 12.0` 是坦克炮弹默认值，被场景 meta 覆盖。

⇒ 单点改动，无镜像表需要同步。

## 影响面

弹体是**权威端**节点：`_flight_seconds = 实际发射距离 / speed`，飞满后 `ResolveImpact`。
所以 ×1.5 同时缩短**命中时刻**（玩法可见），不只是视觉：

| 射程 | 改前 | 改后 |
|---|---|---|
| 15m | 1.50s | 1.00s |
| 40m（最大射程） | 4.00s | 2.67s |

抛物线峰高 `arc_height = 2.2m` 不随速度变（峰高是独立 meta），弹道形状不变、只是更快。

## 步骤

1. [x] S0：确认权威来源唯一性；定位 `HeavyCannonShell.tscn:75`。
2. [x] S1：改 `flight_speed_mps` 10.0 → 15.0。
3. [x] S2：真实 Match 探针复测弹体飞行时长（15m 距离 ≈1.0s，改前 ≈1.5s）；
   独立复核用弹体 `global_position` 回归独立反推得 **14.84–15.24 m/s**（4 种算法），
   对照普通坦克炮弹 11.97 m/s ⇒ 未外溢。
4. [x] S3：`HeavyTankHowitzerTest` + 新增 `HeavyTankShellSpeedTest` 回归 2/2 rc=0；
   闭环报告 `agent/reports/closed-loop/2026-10-10-heavy-tank-shell-speed.md`。

## 后续（由独立复核发现）

新测试原先直接 `get_tree().quit()`，未回收整局 ⇒ 命中 ObjectDB/resources/RID 泄漏禁则
（43 实例 + 9 资源）。已改为 `SmokeTestExit.request(get_tree(), rc, a_match)`，
现为套件里唯一"日志干净"项。

预算：单候选一轮；本改动一行、可回滚。硬门禁失败只撤自己的改动。
