# 世界尺度运行时审计与修复 · 闭环报告

- Run ID: `2026-10-01-world-scale-audit`
- 日期：2026-10-01
- 提示词：`agent/prompts/2026-10-01-world-scale-runtime-audit-execution-prompt.md`
- 计划：`agent/plans/2026-10-01-world-scale-runtime-audit-plan.md`
- **总体状态：`needs-review`**（三处子项未完全闭环，见 §6；未用"应该已经好了"收尾）

## 1. 结论摘要

审计未发现"尺寸更新后需要全局乘系数"的断裂。核心口径（碰撞/逻辑半径/footprint/速度/射程/视野/出生偏移）在运行时证据下**自洽**，真实断裂只有两处显示层问题，已修复：

| # | 问题 | 修复 | 证据 |
|---|---|---|---|
| 1 | **攻击范围圈显示口径过时**：圈画原始 `attack_range`，而权威判定已是"基础射程+双方半径"（坦克对建筑实际可及 12.98m，圈只画 7.5m，误导瞄准） | `Selection.gd`：圈半径改为 `attack_range + 自身半径`（对点目标精确可及；目标表面触圈沿=刚好可及）；`AttackRangeIndicator.gd` 过时注释重写 | `_ScaleScreenshotProbe` 截图 `screenshots/attack_circle.png`（白圈边缘压在敌方指挥中心施工区近侧表面）；`AttackRangeIndicatorSmokeTest` rc=0（断言随新口径更新，见 §5） |
| 2 | **迷雾两层口径未写明**：迷雾圈画基础视野、可见性判定用 `sight_range_against`+2.0m 模糊边缘补偿，两套公式没有解释 | `FogOfWar.gd` 头注释明确两层语义（控制圈=中心→地标；可见性=表面→表面+显示补偿）；不改行为 | 代码审读 + `_Phase4CalibrationProbe`（16/18/19m 可见与公式一致） |

**有证据确认无需调参**（对应提示词"不得没证据改数值"）：
- 速度端到端诚实：坦克 20m/40m 实测 2.98/2.94 m/s（属性 2.92）、步兵 3.76/3.73（3.71）、无人机 8.89~9.30（8.48）。
- 第一发命中中心距 **11.50m** = 7.5 + 2.0 + 2.0，与权威公式严丝合缝（4 个起始距离全部命中边界内）。
- 建筑逻辑半径 == 平衡 footprint（CC 3.48 / 矿场 2.00 / 兵营 2.20 / 对地塔 1.20 …）逐一对上。
- 出生偏移 = 模型外缘 + agent_radius(2.8) + 产品半径 + 0.1，五组实测全中。
- 硬不变量 `UnitRadiusCoverageSmokeTest` rc=0（碰撞半径 ≥ 视觉半宽、避让半径与定制表一致）。

## 2. 基线与探针（全部在 `agent/runs/2026-10-01-world-scale-audit/`）

- `baseline.md`：git 状态（681 行，含并行 Agent 在途改动）、mtime、进程端口、探针清单、rc。
- 审计表：`audit_table.md`（19 类实体的 13 列全口径 + 特效表 + 来源标注）。
- 探针原始输出：`size_table*.log`、`collider_check_raw.log`、`world_audit_*.log`、`spawn_offset_raw.log`、`phase4_raw*.log`、`fx_raw6.log`。
- 截图：`screenshots/attack_circle.png`、`screenshots/scale_lineup.png`（均已实际打开检查）。

新增探针（可重复执行）：
`_WorldScaleAuditProbe`（19 类 13 列运行时直读）、`_SpawnOffsetProbe`（出生偏移）、
`_Phase4CalibrationProbe`（20m/40m 计时+刚好开火+可见性）、`_FxWorldScaleProbe`（特效解析包络+父缩放敏感性）。

**探针修复**（提示词要求的先修探针）：`_SizeTableProbe.gd` 步兵蒙皮网格 AABB 假值（0.02m）
→ 网格并集退化时回退 `Skeleton3D` 骨骼姿态包围盒；修正后步兵 0.50×1.44×0.65m。

## 3. 玩法数值决定（旧值 → 新值）

**零数值改动**。所有实测值与权威口径一致，没有"玩家感觉慢/近"需要修正的证据；
提示词禁止的"全局乘系数/无证据改 speed/range/sight/particle"一条都没有发生。

唯一与本任务相关的数值事实：运行时速度含本机成长存档 `combat_mobility×2`（+6%），
这是永久加点**产品特性**（`config/growth_definitions.json`），不是口径断裂；审计表同时记录平衡值与运行时值。

## 4. 测试与 rc

| 套件 | rc | 说明 |
|---|---|---|
| attack-range-indicator | **0** | 断言随新口径更新（判据过期类，非行为回归） |
| unit-radius-coverage | **0** | 硬不变量绿 |
| fog-of-war-sight-range | **0** | |
| tank-force-attack / force-attack-friendly | **0** / **0** | |
| tank-ordinary-attack | 1 | **既有失败**（stash 归因：基线同红，断言相同） |
| selection-portrait-panel | 1 | **既有失败**（基线同红："工人格应显示 ×3 角标"） |
| unit-auto-attack / turret-aiming / traditional-command-hud / reach-geometry / terrain-ground-collision / size-unification-regression / spawn-point-regression / movement-scale | **0** | 并行 4 道，13/15 通过，2 个失败经串行复核确认真红且基线同红 |
| `dotnet build OpenRTS.sln --no-restore --nologo` | **0 错误** | |

受影响套件已全跑；**全量 113 套件回归未执行**——工作区存在并行 Agent 在途改动且已归因出多套
非本任务造成的红（rule-ai-economy-query、heavy-tank-howitzer 视野 10→13 口径漂移、ore-refinery 夹具、
PostRefactorPlayability 副官挂载），现在跑全量只会得到"混合树"读数（闭环工作法 §2.5）。
建议：并行 Agent 的工作合流后由用户跑 `tools/run_full_regression.ps1`。

## 5. 断言更新清单（判据过期类，均有依据）

1. `AttackRangeIndicatorSmokeTest`：圈半径期望 `attack_range` → `attack_range + 自身半径`
   （随表面到表面射程口径更新；权威判定与实测第一发 11.50m 为依据）。
2. （本任务早前，已单独报告）`TankForceAttackSmokeTest` 地面靶补停火 + "演示模式友伤"断言
   随 `aefeabd` 特性口径更新——与本次审计同属"判据过期 vs 行为回归"分类中的前者。

## 6. 未完全闭环项（诚实清单）

| 项 | 状态 | 原因 | 剩余动作 |
|---|---|---|---|
| 可见实例 MCP 截图 | **替代完成** | 端口 9080/9090/24579 被既有 Godot 实例占用（PID 17592），按 mcp/README 不复用不抢端口 | 改用 Godot 探针场景自渲染截图（`_ScaleScreenshotProbe`），已打开检查；如需 MCP 原生截图，等实例释放后重跑 |
| 可见性边界 20m+ 实测 | **部分** | 夹具内 20m+ 出生被拒（PlainAndSimple 边缘/carve），16/18/19m 已证与公式一致 | 需要更大地图或可见实例复测 |
| 特效视觉肉眼 | **解析法完成，视觉未确认** | headless dummy 渲染器不模拟 GPU 粒子（transformed_aabb 恒空） | 已改用运行时资源解析评估（发射半径/初速/寿命/网格/贴图）；爆炸"火+烟"实际视觉包络需可见实例 eyeball |
| 全量回归 | **未跑** | 上述混合树原因 | 合流后执行 |

## 7. 并行工作区风险（如实记录）

- `Infantry.tscn` / `AntiGroundTurret.tscn` 于 13:45:33 被并行 Agent 写过（本任务只读未动）。
- demo.balance 处于用户在途重写中（946 行重排）；本任务未改平衡 JSON。
- 本任务全部改动**未触碰**任何其他 Agent 正在编辑的文件；编辑前均复查 mtime。

## 8. 可安全回滚的文件与命令

本任务改动（`git checkout -- <file>` 即可回滚，均不影响其他 Agent 工作）：

```text
source/match/units/traits/Selection.gd            # 攻击圈半径口径（可独立回滚）
source/match/units/traits/AttackRangeIndicator.gd # 仅注释
source/match/FogOfWar.gd                          # 仅注释
tests/automated/AttackRangeIndicatorSmokeTest.gd  # 断言随口径
tests/automated/_SizeTableProbe.gd                # 探针修复（建议保留）
tests/automated/_WorldScaleAuditProbe.gd/.tscn    # 新探针（建议保留）
tests/automated/_SpawnOffsetProbe.gd/.tscn        # 新探针
tests/automated/_Phase4CalibrationProbe.gd/.tscn  # 新探针
tests/automated/_FxWorldScaleProbe.gd/.tscn       # 新探针
tests/automated/_ScaleScreenshotProbe.gd/.tscn    # 截图探针
```

回滚验证命令：`git checkout -- <file>` 后跑 `attack-range-indicator`（rc 应回 0——旧断言）。

## 9. 未修复问题（移交给用户/后续）

1. `tank-ordinary-attack` / `selection-portrait-panel` 既有失败（基线同红；与尺寸审计无关）。
2. 重坦视野 10（测试/09-27 口径）vs 13（在途配置）需要用户定夺。
3. `MouseClickAnimation` 若未来迁入缩放节点会 ×2（Sprite3D 不吸收父缩放）——当前挂点安全，已记录。
4. `ShellExplosion` 火焰粒子初速 5m/s×1.4s 的线性上界 3.65m（有阻尼实际更小）——建议可见实例 eyeball 一次。
5. **死亡/建筑爆炸/维修特效不存在**（单位死亡直接 `queue_free()`，无残骸/爆炸/动画资产）——
   产品空缺而非尺寸口径断裂；是否补做属新特性，须用户定夺（审计表 D 节已记录）。
6. `UnitDetailPanel` 显示基础 `attack_range/sight_range`（与平衡表同源的静态属性语义），
   与几何攻击圈（本次修复）分属"数据表 vs 几何可及"两层，均已写明口径，无断裂。
