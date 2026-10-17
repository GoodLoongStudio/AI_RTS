# 闭环报告：重型坦克炮弹速度 ×1.5（2026-10-10）

## 用户口径

"重型坦克的炮弹速度 x1.5"。

## 权威来源（单点，已核验无镜像）

`source/match/units/projectiles/HeavyCannonShell.tscn` 根节点
`metadata/flight_speed_mps`：**10.0 → 15.0**。

排除的其它可能来源：

| 位置 | 结论 |
|---|---|
| `config/godot/demo.assets.v1.json` `weaponAssets` | 只有 `weaponId → projectileScenePath`，**不含速度** |
| `config/balance/demo.balance.v1.json` `heavy_tank_cannon` | 只有 `baseDamage/cooldown/range/targetDomains/warheadId`，**不含弹速** |
| `source/csharp/GodotAdapter/Combat/ProjectileRuntime.cs` | 只 `Instantiate` 场景，**不注入速度** |
| `source/match/units/projectiles/CannonShell.gd` `FLIGHT_SPEED_MPS = 12.0` | 坦克炮弹默认值，被场景 meta 覆盖 |
| `ProjectileVisuals.PROJECTILE_BY_UNIT_SCENE` | 只做"单位场景 → 弹体场景"映射 |

⇒ 改一处即闭环，无需同步镜像表。

## 影响面（弹体是权威端节点，不只是视觉）

`CannonShell.gd:_ready`：`_flight_seconds = 发射点→落点距离 / speed`，飞满后
`projectile_runtime.ResolveImpact()` 结算伤害。所以 ×1.5 同时提前**命中时刻**：

| 射击距离 | 改前 | 改后 |
|---|---|---|
| 15 m | 1.500 s | 1.000 s |
| 40 m（最大射程） | 4.000 s | 2.667 s |

弹道形状不变：`arc_height = 2.2 m` 是独立的 meta，峰高不随速度变。

## 改动文件

| 文件 | 改动 |
|---|---|
| `source/match/units/projectiles/HeavyCannonShell.tscn:75` | `metadata/flight_speed_mps` `10.0` → `15.0`（**唯一行为改动**） |
| `tests/automated/HeavyTankShellSpeedTest.gd` / `.tscn` | 新增：静态 meta + 真实 Match 反推弹速 |
| `tests/automated/HeavyTankShellSpeedTest.gd`（收尾） | 独立复核发现它直接 `get_tree().quit()` 没回收整局 ⇒ 泄漏 43 实例 + 9 资源；**已改为 `SmokeTestExit.request(..., a_match)`**，现为套件里唯一**日志干净**项 |
| `config/full_regression_suite.json` | 新增套件 `heavy-tank-shell-speed` |

## 证据

命令：

```
python tools/run_targeted_godot_tests.py \
  --godot G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe \
  --ids heavy-tank-howitzer,heavy-tank-shell-speed
```

结果：**2/2 通过，rc=0**，`heavy-tank-shell-speed` 的 `日志干净 = 是`。

静态口径 + 运行时反推（`build/targeted_regression/heavy-tank-shell-speed.log`）：

```
[INFO] meta flight_speed_mps: heavy=15.0 tank=12.0
[PASS] 重坦炮弹飞行速度应为 15.0 m/s（实际 15.0）
[PASS] 坦克炮弹飞行速度不应被本改动影响（应 12.0，实际 12.0）
[PASS] 实测弹速应等于 15.0 m/s（实际 15.00，比值 1.000）
[PASS] 炮弹应在采样窗口内飞满并命中回收
Heavy tank shell speed: 0 failure(s)
```

守卫：同一条测试还断言**坦克炮弹仍是 12.0**，防止改动外溢到普通坦克。

## 独立复核（Verifier 子代理，方法与申报方不同）

复核方**不读场景 meta、不读 `_flight_seconds`**：在真实对局里对 18 m 外地面强制攻击，
逐帧墙钟采样**弹体自身的 `global_position`**，从出现到 `queue_free`，用 4 种算法互相校验。
探针：`tests/automated/_IndepVerifyRepairSpeed.gd --phase=shell`。

| 算法 | 重坦炮弹 | 对照：普通坦克炮弹 |
|---|---|---|
| ① 首末 3D 弦速 | **15.060** m/s | **11.974** m/s |
| ② 水平弦速 | **14.946** m/s | **11.964** m/s |
| ③ x/z 线性回归 | **14.837** m/s | **11.971** m/s |
| ④ 首点→爆炸反推落点 | **15.238** m/s | — |

- 重坦炮弹：138 帧 / 墙钟 **1.075 s**；4 种算法 14.84–15.24，偏离 15.0 **≤1.1%** ⇒ **证实**。
- 对照组误差 0.3% ⇒ 测量法精度足够，且证明**未外溢**（普通坦克仍是 12）。

`VERDICT: CONFIRMED`

## 未验证项

- **改前弹速 10.0 只有 git 证据**（`git show HEAD:` 为 `10.0`），复核方未获授权改 tscn，
  所以"改前弹速"**没有**运行时实测；×1.5 的**倍率**由 git 前后值与改后实测共同支撑。
- 未做可见实例截图：本改动无视觉形状变化（弹道仍为同一条抛物线，只是更快），
  "看得见"的差异是命中提前，属时序而非画面。
- 未跑全量回归套件（只跑定向相关集）。

## 并行工作区风险

`git status` 显示工作区有大量其它 Agent 的未提交改动（含
`CannonShell.gd`、`ProjectileVisuals.gd` 等同事文件）。
本次只改 `HeavyCannonShell.tscn` 的 1 行 + 新增 2 文件 + 套件登记 + 自己新测试的收尾方式，
未触碰他人改动。

## candidate / champion

单候选单轮：candidate = `flight_speed_mps 15.0`，一次到位、定向回归全绿、
独立复核 `CONFIRMED` ⇒ 晋级 champion。连续未提升轮数：0。
