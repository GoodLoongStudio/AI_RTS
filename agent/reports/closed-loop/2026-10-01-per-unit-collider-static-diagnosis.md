# 逐单位碰撞与空气墙：静态诊断记录

- 日期：2026-10-01
- 类型：代码审阅基线，不是运行时修复报告
- 状态：`needs-review`

## 已确认的代码事实

1. `source/match/units/Worker.tscn` 的 `CollisionShape3D` 使用半径 `0.92m` 的圆柱，而 `Movement.radius` 为 `2.0m`。这不是“模型一定错”，但足以产生约 1m 级的额外移动个人空间，必须通过贴边实测确认。
2. `source/match/units/CommandCenter.tscn` 的物理圆柱和 `MovementObstacle.radius` 都是 `3.48m`，authored `vertices` 约为 `1.4m` 外缘，且关闭了 `carve_from_collision_bounds`。但 `MovementObstacle._sync_carve_vertices()` 会在初始化时按 radius 重建 vertices，不能把 authored 值直接当作生效导航轮廓。需要测量初始化后的实际顶点和烘焙边界。
3. `MovementObstacle.gd` 的导航 carve 还会被导航 agent 半径外扩；`CollisionVolumeOverlay.gd` 同时画 AABB、Obstacle 圆/顶点和 agent 外扩近似，不能把其中的红色区域直接解释成物理碰撞盒。
4. `Movement.gd::_push_out_of_static_obstacles` 使用 `obstacle.radius + unit.radius + OBSTACLE_CLEARANCE_MARGIN_M`，因此单位可能在模型边缘之外再次被逻辑推出。
5. C# 的放置/导航判断另外读取结构半径、采样圆和 carve 区域。若这些层重复使用同一大圆，会同时影响相邻建造、资源服务和移动到建筑。
6. 形状读取器 `MovementObstacle._shape_local_aabb()`、`CollisionVolumeOverlay._shape_local_aabb()`、C# `ShapeBounds()` 仅有圆柱、球、长方体、胶囊分支，未识别形状返回空 AABB/null。凸体、凹体或组合支持不能仅以引擎支持为依据，必须验证各消费链路。
7. `GeneratedTerrain.gd::set_structure_blocker()` 当前保存中心和 radius；逻辑地图的硬占位不会因为换了物理 shape 自动变为同样轮廓。
8. 单位场景为 `Area3D`，`Movement._on_velocity_computed()` 直接更新世界位置；只改检测形状不能证明实际移动阻挡采用它。

## 本次文档更新

- 提示词和计划已升级为 `v2-shape-pipeline`：增加形状支持矩阵、凸体/组合形状读取、真实移动链路、未知形状失败、旋转及凹口通行测试、性能对照。
- 同步去掉工作法表格中的“移动单位全部圆柱”暗示。
- 本次仅更新文档，没有修改游戏代码或碰撞数值；运行时矩阵、截图和游戏回归仍待执行。

## 尚未由本记录证明的内容

- 图中具体空气墙的第一限制层；需要运行时逐帧/逐目标追踪。
- 每个实体的真实 skinned mesh 地面 hull；不能用未就位骨骼探针结果代替。
- 导航烘焙后的实际可行边界与 `agent_radius` 的精确影响。
- 任何 speed、attack range、sight 或特效需要变更的结论。

## 交付判断

静态代码足以说明“只调一个统一碰撞半径”不可靠，也足以支持逐单位独立场景和截图验收；但在完成运行时矩阵、四方向贴边测试、截图实际打开和回归之前，不能称为空气墙已修复。
