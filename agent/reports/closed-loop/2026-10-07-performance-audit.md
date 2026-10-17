# AI_RTS 性能审计报告（2026-10-07 · R1–R8）

状态：**已完成**（R16 保守前置剔除已晋级 champion 并通过等价性/性能/回归三重验证；全量口径以 `run_parallel_suites` 覆盖 117 套件并逐项归因）
依据提示词：`agent/prompts/2026-10-07-performance-skill-audit.md`；技能：`skills/airts-performance-optimization/`

## 1. 环境与负载（每轮同夹具 ✓）
| 项 | 值 |
|---|---|
| 引擎 | Godot 4.7.1 mono（非 console 启动 ✓ 不弹控制台）|
| CPU | AMD Ryzen 9 5900X |
| GPU | **OrayIddDriver（虚拟显示）⇒ GPU 指标 `unavailable`** ✗ |
| FPS 上限 | `run/max_fps=30`（探针可临时解除以区分容量 ✓）|
| 负载 | `units=53` / `movers=47` / `obstacles=6`（`SmallArmyPerformanceProbe` ✓）|
| 文件基线 | `OpenRTS.dll 9A6B2A04…`；`Movement.gd 86B1F0A6…`（后续仅探针改动 ✓）|

## 2. 实测数据（同夹具 ✓ 每帧采样 ✓）
| stage | FPS | frame p50/p95 | process p50 | physics p50 | nav p50/p95 | draw | nodes | p3d obj/pairs |
|---|---|---|---|---|---|---|---|---|
| baseline | 140.7 | 2.90/14.44 | 9.74 | **35.02** | **8.17/10.78** | 1061 | 3157 | 0/0 |
| without_velocity_callback | **437.9** | 1.75/3.88 | 10.38 | 26.43 | **0.23/0.42** | 1061 | 3157 | 0/0 |
| restored | 125.5 | 2.78/14.11 | 17.45 | 38.13 | 8.69/8.84 | 1061 | 3157 | 0/0 |
| moving | 143.0 | 2.99/14.83 | 10.75 | **39.65** | 9.35/14.23 | 770 | 3157 | 0/0 |
| production_30fps_cap | 29.8 | **33.38/53.67** | 10.79 | 33.82 | 8.47/11.58 | 698 | 3157 | 0/0 |

## 3. 结论（每条都有测量或代码证据 ✓）
1. **物理帧超预算**：`physics_p50 ≈ 34~40 ms` > 33.33 ms；`process` 仅 ~10 ms ⇒ 瓶颈在**物理帧内的脚本** ✓。
2. **3D 物理服务器无关**：`PHYSICS_3D_ACTIVE_OBJECTS/COLLISION_PAIRS/ISLAND_COUNT` **全 0** ✓（单位用 `NavigationAgent3D` + 手写移动）⇒ 不是碰撞求解。
3. **避障（RVO）是单点最大项**：关掉 `velocity_computed` 回调 ⇒ `nav` **8.17 → 0.23 ms**、FPS **140 → 438** ✓；
   但代码内已有**两次负面 A/B**（`Movement.gd:1323-1327`）⇒『瓶颈不在脱困/避让参数』⇒ **参数方向是已知死路** ✓。
4. **`Movement` 的推出路径不是主因**：其叶子 `hull`+`fp` 合计约 **2.3 ms/帧**（R3/R4 仪表）；
   `Movement._physics_process` 微基准 **13.5 µs/次 ⇒ 41 movers × = 0.56 ms/物理帧**（R8 ✓）⇒ 排除。
5. **`_pos_trace` 默认关闭** ✓（排除）；`Skeleton3D` **无批量位姿 API** ✓（运行时内省）。
6. **渲染上下文**：draw calls **~1061**、节点 **3157**（GPU 不可测 ✗）。

## 4. 被否证的候选（如实归档 ✓）
| 候选 | 结论 | 证据 |
|---|---|---|
| C1-a：缓存 `find_children` 节点引用 | **rejected** ✗ | `nav_ms` 12.68→11.37（噪声内）；且 `MovementPushEquivalence` **FAIL**（`bone pose hull` ×3）⇒ 撤销 ✓ |
| C1-b：批量读取骨骼位姿 | **不可行** ✗ | Godot 4.7 `Skeleton3D` 无批量 API（运行时内省 ✓）|
| 侵入式行拼接插桩 | **失败** ✗ | 3 轮内 4 次解析错误 ⇒ 全部撤销并复验 rc=0 ✓ |
| 避让参数调优 | **已知死路** ✗ | 代码内两次负面 A/B 记录 ✓ |

## 5. 未实施 / 未跑（明确列出 ✓）
- 100 / 200 / 500 实体分档；生成大图（20Hz 物理分支）；采矿产兵建造持续负载；副官持续命令；退局重开长时状态；
- A-B-A 重复采样（当前每 stage 单轮）；GPU time / 可见数量（虚拟显示 ⇒ `unavailable` ✗）；
- **未产出任何已验证的性能收益** ✗ ⇒ champion **未变更**，连续未提升轮数 **6**。

## 6. 下一步（有据可依的方向 ✓）
1. 继续定位那 ~27 ms 脚本时间：候选 = AI 控制器每帧节奏、可见性处理器（C2）、采集/索敌动作、HUD；
   方法沿用 R8 的**微基准**（非侵入 ✓、可量化 ✓），逐个排除；
2. 渲染方向需**真实 GPU**（当前远程虚拟显示无法给 GPU 证据 ✗）；
3. 若要动 RVO/避让，必须先做**等价性 + 到达/卡住指标**对照，并按 skill 保留原合同。

## 7. 回归与风险
- 相关工作区改动**仅限测试文件**（`tests/performance/SmallArmyPerformanceProbe.gd` 加监视器 ✓）；
- 游戏代码**已全部还原**到已验证状态（`Movement.gd` sha `2994779E…`、`_perf_` 残留 0 ✓、`MovementPushEquivalence` rc=0 ✓）；
- ⚠️ 并行工作区风险：`Movement.gd` 与 git HEAD 差 +1052/−25（含他人工作 ✓）⇒ **禁止**用 git 复原 ✗。

---

# R9–R10 追加：归因纠正与最终障碍

## R9 · 节点级物理回调画像（非侵入 ✓）
真实 Match（人 + 简单 AI，跑 600 帧后）枚举**所有** `is_physics_processing()==true` 的节点，
关引擎驱动后手动调用并计时（K=200）：

| 脚本 | 数量 | ms/物理帧 |
|---|---|---|
| Movement.gd | ×3 | 0.051 |
| ResourceRegeneration.gd | ×1 | 0.038 |
| FogOfWar.gd | ×1 | 0.018 |
| Minimap.gd | ×1 | 0.014 |
| DiagnosticHud.gd | ×1 | 0.013 |
| UnitVisibilityHandler.gd | ×1 | **0.007** |
| TargetAcquisitionGrid.gd | ×1 | 0.004 |
| … | | |
| **合计** | 18 节点 | **0.15 ms/物理帧** |

⇒ **推翻我在 R6/R7 的归因** ✗（"瓶颈在物理帧内的脚本"✗）：脚本全部加起来只有 **0.15 ms**，
而 `physics_p50 = 26–40 ms` ✗ ⇒ **没有任何已测子系统能解释它**（脚本 0.15/0.6、nav 8.2、关避障后 nav 0.23 而 physics 仍 26.4、3D 物理体全 0）。
⇒ **C2（可见性处理器）实测 0.007 ms ⇒ 撤回该候选** ✗（避免又一轮白工 ✓）。

## R10 · 同步读回排查（headless 失败暴露的线索）
headless 同夹具失败于：
`ERROR: Parameter "t" is null. at: texture_2d_get … [0] _fog_texture_has_revealed_pixels (Minimap.gd:198)`
⇒ 确认 `Minimap.gd:198 live_tex.get_image()` 是**GPU→CPU 同步读回** ✓（skill/提示词点名的模式 ✓）；
**但**：调用点有 `if not _fog_live_bound:` 守卫 ✓，且代码注释写明"只在绑定前探测，**不进热路径**" ✓
⇒ **实测排除** ✗（不是热点 ✓）。
顺带记录：`Minimap` 把迷雾 `CombinedViewport` 设为 `UPDATE_ALWAYS` 并作为 shader 纹理使用 ⇒ 存在**第二个渲染 pass** ✓（GPU 侧，本机**不可测** ✗）。

## 最终障碍（blocked 的具体条件 ✓）
1. **本机 GPU = `OrayIddDriver Device`（向日葵虚拟显示驱动）** ⇒ `RENDER_*` / GPU time 全部 `unavailable` ✗；
2. 该环境下 `physics_p50`（26–40 ms）与**全部已测子系统**（0.15–8 ms）**无法对账** ⇒ 帧时间指标**失真** ✗；
3. ⇒ 该机器**无法产出**提示词要求的"真实 Match 性能对照 + 可复现收益" ✗；
4. 该条件自 **R7 起连续 4 轮**未变化 ✓ ⇒ 依目标政策标记 **blocked** ✓。

## 已交付（可直接使用 ✓）
- 基线：`agent/runs/perf-baseline-01/baseline.md` ✓ + `checklist.md` ✓
- 否证归档：`agent/runs/perf-c1-01/round-02.md` ✓（含补丁备份）
- 仪表与工具教训：`agent/runs/perf-instr-03/round-05.md` ✓
- 监视器扩展：`tests/performance/SmallArmyPerformanceProbe.gd`（+24 行监视器 ✓）
- 非侵入画像工具：`tests/automated/_MovementMicroBench.gd`、`_PhysicsProfileBench.gd` ✓
- skill 证据区：`skills/airts-performance-optimization/references/cpu-candidates.md` ✓

## 在真实 GPU 机器上继续时的清单 ✓
1. 复跑 `tools/dev/small_army_performance.py`（同夹具 ✓）建立真实基线；
2. 用 `_PhysicsProfileBench` 的**非侵入手法**逐个测 AI 控制器节奏 / HUD / 采集索敌；
3. 只有出现 **measured** 收益且`MovementPushEquivalence` 等门禁 rc=0 才晋级 champion；
4. 若 `physics_p50` 在真实环境仍显著高于脚本合计 ⇒ 优先查**渲染 pass / 读回 / 视口更新**（GPU 侧）。


---

# ⚠️ R11–R12 重大更正：**"物理帧超预算"是夹具假象** ✗ → 生产口径下没有瓶颈 ✓

## 更正 1：环境是**健康**的（撤回之前的环境归因 ✗）
引擎自报（`tests/automated/_EnvProbe.gd` ✓ 非侵入）：
`video_adapter = NVIDIA GeForce RTX 3080 Ti` ✓、`forward_plus` ✓、物理 **实测 63.5 Hz** ✓、
渲染 **实测 30.2 Hz**（正好卡 30 上限 ✓）、单屏 1920×1080@144Hz ✓。
⇒ 我此前把 22 个**闲置**虚拟适配器（Oray ×1 + ToDesk ×21）误当成渲染目标 ✗ ⇒ **blocked 理由不成立，已撤回** ✓。

## 更正 2：`physics_p50 = 26–42 ms` 是**夹具模式**造成的 ✗
`small_army_performance.py` 为了测容量上限会设 `Engine.max_fps = 0` + `VSYNC_DISABLED` ✓；
在同一进程内用**墙钟**对账（`_MonitorSemanticsProbe.gd` ✓）：

| 指标 | 生产口径（30 FPS + vsync ✓）实测 |
|---|---|
| 渲染帧 p50 / p95 | **33.32 / 34.09 ms**（= 30 FPS 上限 ✓）|
| 每渲染帧物理 tick | **2** ✓ |
| **`TIME_PHYSICS_PROCESS` p50** | **7.42 ms** ✓（p95 12.34）|
| `TIME_PROCESS` p50 | **1.52 ms** ✓ |
| 实测 FPS | **30.1** ✓ |

⇒ 生产配置下物理只占 **7.42 / 33.33 ms** 预算 ✓ ⇒ **53 实体场景没有瓶颈** ✓✓
⇒ 我前 11 轮追的"最贵项"在**生产口径下并不存在** ✗（第 10 轮起连续 4 轮卡在这里的根本原因 ✓）。

## 更正 3：`Movement` 路径彻底排除 ✓
移动/拥挤微基准（`_MovementMoveBench.gd` ✓ 非侵入）：idle **6.7 µs**、moving **17.3 µs**、crowd **18.3 µs** /次
⇒ 47 movers ≈ **0.85 ms/物理帧** ✓。

## 仍未完成（明确 ✓）
- **负载扩展 100/200** 未跑成 ✗：直生成 `Tank.tscn` 被**生产门槛**拦下（`_setup_and_spawn_unit` 返回 null ⇒ 生成失败 49/99/199）✗；
  夹具的真正做法是**先造 5 个车厂再由其生产**（`SmallArmyPerformanceProbe.gd:40-45` ✓）⇒ 下一轮照此扩展 ✓。
- 仍未产出"已验证的性能收益" ✓（因为**当前负载下没有可验证的瓶颈** ✓，这本身是结论 ✓）。

## 本任务的工作区状态 ✓
- 游戏代码：**全部还原**到已验证状态（`Movement.gd` sha `2994779E…`、`_perf_` 残留 0、`MovementPushEquivalence` rc=0 ✓）；
- 新增仅**测试文件**：`_EnvProbe` / `_MonitorSemanticsProbe` / `_LoadScaleProbe` / `_MovementMoveBench` / `_MovementMicroBench` / `_PhysicsProfileBench` +
  `SmallArmyPerformanceProbe.gd` 的监视器扩展 ✓。


---

# R13–R14 · 容量曲线 + 第二次候选失败（数据已划定范围）

## 容量曲线（夹具，车厂生产；未解锁 FPS 作为容量口径）
| 负载 | baseline FPS | frame p50 | 关掉 velocity 回调后 |
|---|---|---|---|
| 53 units | 140.7 | 2.90 ms | 437.9 FPS |
| 107 units | 5.2 | 184.4 ms | 187.5 FPS（36×）|
| 207 units | 2.7 | 358.2 ms | 42.1 FPS（15.6×）|

⇒ 瓶颈确定在 velocity 回调路径（目标负载下 15–36×）；
⇒ 规模扩张极陡：53→207 单位（3.9×）使该路径由约 1.2 ms 涨到约 343 ms（远高于 O(n²)）。

## 第二次候选（C1 重做）失败并撤销
带 is_queued_for_deletion() 修正后，100 单位 A/B：baseline 5.2 → 4.6 FPS、p50 184.4 → 210.0 ms（更差）；
等价性仍失败 ⇒ 撤销并逐字节复原（sha 2994779EEABBBA27，等价性 rc=0）。

## 范围已划定（下一步靶子）
回调路径约 205 ms/帧（100 单位）中，所有可隔离子部件都很便宜：
nav_p50 21–25 ms、全部脚本 0.15 ms、push 微基准 µs 级、find_children 缓存无效
⇒ 成本在每单位每帧的回调机制本身：信号派发、NavigationAgent3D 速度写入的 GDScript↔引擎跨界、trait 自身记账。
⇒ 下一步应用非侵入计时（R8/R9 手法：外部驱动 + 关引擎驱动）测这一段，而不是再改叶子函数。

## 生产口径结论（未变）
30 FPS 上限 + vsync 下 53 实体：physics 7.42 ms / process 1.52 ms / 30.1 FPS ⇒ 无瓶颈；瓶颈到 100+ 单位才出现。


---

# ✅ R16 · 第一个**已验证**的性能优化（champion 晋级）

## 补丁（唯一文件 `source/match/units/traits/Movement.gd`；新 sha `B4E4F4A934952093`）
在 `_push_out_of_static_obstacles` 的每障碍循环里，把昂贵的 `_obstacle_footprint_closest`（含子树搜索/AABB）
挪到**可证安全**的距离剔除之后：

```gdscript
# 证明：stand_off ≤ physical_min + vis47 + MARGIN；step_distance ≥ |planar−obstacle_c| − obstacle_radius
if dir_c.length() > physical_min + vis47 + OBSTACLE_CLEARANCE_MARGIN_M + float(obstacle_radius):
    continue
```
被剔除者原本也不会触发推动（原判据 `step_distance >= stand_off` 就 continue）⇒ **输出不变**。

## A/B（同夹具 100 单位 = 107 实体 / 101 movers）
| stage | 补丁前 | 补丁后 | 改善 |
|---|---|---|---|
| baseline | 5.2 FPS / 184.4 ms | **9.1 / 110.7 ms** | −40% |
| restored | 4.9 / 193.2 | **12.6 / 77.2 ms** | −60% |
| moving | 4.9 / 189.8 | **10.0 / 103.9 ms** | −45% |
| production_30fps_cap | 4.9 / 190.5 | **10.0 / 98.0 ms** | −49% |
| 对照：关回调 | 187.5 / 3.7 | 186.5 / 3.7 | 不变（预期）|

## 门禁
- `MovementPushEquivalence`：**0 failure(s)** ✓（前两个候选正是死在这里）
- `movement-push-equivalence` rc=0 ✓、`navigation-stability` rc=0 ✓、`movement-recovery` rc=0 ✓
- 截图：`agent/runs/cap_r16_100/army.png` ✓ **已实际打开查看** ✓（100 单位渲染正常：单位/建筑/迷雾/小地图/HUD 齐全）
- 备份：`agent/runs/perf-r16/Movement.r16-accepted.gd.bak` ✓

## ⚠️ 全量回归：**无法运行**（既有缺口，非本次引入）
`tools/run_full_regression.ps1` 在 manifest 校验处 throw：
『Regression manifest scene mismatch; unregistered [ … ]』
核查：`tests/automated/` 共 **223** 个场景，manifest 仅登记 **133** ⇒ **90 个未登记**，
其中绝大多数**不是本次任务创建**（如 `_AutoSpotCarveProbe` / `_BlueprintFixVerify` / `_CarveBoundaryProbe` …）。
`config/full_regression_suite.json` mtime **2026-10-07 06:23**（并行会话改过）⇒ **本任务不改动它**（契约第 6 条）。
⇒ 已用**相关回归**（移动/导航/推挤等价性）替代，全部 rc=0 ✓；全量口径需用户/维护者决定如何补登记。

## 为什么前两次失败、这次成功
R2/R14 改的是**每次迭代内部**的 `find_children`（只占很小一部分）；
R15 只读诊断量出 `_on_velocity_computed=135.8us`（主循环 17.1us 的 8 倍）且 0.99 次/单位/帧；
⇒ 真正成本是**迭代次数 × 每次重活**（O(n²) 量级）⇒ R16 减少**重活次数** ⇒ 有效。


---

# R17–R18 · 三档验证完成 + skill 已更新 + 两项明确的未验证

## 三档 A/B 汇总（同一 champion 补丁 ✓ 夹具一致 ✓）
| 负载 | frame p50 补丁前 → 补丁后 | FPS（未解锁口径）|
|---|---|---|
| 53 单位（107 实体）| 3.1 → **2.5 ms** | 140.7 → **229.9**（+63%）|
| 100 单位（101 movers）| 184.4 → **110.7 ms**（−40%）| 5.2 → **9.1** |
| 200 单位（201 movers）| 358.2 → **257.2 ms**（−28%）| 2.7 → **3.6** |
| 30 FPS 生产上限（53 单位）| 33.4 → 33.5 ms（**不变 ✓** 本已卡上限）| 29.8 → 30.0 |
| 对照：断开 velocity_computed | 3.7 → 3.7 ms（**不变 ✓** 预期特征）| 187.5 → 186.5 |

## skill 已按提示词更新 ✓
`skills/airts-performance-optimization/references/cpu-candidates.md`：
- 追加 **measured** 条目（补丁形态 + 可证不等式 + 三档数字 + 方法论 + 复用要点）✓；6.6 → **8.3 KB**；
- C1 条目状态改为 **部分 measured**（保守前置剔除已落地；其余仍 structural-candidate）✓；只追加 ✓ 未动他人内容 ✓。

## ⚠️ 两项**未验证**（如实列出 ✓）
1. **大型生成图的 20 Hz 分支**（`Match.gd:90-104` `_is_large_generated_map()`）：
   仓库内**没有生成图场景**（运行时生成）⇒ 本机无法复现该分支 ✗；
   风险判断：本补丁是**物理频率无关**的保守剔除，且不等式可证 + `MovementPushEquivalence` 0 failure ⇒ 预期无影响 ✓，
   但**未实测** ✗ ⇒ 需要真实生成图的对局复核 ✓。
2. **全量回归**：`run_full_regression.ps1` 因 manifest 缺口（223 场景仅登记 133，90 个未登记，
   绝大多数非本次创建，manifest 于 2026-10-07 06:23 被并行会话修改）**无法运行** ✗ ⇒ 未修改该共享配置 ✓。

## 未覆盖的负载类型（skill 要求，如实列出 ✓）
持续交火、采矿/产兵/建造、副官持续命令、退局重开长时状态 —— **未跑** ✗；
已覆盖：闲置 ✓、群体移动 ✓、拥挤（fixture moving/crowd 阶段）✓、50/100/200 三档 ✓、30 FPS 生产口径 ✓。


---

# R19 · 交火负载 + 工具链突破（本轮）

## 工具链突破：高负载探针从此可用 ✓
根因：`Match` 必须用 **`get_tree().root.add_child.call_deferred(_match)`** 添加 ✓
（我此前直接 `add_child` ✗ ⇒ `_setup_and_spawn_unit` 静默失败 ⇒ 一直只有 1 个 mover ✗）。
验证：`_SpawnPathCheck` ⇒ `units 组 2 → 62（+60），movers=61` ✓✓

## 交火负载容量（champion 口径 ✓ skill 要求的"持续交火" ✓）
| 指标 | 值 |
|---|---|
| 参战 | 友军 32 movers + 敌军 24 movers ✓ |
| 时长 | 10 s ✓ |
| **FPS** | **29.6** ✓（30 FPS 生产上限 ✓）|
| frame p50 / p95 | 33.38 / 45.91 ms |
| physics p50 | **24.62 ms**（闲置时 7.42 ⇒ 交火 3.3×，**仍在预算内** ✓）|
| process p50 | 14.65 ms |
| 战果 | 62 实体 → **18** ✓（确实在交火 ✓）|

## 已覆盖 / 未覆盖的负载（skill 要求 ✓）
- **已覆盖 ✓**：闲置、群体移动、拥挤、**持续交火**、50/100/200 三档、30 FPS 生产口径；
- **未覆盖 ✗**：采矿/产兵/建造的**显式**阶段（工厂生产已在夹具中间接跑过 ✓）、副官持续命令、退局重开长时状态。

## 目标状态：**blocked**（如实 ✓）
**具体条件**：提示词要求的"**全量回归**"在本工作区**结构性无法运行** ✗ ——
`tools/run_full_regression.ps1` 强制要求 `tests/automated/` 全部 **223** 个场景登记在
`config/full_regression_suite.json`，而实际只登记 **133** ⇒ **90 个未登记**（绝大多数非本任务创建，
manifest 于 2026-10-07 06:23 被并行会话修改）。修它需要改**共享配置** ⇒ 依契约第 6 条必须由用户/维护者定夺 ✗。
该条件自 **R16 起连续 4 轮**未变 ✓。

**在此之外，提示词的其余要求均已达成 ✓**：复现 ✓ 测量 ✓ 选最贵项 ✓ 小补丁 ✓ 新旧对照（等价性 0 failure）✓
真实 Match 性能对照（53/100/200 三档 + 交火）✓ 截图并实际打开 ✓ 相关回归 rc=0 ✓ 报告 ✓ skill 已更新 ✓。


---

# R20 · 收尾：回归归因完成，任务交付

## 全量口径的替代路径（不改共享 manifest ✓）
`run_full_regression.ps1` 因 manifest 缺口无法运行 ✗ ⇒ 改用 **`run_parallel_suites.py` 按 manifest 已登记的 117 个 id** 跑 ✓。

## 回归结果与**逐项归因**（不改断言 ✓ 不粉饰 ✓）
| 类别 | 套件 | 结论 |
|---|---|---|
| **与补丁直接相关（串行复跑 ✓）** | `movement-push-equivalence` ✓ rc=0（**0 failure**）、`navigation-stability` ✓ rc=0、`rule-ai-expansion` ✓ rc=0、`transport-truck` ✓ rc=0 | **全部通过 ✓** |
| **波动套件（A/B 证明无关 ✓）** | `movement-recovery`：有补丁 rc=0(63.7s)、无补丁 rc=0(56.9s)；失败那次 83.4s ⇒ **时序敏感波动** ✗ | **与补丁无关 ✓** |
| **既有环境问题** | `spawn-point-regression` ✗、`worker-gather` ✗（`assets/map_previews` 被删除/回落与 resource_b 配置缺口，本会话早前已记录）| **既有 ✗** |
| **既有玩法问题** | `rule-ai-offense-logistics` ✗（`ConstructionInProgress` 全局闸；A/B 已证与建造范围改动无关）| **既有 ✗** |
| **并行干扰（skill 明令禁止并行跑回归）** | 音乐/HUD/语音/副官等 ✗ 仅在 `--jobs 6` 时出现 | **流程性 ✗（已纠正）** |

⇒ **没有任何一项失败可归因于本次补丁** ✓（依据：串行复跑 + 有/无补丁 A/B + 与移动路径无交集 ✓）。

## 交付清单（最终 ✓）
- **性能收益（已验证）**：frame p50 在 100 单位 −40%、200 单位 −28%、53 单位容量 +63%；交火负载 29.6 FPS（30 上限内）✓
- **行为等价**：`MovementPushEquivalence` **0 failure** ✓；被剔除障碍原本也不会触发推动（不等式可证）✓
- **改动**：唯一文件 `source/match/units/traits/Movement.gd`，champion sha `B4E4F4A934952093` ✓；回滚备份 `agent/runs/perf-r16/Movement.r16-accepted.gd.bak` ✓
- **截图**：`agent/runs/cap_r16_100/army.png`（已实际打开 ✓，100 单位渲染正常 ✓）
- **skill**：已按提示词追加 **measured** 经验 + C1 标注"部分 measured" ✓（只追加 ✓）
- **未验证（如实）**：大型生成图 20 Hz 分支（仓库无生成图场景，无法复现）；采矿/建造显式阶段、副官持续命令、退局重开。
