# DeepSeek Harness 执行提示词：逐单位碰撞包围与空气墙修复

- 版本：`v2-shape-pipeline`，2026-10-01 更新；本版替代本任务的旧提示词，保留原有逐单位截图和数据闭环要求。

你正在修改 `G:/AIRTS/AI_RTS`。请先完整阅读：

1. `AGENTS.md`
2. `skills/闭环验证工作法.md`
3. `agent/manifest.json`
4. `agent/plans/2026-10-01-per-unit-collider-clearance-plan.md`
5. `agent/mcp/README.md`
6. `agent/plans/2026-10-01-world-scale-runtime-audit-plan.md`

本任务的验收目标是：**每个单位和建筑的实际可通行边界紧贴真实地面投影，只留可解释的小余量；绝不出现模型外很远就有空气墙，也绝不允许单位穿入模型。**

你安装了 `godot-bridge`、`dsh-godot-skill`、`dsh-godot-play` 等插件，但插件不是事实来源。先阅读插件实际工具说明；若插件没有可见截图/打开图片能力，必须使用仓库已有 Godot CLI、MCP 或运行器补齐，否则标记未完成，不能用文字假设代替视觉验证。不要因为某个旧插件停用就删除已有脚本、CLI、MCP 或测试。

## 先说清楚问题边界

当前“半径”至少有六种语义：视觉模型、物理形状、移动个人空间、导航 carve、逻辑占位/推出、建造 footprint。它们可以不同，但每一种都必须有来源、单位和独立验收。图中红色圆可能是 `MovementObstacle` 加导航 `agent_radius` 的配置空间洞，不等于黄色物理碰撞盒；工人场景还存在视觉/碰撞约 `0.92m` 而 `Movement.radius=2.0m` 的静态可疑值。请先通过运行时路径证明究竟是哪一层制造了空气墙，再改最小必要层。

这里的 `0.92m` 是场景圆柱属性，不是重新测量过的模型地面半径。旧 `.tscn` 的 authored vertices 也不一定是生效顶点：`MovementObstacle._sync_carve_vertices()` 可能在初始化时重写它们。报告必须读取稳定初始化后的实际形状、变换和 vertices。

**形状支持是本任务的必要部分，不能漏掉。** Godot 支持多种形状，但当前项目的 `MovementObstacle._shape_local_aabb()`、`CollisionVolumeOverlay._shape_local_aabb()`、`GodotStructurePlacementWorldPort.ShapeBounds()` 只识别圆柱、球、长方体和胶囊。未识别的形状会返回空 bounds/null，调用链可能漏掉障碍或按旧 radius 回退。换上凸多面体后，仅 Godot Inspector 看起来正确不算修复。

**碰撞检测不等于移动阻挡。** 当前单位场景使用 `Area3D`，`Movement._on_velocity_computed()` 直接写单位位置；不能假定 `CollisionShape3D` 会像 `CharacterBody3D.move_and_slide()` 一样自动阻止穿越。追踪实际运动链路并修复使用旧圆形规则的环节，不能只换 shape，也不要未经必要性证明重写整个物理架构。

## 绝对禁止

- 不要把坦克写成 9m，也不要依据旧对话猜模型尺寸；先在当前资源和稳定姿态下测量。
- 不要把所有单位改成一个大圆、统一 AABB，或把所有 radius/footprint 强行设成同值。
- 不要因读取器不支持某形状而悄悄回退成大圆、零尺寸或忽略该实体；显式报告缺失支持并补齐本次实际采用的形状。
- 不要缩放模型、给 UnitRoot 追加补偿缩放、提高全局尺寸系数来掩盖碰撞错误。
- 不要关闭碰撞层、导航、避让、逻辑占位或把单位传送到目标来伪造通过。
- 不要只改测试断言、截图标签或 debug overlay；不得以“红圈隐藏了”为修复。
- 未完成截图打开、数据对照、实际贴边通行和回归前，不得声称“已修复”。
- 不得覆盖或清理其他 Agent 的未提交改动。

## 执行协议：一个实体一个闭环

### 1. 基线

先输出 `git status --short`、相关文件 mtime、Godot/MCP 进程和端口。创建 `agent/runs/<run-id>/`，保存原始日志、JSON、截图和命令 rc。枚举所有单位、建筑、炮塔、资源点，不得只修用户截图里的指挥中心和工人。

先建立 `shape-support-matrix.json`：以“形状类型 × 消费模块”为列，记录实际解析分支、回退方式和测试。消费模块至少包括检测/选择、导航 carve、实际移动阻挡、逻辑占位、建造重叠/相邻/预览、出生/集结/采矿站位、调试显示。引擎支持与项目支持必须分列；标为 unsupported 的形状不能投入正式实体。

### 1A. 按模型选择碰撞形状，先打通读取链路

不要仅按“建筑/单位”类别固定一种形状，逐实体选择能贴合本体的低复杂度方案：

| 形状 | 使用规则 |
|---|---|
| `BoxShape3D` | 长方体的三维尺寸独立设置；正方体只是特例。可旋转形成贴合车身的盒体，不是世界 AABB。 |
| `CylinderShape3D` / `SphereShape3D` | 仅在本体确实接近圆形/球形时采用；不能用覆盖窄长车身的大圆代替贴合形状。 |
| `CapsuleShape3D` | 可作为人物或特定主体的近似，需核实轴向、姿态和地面投影，不能按名字自动套用。 |
| `ConvexPolygonShape3D` | 对简单形状无法贴合的实体采用简化凸包；读取实际 points 及完整变换。单个凸包会填平凹口，不能用它堵住玩家可通过的凹形通道。 |
| 多形状组合/凸分解 | 使用少量 Box/凸体等组合保留 L/U 形、支架或入口。按有效形状的并集做窄相位，不能把整个并集变成一个大 AABB/大凸包。 |
| `ConcavePolygonShape3D` | 主要考虑静态地形，不能为了贴模给所有移动实体套完整三角网格；凹网格是空心的，不宜直接当成 `Area3D` 的实体占用体。需要时用凸分解/简化占地表示，并显式验证。 |

不要求每个实体都改成多边形，也不要求实现本任务未用到的全部引擎形状。但至少保留已有四种简单形状兼容，支持实际选用的凸体与组合形状；未采用的凹网格必须有明确的拒绝/适用范围，不能静默漏读。

为实际使用的形状确定唯一可追踪的几何来源，并分别派生地面占用、命中/选择、导航轮廓和建造脚印。优先复用已有工具、Godot 几何/查询 API 和本地模式；只在多处重复读取确实造成漂移时建立小型共享转换契约，遵守现有 C#/GDScript 层边界，不把 Godot 类型塞进 Domain/Application。

必须核查和修复这些消费点，不能只改 `.tscn`：

- `MovementObstacle.gd`：有效 shape 的读取、points/完整世界变换、carve vertices，以及初始化时覆盖 authored vertices 的行为。
- `CollisionVolumeOverlay.gd` 与尺寸探针：凸体边/三角面/组合轮廓真实显示；AABB 独立标为粗包围框，不能伪装成实际 shape。
- `GodotStructurePlacementWorldPort.cs`：`ShapeBounds`、重叠检测、边缘距离；AABB 仅作 broad-phase，保留窄相位轮廓，不能把两个未接触的旋转盒判成相撞。
- `Movement.gd`：静态推出、目标钳制和每步移动应遵守实体的有效地面几何；RVO 圆只是避让近似，不能成为硬占位真相。
- `GeneratedTerrain.gd`：`set_structure_blocker()` 当前接口只接收中心和 radius，必须检查逻辑地图是否仍按圆挡路，按必要范围接入轮廓，并验证格子量化影响。
- 建造白色范围、自动选址、出生/集结、采矿/卸矿站位：核查是否仍按旧 radius 推远。白色范围与权威放置使用同一规则，不只是画一个较小圆。

读取时明确 collision owner 和用途，区分主体 shape 与子 Area 的选中/索敌检测圈；按各用途过滤 disabled/不生效的形状，不能递归收集所有 `CollisionShape3D` 合成一个超级碰撞体。处理嵌套变换、偏移、旋转、组合和资源复用；修改共享 Shape 资源不得意外改变其他实体。非均匀缩放先诊断，不允许为了读取方便改坏原模型。

fallback 必须显式可审计：日志/矩阵包含 entity、shape class、节点路径和原因。正式占位遇到未支持形状，拒绝使用或要求修复；不能把空 bounds 当作“没有障碍”。若已有不可避免的近似，报告近似误差和通行实测，不能自动放大 radius。

### 2. 独立 Godot 检查场景

为当前实体在**同一主项目**创建可独立运行的检查场景/探针，不要创建无法回写主项目的复制工程。每次只加载一个实体，显示米制网格、坐标轴、模型地面投影和以下分色层：

- 绿色：实际 `GeometryInstance3D` 地面投影/hull；
- 黄色：`CollisionShape3D` 的真实 shape 或精确简化形状；
- 蓝色：`Movement.radius` 或移动 hull；
- 红色：`MovementObstacle` 实际 vertices 及导航 `agent_radius` 外扩后的 carve；
- 紫色：逻辑 occupancy/stand-off/建造 footprint（若存在）。

AABB 只可用于 broad-phase 显示。窄长车辆必须用 OBB/凸 hull/复合形状测试；不要用世界 AABB 的长边制造假空气墙。每个场景至少生成俯视、侧视、正常游戏视角三张截图，并**实际打开查看**。截图必须包含实体名、姿态、yaw、世界米标尺、各层数值和截图对应的源码/资源 hash。

### 3. 稳定测量

等待资源导入、蒙皮、骨骼和动画完成后再测。对每个实体记录 yaw `0/45/90/135°`；带骨骼/旋翼/炮塔的实体至少记录静止、移动、攻击姿态。骨骼包围盒不能冒充完整 skinned mesh envelope。地面阻挡只计入实际接近地面的几何；炮管、天线、旋翼等悬空部件另记为命中/选择 hull。

地面域与空中域、高度是否实际重叠分别验收；不能把旋翼/悬空炮管直接投影成地面障碍，也不能让空中实体被地面硬占位无条件拦下。若 footprint 需要扩展配表，先更新现有 schema/DTO/加载器/测试，不得添加项目不识别的字段使整个 balance 加载失败。

矩阵每行至少包含：

```text
entity
visual_world_aabb_m
ground_projection_hull_m
collision_shape_world_m
collision_shape_types_and_owner_paths
shape_reader_status_and_fallback_reason
movement_hull_or_radius_m
obstacle_vertices_and_carve_bounds_m
logic_blocker_and_stand_off_m
construction_footprint_m
spawn/rally/service_offsets_m
first_limiting_layer
minimum_hull_to_hull_clearance_m
source_and_screenshot_paths
```

不能稳定测量的字段写 `unknown`，并阻止该实体进入通过状态。

### 4. 空气墙复现和第一限制层追踪

对每个实体在四个方向进行：从外部靠近、沿边横向走、从一侧穿过、点击模型内部/边缘/外部目标。至少重复三次，记录最后可行位置和停止原因。每帧或每次目标钳制都追踪以下候选：`NavigationServer3D` closest point、RVO/avoidance velocity、`_push_out_of_static_obstacles`、逻辑 occupancy、施工/服务站位、arrival tolerance。报告第一层把单位挡住的位置，和其后的重复膨胀；不要只测中心距。

特别检查：

- `MovementObstacle` 是按真实 vertices、碰撞 bounds 还是 fallback radius 生成；
- navmesh `agent_radius` 是否为所有单位共用过大的最大值；
- carve 外扩是否在导航、C# 放置和逻辑占位中被重复应用；
- worker/vehicle 的 `Movement.radius` 是否明显大于其真实地面 hull；
- 调试 overlay 的红色范围是否只是可视化近似，是否误导排查。

导航 carve 是供单位中心走的配置空间边界，本来要包含单位尺寸；不要误把这次正常外扩再当成本体大小，随后又加一遍单位半径。对共用最大 agent radius 的网格，记录小单位的额外空隙；选最小可验证修复，并确保大单位仍不会穿墙，不能仅把全局 agent radius 调小就交付。

### 5. 最小修复和量化门槛

按第一限制层最小修改。候选安全余量只作起点，必须用测量证明：工人/步兵 `0.05–0.15m`、车辆 `0.10–0.25m`、建筑 `0.10–0.30m`，并且总余量通常不超过最长地面尺寸 5%。若超出，报告真实几何、导航 voxel 或性能原因。验收使用 hull-to-hull 表面间隙，不使用中心点距离；要求能贴近而不穿模、沿边能通过、狭窄两单位走廊不互相卡死。

不要先改 speed/range/sight/effects。若验证发现它们也因尺寸迁移而不一致，分别用固定米制路线、固定目标半径、固定视野目标和效果 AABB 测试，逐项记录旧值/新值/依据，禁止全局乘系数。

### 6. 每实体循环与完整回归

先跑形状链路夹具，再逐实体跑实际 Match。夹具必须包含：

- 圆柱、球、胶囊、长方体、实际采用的凸体和组合形状；每个读取器得到非空、正确的世界几何。
- 偏心/嵌套变换、yaw `0/45/90/135°`、禁用形状、子 Area 检测圈，以及未支持形状的显式失败。
- 两个 AABB 重叠但实际轮廓不重叠的实体，应允许通行/落位；真正轮廓重叠则拒绝。
- L/U 形组合的可通行凹口不得被整体 AABB/凸包堵死；不能为通过测试移除有效主体形状。
- 狭窄通道中的侧向通过、转向及每步/swept 接触测试，验证高速或低帧率也不穿薄障碍。
- 普通导航图与逻辑地图两条路径，建筑完成/出售/销毁后的 blocker 更新；真实出生、采矿卸矿、建造预览与权威结果一致。
- 记录相同实体数、地图、运行环境下的修改前后帧时间和停滞统计。避免所有实体使用高面数网格/每帧全场扫描；不能为性能丢掉正确性，也不能只看 FPS 就宣称通过。

对每个实体执行：基线截图/数据 → 一次最小改动 → 解析/构建 → 运行时数据 → 实际打开前后截图 → 四方向贴边/横向/穿越 → 相关回归。不能“批量改所有 tscn 后抽查一个”。完成后由独立探针或独立复核重新测量至少一个单位、一个建筑、一个资源点。

最终必须生成：

- `agent/runs/<run-id>/per-unit-collider-matrix.json`；
- `agent/runs/<run-id>/shape-support-matrix.json`，逐消费模块列出已测试形状、拒绝的形状和回退策略；
- `agent/reports/closed-loop/2026-10-01-per-unit-collider-clearance-report.md`。

报告按实体列出改动文件、旧/新测量值、截图路径、命令 rc、第一限制层、未验证项和回滚方式。任何实体未测、截图未打开、路径原因不明、只完成 headless 或出现回归，整体状态必须是 `needs-review`/`blocked`，不能写“完成”。

## 官方依据

- [Godot 碰撞形状与凸分解](https://docs.godotengine.org/en/stable/tutorials/physics/collision_shapes_3d.html)
- [Area3D 的检测用途及凹网格警告](https://docs.godotengine.org/en/stable/classes/class_area3d.html)
- [ConcavePolygonShape3D 的空心与静态用途限制](https://docs.godotengine.org/en/stable/classes/class_concavepolygonshape3d.html)

参考文档后仍需以当前工程的 Godot 版本、代码和运行时结果为准。最终目标是修好游戏，不是最大化形状种类或让调试图看起来精确。
