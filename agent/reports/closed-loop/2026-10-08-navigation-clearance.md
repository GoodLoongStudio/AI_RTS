# 2026-10-08 闭环报告：建筑导航净空统一（矿车卡基地/矿场）

计划与偏差：`docs/plan/navigation-clearance-plan.md`。运行产物：`agent/runs/nav-clearance/`。未提交 git。

## 参数

| 项 | 取值 |
|---|---|
| A carve 外扩 | `STRUCTURE_CARVE_MARGIN_M = 0.6`；矿场/兵营/车厂/机场 `carve_from_collision_bounds = true` |
| A 洞边离表面（实测最小） | 方盒 1.35 / 主基地 1.25 / 炮塔 1.30（改前 0~0.8） |
| B | `STRUCTURE_AVOIDANCE_ENABLED = false` |
| C | 脱困 0.6s、冷却 1.5s、半径 → 0.9、接触余量 0.35；放弃上限 3 轮只做诊断 |
| D | `StructureSealGapMeters = 2.4`、`StructurePassGapMeters = 5.6`，issue `BlocksPassage` |
| Worker `path_max_distance` | 保持 0.31（0.8 对比无收益） |

## 复现探针 `_RefineryJamProbe`（90s，6 矿车）

| 配置 | gap2 交付 | gap2 建筑旁卡住 | gap4 交付 | gap4 建筑旁卡住 | 最小表面间隙 |
|---|---|---|---|---|---|
| 改前（基线） | 11 | 13 | 12 | 12 | -0.24 |
| 最终（×4） | 20/20/21/21 | 9/12/10/14 | 19/21/20/19 | 11/13/14/16 | -0.18（仅脱困模式） |

## 回归

最终 20 项定向：15 通过；失败 ore-refinery、worker-gather、spawn-point-regression、rule-ai-economy-query、vehicle-factory-worker-production，断言集合与基线一致（基线 14/20）。重烘：主线程约 0.1ms，异步约 133ms，改前改后无变化。

## 第二轮（2026-10-09）

开发根 `G:/AIRTS/AI_RTS`。未提交。路径检查 rc=0。Godot：`G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`，`--path G:/AIRTS/AI_RTS`。

### 五项旧失败

| 测试 | 判定 | 处理 |
|---|---|---|
| ore-refinery | 夹具选点过时（远矿被对齐拉近） | 上一轮已改测试选点，断言未放宽。终局 rc=0 |
| worker-gather | 测试过时（货币/批量/交货点）+ 真实缺陷 D-R2-1（矿点 RVO） | 测试已改。游戏侧矿点 RVO 未改，留给产品拍板 |
| spawn-point-regression | 夹具产品过时：车厂不能产矿车 | C1/C5 改为坦克，几何断言不变。终局 rc=0 |
| rule-ai-economy-query | 间歇：10s 内工人仍在施工 | 断言未改。终局仍失败 |
| vehicle-factory-worker-production | 真实口径分裂 | 不改 catalog。终局仍 3 失败 |

Core：`Production service tests` 6 项中 3 失败，都在 `BlockedDeploymentStopsQueueUntilSuccessful`（解除阻挡后未完成部署 / 下一项未进入 Producing / 完成事件重复口径）。夹具不读 demo balance。`Balance config tests` 17 项中 24 条检查失败，是 `demo.balance.v1.json` 与测试里的替换锚点、坦克数值、技能下标不一致。这两处按用户要求不改配置。

### 改动

- `UnitMovementUtils.structure_approach_point` / `approach_slot` / `rotate_approach_slot`：交货落点在靠近侧按车道错开，只在选点时计算。
- `Movement._sample_path_progress`、`_give_up_commitment`、`_classify_navigation_end`：无路径消耗连续 3 轮或 45s 判 Unreachable；贴到网格外目标 0.6m 内算到达。
- `MovingToUnit._on_movement_ended`、`CollectingResourcesSequentially._retarget_stuck_resource` / `_retarget_stuck_dropoff`：矿车到上限后换矿或换交货落点。
- `GodotStructurePlacementWorldPort.LeavesBlockingGap`、`RegisterCandidateFootprint`；`StructurePlacementRuntime` 三处注册。候选碰撞足迹按 yaw 旋转。
- `SpawnPointRegression._test_spawn_points`、`_StructureGapRuleProbe._check_aircraft_short_side`。

### 探针（3 车 × 90s，与第一轮夹具相同）

第一轮记录写「6 车」，探针常量与当次日志是 3 车（`WORKER_COUNT=3`，文件时间早于 `jam-final-*.json`）。本轮用 3 车才能和那些交货次数对比。

| | gap2 交货 | gap2 建筑旁卡住 | gap2 穿模帧 / 最深 | gap4 交货 | gap4 建筑旁卡住 | gap4 穿模帧 / 最深 |
|---|---|---|---|---|---|
| 第一轮终局 | 20/20/21/21 | 9/12/10/14 | 33+31+1+0，-0.18 | 19/21/20/19 | 11/13/14/16 | 23+0+0+13，-0.18 |
| 第二轮 | 21/23/22/20 | 11/14/17/10 | 31+0+0+0，-0.175 | 21/22/21/21 | 18/14/13/15 | 24+0+4+0，-0.18 |

交货均值 gap2 20.5→21.5，gap4 19.75→21.25。建筑旁卡住没有下降。穿模总帧数下降，最深仍约 -0.18m（脱困模式）。重烘：主线程约 0.11ms，异步约 134–146ms。

飞机厂短边：半径方形间隙 3.59m 会落在禁区；按旋转足迹后可通行距离 `issues=[]`，禁区中点仍是 `BlocksPassage`。yaw 0 与 90° 都如此。AI 兵营/车厂/机场/矿场自动选址 4/4。

四方向贴边与第一轮同一行：Worker 表面间隙 0.24m（贴体），Tank 1.74m（carve）。`Movement push equivalence: 5959 checks, 0 failure(s)`。

### 测试 rc

- `dotnet build OpenRTS.sln --no-restore` rc=0
- 放置 core：`Structure placement tests completed: 8 test(s), 0 failure(s)`
- 间隙探针 rc=0
- movement-recovery rc=0
- 终局 20 项：17 通过，rc=1。失败 rule-ai-expansion（ConstructionInProgress，不是 BlocksPassage）、rule-ai-economy-query、vehicle-factory-worker-production
- narrow-passage 标记通过，日志仍有既有 SCRIPT ERROR

### 剩余风险

- 对向互挤没有被车道错开消掉，建筑旁卡住次数仍在第一轮波动范围内。
- 硬上限 45s 只在路径完全不消耗时累计；友军把人慢慢挤向目标时仍可能很晚才停。
- D-R2-1 矿点 RVO 与过近矿缝仍在。
- 矿车生产者 catalog 仍是主基地，HUD/车厂测试仍是车厂。
- 平衡 JSON 与 core 平衡测试、生产部署 3 项失败未动。

## 第三轮（2026-10-09）

开发根 `G:/AIRTS/AI_RTS`。未提交。Godot 仍是 `G:\AIRTS\godot_mono_471\...\Godot_v4.7.1-stable_mono_win64_console.exe`，`--path G:/AIRTS/AI_RTS`。

### 诊断

45 秒缝 2m：卡住分类 head_on=0、drop_overlap=7、route_cross=2、alone=1。建筑旁的车停在主基地南侧，提交目标彼此仍小于 2.2m。所以做交货排队，不做每帧让行扫描。

### 排队规则

`CollectingResourcesSequentially` 按「所属玩家 + 矿场」维护返程队列。只有队首走向交货落点；其余在当前位置远离矿场 4m、再按序号横向错开 3m 停下，等前车离开返程再放行。登记只发生在状态切换。本工程没有盟友名册，其他玩家不进队列，也不缩小半径。

### 探针（3 车 × 90 秒）

| | gap2 交货 | gap2 建筑旁卡住 | gap2 穿模帧 / 最深 | gap4 交货 | gap4 建筑旁卡住 | gap4 穿模帧 / 最深 |
|---|---|---|---|---|---|---|
| 第二轮 | 21/23/22/20 | 11/14/17/10 | 31+0+0+0，-0.175 | 21/22/21/21 | 18/14/13/15 | 24+0+4+0，-0.18 |
| 第三轮 | 17/17/18/20 | 0/3/2/2 | 0，+0.28 | 18/18/18/20 | 3/2/2/3 | 0，+0.28 |

建筑旁卡住均值 gap2 13.0→1.75，gap4 15.0→2.5。穿模帧归零。交货均值 gap2 21.5→18.0，gap4 21.25→18.5。卡住已经明显下降，没有再叠第二套机制。重烘：主线程约 0.11ms，异步约 125–142ms。

四方向贴边与第二轮同一行：Worker 表面间隙 0.24m，Tank 1.74m。间隙探针 rc=0，飞机厂短边结论不变。`Movement push equivalence: 5959 checks, 0 failure(s)`。

### 矿车生产者

- `config/balance/demo.balance.v1.json`：`worker.allowedProducerUnitTypeIds` 从 `command_center` 改为 `vehicle_factory`。`requiredWork` 180、成本 200 未改。出生点与集结点走车厂队列里和其他产品相同的 `production_spawn_spot` / Rally。
- HUD 本来就把矿车按钮放在车厂，没有再改。
- `EconomyController`：没有完工车厂时不发矿车生产请求；矿场点火完成前不建车厂，避免抢施工位。车厂完工后才入队矿车。
- 测试断言：`CommandCenterWorkerProductionSmokeTest` 改为期望主基地拒绝；`RallyPointSmokeTest` 改为从车厂出矿车并继承车厂姿态；`NetInfantrySmokeTest` 改为向预置车厂要矿车（本轮未启动专用服，没跑这条）；`SpawnPointRegression` 的 C1/C5 仍是坦克，只改了过时注释。
- `adjutant-e2e.balance.v1.json` 未改。对局读的是 demo catalog。

### 测试 rc

- `dotnet build OpenRTS.sln --no-restore` rc=0
- 放置 core：8 test(s), 0 failure(s)。生产部署仍 3 失败，平衡配置仍 24 失败，都不是这条生产者改动新带出来的
- movement-recovery rc=0
- 定向 20 项：19 通过。失败只有 rule-ai-economy-query rc=1（工人在窗口结束时仍是 Constructing，采集断言未放宽）。vehicle-factory-worker-production rc=0。rule-ai-expansion 这次 rc=0
- rally-point rc=0；主基地拒绝入队的冒烟 rc=0
- 间隙探针 rc=0；四方向探针 rc=0
- narrow-passage 标记通过，日志仍有既有 SCRIPT ERROR

### 剩余风险

- 排队把返程串成一辆一辆，90 秒交货大约少 3 次。剩下的建筑旁卡住多半是单独停住，不是对向死锁。
- 去程的空车仍可能和正在进缝的那一辆交会。
- 硬上限、矿点 RVO（D-R2-1）未动。
- 副官 e2e 那份 balance 仍写主基地产矿车。
- 经济查询仍会间歇失败；断言没放宽。

## 服务半径退出（2026-10-09）

开发根 `G:/AIRTS/AI_RTS`。未提交。Godot 仍是 `G:\AIRTS\godot_mono_471\...\Godot_v4.7.1-stable_mono_win64_console.exe`，`--path G:/AIRTS/AI_RTS`。

### 原来卡在哪

`BalanceConfigRuntime.ConfigureUnit` 把 `serviceRadiusMeters` 写进 `OreRefinery.service_radius_m`。`OreRefinery._nearest_ore` 用它决定有没有可接管的矿；没有就不指派。`CollectingResourcesSequentially.find_drop_off` 只认 `ore_refinery_assignment`。布局 36 的矿在矿场外约 31–34 米，半径 30 时矿场不接管，满载矿车找不到交货点，采满后停住。46 米只是临时绕过。

另外 `OreRefinery._gathering_inside_service_radius` 会按同一半径释放正在采集的工人。`serviced_ore_count` 也按半径计数。建造预览和 AI 选址不读这个字段，界面也不画圈。`AutoGatheringResources` 另有一个以矿车为圆心的 30 米搜索，不是矿场服务半径。

### 现在的规则

- 无命令、侵略姿态的矿车：在全图里找该玩家当前看得见、还有存量的矿。视野用 `FogOfWar.player_can_see`，公式与单位可见性相同（`sight_range_against` 加已有的 2 米补偿），只数这个玩家自己的活着的已完工单位。迷雾运行时关掉时全图算看得见。不新做射线。曾经探明但现在看不见的矿不自动去采。选目标时过滤；已经在路上的不因为离开基地视野而取消。
- 满载：水平距离最近的己方已完工、`is_drop_off` 的矿场。主基地不是交货点。没有可用矿场就持货。不要求事先指派。
- 停止会留下 `player_hold_auto`。矿场在这期间不接管、也不把自动采集挂回去。新的移动、攻击、采集、施工命令会清掉这个标记。
- 同一玩家、同一矿场同时只一辆走向交货落点。卡住后改去另一座矿场时，用 `_keep_drop` 避免刚选中又被「最近」覆盖。

### 字段

`serviceRadiusMeters` 从 `demo.balance.v1.json` 和 `adjutant-e2e.balance.v1.json` 删除，并从 `OreRefineryDefinition`、DTO、加载校验、`BalanceConfigRuntime` 的写入里删除。再把 30 写回 JSON 会在未知字段校验里让平衡表加载失败，不会悄悄恢复门槛。`OreRefinery.service_radius_m` 导出保留，逻辑不读。

### 复测

布局 36，种子 1846106761，有 AI，和平。矿场自动落在 ResourceA4 外 30.9 米（原 30 米圈外）。无人机受移动令飞到矿旁 4.6 米，矿进入现有视野。其后观察墙钟 71.3 秒。

- 人类 `[GATHER] 交付` 12 次，每次 resource_a=400
- 同时朝同一矿场落点接近的满载车最多 1
- 远处等待样本 6。满载车随后都交掉了，没有再因半径停住
- 贴建筑指标有 1 段（Unit_15，从观察 47.8 秒起约 20 秒），发生在它已经贴着交货点、采样间隔被状态查询拉长的时候；68 秒时又有一次交货
- SCRIPT ERROR 0，`[MOV][放弃上限]` 0
- 主基地生产矿车 `ProductNotAllowed`，车厂两单 `Accepted`
- 只结束本轮拉起的进程。结束后 Godot 进程列表为空

### 测试 rc

先跑时平衡表仍由 10 月 8 日的旧 DLL 要求 `serviceRadiusMeters`，ore-refinery rc=1。`dotnet build OpenRTS.csproj -c Debug` 之后：

- ore-refinery：标记通过，Godot rc=0。日志有既有的 ObjectDB / RID 泄漏，套件退出码仍是 0
- worker-gather：同样 rc=0，同样泄漏噪声
- `WorkerDeliveryRefineryOnlyTest` 不在套件里，单独 headless：无矿场时持货、不回主基地；半径设为 1 米后 5 秒内交货 1 次，账户 1200→1700。`RESULT PASS`，进程 rc=0

矿场冒烟第 1 节从「半径内无矿不得接管」改成「半径设为 1 米仍接管视野内的矿」。容量、显式移动让出名额、真实消耗和入账没有放宽。

### 剩余风险

- 开局基地视野约 20 米，31 米外的矿要等己方单位看到才会自动去采。这是当前视野规则，不是半径停住。
- 停止之后要下新命令才会恢复自动采集。
- 明确的采集令仍算采集类，矿场不因此释放名额，避免和规则层采集令乒乓。移动、攻击、停止会让出名额。
- 贴建筑指标会把「正在交货点卸货、采样变慢」记成卡住。
- 副官 e2e 的矿车生产者仍是主基地。这份变更只删了它的服务半径字段。

## 无人机开局视野（2026-10-09）

上一节复测里，31 米外的矿要等无人机飞到 4.6 米才进视野。这次只提高无人机自己的 `sightRangeMeters`：20 → 36。主基地、矿场保持 20，侦察机保持 24。仍只采当前看得见的矿。交货排队和车厂产矿车未改。

有效圆心距 = 视野 + 无人机半径 1.2 + 矿点半径 1.2 + 已有补偿 2.0。改前 24.4 米，改后 40.4 米。

出生偏移是世界坐标 `(-2, 0, -2)`。五张已生成地图上，开局无人机到最近矿：

| 地图 | 出生点 0–3（米） | 最远 |
|---|---|---|
| 36 / 1846106761 | 31.63、36.25、30.38、29.25 | 36.25 |
| 39 / 655312406 | 31.45、31.37、29.71、36.45 | 36.45 |
| 47 / 903520021 | 30.12、31.07、32.72、32.49 | 32.72 |
| 8 / 561215132 | 29.68、26.44、30.71、37.08 | 37.08 |
| 8 / 608324557 | 29.89、35.08、29.54、35.25 | 35.25 |

改前 24.4 米盖不住其中任何一颗。改后最远 37.08 米仍在 40.4 米内，余量约 3.3 米。

### 布局 36 实局

专用服 + 屏幕外客户端，有 AI，和平。没有给无人机移动令。

- 玩家 Player_1，无人机 Unit_3，视野 36，半径 1.2
- 采样位置 (222.95, 222.56)，2 秒后仍在原处，位移 0
- 最近矿 ResourceA4，36.25 米，按 `player_can_see` 口径已看见
- 主基地到同一矿 33.5 米，主基地视野盖不住
- 观察墙钟 71.2 秒（状态查询把约 60 秒的采样拉长）。窗口内人类 `[GATHER] 交付` 13 次；整局日志 15 次，多出的 2 次在观察开始前
- 同时朝同一矿场落点接近的满载车最多 1
- 服务端与客户端日志无 SCRIPT ERROR
- 只结束本轮拉起的进程。结束后 Godot 进程列表为空

### 测试

`fog-of-war-sight-range`：Godot rc=0，标记 `completed: 0 failure(s)`。该测试只检查 `sight_range == null` 的兜底，不断言无人机视野等于 20，所以没有改断言。

### 剩余风险

- 只量了 `source/match/maps/generated` 里现有的 5 张图。新种子若把最近矿放到 40.4 米以外，开局仍看不见，要再加视野或改布矿。
- 第二近的矿不保证在圈内。不是全图揭露。
- 无人机被击落或飞离后，若没有别的单位覆盖，该矿会重新不可见，自动采集只认当前看得见的矿。
- 副官 e2e 目录里的无人机视野已一并改成 36，避免那份目录把对局无人机留在 20。

## 确认局（2026-10-09）

未改代码。专用服 + 屏幕外客户端，Mono `G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`，两条进程都带 `--path G:\AIRTS\AI_RTS`。布局 36，种子 1846106761，有 AI，和平。没有给无人机移动令。开局没有矿场，调试建造走玩家同一条 Place（矿场 `auto=resource`，车厂 `auto=base`）。矿车来自矿场赠送 Unit_8 和车厂两单，没有从主基地刷出。观察墙钟 91.0 秒，35 次采样，中位间隔 2.02 秒。只结束本轮进程，结束后 Godot 列表为空。

| 项 | 结果 | 证据 |
|---|---|---|
| 1 开局看见最近矿 | 通过 | Unit_3 视野 36，半径 1.2，位置 (222.95, 222.56)，2 秒位移 0。最近矿 ResourceA4 36.25 米，有效距离 40.4 米 |
| 2 可视矿自动采并交最近矿场 | 通过 | 矿场 Unit_5 距 ResourceA4 30.93 米。指派 Unit_8/12/15 去 ore=(243.2, 256.1)。观察窗口人类 `[GATHER] 交付` 17 次，每次 resource_a=400。完工日志不再打印服务半径，全日志 `服务半径`/`service_radius` 0 行 |
| 3 同时朝落点最多 1 辆 | 通过 | `max_simultaneous_closing=1`。满载且距矿场 >10 米几乎不动的等待样本 9 |
| 4 贴建筑卡住 / 穿模 | 通过 | 满载、速度 <0.35、贴建筑超过 3 秒的次数 0。表面间隙最深 +0.35 米，重叠采样 0 |
| 5 车厂产矿车、主基地拒绝 | 通过 | 车厂两单 `Accepted`。主基地同一订单 `ProductNotAllowed`。工人 Unit_8（赠送）、Unit_12、Unit_15 |
| 6 脚本错误 / 放弃上限 | 通过 | 本局服务端与客户端日志 SCRIPT ERROR 0，`[MOV][放弃上限]` 0 |

约 49 秒到 71 秒有一次状态查询变慢，前后都没有打开卡住记录，期间仍有交货。剩余风险与上一节相同：只覆盖这张图的这一局；新种子若把最近矿放到 40.4 米外，开局仍看不见。
