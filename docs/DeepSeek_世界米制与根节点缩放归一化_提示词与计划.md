# DeepSeek Harness 提示词：世界米制与根节点缩放归一化

你正在维护 G:\AIRTS\AI_RTS。最终目标是修复 2026-09-27 尺寸统一改动造成的整条回归链：视觉比例、物理碰撞、逻辑占地、相邻建造、导航避让、单位出生点和实际移动都必须恢复可玩。

## 核心架构

运行时采用单一世界米制：

    UnitRoot scale = 1
    ├─ Visual：唯一允许存在美术资产缩放
    ├─ CollisionShape3D：直接使用世界米
    ├─ Movement / MovementObstacle：直接使用世界米
    ├─ NavigationObstacle3D：直接使用世界米
    ├─ Selection / Highlight：直接使用世界米
    └─ SpawnPoint / RallyPoint：位置直接使用世界米

玩法代码不能从 Visual 的缩放系数推导半径。根节点、碰撞、导航和逻辑节点不能继续使用“根节点乘 3、子节点乘 1/3”的补偿结构。

第一阶段只整理坐标体系，保持当前实际世界尺寸和玩法行为不变。第二阶段才根据截图和 RTS 观感重新调整大小。不要把迁移和重新平衡混在一次修改中。

## 工具决策

- godot-bridge：项目检查、headless、调试输出、脚本检查和截图。
- dsh-godot-skill：Godot 4 的节点、Transform、物理、导航和 C# 规则。
- dsh-godot-play：可见单机开局、建筑按钮、蓝图、生产、移动和截图。
- airts-auto-loop-testing、DCS、tools/dev/match_instance.py：自动开局、实例登记、状态读取、动态端口和安全清理。
- dsh-godot-dev-shell：先检查是否启用；停用时切换到 bridge、Godot Mono console 或仓库脚本。
- dsh-godot-ai 和 godot-asset-planner 未安装，不得调用或伪造。

插件是执行通道，不是任务边界。无头测试不能代替可见单机测试；PNG 文件存在不能代替打开图片检查。

## 尺寸契约

为每个单位打印四个世界米值：

1. visual_world_aabb：Visual 分支实体模型的世界包围盒。
2. collision_world_aabb：CollisionShape3D 完整 global_transform 后的包围盒。
3. logical_world_radius：Movement 或 MovementObstacle 的逻辑世界半径。
4. navigation_world_bounds：NavigationObstacle3D 实际送入 Godot 烘焙的边界。

这四个值可以不同，但差异必须有明确用途。玩法代码只能使用逻辑世界尺寸。

当前建筑逻辑半径先作为迁移基线核对：

| 建筑 | 当前世界半径 |
|---|---:|
| CommandCenter | 7.00 m |
| VehicleFactory | 6.65 m |
| Barracks | 6.25 m |
| AircraftFactory | 8.00 m |
| OreRefinery | 9.80 m |

当前移动单位逻辑半径先作为迁移基线核对：

| 单位 | 当前世界半径 |
|---|---:|
| Tank | 2.00 m |
| HeavyTank | 2.25 m |
| APC | 2.70 m |
| TransportTruck | 2.80 m |
| Worker | 2.00 m |
| Drone / Scout | 2.00 m |
| Infantry / Sniper / Rocketeer | 1.35 m |

这些是迁移基线，不是最终美术设计结论。必须通过完整 global_transform、物理查询和截图复核。

## 必须检查的代码

检查并按新契约迁移：

- source/match/Match.gd
- source/match/units/Unit.gd
- source/match/units/traits/MovementObstacle.gd
- source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs
- source/match/utils/UnitPlacementUtils.gd
- source/match/units/traits/ProductionQueue.gd
- source/match/units/OreRefinery.gd
- 所有建筑、车辆、步兵和资源场景

重点检查 Match.gd 是否把场景 root scale 偷偷合入 spawn transform；迁移后实例化只传世界位置和旋转，Visual 自己保留资产缩放，玩法节点父链保持 scale=1。

## 建造、碰撞和出生规则

普通建筑相邻条件使用世界半径：

    distance(candidate, own_structure)
      <= candidate_world_radius + existing_world_radius + 0.75

建筑与建筑、建筑与资源重叠时硬拒绝。只有带 Movement 的己方机动单位允许驱逐。不能把 UI 的 Something already occupies that spot 当作根因，必须记录 primary issue、候选中心、半径、对象名称和实际距离。

生产出生点必须在生产建筑世界边界之外，并重新验证重叠、地图边界、地形和导航。没有合法位置时保持待部署或重试，禁止生成在建筑中心或未经验证的建筑前方。

NavigationObstacle 的实际 carve 公式必须用单障碍实验测量 Godot 4.7.1 的真实输入后确定。不要只看注释，也不要让 C#、GDScript 和审计脚本各自使用不同公式。

## 执行计划

### 阶段 0：基线

保存工作树和程序集信息。用可见单机流程复现：开局、指挥中心旁建车厂和机场、生产三辆矿车或车辆、选中并移动。保存状态、坐标、日志和截图，并实际打开截图。

### 阶段 1：尺寸审计

写可重复探针，打印每个单位的四类尺寸、root scale、完整 Transform、导航输入和 agent radius。排除血条、选择圈和特效，只测实体模型。

### 阶段 2：根节点归一化

逐场景将 UnitRoot、CollisionShape、MovementObstacle、NavigationObstacle 和玩法子节点的父链 scale 归一到 1，把原有美术缩放集中到 Visual。每迁移一个场景，确认迁移前后的世界碰撞和逻辑半径在容差内。

### 阶段 3：运行时实例化

移除 Match.gd 中合入场景 root scale 的逻辑。检查地面吸附、空中单位高度、RallyPoint、SpawnPoint 和网络同步，确保 Transform 不再重复缩放或丢失缩放。

### 阶段 4：建造、导航和出生点

在新坐标体系上验证相邻建造、脚印重叠、建筑硬阻挡、机动单位驱逐、导航 carve、生产连续三辆、建筑旋转、地图边缘和被围堵出生。

### 阶段 5：闭环

每轮执行：C# 编译、新进程、headless 测试、可见单机操作、状态读取、截图并实际查看、修复前后对比。失败必须分类为源码、测试夹具、旧程序集、导航异步、相机、插件或进程管理问题，不得笼统标成环境噪声。

## 完成标准

- 所有 UnitRoot、CollisionShape、MovementObstacle 和 NavigationObstacle 的父链 scale 为 1。
- Visual 是唯一允许存在资产缩放的地方。
- 逻辑半径全部是世界米，代码没有重复 scale 补偿。
- 第一阶段迁移前后世界碰撞、占地和出生行为保持一致。
- 建筑相邻可建，脚印重叠拒绝，建筑不可被驱逐。
- 单位不在建筑内部、地图外或不可通行地面出生，被围堵时等待部署或重试。
- 单位能实际到达目标，不抖动、不穿模、不被错误 carve 隔离。
- headless 和可见单机均通过，新进程重复验证成功。
- 报告列出每个场景的迁移前后尺寸、修改文件、插件和回退工具、截图路径、测试结果和所有未验证项目。
