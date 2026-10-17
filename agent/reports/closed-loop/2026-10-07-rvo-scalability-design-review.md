# 大规模移动性能：报告复核与质变优化路线

状态：**needs-review（方案已形成，产品优化尚未实施）**。
日期：2026-10-07。范围：只读源码/历史日志审计、网上原始资料查证、文档设计。没有启动新 Match、修改产品、生成新截图或实测新的 FPS。

**共享工作区版本警告：** 审计开始时 Movement 是报告中的 `B4E4F4A...`；收尾复查变成 `9690F7FC6EBD069D893AA9771CDE9B910219C61869C8BED2E9C35D9D8422DBC1`。与原快照比较，新版加入 `_pcache_*` 帧内句柄缓存，并移除了 R16 的距离前置剔除。本轮没有写 Movement，也没有撤销这个外部变更。下面的具体旧行号/成本解释以审计开始的 B4 快照为准；接手者必须重核当前代码，不能把 R16 验收数字套到 9690 版。

## 1. 我的判断

原报告抓住了有价值的入口：`velocity_computed` 的落地管道值得优先调查，现阶段不应靠降低画质解决 CPU 卡顿。但是，它把几项尚未证明的解释升级成了根因；直接照“取消全军两两静态推出”实施，可能优化错对象，或者重新引入空气墙、穿模和卡住。

最值得先做的组合是：**修正夹具和计时 → 静态几何数据化 → 保守 broad-phase 在精确 hull 采样之前 → 热点数学的 C# 批处理 → 用新 profile 决定是否做群体共享导航。**

这些是 `structural-candidate`，不是已验证收益。现有 Godot RVO 先保留，不先重写整个游戏、引擎或 ECS。

原始资料：[交接报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-07-rvo-push-bottleneck-handoff.md)。本轮读取的 `Movement.gd` SHA256 为 `B4E4F4A93495209356EEF88E2BCA1E6D97866AA8250B6909025FEDF9AB9FE187`，与该报告前缀一致。

## 2. 必须纠正的结论

### 2.1 静态障碍数不等于移动单位数

当前代码的注册入口在 [MovementObstacle.gd](G:/AIRTS/AI_RTS/source/match/units/traits/MovementObstacle.gd:209) 和该文件 276 行。常规单位场景中，建筑/资源带 MovementObstacle，坦克、APC、步兵等带 Movement。`Movement.gd` 本身没有向该障碍组注册；压力探针也没有把这些 mover 加入该组。域常量的地面组名实际是 `navigation_obstacles_terrain`，不是报告举例的 `navigation_obstacles_ground`。

因此，**当前源码不支持“303 mover 就有约 303 个静态障碍”**。还需运行时打印成员类别，核验动态添加和场景继承，但不能继续把 `303 × 303 × 8` 当作实测访问数。

推出显式全扫的结构是 `N movers × S 静态障碍`。若 S 固定，它不是按 N 的 N²；若建筑数也增长才可能表现为乘积增长。此外，`_nearby_unit_stats` 在 [Movement.gd](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:1916) 确实全扫 units，拥堵触发大量脱困时有二次扫描风险，值得单独计数，但本轮没有证明其成本占比。

报告的密集军团“人人都是邻居”也不能代替计数。300 个单位占 60m 区域，不代表每个单位都在另一个单位 3m 邻居范围内；静态障碍距离、RVO 感知距离和空间格大小又是不同语义。

### 2.2 1000 单位夹具的出生输入重复

[压力探针](G:/AIRTS/AI_RTS/tests/automated/_AiArmyStressProbe.gd:54) 用 `i % 20` 和 `(i / 20) % 20` 生成坐标，400 个输入位置以后重用。按相同整数分组公式进行本轮纯数据检查，rc=0：

| 项目 | 数值 |
|---|---:|
| 请求出生数 | 1000 |
| 不同输入坐标 | 400 |
| 重复使用既有坐标的额外请求 | 600 |
| 同一输入坐标最多请求数 | 3 |

这是出生输入的确定问题；实际单位可能经过对齐/分散，**本轮没有测其最终重叠量**。修正夹具后必须记录最终位置、初始穿透和合法出生结果，把异常堆叠恢复单列为 adversarial 场景，不能用它代表正常 1000 单位军团。

该探针的显式推进命令只发给 `human` 的 `mine` 集合（67–74 行）。AI 方能自行行动，但总 mover 数不能证明 1000 单位都在持续移动/交战，更不是副官端到端负载认证。

### 2.3 8.3ms 不能排除脚本

[聚合探针](G:/AIRTS/AI_RTS/tests/automated/_ScriptAggProfile.gd:53) 手动重复调用 `_process/_physics_process`，不包含由导航服务器稍后调用的 `_on_velocity_computed`。后者本身就是 GDScript，还包括转向、推出、位置写回和信号追踪。手动循环还会改变状态，缺少真实服务器阶段，不能算“全部脚本总成本”。

因此“8.3ms 脚本 + 39ms 引擎”没有被该实验证明。135.8µs 测的是整个回调的历史微基准，不是 `_push_out_of_static_obstacles` 的独立 exclusive 计时，也不能直接当作 300/1000 单位真实运行的逐次成本。

### 2.4 断开信号不是关闭 RVO，且剩余开销仍很大

历史 [rvo.log](G:/AIRTS/AI_RTS/agent/runs/rvo.log:5560) 的三个阶段确实记录：基线 frame p50=418.2ms，断开=176.9ms，恢复=422.0ms。这证明回调及其引发的后续工作是重要嫌疑，不证明只有静态推出最贵。

[探针](G:/AIRTS/AI_RTS/tests/automated/_RvoVerdictProbe.gd:67) 只是断开信号接收器，未改变 avoidance_enabled。Godot 当前官方源码中，服务器的避障注册与脚本信号连接是两层；RVO 算好速度后，NavigationAgent 才发信号。源码：[NavigationAgent3D](https://github.com/godotengine/godot/blob/master/scene/3d/navigation/navigation_agent_3d.cpp)、[NavMap3D](https://github.com/godotengine/godot/blob/master/modules/navigation_3d/nav_map_3d.cpp)。实施时还需对照本机 4.7.1 的对应 tag/commit，而不是把 master 当作本机的运行时证明。

断开后也停止了正常位置落地，改变后续拥挤、到达、重寻路和脱困，不是相同轨迹下的纯 RVO 求解 A/B；177ms 的剩余帧时间本身仍远超 33.3ms。应拆开 native 求解、脚本回调、物理/变换提交和其它阶段，不能把剩余成本忽略。

### 2.5 补步放大成立，但不能靠它算出固定收益

Godot 会限制每渲染帧最多物理步数；负载超预算可导致补步和模拟落后。**60Hz 物理、30FPS 显示正常平均就需要两步，不是一步。**每个渲染帧真实补了几步，应用相邻帧的 `Engine.get_physics_frames()` 差值测量，不是只读 max=8 后假定每帧都跑八次。[Engine 官方说明](https://docs.godotengine.org/en/stable/classes/class_engine.html)

Performance monitor 并非即时互斥时间片，官方说明有更新延迟；当前引擎源码还按采样窗口保存最大值。不能直接相加多个 monitor 的 p50，再把差额判成“12649 个节点的引擎工作”。[Performance](https://docs.godotengine.org/en/stable/classes/class_performance.html)、[主循环源码](https://github.com/godotengine/godot/blob/master/main/main.cpp)

因此“单次快 5 倍最多 13FPS”“53→300 推出算法就是 O(N^2.7)”都只是建立在未确认访问数/阶段上的估算。补步、密度、不同夹具和状态会造成非线性，不能由少量墙钟样本反推算法阶数。

### 2.6 不能永久排除渲染

原报告隐藏模型后帧时间几乎不变，是当前重 CPU 场景下渲染不是首要方向的证据。CPU 修好后，1448 draw、动画、透明特效和 GPU 可能成为下一瓶颈；需要重新 profile，不表示它们永远无关。历史日志还含 RID 泄漏错误，不能作为完整绿色验收。

## 3. 质变方案一：先查询接触候选，再碰几何

### 当前浪费

[推出循环](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:1138) 每次拿全组，只要有一个 radius 更大的障碍，就先采本单位近地 hull，再按每个方向做 support，直到 1224 行才拒绝远处障碍。R16 减少了后续精确查询，但**远处建筑仍可能触发每单位每 tick 的模型/骨骼采样**。

### 推荐改法，第一阶段保持严格行为等价

1. 建立 Match 内障碍注册表，保存稳定顺序、域、版本和纯几何描述。建筑/资源的实际形状、局部变换、世界 AABB、偏心、disabled 状态从现有权威来源获取。资源形状、父链变换、施工完成、换形状、死亡/queue_free、换局必须同步失效。
2. 将静态障碍几何解析放在生命周期/dirty 事件，不在每个 mover 的回调里重新 `find_children`、取 shape 和做 affine_inverse。不能重做已否证的“每帧节点引用缓存”；先以可观测 generation/dirty 和同帧差分证明正确。
3. **使用保守 AABB/空间格/树筛选，在精确 hull 采样之前判断是否可能接触。**移动单位的保守上界必须覆盖当前权威 hull/形状/临时半径；未知类型或无法证明上界时走旧算法。不要固定“附近 3m”，不要只按障碍中心入格；大建筑按覆盖 AABB 入多个格或使用 AABB tree。
4. 只有可能接触障碍，才计算当次真实 hull/support 和沿用原精确推出。保守 envelope 只用于筛选，**不充当碰撞体，不放大个人空间，不制造空气墙**。
5. 连续推出会改变落点。候选查询要覆盖每个中间位置，或在落点改变后重查；按原组顺序处理原算法尚未访问的障碍，不能任意排序、跳过新靠近者或重启整遍改变语义。密集/未知/超长链可以回退旧算法，并计数回退。

预期结构从“每单位总是采几何，再扫描全部 S”变为“维护 S 的数据 + 每单位 cheap query + K 个真实近处障碍的精算”。K 是真实候选数，不承诺所有密集建筑情况下仍线性；但**军团密集并不自动让静态建筑 K 等于军团 N**。

Box2D 的动态 AABB 树展示了成熟的保守 broad-phase：索引筛掉不相交 bounds，窄相位仍按真实形状处理。借鉴原理，不建议为这件事更换整个物理引擎。[官方碰撞资料](https://box2d.org/documentation/md_collision.html)

## 4. 质变方案二：纯数据热点，不从渲染骨架反推每次接触

第二阶段只在第一阶段 profile 证明值得时进行。现有项目已用 C#，可将热点数值计算迁入有界数组/结构体服务；GDScript trait 保留订单、状态机与适配职责。不是把同一个全扫循环搬个语言就结束。

推荐数据流：

```text
主线程：生命周期/dirty 更新几何描述
       → 保留真实物理 tick、转向/姿态和回调顺序的输入
       → Godot RVO safe_velocity
       → 保守候选 + 原精确推出的纯数据计算
       → 同一物理步主线程提交位置和订单/被动移动事件
```

首版 C# 求解可仍同步、单线程，验证语言边界与采集开销。然后只把独立纯数据分块并行：不在每单位上新建 Task，不用节点/骨骼/RID 的线程访问替代数据快照。批处理若改变原回调顺序或同帧节点读取时序，就不能自动称严格等价；先影子求解逐调用差分，必要时保留原提交顺序。[Godot 线程规则](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)

采样/序列化/桥接/同步/GC/主线程提交全部计入总成本。纯数据工作需 match-generation、unit-generation、geometry revision、tick 校验；同一权威 tick 有界同步，禁止异步积压后把上一帧结果当本帧碰撞。不可在退局后提交结果。

长期健康方向是**每单位经验证的简化地面接触代理**：车辆 chassis/履带、步兵本体/胶囊或小凸体、建筑 footprint，视觉动画照常。当前骨骼原点并不是完整蒙皮表面；应在资产验证阶段测动画包络，不能靠动画骨架顶点遍历长期维护玩法碰撞。

但用稳定代理替换当前姿态相关 support 可能改变玩法，必须单独作为产品重标定候选、征求批准并验证接触误差；在此之前保留精确旧路径。不能借“优化”把车型都改成巨大的圆，或擅自启用默认关闭的 FLOW_BIT_VEL_UNITS。

## 5. RVO、共享路径、交通管理各解决什么

| 层 | 建议 | 作用与边界 |
|---|---|---|
| 群体方向/路径 | 先合并重复请求和已有路径读取；高重复群体命令再做共享 corridor / 分块 Flow Field | 减少重复全局寻路；不能代替局部碰撞 |
| 移动单位避让 | 先保留 Godot RVO | 当前官方源码已有 KD-tree 和可选并行求解；不先另造 N² 分离力/新 RVO |
| 建筑硬边界/去穿透 | 保守索引 + 真实形状精算 | RVO 不读取物理碰撞体，仍需要正确的静态接触保障 |
| 拥堵与死锁 | 按编组分配合法终点槽位，窄口保持侧别/排队/局部恢复 | 解决所有人挤同一点/对向死锁；属于行为设计候选，不凭性能任务直接改玩法 |

官方说明避障与物理/navmesh 是不同空间，不能认为 RVO 有了就不需建筑阻挡；静态 vertices 与动态 radius 也有不同作用。[NavigationAgents](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationagents.html)、[NavigationObstacles](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationobstacles.html)

ORCA 原论文展示过千级 agent 的高效局部求解，所以规模本身不是必须 0.6FPS 的理由；那是算法基准，不是这个游戏的含动画/战斗/网格/副官综合预算。[ORCA 作者资料](https://gamma-web.iacs.umd.edu/ORCA/)

Supreme Commander 2 开发者的分块 Flow Field 方案共享目标/门户的方向场，并按脏区域更新。它适合大部队同目标，但仍需要局部 steering/接触。项目现有 `FLOW_BIT_*` 是让行、车道和量纲实验开关，**不等于已经实现目标共享 Flow Field**。[Elijah Emerson 原始文章](https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter23_Crowd_Pathfinding_and_Steering_Using_Flow_Field_Tiles.pdf)

Flow Field 缓存若实施，需按地图 revision、移动域、通行/净空类别和门户/目标区域分账，有界引用与淘汰。过桥、新建筑、不同大小车辆、不可达、单独侦察和空军保留合法独立导航。先证明 path query 是新热点，不能为未测热点重写导航。

不推荐直接换 DetourCrowd 作为 1000 单位保证；其官方页面自身给出较保守的 crowd 管理建议。成熟库也要按本负载基准验证，不靠名字承诺容量。[DetourCrowd 官方说明](https://recastnav.com/group__crowd.html)

## 6. 分阶段实施和停止条件

| 阶段 | 最小交付 | 晋级条件 |
|---|---|---|
| P0 测量纠偏 | 合法非重复出生的正常负载 + 单列重叠 adversarial；真实组成员计数、每渲染帧物理步数、逐阶段计时 | 有实际移动/开火/受令/完成计数，A/B 负载相同，不再靠标签证明模拟 |
| P1 候选查询/静态描述 | 原推出影子差分、生命周期失效与顺序等价 | movement-push-equivalence、导航/避障/恢复全绿；候选/骨骼采样显著下降，整帧收益可复现 |
| P2 数据化热点 | C# 纯数据原算法，先同步再按证据分块 | 总采集+求解+提交变快，事件/时序/净空/内存不退化 |
| P3 剩余热点 | 实测后选择重寻路去重、脱困邻居索引、物理接触/变换提交、共享导航等 | 每轮只动一个热点；不再把问题一律归因给 RVO |
| P4 产品行为候选 | 可选稳定接触代理、终点槽位/交通协调 | 明确批准行为口径，再用新合同与场景验收；不能偷改等价门禁 |
| P5 综合容量 | 100→200→400→700→1000 正常和恶劣场景、持续交战/生产/副官命令 | 保画质/玩法/频率，达目标 FPS 与真实模拟吞吐，并长时/换局验证 |

实现前先写一轮可证伪假设，超过两轮收益不明确换角度；连续三轮不晋级按 RSI 饱和处理。只撤销自己的补丁，保留当前 champion，不覆盖其它 agent。

粗预算是设计目标而非 measured：30FPS 的 33.3ms 中，60Hz 平均约两个完整物理步；若每步约 8–10ms，则两步占 16–20ms，余量留给渲染、UI、同步与尖峰。不能只把单 tick 降到 16.7ms 就宣布整帧 30FPS。

## 7. 验证口径

首先对固定轨迹的新旧实现做逐调用/逐 tick 差分，涵盖旋转盒、偏心 shape、多形状/disabled、同帧 queue_free/换 shape、连续推出、内部出生、静止被嵌入、窄口半径还原和敌我边界。任何缓存必须覆盖支持范围，否则显式回退，不静默漏障碍。

每个负载统计：实际活跃移动/交火实体，静态障碍数 S，候选 K 分布，接触 pairs、hull 次数/骨骼点数、shape 查找次数、回调 exclusive/inclusive、位置写回数、native RVO、路径/重烘、物理服务器、脱困全扫、日志/GC。不能用 monitor 相加重复归因。时间线和采样 profiler 必须对照本机引擎源码。

记录墙钟 frame p50/p95/p99、最长帧、物理 ticks/墙钟秒、simulation_time/墙钟比例、到达/产出/伤害/命令延迟。30FPS 但模拟变慢不算通过；大图既有 20Hz 分支另记，不混入小图 60Hz 曲线。窗口样本预热、A-B-A/至少三次、同画质/镜头/随机种子，不删除 >500ms 长帧。

回归命令沿用现有运行器（原报告的 `toolspython` 是拼写错误）：

```powershell
python tools/dev/small_army_performance.py --equivalence --out agent/runs/<run-id>/equivalence
python tools/run_parallel_suites.py --jobs 1 --serial "" --no-recheck --ids movement-push-equivalence,navigation-stability,movement-recovery,local-avoidance
```

Godot 路径、Python 环境与工具参数先读本机代码确认。`small_army --count` 夹具也有出生边界/负载问题，不能直接拿它认证 1000 单位。相关和全量回归还要求 rc=0、expected marker、forbidden 为空、无超时崩溃、当前产物和本轮进程清理成功。截图在采样窗口外生成并实际打开，必要时视频/轨迹判断动画和挤压。关键候选另找独立 verifier 实跑，不复读主线。

## 8. 本轮验证与交付

- 已读文件/hash、注册链路、3 个压力/画像探针、历史 rvo/agg 日志及官方资料；本轮没有游戏产品编辑。
- 纯数据坐标重复检查 rc=0，结果见 2.2；它不是 Godot 运行时碰撞/性能验证。
- 三份文档的非空、所有本地 Markdown 链接目标和尾随空白检查 rc=0；仅这三份新文档属于本轮修改。
- 初次搜索包含不存在的 `scenes` 目录，以及一次 PowerShell 字面通配符路径，命令 rc=1；后续用实际路径的 rg 核对，非游戏错误，不影响上述注册结论。个别网页获取失败未作为来源使用。
- 未跑：构建、Godot 场景、截图、相关/全量回归、优化后的性能 A/B、独立运行时复核。没有新的 FPS 或 champion 晋级；静态审计本身完成，产品保持 needs-review。
- 并行风险：当前工作区已有 872 条 git 状态记录；未覆盖原报告或任何产品文件。实施前再次核验目标文件 mtime/hash。

收尾 hash 一致性检查 rc=1，是发现共享源码已改变的预期保护，不是本轮产品测试失败。只读 `git diff --no-index agent/runs/Movement.patched.gd source/match/units/traits/Movement.gd` 返回 rc=1 表示有差异；对应快照为原 B4 版本。新增帧缓存只检查已有节点仍有效/未 queued-for-deletion，静态审查可见**同帧新增或重挂节点没有专门失效机制**，空列表也会被认作有效缓存；这是需要差分测试的新风险，不是已复现实测失败。当前新文件 mtime 甚至早于审计时文件，说明不能只靠 mtime 判断版本。三份文档独立静态校验仍 rc=0；不要自动恢复 R16 或删掉别人缓存。

实施交接：[DeepSeek 提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-rvo-scalability-deepseek.md)；[本轮计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-07-rvo-scalability-design.md)。
