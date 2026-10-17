# 建筑尺寸统一、放置碰撞与单位出生点修复指南

> 2026-09-30 复查修正：本文是上一轮诊断快照，不是永久规格。请先读同目录 `自动闭环测试技能审查与纠正计划.md`。当前 MovementObstacle 已加入缩放补偿，不能直接沿用本文的 carve 公式；必须核对实际烘焙输入并测量边界。出生点沿朝向的回退也必须重新验证碰撞、地图边界和地形，否则应保留待部署状态。之前将同帧测试失败归因于“导航未就绪”的证据不足，需同时排查错误 carve 和地图实际缺口。

## 目的

修复 2026-09-27 尺寸统一改动后出现的三个核心问题：

1. 相邻建筑判定错误，合法位置被拒绝或不相邻位置被接受。
2. 建筑物理碰撞和逻辑占用范围不一致，建筑可能重叠或被错误阻挡。
3. 单位、矿车和生产单位可能生成在建筑内部或出生点错误的位置。

本文件是实施期间的持续约束。每次修改前后都必须参考本文件，不能通过临时放大半径、相邻范围或导航容差来掩盖问题。

## 已确认的根因

建筑根节点已经使用 `scale = Vector3(3, 3, 3)`，但部分修改把世界半径直接写进了 `CollisionShape3D`。这会让物理碰撞半径再次乘以 3。

同时，导航 carve 使用了 `MovementObstacle.radius + agent_radius`。`MovementObstacle.radius` 已经是世界脚印半径，再加一次会产生过大的不可建区域。

生产出生点搜索失败时曾经回退到 `global_position`，这会把单位直接生成在建筑中心。

部分回归测试没有等待导航图完成，新增测试还存在解析错误或不能退出的问题，不能把这些测试结果直接当作运行时结论。

## 相关文件

- `G:\AIRTS\AI_RTS\source\csharp\GodotAdapter\Construction\GodotStructurePlacementWorldPort.cs`
- `G:\AIRTS\AI_RTS\source\match\utils\UnitPlacementUtils.gd`
- `G:\AIRTS\AI_RTS\source\match\units\OreRefinery.gd`
- `G:\AIRTS\AI_RTS\source\match\units\CommandCenter.tscn`
- `G:\AIRTS\AI_RTS\source\match\units\VehicleFactory.tscn`
- `G:\AIRTS\AI_RTS\source\match\units\Barracks.tscn`
- `G:\AIRTS\AI_RTS\source\match\units\OreRefinery.tscn`
- `G:\AIRTS\AI_RTS\source\match\units\AircraftFactory.tscn`

## 尺寸统一规则

必须明确区分本地尺寸和世界尺寸。

### 建筑 CollisionShape3D

建筑根节点保持 `scale = Vector3(3, 3, 3)` 时，`CollisionShape3D` 使用本地半径：

| 建筑 | 本地 CollisionShape 半径 | 世界逻辑半径 |
|---|---:|---:|
| CommandCenter | 2.333 | 7.00 |
| VehicleFactory | 2.217 | 6.65 |
| Barracks | 2.083 | 6.25 |
| OreRefinery | 3.267 | 9.80 |
| AircraftFactory | 2.667 | 8.00 |

`MovementObstacle.radius` 保存世界逻辑半径。放置、Overlap、相邻和驱逐判定全部使用世界半径。禁止把世界半径直接写入已经缩放的 CollisionShape3D，也禁止在 C# 读取 `MovementObstacle.radius` 后再次乘根节点 scale。

### 导航障碍

`NavigationObstacle3D.vertices` 是本地坐标。计算 carve 半径时必须先转换到世界坐标：

```text
world_vertex = obstacle.global_transform * vertex
body_world_radius = max(distance_xz(world_vertex, obstacle.global_position))
carve_radius = body_world_radius + agent_radius + 0.05
```

如果没有 vertices，才允许使用已经明确是世界尺寸的 radius 作为回退值。不能使用 `MovementObstacle.radius + agent_radius`，否则会重复扩大 carve 区域。

## 建造判定规则

普通建筑必须与己方建筑相邻：

```text
center_distance <= candidate_world_radius + existing_world_radius + 0.75
```

指挥中心可以作为远程部署锚点。

建筑与建筑重叠必须始终返回 `Occupied`。资源也必须硬阻挡。只有带 `Movement` 的己方机动单位才允许进入驱逐规划。没有 `Movement` 的建筑不能被加入驱逐列表。

界面上的 `Something already occupies that spot` 可能对应 `Occupied` 或 `FriendlyDisplacementUnavailable`。调试期间必须记录真实的 `primary_issue`、候选中心、候选世界半径和被检测对象，不能只根据这句界面文字判断原因。

导航判定只负责真实地形是否有导航面。建筑或资源 carve 区域属于占用逻辑，不能把它们误报成 `SurfaceNotBuildable`。禁止用数米级导航容差解决问题。

## 单位出生点规则

`production_spawn_spot`、矿场免费矿车和 `ProductionQueue` 必须共用同一套出生点算法。

出生点必须位于生产建筑世界几何外缘之外，并满足：

```text
distance(producer_center, spawn_point)
    > producer_world_radius + produced_unit_world_radius + spacing
```

几何就绪时使用世界空间 AABB 外缘。搜索失败时不能回退到 `producer.global_position`。可以沿建筑朝向，在外缘加单位半径和间距作为确定性回退；如果仍然没有合法位置，则不生成单位，销毁临时实例并等待下一次重试。

## 实施顺序

1. 先检查 `git diff`，只修改尺寸、放置、导航 carve、生产出生点和对应测试，保留其他 AI 的无关改动。
2. 修正五类建筑的 CollisionShape3D 本地半径，保留 MovementObstacle 世界半径。
3. 修正 C# 中的世界半径读取、Overlap、相邻和驱逐逻辑。
4. 修正导航 carve 的 vertices 世界变换和 carve 区域判断。
5. 修正 `UnitPlacementUtils.production_spawn_spot` 和 OreRefinery 的失败回退。
6. 修复测试夹具：测试放置前等待 `NavigationServer3D.map_get_iteration_id(map_rid) > 0`，必要时调用 `map_force_update`，并确认 `map_get_closest_point_owner` 有效。
7. 删除临时诊断日志，或限制在明确的 debug 条件下。

## 验收标准

运行：

```powershell
dotnet build G:\AIRTS\AI_RTS\OpenRTS.sln --no-restore
```

然后运行：

```powershell
python G:\AIRTS\AI_RTS\tools\run_targeted_godot_tests.py `
  --godot "G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe" `
  --ids runtime-placement,structure-placement,refinery-free-miner,vehicle-factory-worker-production,production-queue,unit-radius-coverage
```

必须验证：

- 建筑刚好贴近己方建筑时可以建造。
- 建筑圆心或脚印重叠时返回 `Occupied`。
- 建筑覆盖己方坦克时可以安全驱逐。
- 建筑旁边有己方建筑时不能驱逐建筑。
- 矿车不会出生在矿场中心。
- 生产单位不会出生在生产建筑内部。
- 所有半径计算都明确区分 local radius 和 world radius。
- 不出现 Parse Error、脚本解析失败或测试场景无限运行。
- 启动新的游戏进程后再做一次手动建造和生产验证，确保加载的是最新 C# DLL。

## 当前已知测试限制

`SameFrameOverlapPlacementTest` 当前曾经因为导航地图未准备好而把候选点全部报成 `SurfaceNotBuildable`。修复测试等待逻辑前，不能把这个结果当作相邻判定失败。

`SizeUnificationRegression.gd` 曾出现类型推断和 `Vector2.z` 解析错误；`SpawnPointRegression.gd` 曾缺少结束路径导致进程一直运行。任何回归测试必须先保证能解析、能退出，再用于判断功能。

## 最终报告格式

完成后必须报告：

1. 修改了哪些文件。
2. 每个建筑的本地碰撞半径和世界逻辑半径。
3. 相邻、Overlap、导航 carve、驱逐和出生点分别采用什么公式。
4. 每条测试的返回码、marker 和失败日志。
5. 是否重启了新的游戏进程验证实际运行结果。
