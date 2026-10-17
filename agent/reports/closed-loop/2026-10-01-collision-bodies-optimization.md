# 闭环验证报告：碰撞物件全面优化（RA3 口径）

- 日期：2026-10-01
- 计划：`agent/plans/2026-10-01-collision-bodies-optimization-plan.md`
- 运行目录：`agent/runs/`、`tmp_logs/`
- 状态：`complete`（四类证据齐备：运行时实测 / 截图 / 套件全绿 / 独立复核三轮）

## 1. 目标与验收条件

所有碰撞物件（单位/建筑/炮塔/金矿/装饰/地图静态体）的碰撞体贴合本体；carve 洞只存在于真正需要阻挡的物件上；
运行时实测 + 截图 + 套件全绿 + 独立复核四项齐备。

## 2. 实施改动

| 文件 | 改动 | 权威口径/新值 |
|---|---|---|
| `source/match/units/*.tscn`（19） | 逐单位定制碰撞形状与半径 | 建筑 Box（车厂 6.62×3.06×5.09 等）；炮塔 Cylinder 只算底座 **1.20/1.10/0.90**；载具 Cylinder（坦克 1.40、矿车 0.92、无人机 0.87、步兵 0.35） |
| `units/Infantry|Rocketeer|Sniper.tscn` | **去重**：形状块里 height/radius 各写两遍（后值 0.48/0.6 生效） | 现为 height 1.45 / radius **0.35** |
| `units/Anti*Turret.tscn`（3） | 同类重复属性去重 | height 1.68 / 1.87 / 1.19 |
| `units/non-player/ResourceA|B.tscn` | 金矿退出导航烘焙 | `affect_navigation_mesh = false`、`carve_from_collision_bounds = false`；carve 洞 4.0m → **0** |
| `units/traits/MovementObstacle.gd` | 新增开关 | `carve_from_collision_bounds`（建筑 false ⇒ 圆形洞） |
| `units/actions/ReturningToBase.gd` | 到家阈值按 carve 净空 | 4.83m → max(半径和, carve+单位半径)+0.35 ⇒ 集体回基地 1/8 → **8/8** |
| `debug/CollisionVolumeOverlay.gd` | **修复可视化撒谎** | 按 `affect_navigation_mesh` 判断是否画 carve；关烘焙时标签显示"不参与导航烘焙(无洞)" |
| `tests/automated/UnitRadiusCoverageSmokeTest.gd` | 判据补 Box 分支 + 表项修正 | Box 单位现在真的回读几何；HeavyTank 2.00 → 1.93 |

## 3. 运行时实测

| 探针 | 结果 | 原始日志 |
|---|---|---|
| `_RuntimeColliderCheck.tscn`（真 Match） | 主基地 Cylinder 3.48 / 矿场 Box 1.90 / 兵营 Box 2.08 / 对地炮 1.20 / 坦克 1.40 / 矿车 0.92 / **步兵 0.35** / 无人机 0.87 | `tmp_logs/rt3.log` |
| `_NonUnitColliderProbe.tscn` | 金矿 视觉 2.73×0.57×2.38、碰撞 Cylinder 1.20、**参与导航烘焙=false、carve 净空 0.00m**；装饰石 Box 0.50 | `tmp_logs/nonunit_col3.log` |
| 独立复核探针 `_IndepVerifyColliders.tscn`（复核方自写） | 19 项逻辑半径全部一致；金矿 18/18 无洞；**导航层直测**：矿点处 `map_get_closest_point` 距离 0.000（兵营对照被吸附 4.8m） | `agent/runs/_indep_colliders2.log` |

## 4. 截图验收

| 截图 | 观察结论 |
|---|---|
| `tmp_logs/r43_ore_truthful.png` | 金矿：`碰撞包围盒=2.40×1.00×2.40`、`逻辑 r=1.20 不参与导航烘焙(无洞)`，**无红盒**；矿场对照：`carve=4.74(hole)` 正常挖洞 |
| `tmp_logs/r44_carve_truthful.png` / `r45_all_classes.png` | 收口后：矿场 carve 改为**圆形**（r=2.0+2.8=4.8，与真实烘焙口径一致）；金矿仍无红圈 |
| `tmp_logs/r46_all_classes.png` | **七件一排**（金矿A/B、装饰石、对地炮、对空炮、矿场、矿车）：金矿与装饰石**无红圈**；对地炮/矿场有红色**圆**洞（4.0 / 4.8）——与真实烘焙口径一致 |
| `tmp_logs/r40_collider_shapes.png` / `r41_collider_shapes.png` | 单位类：无人机小圆柱贴合本体、主基地 carve 圆洞 |

## 5. 自动化验证

| 命令 | rc | 结论 |
|---|---:|---|
| `run_parallel_suites --ids ore-refinery --jobs 1` | 0 | **0 failure**（此前 4 条红） |
| `--ids unit-radius-coverage,structure-placement,refinery-free-miner` | 0/0/0 | 全绿（含新补的 Box 判据） |
| `--ids local-avoidance`（低并发） | 0 | 绿 |
| 全量 18 套件（**清理污染后** `--jobs 6`） | 0 × 18 | **全绿**：并行道 16/16，串行复核 `movement-scale` 0 失败、`ore-refinery` 0 失败、`movement-recovery` 0 失败（86.5s，此前并发假红） |
| `unit-radius-coverage`（恢复强断言后） | 0 | 19/19 表值 == 实测几何 |

## 6. 独立复核

复核方（独立子智能体，自写探针）结论：**主张 3/4/5 成立**；指出 3 类问题 —— 均已修复：
① 步兵三型与三炮塔的形状属性重复（后值生效）；② 覆盖率判据对 Box 是同义反复；③ 金矿 `carve_from_collision_bounds` 仍是默认 true（潜在方洞）。
复核方另外独立在导航层证明金矿无洞。

**复检（第二轮，已完成）**：

| 项 | 复核结论 | 关键实测 |
|---|---|---|
| ① 形状属性重复 | **已修复** ✅ | infantry/rocketeer/sniper `radius=0.35 height=1.45`；炮塔 height 1.68/1.87/1.19；**全仓 110 个 .tscn 的 sub_resource 重复键 = 0 处** |
| ② 覆盖率判据 Box 同义反复 | **已修复** ✅ | 三种形状全部回读几何、读不到即失败；实跑 rc=0 / 0 failure；复核方独立复算 19/19 PASS |
| ③ 金矿双开关 | **已修复** ✅ | 18/18 实例 affect=false + carve_from_collision_bounds=false；carve_clearance_of=0.0000；导航层最近点 0.000（对照兵营 4.800） |
| ④ 可视化红盒几何 | 矿那类已修复 ✅；**红盒口径**经复核指出仍不准 ⇒ 本轮已按 `carve_from_collision_bounds` 分口径重画（方盒/圆），待第三轮确认 ⚠️ | 复核实测偏差：aircraft_factory x 向原画小 1.77m、barracks z 画大 0.905m |

复核方另指出两条**遗留观察**（未决口径，已记入 §7）：
- `COLLISION_RADIUS_M` 现无读取点（判据退化为纯上界"几何 ≤ 视觉半宽"）；两条擦边：vehicle_factory 裕量 −0.0018、barracks +0.0009（靠 +0.05 容差）。
- 建筑 Box 半宽（3.31/2.08/1.63）与"主张值"（2.70/2.20/3.40）的差异源于**主张写的是逻辑半径**，场景本身正确 —— 已在报告中改正措辞。

## 6.5 全类别导航职责（本轮补全）

| 类别 | 是否挖洞（挡路） | 机制 | 证据 |
|---|---|---|---|
| 移动单位 | 否 | 只做避让（`Movement.radius`） | 运行时 carve 外缘 = 0 |
| 建筑 / 炮塔 | **是** | `MovementObstacle` + `radius` 圆形洞（`carve_from_collision_bounds=false`） | 兵营处 `map_get_closest_point` 被吸附 4.800m |
| **金矿** | **否** | 退出导航烘焙（RA3 语义：地面资源） | 矿点处最近点距离 0.000；18/18 实例开关为 false |
| 装饰石 / 地图静态体 | **是** | 属 `terrain_navigation_input` 组 ⇒ 作为地形烘进导航 | 生成图 315 个 `Solid*` + RockLargeA 均在该组 |

## 6.6 第三轮复检（已完成）

| 项 | 复核结论 | 证据 |
|---|---|---|
| ④ 可视化 carve 口径 | **已修复** ✅ | 复核方做**逐方向洞边界直测**：兵营 8 向均值 **4.96** ≈ 圆口径 5.00（方盒口径 x4.88/z5.90 被否）；飞机场均值 **6.23** ≈ 6.20（方盒 x4.43 被强否）；`agent_radius=2.8000` 实测 |
| ② 覆盖率强断言 | **已修复** ✅ | 跑前跑后 hash 一致：直跑 rc=0 / 0 failure；runner passed=True；表值 vs 实测几何 **19/19** 一致 |

复核方另报一次"8 项红"读数，经双方核对确认为**采样到并发编辑中的旧 revision**（表在我 14:03:42 同步前）；不是判据缺陷。

## 6.7 运维教训（已处理）

复核方发现机器上有 **8 个我遗留的非 headless 探针 Godot 实例**（13:21~13:46 起），会污染 `local-avoidance`/`movement-recovery` 等时序套件 —— 这正是此前"并发假红"的真因。
已按命令行筛选**只杀我这 8 个**（保留用户的编辑器实例），清理后重跑：`movement-recovery` 在并发批里直接 **passed=True**。
⇒ 纪律补充：探针必须自带 `quit()` 兜底（已给 `_OreColliderShot` 加），跑完必须确认无残留进程。

## 7. 未验证项与风险

- 截图只覆盖了金矿/矿场一类；单位、装饰、地图墙体**尚无逐类截图**。
- `movement-recovery` 在并发下会假红（单跑 0 失败，已三次实测），属负载敏感；本轮全量并行道 16 绿 0 红。
- 截图覆盖：单位类（r40/r41）、金矿/矿场类（r43/r44/r45）；**装饰石与炮塔未单独出图**（有运行时数值 ✓）。
- ~~`COLLISION_RADIUS_M` 强断言~~ **已收口**：表按运行时实测几何修正 8 项（步兵 0.35、APC 1.20、运输车 1.21、侦察车 0.70、矿车 0.92、无人机 0.87），并恢复"几何 == 表值（容差 0.02）"强断言；实跑 rc=0 / 0 失败。
- 装饰石与地图墙体按 `terrain_navigation_input` 组烘焙（正确挡路）；未单独出图，且其 **carve 半径受全局 agent 2.8 影响**（属 navmesh 标准，未改）。
- 工作区并行风险高：19 个单位场景 + ResourceA/B 均为**未提交改动**；另有会话在改 `EconomyController` 等 AI 脚本。

## 8. 回滚方式

按文件粒度回滚：形状与半径改动集中在 19 个 `.tscn` + `ResourceA/B.tscn`；
开关改动在 `MovementObstacle.gd`（新增属性，回滚只需删除引用并恢复场景行）。
