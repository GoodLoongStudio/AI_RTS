# CPU 候选与当前入口

审计日期：2026-10-07。优先级表示先测顺序，不承诺收益；按 profiler 重新排序。

## 已验证的经验

`source/match/units/traits/Movement.gd` 的 `_on_velocity_computed → _push_out_of_static_obstacles` 曾在每个障碍上重复采样同一单位的模型/骨骼点。静止单位也有 RVO 回调，原 `_physics_process` 计时漏掉该成本。

已实施：一次同步推出调用内懒采样点集，再按各障碍原方向计算 support；远障碍拒绝后才查询当前位置 inside/escape。不跨帧缓存，不简化 OBB，不改变碰撞和到达输出。

历史数据：53 实体同夹具原约 4.4 FPS，补丁后移动约 105 FPS；完整建筑后独立重放移动约 91.5 FPS，正常 30 FPS 上限约 29.8 FPS、p95 约 54 ms。5,959 项原算法对照和 340 项独立手算通过；全局回归仍 needs-review。范围和原始证据见 `agent/reports/closed-loop/2026-10-07-small-army-performance.md`，不是本轮新测。

可复用原则：把不随内层变量变化的工作移出内循环，先 cheap reject 再 exact check；证明时序相同后才缓存，不把随姿态、方向变化的 support 固化成一个最大圆。

## C1：静态障碍候选筛选与 trait 句柄缓存

状态：**部分 measured**（保守前置剔除已落地，见本文末 ✓）；其余仍 `structural-candidate`；优先 P1；同输出实现无画质影响。

入口：Movement 的 `_push_out_of_static_obstacles`、`_obstacle_footprint_closest`、`_unit_ground_half_extent`；`source/match/units/traits/MovementObstacle.gd`。仍存在每单位回调全扫障碍组、反复 `find_children(CollisionShape3D)` 的路径。

方案：先统计组扫描数、形状查找数、骨骼点数/采样数和总耗时。优先缓存节点引用/形状描述，再考虑 Match 内静态障碍空间索引，保留精确形状窄相位。

关键边界：

- broad-phase 界必须来自有效碰撞形状的实际世界 XZ 范围和单位 support 上界，覆盖偏心中心、嵌套缩放、旋转长盒、多形状和实际净空；不能仅用 `MovementObstacle.radius` 或固定“附近 X 米”。
- 顺序推出会改变候选位置；索引不能只查询最初点后漏掉新靠近的障碍。证明候选界覆盖所有中间位置，或在需要时重查，并保留原处理顺序/结果。
- 句柄失效：离树/死亡、建造完成换形状、shape resource 改动、disabled、父节点/变换改变、换局；不缓存会临时变化的 radius 数值（窄口/软穿行）。
- 不能因零速度跳过推出来隐藏问题：静止单位可能被新建筑、其它单位或同步位移嵌入。

验证：复用 movement-push-equivalence，增加索引漏候选、连续推出、销毁/新增/形状替换、偏心 OBB、内部出生/脱出；检查产出/采矿/到达/窄口/大群拥挤。测 50/100/200 mover 与建筑增长曲线。

## C2：单位可见性空间候选和半径读取

状态：`structural-candidate`；优先 P1；同输出实现无画质影响。

入口：`source/match/handlers/UnitVisibilityHandler.gd::_physics_process/_recalculate_unit_visibility`，当前每 0.20 秒对目标逐个扫 revealers；`source/match/units/Unit.gd::_get_radius` 每次重复查找 Movement/MovementObstacle。单位缓存已存在，不要重复解决组缓存。

方案：同一拍先快照观察者的实际位置/基础视野/半径/归属/揭示状态，再做保守空间查询和原精确距离检查。缓存 trait 引用，半径仍读取当前值。

已有 `source/match/TargetAcquisitionGrid.gd` 是索敌候选网格；先核验是否可复用维护快照，否则扩展现有机制。它的固定 4m 目标半径 allowance 与索敌业务有关，不能直接充当视野查询上界而漏掉大建筑。

关键边界：保留 `sight_range_against + SIGHT_COMPENSATION`、禁用/观战、揭示组变化、死亡当帧与建筑残影规则。索引快照落后时必须覆盖最大位移，瞬移/新单位及时入格；只用 process_priority 不能证明覆盖晚到的 velocity callback。按实际事件时序验证。不改变 UPDATE_INTERVAL 为“省 CPU”。

验证：每拍与暴力参照比较全部显隐结果；视野边界、大小建筑、重叠视野、空中/地面、瞬移、死亡/换局、观战。新扫描候选数和维护成本必须一起测。若密集相互覆盖仍近似 N²，如实报告，不把算法复杂度保证成普遍线性。

## C3：探索网格批写与迷雾 dirty 更新

状态：`structural-candidate`；优先 P1；同输出实现可无画质影响，但视口调度有已知黑图风险。

入口：`source/match/FogOfWar.gd::_sync_revealed_circles/_mark_explored/_paint_fog_viewports`。

当前：10Hz 每个 revealer 重扫覆盖格、写 1；每单位从玩家字典取 PackedByteArray 再写回。检查 COW detach 及重复写成本，不凭注释断言分配数量。两个 fog 子视口又常驻 UPDATE_ALWAYS。

第一候选：一次同步内按玩家获取/更新网格、最后统一提交；只在格子从 0→1 时写入。单位位置/视野/归属/揭示状态完全不变可跳过重复圆栅格化；不能仅按“还在同一格”跳过，小幅移动也可能揭开新格。网格 reset/generation 更换必须清掉缓存。不同玩家的网格不得串账。

第二候选：分开当前可见与永久探明的 dirty 标志；无数据变化时不重绘，数据变化时保留原刷新节拍和正确的 FogViewport → CombinedViewport → 主画面/小地图消费依赖。现有 UPDATE_ALWAYS 是防黑图补丁，**不能直接全改 UPDATE_ONCE/UPDATE_DISABLED**。先证明首帧、刷新完成信号和累计历史保存。

验证：逐格比对暴力探索结果/玩家分账、视野变化/显隐/死亡/换局/地图 resize；完整地表/小地图像素和建造判断一致。记录变更格数、数组复制/分配、CPU 时间与子视口 GPU 时间。不要把 GPU 纹理搬回 CPU 逐帧查询；小地图当前只在绑定前有限次 `get_image()`，不是稳态每帧读回。

## C4：副官路径提示与寻路复用

状态：`structural-candidate`；优先 P1（副官大队命令）；同输出实现无画质影响。

入口：`source/match/hud/CommandVisualizer.gd::_spawn_pulse/_find_unit/_navigation_points`。

当前：每个受令单位 `_find_unit` 全扫 units，随后额外 `map_get_path` 并创建 ImmediateMesh/Material/Tween。一次 M 个受令单位产生 M 次全扫和 M 次求路，纯 UI 路径可能和权威寻路重复。

方案：先一次构造单位 ID 映射或复用 Match 的生命周期索引；使用已生成的有效路径，按命令/目标/导航版本缓存，批合并路径几何与共享材质。复用条件须包含单位/移动域/地图/目标/路径版本，不能把第一辆坦克的路径给所有兵；路径待就绪时按既有表现合同处理，不阻塞权威命令。

材质共享要保留生命周期独立性：`_apply_alpha` 每个 pulse 都改 material alpha，不能跨不同时间的命令 pulse 共享这份可变材质，否则旧命令会把新命令提前淡出。可在同 pulse 内共享，跨 pulse 只共享不变资源，或把各自 alpha 移到实例参数并验证兼容后端。

先消除重复算同一路径，若仍需分帧生成 UI 路线，明确并测量显示延迟；减少路线数量/换成只有中心线属于表现改动，不自动实施。

权威导航已有 `TerrainNavigation.gd` 的 collider 源、异步 bake、双缓冲和 bake_revision，生成地形已有路径缓存。优先检查多次目标重置、缓存版本失效、同目标重复可达性查询；不要重新“添加异步烘焙”。绘制型查询与实际 movement 分别计时，不把导航监控直接归因给 RVO。

验证：大队单次/连续命令、过桥/窄口/新建筑阻塞、导航版本更新、空中单位；路线/到达正确，命令回执延迟不增。比较实际 path query 次数、命令瞬间最大帧耗时和路线节点峰值。缓存上限/换局清理必须可观测。

## C5：步兵站立更新、特效与日志

状态：`structural-candidate`；优先 P2，步兵/战斗负载下再排序。

- `InfantryAnimationDriver.gd::_plant_feet_on_origin`：站立渲染帧强制更新骨骼，再找六个脚骨。先缓存 Geometry/骨架和骨索引；验证是否有重复强制刷新可合并。不能减攻击事件/枪口刷新，也不能冻结供真实 hull 使用的骨骼姿态而改变碰撞。近处 Fire/Run/Death、足部贴地必须保持。
- `ShellExplosion.gd`、BloodMist、MouseClickAnimationsHandler、采矿 SparklingAnimation：测量 instantiate/free、Timer/Tween、资源与粒子峰值，优先有上限的表现对象池。归还时断开信号、取消旧 timer/tween、重置 emitting/粒子残留/姿态/阵营/可见性，用 generation 防旧回调误删新效果；共享不可变资源，避免池无限长大。
- **CannonShell.gd::_process/_perform_impact 会调用 ResolveImpact，不是纯视觉。** 不能因屏幕外/特效预算跳过该节点或延长它的时间。先分离权威结算与表现，等价测试通过后才裁表现。
- `Movement.gd::_physics_process` 中 G4PERF 每 40 物理帧按单位打印，FogOfWar 也打印。先测发行/调试日志的格式化、I/O、日志体积；诊断开关控制详细采样，常规仅低频聚合/计数，保留错误和有界回放。禁用日志不等于禁用功能。

## C6：小地图、HUD、副官快照与网络

状态：`structural-candidate`；优先 P2；只在相关场景的 profile 支持时实施。

- `Minimap.gd::_sync_real_units_with_minimap_representations` 每拍重扫 units/resource_units、重建字典；用生命周期集合、dirty 点数据和批量绘制候选替代重复工作。当前已有静态底图、0.10 秒单位同步、HUD overlay 和实时 fog 绑定，不要额外重复造这几项。相机视锥框继续平滑跟随；资源点/敌人不可泄露。
- `Ra3Sidebar.gd` 已 0.4 秒刷新，`SelectionPortraitPanel.gd` 已签名复用和仅更新 HP，不存在每帧重建所有肖像的证据。继续优化需统计条目扫描、无变化属性写入/布局失效，而不是先减 UI 更新频率。
- `DebugControlServer.gd::_fast_sample` 已 10Hz、reachability 分槽/上限；先测 sample_ms、JSON、production snapshot、路径 getter 是否触发新查询。代码注释不能证明每次 is_target_reachable 都执行一次新寻路；用实计数/引擎行为核实。预算需公平轮转，不能长期饿死后排单位；固定 256 条 limit 不是支持大规模军队的优化方案。
- `NetSync.gd::_recompute_client_visibility` 多客户端各扫己方 revealers 与目标；可以复用按玩家空间候选/快照，保留权威信息隔离。它与单机当前视野口径存在差异，优化前明确产品规则，不能悄悄“统一”后声称只是性能等价。delta/interest management 要测出生、死亡、重连/揭示、RPC/快照字节与延迟；本地单人路径不应执行无用网络工作。

所有缓存/索引/pool：记录最大容量、释放/换局归零、命中/失效统计和内存曲线；拒绝用越来越大的缓存掩盖运行时间越长越卡。

## 实测否证与教训（2026-10-07，R2）

- **否证 C1 的假设**：把 `_push_out_of_static_obstacles` 里 4 处 `find_children`（L969/L1211/L1831/L1052）
  改为"每物理帧一次的节点引用缓存"后，同夹具 `nav_ms` 仅 12.68 → 11.37 ms（噪声内），FPS 无可复现提升，
  且生产上限下 p95 仍 53.67 ms ⇒ **子树扫描不是该路径瓶颈**（负载 53 实体 / 47 movers / 6 obstacles）。
- **帧内节点缓存不安全（决定性 A/B）**：同一补丁使 `MovementPushEquivalence` 失败
  （`Movement push mismatch: bone pose hull` ×3），撤销后同命令 rc=0 通过 ⇒
  `queue_free()` 的节点在本帧结束前 `is_instance_valid()` 仍为 true，缓存会返回**僵尸引用**；
  等价性夹具会在同帧内替换形状/子节点。⇒ **不要**用"每帧刷新 + 实例有效"来缓存节点列表。
- **方法教训**：整个推出路径 ≈12 ms（关掉回调仅 0.246 ms）说明成本在**真实计算**内；
  先从代码结构推断热点会浪费整轮 ⇒ **先加分步计时/计数仪表**，再决定补丁。

## 第二次否证与工具教训（2026-10-07，R5）

- **不要在大文件里行拼接插桩**：`Movement.gd`（2400 行）三轮内 4 次解析错误
  （孤立 `if`、缩进方向错、`return point` 缩进坏、子树块层级不一致）⇒ 全部撤销；
  还原后用 `MovementPushEquivalence` **rc=0** 复验 ✓。
- **可行替代**：`Performance` 监视器 / `Engine.get_physics_frames()` 采样 / 独立包装探针；
  必须插桩时**每插一处立刻解析冒烟**。
- **仍然成立的数字**（R3/R4 实测，未撤销）：推出路径整体 ≈12 ms/帧（关回调 0.246 ms）；
  `hull` 采样 2166 次 / 113.9~173.7 ms 每单位；`fp` 12951 次 / 124.9 ms 每单位 ⇒ 合计仅约 **20%**，
  其余 ~80% **尚未定位**（`get_nodes_in_group` 与 `vis47<=0.01` 的子树扫描是**未验证**嫌疑 ✓）。
- `Skeleton3D` 在 Godot 4.7 **没有**批量全局位姿 API（运行时内省 ✓）⇒ 批量读取方案不可行。


## ✅ measured：C1 的落地形态——**保守前置剔除**（2026-10-07 R16，已晋级 champion）

状态：**measured**（同夹具 A/B + 等价性 0 failure + 相关回归 rc=0）

### 改动（唯一文件 `source/match/units/traits/Movement.gd`，sha 前缀 `B4E4F4A934952093`）
在 `_push_out_of_static_obstacles` 的每障碍循环里，把**昂贵的** `_obstacle_footprint_closest`
（子树搜索 + AABB）与后续几何回退，挪到**可证安全**的距离剔除之后：

```gdscript
# 证明：stand_off ≤ physical_min + vis47 + OBSTACLE_CLEARANCE_MARGIN_M
#       step_distance ≥ |planar − obstacle_c| − obstacle_radius
if dir_c.length() > physical_min + vis47 + OBSTACLE_CLEARANCE_MARGIN_M + float(obstacle_radius):
    continue
```
被剔除的障碍**原本也不会触发推动**（原判据 `step_distance >= stand_off` 即 continue）⇒ **输出不变** ✓。
为拿到 `vis47` 上界，把 hull/vis47 段前移到 `fp47` 之前（二者无依赖 ✓）。

### 实测（`tools/dev/small_army_performance.py` 同夹具，未解锁 FPS 口径）
| 负载 | frame p50 补丁前 → 补丁后 | FPS |
|---|---|---|
| 53 单位（107 实体）| 3.1 → **2.5 ms** | 140.7 → **229.9**（+63%）|
| 100 单位（101 movers）| 184.4 → **110.7 ms**（−40%）| 5.2 → **9.1** |
| 200 单位（201 movers）| 358.2 → **257.2 ms**（−28%）| 2.7 → **3.6** |
| 30 FPS 生产上限（53 单位）| 33.4 → 33.5 ms | **不变**（本已卡上限）|
| 对照：断开 `velocity_computed` | 3.7 → 3.7 ms | 不变（预期特征）|

### 为什么两次"缓存句柄"失败而这次成功（方法论）
- R2/R14 改的是**每次迭代内部**的 `find_children` ⇒ 只占迭代成本很小部分 ⇒ 无收益（且 R2 因
  `queue_free` 节点 `is_instance_valid` 仍为 true 而**破坏等价性** ⇒ 两次均撤销）；
- R15 只读诊断（关引擎驱动 + 手动调用计时）：`_on_velocity_computed = 135.8 µs/次`，
  是 `_physics_process = 17.1 µs` 的 **8 倍**；触发 **0.99 次/单位/物理帧** ⇒ 101 movers ⇒ 13.7 ms/帧；
- ⇒ 真成本是**迭代次数 × 每次迭代的重活**（高负载下属 O(n²) 量级）⇒ **减少重活次数**有效，
  单纯把重活做快无效。

### 复用要点
1. 先量"每帧调用次数 × 每次成本"，再决定"减少次数"还是"降低单次成本"；
2. 剔除上界必须**可证**（写出 stand_off/step_distance 的不等式），否则会改变输出；
3. 目标负载上验（53 单位看不出差别，100/200 才显现）；
4. 门禁：`MovementPushEquivalence` 必须 0 failure（它是前两个候选的杀手）。
