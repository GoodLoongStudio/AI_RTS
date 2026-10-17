# 闭环报告：残血单位/建筑的血条常显

- 日期：2026-10-10
- 用户口径（原话）：**「残血单位和建筑的血条要一直显示的」**
- 计划：`agent/plans/2026-10-10-damaged-healthbar-persistent-plan.md`
- 状态：**已完成并验证**（静态 + 真实 Match 自动化测试 + 可见截图亲自查看 + 相邻回归）

## 1. 改动

| 文件 | 改动 |
|---|---|
| `source/match/units/traits/HealthBar.gd` | 新增 `_is_damaged()` 与 `_sync_visibility()`；`_ready()`/`_recalulate_bar_value()`/`_on_unit_deselected()`/`_on_visibility_timer_timeout()` 接入可见性单一入口 |
| `tests/automated/HealthBarFlickerSmokeTest.gd` | 按新口径更新断言 2/3（**口径过期**，见 §4），断言 1/4 不变 |
| `tests/automated/DamagedHealthBarPersistentSmokeTest.gd` + `.tscn` | **新增**：单位 + 建筑 + 施工中负例 + 修满对照 |
| `config/full_regression_suite.json` | 登记新套件 `damaged-health-bar-persistent`（category=visual，timeout=120） |

**新口径**：`hp < hp_max` 且**非施工中** ⇒ 血条常显（不受 2 秒自动隐藏窗口限制；取消选中也不隐藏）；
修满/治疗到满血后回到"数值变化闪 2 秒再隐藏"；满血未选中仍隐藏。

**为什么必须排除施工中的建筑**：`Structure.mark_as_under_construction()` 故意把 hp 置 1，
再按施工进度 `1 + progress*(hp_max-1)` 递增（`Structure.gd:96`、`:108-112`）。
若按 `hp < hp_max` 直接判定，**所有在建建筑都会常显血条**（明显观感回归）。
新测试专门覆盖了这条负例。

## 2. 自动化验证（真实 Match，仓库树）

| 套件 | 结果 |
|---|---|
| `DamagedHealthBarPersistentSmokeTest`（新） | **rc=0，0 failure** |
| `HealthBarFlickerSmokeTest`（改断言后） | **rc=0，0 failure** |
| `EnemyHealthBarSmokeTest`（敌方染红，回归） | **rc=0，0 failure** |

新测试断言（全部通过）：满血隐藏 → 单位打掉 25% ⇒ 立即显示且**等 3.5s（>2s 窗口）仍在**、计时器停表 →
建筑同样 → **施工中建筑 3s 后必须隐藏**（负例）→ 单位与建筑修满 ⇒ 2s 窗口内隐藏。

## 3. 可见截图（已亲自打开查看）

探针：`agent/runs/healthbar/_HealthBarShot.tscn`（窗口化运行，真实渲染）。
截图在 `agent/runs/healthbar/screenshots/`：

| 图 | 内容 | 我看到的 |
|---|---|---|
| `01a_crop_tank_damaged.png` | Tank 打成 4/10 | 坦克上方**常驻血条**（绿 40% + 灰底）✓ |
| `01b_crop_factory_damaged.png` | VehicleFactory 打成 19/32 | 建筑上方**常驻血条**（绿约 60%）✓ |
| `01c_crop_heli_full_hp.png` | Helicopter 满血（对照） | **没有任何血条** ✓ |
| `02a_crop_tank_repaired.png` / `02b_crop_factory_repaired.png` | 两者修满后 | **血条消失** ✓ |

探针输出的逻辑判定同样一致：受伤后等 3.5s `tank=true factory=true heli(满血)=false`；修满后 `tank=false factory=false`；
`HBAR SHOT completed: 0 failure(s)`。

> 注：前两版截图取景失败（TestAllUnits 的目标贴近地图北缘，等距相机被地图边界钳制 ⇒ 目标挤在画面顶部）。
> 最终版把三个目标挪到地图中心并**按屏幕坐标裁剪**，才有可判读的局部图；过程记录在探针日志里。

## 4. 既有断言为什么改（区分"判据过期"与"行为回归"）

`HealthBarFlickerSmokeTest` 原来断言：
- 旧 2)「停止掉血后 2 秒内血条应**自动隐藏**」→ 与用户新口径**直接冲突**（残血必须常显）；
- 旧 3)「取消选中后血条应**隐藏**」→ 同样冲突（残血时取消选中仍须显示）。

⇒ 这两条属**判据过期**（产品口径变了），按新口径改写，并新增"修满后仍在窗口内隐藏"来守住旧行为；
断言 1（持续掉血不闪烁）与断言 4（数值不变不点亮）保持不变，闪烁回归仍被覆盖。
旧断言 4 额外要求"必须在满血下测"，新流程把测试步骤调整到修满之后执行。

## 5. 相邻回归（`visual` 类别 8 个套件，仓库树）

| 套件 | 结果 |
|---|---|
| BuildingOcclusionFadeSmokeTest | rc=0，0 failure |
| **DamagedHealthBarPersistentSmokeTest** | rc=0，0 failure |
| EnemyHealthBarSmokeTest | rc=0，0 failure |
| HealthBarFlickerSmokeTest | rc=0，0 failure |
| InfantryAnimClipsSmokeTest | rc=0，0 failure |
| FogOfWarSightRangeSmokeTest | rc=0，0 failure |
| InfantryAnimDriverSmokeTest | rc=1，**抖动**（见下） |
| PerformanceGovernorSmokeTest | rc=1，13 failure（**既存红**，两边一致） |

**两条红都做了"改动前 vs 改动后"的 in-repo A/B**（临时切回 HEAD 版 `HealthBar.gd`，跑完立即恢复，已校验 sha 复原）：

| 套件 | baseline（改动前） | with-change（改动后） |
|---|---|---|
| PerformanceGovernorSmokeTest | 13 failure | **13 failure（一致）** |
| InfantryAnimDriverSmokeTest | 6 次：2/2/2/**5**/**5**/2 | 6 次：2/2/**5**/2/2/2 |

- `PerformanceGovernor` 13 条红与本次改动**完全无关**（两边数字相同）。
- `InfantryAnimDriver` 的失败项是「单位应实际位移（0.96m / **0.00m**）」——**位移型抖动**，
  且 0.00m 那个离群**在 baseline 上同样出现**（6 次里 2 次）⇒ 属既存环境/移动层抖动，
  `HealthBar.gd` 只切换自身 `visible`，不可能影响单位位移。
- 结论：本次改动**未引入回归**；这两条红按既有问题记录，不在本任务范围。

## 6. 未验证 / 残留

1. **未跑全量回归**（`full_regression_suite.json` 共 118 项）：本次按改动面跑 `visual` 类别 8 项 + 血条相关 3 项。
2. **敌方残血血条也会常显**：用户口径未区分敌我；若只想要己方常显，是 `_is_damaged()` 里加一行归属判断的事。
   注意敌我血条颜色本来就不同（敌方红色，`_apply_enemy_color_if_needed` 未改）。
3. **联机客户端表现未实测**：`HealthBar.gd` 是本地表现层（读镜像 `hp`），逻辑上无差异；
   本轮只在单机真实 Match 里验证。
4. **施工中建筑的排除**是本次的设计判断（依据 §1），若产品希望"在建也常显"需另定。

## 7. 回滚

只需回退一个源文件（测试文件与套件登记可一并回退）：

```powershell
cd G:\AIRTS\AI_RTS
# 改动前版本 = git HEAD 版
git show HEAD:source/match/units/traits/HealthBar.gd > source/match/units/traits/HealthBar.gd
# 测试与登记（若也要回退）
git show HEAD:tests/automated/HealthBarFlickerSmokeTest.gd > tests/automated/HealthBarFlickerSmokeTest.gd
# 新增文件：删掉 tests/automated/DamagedHealthBarPersistentSmokeTest.{gd,tscn} 与套件里的对应条目
```

（本会话已在 A/B 中验证过"HEAD 版 HealthBar"的可运行性：切回后三个血条套件仍可跑，A/B 日志在
`agent/runs/healthbar/ab/`。）
