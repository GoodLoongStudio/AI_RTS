# 闭环验证报告：弹速统一 2 倍（重坦豁免）+ 命中判定范围放大

- 日期：2026-10-12
- 计划：`agent/plans/2026-10-12-projectile-speed-and-hit-window-plan.md`
- 运行目录：`agent/runs/speedx2-combat/`
- 状态：`complete`（附未验证项）

## 1. 目标与验收条件

- 除重型坦克外所有弹种飞行速度 ×2；重坦保持 15 m/s。
- 所有单位（含重坦）命中判定范围按用户选的"激进档"放大：直射 +2.0m 容差、溅射半径 ×2。
- 伤害、冷却、射程、视野、单位碰撞半径一律不动。

## 2. 实施改动

| 文件 | 改动 | 旧 → 新 |
|---|---|---|
| `source/match/units/projectiles/CannonShell.tscn:81` | `metadata/flight_speed_mps` | 12.0 → **24.0** |
| `source/match/units/projectiles/RifleRound.tscn:19` | 同上 | 45.0 → **90.0** |
| `source/match/units/projectiles/Rocket.tscn:171` | 同上 | 5.33 → **10.66** |
| `source/match/units/projectiles/HeavyCannonShell.tscn:81` | **不动** | 15.0（另一会话 2026-10-10 定的慢榴弹手感，本次豁免） |
| `source/match/units/projectiles/CannonShell.gd:15`、`Rocket.gd:18` | 兜底常量与场景 meta 同值 + 注释记录口径 | 12.0→24.0、5.33→10.66 |
| `config/balance/demo.balance.v1.json` + `adjutant-e2e.balance.v1.json` | `warheads[].radiusMeters`（area） | cannon_splash 2.5→**5.0**、tank_cannon_splash 4.0→**8.0** |
| `source/csharp/Application/Combat/WarheadDamageResolver.cs` | 新增 `internal const DirectHitToleranceMeters = 2.0f`，计入非制导直击命中窗 | 直击窗 0+footprint → **2.0+footprint** |

为什么直击容差写在代码而不是 balance：`BalanceConfigLoader.cs:275` 规定
`IntendedTargetOnly` 弹头的 `radiusMeters` 必须为 0，写 2.0 会**整份平衡表被拒**（级联表现见
`airts-build-import-is-the-real-gate`）。容差只放宽"目标仍在冻结落点窗内"的判定，
不会把直击弹变成溅射（新用例专门锁住这一点）。

## 3. 运行时实测

`tests/dev-probes/_ProjectilePaceProbe.tscn`（真实 Match，四单位各开一枪，抓到自己那发弹体后
用弹体内部算出的飞行时长 ÷ 实测发射距离反推）：

| 单位 / 弹体 | 场景 meta | 实测距离 | 实测飞行 | 反推弹速 | 期望 |
|---|---:|---:|---:|---:|---:|
| Tank / CannonShell | 24.0 | 8.42 m | 0.351 s | **24.00 m/s** | 24.0 ✓ |
| HeavyTank / HeavyCannonShell | 15.0 | 8.84 m | 0.589 s | **15.00 m/s** | 15.0 ✓（豁免生效） |
| Sniper / RifleRound | 90.0 | 9.76 m | 0.108 s | **90.00 m/s** | 90.0 ✓ |
| Rocketeer / Rocket | 10.66 | 9.76 m | 0.916 s | **10.66 m/s** | 10.66 ✓ |

同一探针打印的命中窗权威值：`direct_full_damage radiusMeters=0.0`（直击走代码容差）、
`cannon_splash 5.0`、`tank_cannon_splash 8.0`。日志 `agent/runs/speedx2-combat/_ProjectilePaceProbe.log`
（`Projectile pace probe: 0 failure(s)`）。

命中窗算术（直击，非制导）：旧 = 目标碰撞半径；新 = 目标碰撞半径 + 2.0m。
坦克 footprint ≈ 2.02m ⇒ 窗从 ≈2.0m 扩到 ≈4.0m；溅射（重坦）从 4.0+2.0≈6.0m 扩到 8.0+2.0≈10.0m。

## 4. 截图验收

未出截图：本轮改的是飞行时长与判定半径，判定半径在画面上**不可见**（见 §7 的视觉失配风险），
"看起来对"不具备判别力；改用 §3 的实测弹速与 §5 的边界用例作判据。

## 5. 自动化验证

| 命令 / 用例 | rc | marker | 结论 |
|---|---:|---|---|
| `dotnet build OpenRTS.sln -v q --nologo` | 0 | 已成功生成，0 错误 | C# 改动编译通过 |
| `dotnet run --project ./tests/core/AI_RTS.Core.Tests.csproj` | 1（改前亦 1） | `AI_RTS.Core tests completed: 63 test(s), 0 failure(s)` | 新增直击容差用例通过（2.4m 命中 / 2.6m 脱靶 / 旁观者不受伤）；Balance config 21 红、Production service 3 红与改前逐条同数 |
| `_ProjectilePaceProbe` | 0 | `Projectile pace probe: 0 failure(s)` | 四种弹速实测全部命中期望值 |
| `HeavyTankShellSpeedTest` | 0 | `Heavy tank shell speed: 0 failure(s)` | 弹速总表（24/15/90/10.66）+ 重坦真局实测 15.00 双验 |
| `projectile-guidance`（冻结落点规则） | 0 | `Projectile guidance smoke test completed: 0 failure(s)` | 目标瞬移 12m 仍脱靶（新窗 10.0m < 12m）；4.5m 邻居仍被溅到 |
| `sniper-rocketeer` | 0 | `Sniper/Rocketeer smoke test completed: 0 failure(s)` | 狙击远点命中、火箭 5m 溅射仍成立 |
| `heavy-tank-howitzer` | 1 | 1 failure(s)：`重坦视野应为 20m（实际 24.0）` | **非本任务**：视野是另一会话未提交改动（HEAD 10.0 → 工作区 24.0），我没碰 `sightRangeMeters`；抛物线峰高/弹道断言本次通过 |
| `tank-force-attack` | 0 | `Tank force attack smoke test completed: 0 failure(s)` | 12 条 `[DAMAGE]` 结算正常（强制攻击友军路径未被放宽） |
| `rule-ai-battlegroup` | 0 | `Rule AI battlegroup smoke test completed: 0 failure(s)` | AI 满编战斗 0 红，14 条 `[DAMAGE]` |
| `attack-range-indicator` | 0 | `Attack range indicator smoke test completed: 0 failure(s)` | 射程指示 UI 未受半径改动影响（它画射程，不画判定半径） |
| `net-infantry` | 1 | 仅 `联机对局应完成加载并出现 Match`，0 条 `[DAMAGE]` | **夹具前提未满足**，非本任务：该用例 `prelaunch_server: true`，需要 runner 预启 24682 专用服；`tools/run_full_regression.ps1:308-312` 的注释原文就写着单跑必出这条失败信息。联机会话链路本轮未验证 |

配置健康检查：本轮所有 Godot 运行日志里 `平衡配置加载失败` 计数为 0（直击容差没有踩到
"给 IntendedTargetOnly 弹头写半径 ⇒ 整表被拒"那个坑）。

判据变更说明（改的是产品口径，不是把红改绿）：`EXPECTED_TANK_SPEED` 12→24、
`_IndepVerifyRepairSpeed` 对照组 12→24，两处都在文件注释里写明 2026-10-12 口径与重坦豁免；
`HeavyTankShellSpeedTest.gd` 与 `_IndepVerifyRepairSpeed.gd` 是另一会话的**未跟踪新文件**，
我只改了其中的弹速期望值，未动其结构。

## 6. 独立复核

未做。复核入口两条：
1. `grep -n flight_speed_mps source/match/units/projectiles/*.tscn` ⇒ 24.0 / 15.0 / 90.0 / 10.66；
2. `res://tests/dev-probes/_ProjectilePaceProbe.tscn` headless 跑一次 ⇒ 四行实测弹速 + 三行 warhead 半径。

## 7. 未验证项与风险

- **爆炸视觉与判定半径失配（建议下一步处理）**：`ShellExplosion.tscn` 是固定尺寸粒子
  （`emission_sphere_radius 0.75/0.9`），不读 warhead 半径。现在 8m 溅射看起来仍像 ~2m 爆炸，
  玩家会遇到"没被炸到也掉血"。要修就是把落点特效按 `radiusMeters` 缩放（另一会话正在改弹体视觉，需协调）。
- **溅射放大 = 友军误伤圈同步放大**：`WarheadDamageResolver.Resolve` 对 area 弹头不拦友军，
  按 `friendlyFireDamageMultiplier=0.5` 结算（既有 C# 用例 `WarheadResultsAreStableUniqueAndRespectFriendlyFire` 锁的就是这条）。
  重坦/坦克在密集队形里的自伤范围因此从 ≈6m 扩到 ≈10m。若不想误伤，可把这两个弹头的友伤倍率设为 0。
- **步枪曳光近乎不可见**：90 m/s 下 10m 只需 0.108s（约 6 个物理帧），视觉接近瞬时命中。
  实测已确认（§3），是否保留 45 m/s 纯观感取舍，等用户定。
- **弹速/命中窗未在满编大会战里做前后对比**：`rule-ai-battlegroup` 等实战回归本轮只跑"改后"单侧，
  没有取"命中率提升了多少"的量化数（要做需可逆切换 balance + 场景 meta 再跑一遍，参考
  `2026-10-12-production-construction-speed-2x.md` §5.2 的对照法）。
- **并发风险**：`HeavyCannonShell.tscn`、`ShellExplosion.tscn`、`ProjectileVisuals.gd` 是另一会话
  00:36 的在飞弹体视觉改动；`git status` 全程 1100+ 未提交文件。我只按行改了自己负责的 5 个文件与 2 处半径，
  未整文件重写、未回滚他人工作。重坦 15 m/s 与其豁免判据保持原样并由实测复证。
- **联机会话链路未验证**：`net-infantry` 因缺预启专用服而没有跑到战斗阶段（见 §5 归因）。
  服务器侧同样吃这份 balance 与这些场景 meta，理论上同步生效，但没有实测。
- **改动存续已复核**：本任务实施与末轮回归之间隔了约 7 小时（并发会话活跃期，且有批量还原的前科），
  08:51 重新逐项确认：四个 `flight_speed_mps` 仍为 24.0/15.0/90.0/10.66、两处兜底常量同值、
  两份 balance 的 `radiusMeters` 仍为 0.0/5.0/8.0、上一轮的 `requiredWork` 减半值未被回滚、
  `DirectHitToleranceMeters = 2.0f` 仍在 `WarheadDamageResolver.cs:20` 并被 `:93` 使用。
- **打包版不生效**：与上一轮同理，需重新启动游戏或重新导出成品。
