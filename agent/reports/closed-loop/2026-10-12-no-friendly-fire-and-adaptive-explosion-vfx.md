# 闭环验证报告：取消流弹误伤 + 爆炸特效按判定半径自适应

- 日期：2026-10-12
- 计划：`agent/plans/2026-10-12-projectile-speed-and-hit-window-plan.md`
- 运行目录：`agent/runs/speedx2-combat/`
- 录像（最终代码态）：`agent/runs/speedx2-combat/video/explosion-07.mp4`
  （12 FPS / 27s / 323 帧画面在变 / PrintWindow 窗口客户区）
- 抽帧：`review/fix8/`（定稿）、`review/cal8b|final8/`（返工前对照）、`review/ring8|ring5/`
- 状态：`complete`（附未验证项）

## 1. 目标与验收条件

1. 子弹不得有友军误伤。
2. 爆炸特效尺寸"稍微比爆炸半径大一点，且自适应"（跟着判定半径走，不是固定一档）。
3. 步枪曳光弹速维持 90 m/s（用户："先 90 吧"）。
4. 按 `skills/airts-temporal-playtest/SKILL.md` + `skills/闭环验证工作法.md` 出**录像**并实际抽帧查看。

## 2. 实施改动

| 文件 | 改动 | 口径 |
|---|---|---|
| `source/csharp/Application/Combat/WarheadDamageResolver.cs` | 友军跳过条件从"仅 IntendedTargetOnly"推广到**两种模式**：`candidate.OwnerId == SourcePlayerId && !AllowsFriendlyDamage ⇒ continue` | 普通溅射不再波及自己人；玩家**主动**强制攻击自己单位（`ExplicitForceAttacking.gd:45` 置 `allows_friendly_damage=true`）仍按倍率结算 |
| `config/balance/*.json` | **净变化为零**（曾把 area 倍率改 0.0，后回滚到 0.5） | 零误伤的规矩写在判定层，不靠把数据清零——清零会连"主动打自己"这条既有机制一起砍掉 |
| `source/csharp/GodotAdapter/Combat/ProjectileRuntime.cs` | 新增 `GetWarheadRadius(attackId)` | 把权威判定半径交给表现层，视觉与结算同源 |
| `source/match/units/projectiles/CannonShell.gd`、`Rocket.gd` | 命中结算**前**取半径，写进特效 meta `blast_radius_m` | ⚠ 结算后攻击已从 `_active` 摘除，再取只会拿到 0（实测踩过） |
| `source/match/units/projectiles/ShellExplosion.gd` | 按 meta 判定半径自适应：`spread = clamp(半径 ÷ 8.0, 0.45, 1.0)`，火花尺寸只按 `spread^0.5` 长（按实例 `duplicate()`，不改共享资源） | 直击弹头半径 0 ⇒ 原尺寸；映射函数是 `static` 的，探针直接调用它取期望值，不在测试里重抄公式 |
| `tests/core/Program.cs` | 新增 `AreaSplashSparesFriendlyWithoutForceAttack`（正反两支）；既有 `WarheadResultsAreStableUniqueAndRespectFriendlyFire` 改走显式 ForceAttack 路径 | 见 §3 |
| `tests/core/BalanceConfigLoaderTests.cs` | 断言 area 倍率仍为 0.5，并写明"零误伤在判定层" | 防止后人再用清零数据的方式"修"误伤 |
| `tests/dev-probes/_ProjectilePaceProbe.gd` | 新增落点特效尺寸实测 + 友军零误伤正反例 | 见 §3 |
| `tests/dev-probes/_ExplosionSizeDemo.gd/.tscn` | 新增录像演示件：真实 Match、爆点地面画**精确 8.0m 参考圈**、事件时间轴落盘 | 见 §4 |

### 过程中挖出的三个引擎/实现坑（都写进了代码注释）

1. **结算后再问判定半径只会拿到 0**：`ResolveImpact` 会把攻击从 `_active` 移除，所以半径必须在结算前取。
2. **节点 `scale` 不放大粒子尺寸**：只放大散开的位置，每颗火花仍按 `process_material.scale_min/max` 画原大小
   ⇒ 录像里像"撒了一地碎屑"，不像爆炸。
3. **`ParticleProcessMaterial.scale_min` 与 `scale_max` 在这版引擎里联动**：
   连写 `mat.scale_min *= f; mat.scale_max *= f` 会被乘两遍（实测 1.4 → 4.9 → 30.1，预期 8.6）。
   必须先取原值再分别赋值。这条是被探针的"火花尺寸比值应等于节点 scale"断言逼出来的。

## 3. 运行时实测

### 爆炸尺寸自适应（`_ProjectilePaceProbe`，headless，`gate-_ProjectilePaceProbe.log`）

| 阶段 | blast_radius_m | 散开 scale | 火花 scale | 判定 |
|---|---:|---:|---:|---|
| Tank（tank_cannon_splash） | 8.00 | 1.000 | 1.000 | = 原美术尺寸（最大档锚点）✓ |
| HeavyTank（同上） | 8.00 | 1.000 | 1.000 | ✓ |
| Rocketeer（cannon_splash） | 5.00 | 0.625 | 0.791 | ✓ 按比例缩小，火花只按平方根长 |
| Sniper（RifleRound） | 无特效 | — | — | `impact_explosion=false`，预期内 |

探针期望值直接调 `ShellExplosion.spread_scale_for()/puff_scale_for()`，不重抄公式；
另加一条硬判据 `散开 ≤ 1.0`，防止以后又被改成"放大铺满杀伤圈"那类返工。

### 友军零误伤

- 单元层（`AreaSplashSparesFriendlyWithoutForceAttack`）：半径 3m 的爆炸里，敌方候选掉血、
  站在爆点里的友军**不结算**；同一组候选改成显式 ForceAttack 后友军按 0.5 倍率受创 —— 两支都断言，
  防止"把主动机制一起砍掉"被当成修好了误伤。
- 真局层（探针，爆点 3m 放己方坦克、爆点上放敌方对照）：
  己方 `hp 100.00 → 100.00`，敌方对照 `100.00 → 85.44`，射手自身不掉血。
  正向对照是必须的：没有它，"没掉血"可能只是什么都没发生。
- 中途用可逆对照证过场景是活的：把 area 倍率临时改 0.0→0.5 重跑，己方立刻 `100 → 92.72` 且探针报红。
  随后设计从"数据清零"改成"判定层闸门"，数据已回滚（`diff -q` 与快照一致）。

## 4. 录像验收（按 skill 的非干扰纪律）

- 采集：`tools/dev/record_playtest.py record --pid <本轮PID> --fps 12 --seconds 30 --method printwindow`；
  游戏窗口 `--position -4000,-4000` 屏外、`--audio-driver Dummy`、不置顶不抢焦点、不动真实光标；
  游戏与录制器都以 `CREATE_NO_WINDOW` 启动，不弹控制台。
- 第一版踩坑：`*_console.exe` 的 PID 是 console 包装进程，窗口在子进程上，录制器报
  `PID has 0 visible windows`；换非 console exe 后正常（hwnd 200074，title `Open RTS (DEBUG)`）。
- 时间轴：demo 自写 `demo-events-<wallms>.jsonl`（`engine_ms` + `wall_ms`），与 `explosion-06.frames.jsonl` 同机墙钟对齐。
- **实际打开看了帧**：`review/final8/frame-0000050.jpg`（t=4.17s，一发 8m 爆炸后 0.06s）——
  画面非黑/白帧；青色椭圆是**精确 8.0m 判定圈**，火球与烟团主体在圈内、外缘略超圈（约 1.1 倍），
  符合"稍微比爆炸半径大一点"；圈心的己方坦克全程站立。
- 尺寸映射**返工过一次**（用户实拍判"过于离谱"）：
  - 第一版按"包络 = 判定半径 ×1.15"做，标称常数靠肉眼看录像帧估（估成 1.8m），结果 8m 档放大到
    `scale 5.111`，26 颗方块粒子被铺成满屏地砖 —— 用 OpenCV 量用户实拍：火团跨约 250px，
    而 15m 射程圈约 514px ⇒ 云团直径 ≈ 7-8m 起步且单颗火花被放大到 1.5m 见方，观感确实离谱。
    根因是**把方块粒子美术硬拉到 16 米宽的杀伤圈**，不是比例算错。
  - 定稿：以最大档 8m = 原美术尺寸（`spread 1.0`）为锚点，更小半径按比例缩（5m → 0.625），
    火花尺寸只按 `spread^0.5` 长（5m → 0.791），并加 `MAX_SPREAD_SCALE = 1.0` 硬顶，防止再被放大。
  - 定稿实测（`probe-fx6.log`）：8m → 散开 1.000 / 火花 1.000；5m → 0.625 / 0.791；探针 0 failure。
  - 定稿录像 `video/explosion-07.mp4`（323 变化帧）抽帧 `review/fix8/frame-0000048.jpg`：
    火团收在 8m 圈内约三分之一处（OpenCV 量得 90×97px ≈ 5.9m 宽），观感回到正常 RTS 爆炸。
- **代价说清楚**：现在视觉包络（≈2.9m 半径）**小于** 8m 杀伤半径，边缘被炸到的单位看起来"没炸到"。
  要让玩家看清杀伤圈，正确做法是加地面冲击波 decal/环，而不是把方块火球放大 —— 本轮未做，等用户点头。
- 录制器 `rc=2 / status=partial` 的唯一原因是片尾窗口随对局正常关闭
  （`Window disappeared or no longer belongs to target PID`），312/333 帧画面在变，不影响本段验收。
- 事件时间轴（最终那轮）：三段相位里 `friend_hp` 恒为 300.0，敌方靶子 `300 → 281.8 → 258.4 → 205.9`。

## 5. 自动化验证

| 命令 / 用例 | rc | 结果 |
|---|---:|---|
| `dotnet build OpenRTS.sln -v q --nologo` | 0 | 0 错误 |
| `dotnet run --project ./tests/core/AI_RTS.Core.Tests.csproj` | 1（改前亦 1） | `AI_RTS.Core 64 test(s), 0 failure(s)`（含本轮 2 条新用例）；`Construction service 12/0`；Balance config 21 红、Production service 3 红与本轮改动前逐条同数 |
| `_ProjectilePaceProbe` | 0 | `Projectile pace probe: 0 failure(s)` |
| `tank-force-attack` | 0 | `0 failure(s)`（显式打自己单位的机制未被砍） |
| `projectile-guidance` | 0 | `0 failure(s)`（冻结落点/溅射邻居规则未被放宽） |
| `sniper-rocketeer` | 0 | `0 failure(s)` |
| `heavy-tank-shell-speed` | 0 | `0 failure(s)`（弹速总表 24/15/90/10.66 仍成立） |
| `rule-ai-battlegroup` | 0 | `0 failure(s)` |

非本轮引入的红（已归因，未动）：
`live-enemy-building-death` 的「人类应有工人」是开局单位构成的他人在飞改动；
`heavy-tank-howitzer` 的「视野 20 vs 24」同（HEAD 是 10.0，工作区 24.0）；
`net-infantry` 需要 runner 预启 24682 专用服（`tools/run_full_regression.ps1:308-312` 注释原文）。

## 6. 未验证项与风险

- **主动打自己单位仍会掉血**（`direct_full_damage` 与 area 弹头在显式 ForceAttack 下都按 0.5 结算）。
  用户原话是"不要误伤"，所以保留了这条既有机制；若要绝对零伤害，把两个倍率改 0 即可（要同步 3 处判据）。
- **特效仍是方块粒子美术**：本轮只改尺寸自适应，没换贴图、没加冲击波环。
- **联机会话未验证**：服务器侧吃同一份 balance 与场景，理论上同步，但没起专用服实测。
- **满编大会战的误伤/命中率未做量化统计**：只做了单点正反例；`rule-ai-battlegroup` 只作回归不判红。
- **录像 12 FPS / 27s**：符合 skill 对短特效（10-15 FPS、20-40s）的口径；比这更短的瞬时事件与真实性能 p95 不在本证据范围。
- **并发风险**：`ShellExplosion.tscn`、`HeavyCannonShell.tscn`、`ProjectileVisuals.gd` 是另一会话 00:36 的弹体视觉在飞改动，
  我只改了 `ShellExplosion.gd` 脚本逻辑与自己的探针/演示件，没动那几个场景文件；重坦 15 m/s 未动。
  全程 `git status` 1100+ 未提交文件，未做任何 reset/checkout。
- **全量回归未跑**：本轮只跑了受影响的 8 条套件；`config/full_regression_suite.json` 整套未执行。
- **打包版不生效**：需重启游戏或重新导出成品。
