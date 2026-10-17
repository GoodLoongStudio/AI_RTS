# 问题报告：AI_RTS 大规模单位下的性能瓶颈（交给方案设计者）

> 目的：把已测清的事实、代码位置、约束与验收方法一次性交给另一个 AI/工程师，让它**不必重测**就能设计新方案。
> 生成时间：2026-10-07｜生成者：本仓库内的自动化 Agent（按 AGENTS.md 与 skills/airts-performance-optimization 流程作业）
> 原则：**实测**与**推断**严格分开标注。凡标「未验证」的，请不要当成事实。

---

## 0. 摘要（TL;DR）

- 目标：**1000 个单位、由 AI 指挥、持续交战，稳定 30 FPS**（生产口径 30 FPS 上限 + vsync）。
- 现状：1000 单位 **0.6 FPS**（frame p50 **1577 ms**）；300 单位 **2.2 FPS**（**400–430 ms**）；53 单位 **30 FPS**（正常）。
- 已用实测**排除渲染**（全图视野下把单位模型全藏掉：draw call 1448 → 213，**帧时间不变**）。
- 已用实测**排除脚本**（全部 `_process` + `_physics_process` 合计 **8.3 ms**，占 392 ms 的 **2%**）。
- 根因锁定：**逐单位逐障碍的局部避让 + 去穿透管道**（O(n²) 的碰撞响应），单物理 tick 46 ms，而引擎每帧跑 **8** 个物理步。
- 关键算术：即使把**单次**障碍访问优化 5 倍，仍只有约 **13 FPS** ⇒ **必须减少访问次数本身**（数量级）。

---

## 1. 目标与验收标准（我们要的最终形态）

| 项 | 要求 |
|---|---|
| 规模 | **1000 个作战单位**（由 AI 一方指挥，全线推进/持续交战）|
| 帧率 | **稳定 30 FPS**：frame p50 ≤ **33.3 ms**，p95 ≤ **45 ms** |
| 画质 | **不得**靠降画质/关迷雾/减特效达成 |
| 模拟 | **不得**停掉屏幕外/迷雾外单位的模拟（它们仍须移动/攻击/采矿/生产/参与权威同步）|
| 权威口径 | **不得**改单位尺寸、射程、速度、视野、碰撞来冒充优化 |
| 门禁 | `MovementPushEquivalence` 必须 **0 failure**；移动/导航相关套件 rc=0；全图视野下截图与 A/B 对照 |

---

## 2. 环境与基线（复现所需）

| 项 | 值 |
|---|---|
| 引擎 | **Godot 4.7.1**（.NET/Mono），渲染后端 `forward_plus`，实测 video_adapter = **NVIDIA GeForce RTX 3080 Ti** |
| CPU | AMD Ryzen 9 5900X（12 核）|
| 生产口径 | `run/max_fps = 30` + vsync 开启（实测渲染 30.1–30.2 Hz）|
| 物理 | `physics_ticks_per_second = 60`，`Engine.max_physics_steps_per_frame = 8`（Godot 默认）|
| 大地图分支 | 大型**生成图**会把物理锁到 **20 Hz**、`max_physics_steps_per_frame = 1`、关物理插值（`Match.gd:90-104`）|
| 相关文件 hash | `Movement.gd` sha256 前缀 **B4E4F4A934952093**（含已验收的 R16 优化）；`OpenRTS.dll` 前缀 9A6B2A04 |
| 地图 | `PlainAndSimple`（208×208）为主；测试把单位集中在 60–90 米见方的区域（密集军团）|

### 复现命令（本仓库自带工具）

```powershell
# 1) 同夹具 A/B（真实窗口探针，含 idle/moving/crowd/生产上限五个阶段）
$env:AIRTS_GODOT = "G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
python tools/dev/small_army_performance.py --count 100 --out agent/runs/<你的目录>
# 2) 等价性硬门禁（改移动/碰撞必跑）
python tools/dev/small_army_performance.py --equivalence --out agent/runs/<你的目录>
# 3) 大规模压力（AI 一方 N 个单位；N 由环境变量给）
#    场景：tests/automated/_AiArmyStressProbe.tscn   （$env:AIRTS_AI_ARMY = 300 或 1000）
# 4) 全图视野渲染压测：tests/automated/_FullVisionRenderProbe.tscn（关迷雾遮罩 + 相机 size=320 + 强制单位可见）
```

⚠️ 注意（踩过的坑）：
- 生成单位必须用 `get_tree().root.add_child.call_deferred(_match)` 且用 `Match.get_local_player()`；用 `add_child` 直接加会**静默失败**。
- 单位视觉分支的真实节点名是 **`Geometry`**（不是 `Visual`）。
- **不要**把单位从障碍组 `remove_from_group`（会触发大范围重烘焙并**挂起**）。
- 探针一律 `-WindowStyle Hidden`（避免弹控制台窗口打扰使用者）；回归**串行**跑（本仓库规范禁止并行跑回归）。

---

## 3. 关键实测数据

### 3.1 规模曲线（未解锁 FPS 上限口径，同夹具）

| 单位数 | frame p50 | FPS | 备注 |
|---|---|---|---|
| 53 | 2.9 ms | 140.7 | 生产上限下 30 FPS 稳定 |
| 100 | 184.4 ms | 5.2 | R16 优化后 110.7 ms / 9.1 FPS |
| 200 | 358.2 ms | 2.7 | R16 后 257.2 ms / 3.6 FPS |
| 300（AI 方 300）| **392–430 ms** | **2.2** | |
| 1000（AI 方 1000）| **1577 ms** | **0.6** | p95 2924 ms |

⇒ 扩张形态：53 → 300 单位（×5.7）使帧 ×135 ≈ **O(n^2.7)**（超二次）

### 3.2 帧时间分解（300 单位）

| 指标 | 值 | 说明 |
|---|---|---|
| frame p50 | ~400 ms | 墙钟 |
| `TIME_PHYSICS_PROCESS` | 40–50 ms | **一个物理 tick 的耗时** |
| `TIME_PROCESS` | 110–145 ms | idle/process 相位 |
| 两者之和 | ~175 ms | ⇒ **其余 ~225 ms 不在两个 monitor 里** |
| 单位全部脚本回调 | **8.3 ms** | `Movement` ×303 = 6.06 ms 是大头 |
| `TIME_NAVIGATION_PROCESS` | 8–25 ms | 导航服务器 |
| draw calls | 1448（全图视野 + 311 单位可见）| |
| 节点总数 | 12649（300 单位）／9395（200 单位）| |

### 3.3 决定性对照实验（全部只读、模拟不停）

| 实验 | 结果 | 结论 |
|---|---|---|
| **断开 `velocity_computed` 回调**（303 单位）| frame **418 → 177 ms（−58%）**，可复现（恢复后回 422 ms）| ✅ 该管道是主因 |
| 藏掉 307 个单位 `Geometry`（**全图视野**下，draw 1448 → 213）| frame 417 → **415.6 ms（不变）** | ❌ 单位渲染无关 |
| 藏地形网格（162 个，draw → 264）| 392 → 411 ms（噪声）| ❌ 地形渲染无关 |
| 停迷雾 SubViewport 更新（2 个）| 411 ms（不变）| ❌ 迷雾无关 |
| 停小地图 SubViewport | 414 ms（不变）| ❌ 小地图无关 |
| 藏建筑视觉 | 370 ms（噪声）| ❌ 建筑渲染无关 |

### 3.4 回调本体成本（只读诊断，关引擎驱动后手动调用计时）

| 项 | 值 |
|---|---|
| `Movement._on_velocity_computed` | **135.8 µs / 次** |
| `Movement._physics_process` | 17.1 µs / 次 |
| 触发频率 | **0.99 次 / 单位 / 物理 tick** |
| ⇒ 303 单位 | 135.8 µs × 303 ≈ **41 ms / tick** |
| ⇒ 每帧 8 步 | 41 × 8 = **329 ms** ⇒ 与实测 418 ms 吻合 |

---

## 4. 根因定位（代码层）

### 4.1 调用链

```
物理 tick（60 Hz）
  → NavigationAgent3D 的 RVO 求解（引擎侧）
    → 发出 velocity_computed 信号
      → Movement._on_velocity_computed(safe_velocity)        # Movement.gd
        → Movement._push_out_of_static_obstacles(wanted_step)  # 热点，135.8 µs/次
          → for obstacle in obstacles:                         # 遍历障碍组（含单位！）
              → _obstacle_footprint_closest()   # 含 find_children(CollisionShape3D) + 形状数学
              → _ground_hull_points_xz()/_ground_hull_support()  # 单位视觉 hull，点集循环
              → _unit_ground_half_extent()      # 本单位形状半宽
              → 顺序推出（planar = closest + outward * stand_off）
```

### 4.2 关键代码位置（当前工作区，sha 前缀 B4E4F4A934952093）

| 位置 | 内容 |
|---|---|
| `source/match/units/traits/Movement.gd` | `_push_out_of_static_obstacles`（热点主循环）|
| 同上 | `_obstacle_footprint_closest`（含 `find_children("*","CollisionShape3D")`）|
| 同上 | `_ground_hull_points_xz`（逐骨骼/逐几何顶点采样）与 `_ground_hull_support` |
| 同上 | `_unit_ground_half_extent`（遍历本单位 CollisionShape3D）|
| 同上 | `_on_velocity_computed`（每 tick 每单位一次）|
| `source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs` | `BuildRangeMeters`（放置网络窗口；与本问题无关但被 AI 建造使用）|
| `source/match/TargetAcquisitionGrid.gd` | **已有的单位空间网格**（`acquire_candidates(origin, radius)`，增量维护，`CELL_SIZE = 10.0`）|
| `source/match/handlers/UnitVisibilityHandler.gd` | 逐单位可见性（每 0.2 s 扫 revealers；实测仅 0.007 ms/帧，非热点）|

### 4.3 障碍组是什么

- 组名由 `Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain]` 决定（如 `navigation_obstacles_ground` / `..._air`）。
- **单位与建筑都在组里**（推断：303 单位场景下组规模与单位数同量级；⚠️ **未单独打印确认**，见第 10 节）。
- 循环里对每个障碍都有若干廉价前置判断（`== _unit`、`is_instance_valid`、`radius <= own_radius` 等），但**昂贵部分（footprint / hull）对通过前置判断的障碍仍会执行**。

### 4.4 恶性循环（放大器）

```
单 tick 46 ms 已远超 16.7 ms（60 Hz 预算）
  ⇒ Godot 每渲染帧最多补 8 个物理步
    ⇒ 每渲染帧单位要做 8 次推出去穿透
      ⇒ 帧时间 ≈ 8 × 46 = 368 ms（实测 418 ms）
```

---

## 5. 已尝试并失败的方案（请勿重复）

| 方案 | 结果 | 失败原因 |
|---|---|---|
| 缓存 `find_children` 的节点引用（每物理帧刷新 + `is_instance_valid`）| **破坏等价性**（`Movement push mismatch: bone pose hull`）⇒ 已撤销 | `queue_free` 的节点在本帧内 `is_instance_valid` 仍为 true ⇒ 缓存返回**僵尸引用** |
| 同上但加 `is_queued_for_deletion()` 判据 | 等价性 **0 failure** ✓ 但**性能更差**（100 单位 5.2 → 4.6 FPS）⇒ 已撤销 | 改错了地方：`find_children` 不是主要成本 |
| 保守前置剔除 + 把精确 hull 支撑挪到剔除之后（R25）| 等价性 ✓ 但帧 417 → 428.9 ms（无收益）⇒ 已撤销 | 60 米内 300 单位**人人都是邻居** ⇒ 剔除跳不掉任何障碍 |
| 调 RVO 参数（`neighbor_distance` / `max_neighbors`）| 项目内**已有两次负面 A/B**（见 `Movement.gd` 注释）| 瓶颈不在避让参数 |
| 把单位移出障碍组（诊断用）| **挂起** | 触发大范围重烘焙 |

---

## 6. 硬约束（方案不得违反）

1. **不得**用降低画质、关迷雾、降分辨率、删阴影/战斗反馈来换帧率；
2. **不得**停掉屏幕外/迷雾外单位的模拟（它们仍须移动/攻击/采矿/生产/参与权威同步）；
3. **不得**修改单位的**尺寸、射程、速度、视野、碰撞**来冒充优化；
4. 行为必须**可证明等价**或经产品口径批准的**重标定**；
5. 不把 SceneTree/节点变换/骨骼/导航对象随意搬到工作线程（只允许稳定纯数据计算外移 + 主线程提交）；
6. 不把普通战斗单位整批替换成 MultiMesh 而丢掉动画/选择/迷雾；
7. 改动要小而可回滚；失败必须撤销并保留最后已验证版本。

---

## 7. 验收方法（任何方案都要过这几关）

| 关卡 | 命令/方法 | 通过标准 |
|---|---|---|
| **行为等价**（硬门禁）| `python tools/dev/small_army_performance.py --equivalence --out <dir>` | `Movement push equivalence completed: 0 failure(s)` |
| 移动/导航回归 | `toolspython tools/run_parallel_suites.py --jobs 1 --serial "" --no-recheck --ids movement-push-equivalence,navigation-stability,movement-recovery` | 全部 rc=0 |
| 性能 A/B（同夹具）| `python tools/dev/small_army_performance.py --count 100 --out <dir>` | 同负载 frame p50 下降且对照组（关回调阶段）不变 |
| 大规模 A/B | `tests/automated/_AiArmyStressProbe.tscn`（`$env:AIRTS_AI_ARMY=300/1000`）| 阶梯 100→200→400→700→1000 逐级 30 FPS |
| 渲染回归（如动渲染）| `tests/automated/_FullVisionRenderProbe.tscn` | **全图视野**下 draw 与视觉对照，且 frame p50 不退化 |
| 大地图分支 | 20 Hz 物理分支（`Match.gd:90-104`）| ⚠️ 仓库内**无生成图场景**，**未验证**（见第 10 节）|

---

## 8. 方案的**可能方向**（均为候选，未验证；按性价比排序供参考）

### 方向 A：消除重复避让（唯一有量级希望的方向）
引擎的 RVO **已经在做单位间避让**；而 `_push_out_of_static_obstacles` 又把**所有单位**当作静态障碍逐个精算一遍 ⇒ 疑似**双重避让**。
若让静态推出**只管建筑**、单位间交给 RVO ⇒ 障碍数与访问次数可降**一个数量级**。
⚠️ **这会改变行为** ⇒ 必须重跑等价性门禁并做移动/导航重标定；预期需产品口径批准。
■ 未验证：单位在障碍组中的**确切占比**（见第 10 节，探针两次挂起未取到数）。

### 方向 B：降低**单次访问**成本（上限约 5×，不足以单独达标）
- `_obstacle_footprint_closest` 里的 `find_children("*","CollisionShape3D")` 可以改为**一次性的形状句柄缓存**（注意僵尸引用问题，见第 5 节）；
- `_ground_hull_points_xz` 逐骨骼采样（每单位约 100 个骨骼位姿）⇒ 考虑**预计算 hull 多边形**并用「一次调用内复用」的方式；**不要**跨帧缓存随姿态变化的 support；
- 注意：`Skeleton3D` 在 Godot 4.7 **没有**批量位姿 API（我们运行时内省确认过）。

### 方向 C：减少「每次推出去穿透」的**调用频率**
每单位每 tick 一次 ⇒ 每帧 8 次。若能把推出从「每个 tick」改成「按需/限量」（例如仅当位移超过阈值时）⇒ 直接乘性收益。
⚠️ 需证明不改变到达/卡住/窄口等行为。

### 方向 D：打破 8 步放大器
当前恶性循环是「tick 太慢 ⇒ 引擎补 8 步 ⇒ 更慢」。若单 tick 降到 16.7 ms 以内，引擎只需 1 步 ⇒ **8× 收益**。
⇒ 所以**单 tick 成本**是比帧时间更本质的指标（我们的诊断都保留了 `TIME_PHYSICS_PROCESS`）。

### 方向 E：把推出计算搬到纯数据层/批处理（遵守第 6 节第 5 条）
例如把「本 tick 所有单位的推出求解」收集为稳定快照后在主线程一次性求解（避免每单位重复遍历组）。

---

## 9. 代码阅读入口（给方案设计者的最短路径）

1. `source/match/units/traits/Movement.gd` → 搜 `_push_out_of_static_obstacles`、`_on_velocity_computed`、`_obstacle_footprint_closest`、`_ground_hull_points_xz`、`_apply_crowd_avoidance_defaults`；
2. `source/match/TargetAcquisitionGrid.gd`（已有的空间网格，可复用为候选集来源）；
3. `source/match/handlers/UnitVisibilityHandler.gd`（同类「逐单位扫描」模式，实测非热点）；
4. 仓库规范：`AGENTS.md`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`、`skills/airts-performance-optimization/SKILL.md` 及其 references。

---

## 10. 未验证 / 未知（诚实清单）

| 项 | 状态 |
|---|---|
| 障碍组里**单位 vs 建筑**的确切占比 | **未取到数**（组成统计探针两次挂起、无输出）|
| **路径查询（A*/导航网格）**本身的成本 | **未单独测量**。已知：导航服务器总计 8–25 ms，且断开避让回调后掉到 0.23 ms ⇒ 从这两个数看路径查询不是大头，但**没有专门的计数证据** |
| 大地图（生成图）20 Hz 分支下的表现 | **未验证**（仓库内无生成图场景，无法复现）|
| 采矿/产兵/建造、副官持续命令、退局重开等长时负载 | **未跑** |
| `TIME_PROCESS` 110–145 ms 与「两 monitor 之外」的 ~225 ms 的确切归属 | **未定位**（渲染已被排除；疑似引擎主循环对 12649 个节点的自身工作）|
| GPU 时间 | 本次环境可测（RTX 3080 Ti），但**未做 GPU 侧 profiling** |

---

## 11. 已交付的成果（当前工作区状态）

- ✅ **一项已验证的性能优化已合入**（`Movement.gd` 的保守前置剔除，sha 前缀 `B4E4F4A934952093`）：
  - 100 单位 frame p50 **184.4 → 110.7 ms（−40%）**；200 单位 **358.2 → 257.2 ms（−28%）**；53 单位容量 **+63%**；
  - 等价性 **0 failure**；移动/导航相关套件 rc=0；
  - 回滚备份：`agent/runs/perf-r16/Movement.r16-accepted.gd.bak`。
- ✅ 完整诊断数据与探针：`agent/runs/perf-1000/`、`agent/runs/rvo.log`、`agent/runs/vis2.log`、`agent/runs/agg.log`；
- ✅ 探针族：`tests/automated/` 下的 `_AiArmyStressProbe`、`_FullVisionRenderProbe`、`_RvoVerdictProbe`、`_ScriptAggProfile`、`_MovementMicroBench`、`_MovementMoveBench`、`_PhysicsProfileBench` 等；
- ✅ 技能证据区已更新：`skills/airts-performance-optimization/references/cpu-candidates.md`（含 measured 条目的方法教训）。

---

## 12. 一句话给方案设计者

> 这不是「渲染问题」也不是「A* 算得慢」，而是 **每个单位每个物理步都要对场上所有其他单位做一次局部避让 + 去穿透精算**（O(n²) 碰撞响应），再被「单 tick 超时 ⇒ 引擎补 8 步」放大成帧时间。
> 单次访问提速最多给 5×，**必须减少访问次数本身** —— 而最可能的数量级来源是**消除 RVO 与静态推出之间的重复避让**。
