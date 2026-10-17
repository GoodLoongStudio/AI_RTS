# 任务计划：弹速统一 2 倍（重坦豁免）+ 命中判定范围放大

- 状态：`complete`（报告：`agent/reports/closed-loop/2026-10-12-projectile-speed-and-hit-window.md`）
- 创建时间：2026-10-12
- 负责人 Agent：Qoder

## 目标

玩家可观察结果：除重型坦克外所有弹种飞得快一倍（脱靶窗口随之减半）；所有单位（含重坦）的命中判定范围按"激进档"放大——直射 +2.0m 容差、溅射半径 ×2。

## 非目标

- 不改单发伤害、冷却、射程、视野、单位碰撞半径。
- 不改重坦弹速（另一会话 2026-10-10 定为 15 m/s 慢榴弹手感，本次沿用其豁免）。
- 不改爆炸视觉尺寸（`ShellExplosion` 是固定尺寸粒子，与半径无绑定）。

## 权威口径

| 领域 | 权威来源 | 旧值 | 新值 |
|---|---|---:|---:|
| 弹速 | 弹体场景根节点 `metadata/flight_speed_mps`（脚本常量仅兜底） | CannonShell 12 / RifleRound 45 / Rocket 5.33 / HeavyCannonShell 15 | 24 / 90 / 10.66 / **15 不变** |
| 溅射命中窗 | `config/balance/demo.balance.v1.json` → `warheads[].radiusMeters`（area 弹头） | cannon_splash 2.5 / tank_cannon_splash 4.0 | 5.0 / 8.0 |
| 直击命中窗 | `WarheadDamageResolver.CanHit`：窗 = 弹头半径 + 目标碰撞半径 | 0 + footprint | 0 + footprint + **2.0m 容差** |
| 直击不能用 balance 半径 | `BalanceConfigLoader.cs:275`：IntendedTargetOnly 的 radiusMeters 必须为 0，非零整表拒绝 | — | 容差只能写在代码权威里 |

## 改动范围

- 已修改：3 个弹体 `.tscn`（meta）+ `CannonShell.gd`/`Rocket.gd`（兜底常量与注释）、两份 balance 的 2 个 area 半径、
  `WarheadDamageResolver.cs`（新增 `internal const DirectHitToleranceMeters = 2.0f`）、
  `tests/core/Program.cs`（新增直击容差边界用例）、`tests/core/BalanceConfigLoaderTests.cs`（半径断言 3 条）、
  `tests/automated/HeavyTankShellSpeedTest.gd`（弹速总表 + 对照值 12→24）、`tests/automated/_IndepVerifyRepairSpeed.gd`（对照 12→24）。
- 并发风险：`HeavyCannonShell.tscn`/`ShellExplosion.tscn`/`ProjectileVisuals.gd` 是另一会话 00:36 的在飞弹体视觉改动，未覆盖；
  `HeavyTankShellSpeedTest.gd` 与 `_IndepVerifyRepairSpeed.gd` 同为该会话的未跟踪新文件，我只改了其中的弹速期望值。

## 验证矩阵

| 判据 | 方法 | 结果 |
|---|---|---|
| 弹速真的被权威发射路径吃进去 | `tests/dev-probes/_ProjectilePaceProbe.tscn` 真局抓弹体反推 | Tank 24.00 / Heavy 15.00 / Sniper 90.00 / Rocketeer 10.66 m/s，0 failure |
| 直击容差边界 | `tests/core` 新用例（2.4m 命中 / 2.6m 脱靶 / 旁观者不受伤） | AI_RTS.Core 63 项 0 failure |
| 溅射半径进 Catalog | `BalanceConfigLoaderTests` 3 条新断言 | 无新增红（Balance config 21 红为既有） |
| 冻结落点规则未被放宽成追命中 | `projectile-guidance` 冒烟（目标瞬移 12m 必须脱靶、4.5m 邻居必须溅到） | 0 failure |
| 直击/溅射实战未坏 | sniper-rocketeer / heavy-tank-howitzer / net-infantry / tank-force-attack / rule-ai-battlegroup / attack-range-indicator | 见报告 §5 |
| 配置整表未被拒 | `dotnet build OpenRTS.sln` + 真局日志无"平衡配置加载失败" | 0 错误、无该日志 |
