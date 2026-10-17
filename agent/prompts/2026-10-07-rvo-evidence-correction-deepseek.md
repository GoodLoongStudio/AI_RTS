# 给 DeepSeek：先纠正性能证据，再实施规模化优化

你接手 AI_RTS 的1000单位 / 30 FPS目标。用户没有选择下调规模，也没有批准新的原生依赖。选择A的修正版：修测量器、健康基线、实际执行管道归因，然后按最大实测热点实现一个有效候选。不要继续要求用户在A/B/C中盲选，不要把旧错误数据当换库授权。

先读：

- `AGENTS.md`，`skills/airts-workspace-boundaries/SKILL.md`。
- `skills/闭环验证工作法.md`，`skills/AI_RSI自校验循环.md`，`agent/manifest.json`。
- `skills/airts-performance-optimization/SKILL.md` 及 `references/measurement.md`、`references/cpu-candidates.md`。
- [本次证据复核](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-07-rvo-isolation-evidence-review.md) 与 [计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-07-rvo-evidence-correction.md)。
- 前一轮 `2026-10-07-rvo-scalability-design-review.md` / `2026-10-07-rvo-scalability-deepseek.md` 的有效方案仍保留；本提示词纠正新实施报告的证据，不要求推翻所有旧设计。

## 一、先承认并纠正已查明的问题

以下不是用户猜测，已在源码/原始日志中核对：

1. `_RvoIsolationProbe` 关闭 avoidance 后，导航服务路径不再得到 `_on_velocity_computed` 的位置提交；保留寻路节点不等于保留运动管道。不允许把差值全部算作native RVO。
2. `_ScriptAggProfile` 用float调用需要Vector3的 `_on_velocity_computed`，用1个参数调用0参数的 `_nearby_unit_stats`。`agg2_300_err.log` 和 `agg2_1000_err.log` 真实报错；不能再说回调画像成功、脚本只占0.13%。
3. `rvoiso_1000.log` ON/OFF/ON分别17959/854/1787ms，恢复段没有回到基线；不能称干净可逆A/B。
4. 所有单位汇聚同一点，属于异常高密度压力；与正常编组负载分开报告。脚本聚合夹具还用旧20×20坐标，1000次输入最多400个独立坐标。
5. Godot有避障多线程项目设置，不能用“没有公开线程方法”证明不能并行。现有RVO已是原生实现，不是GDScript算法。
6. `set_active(false)` 不闸住所有直接路径查询，也不是一键停止全部sync；物理monitor计数0不等于全部物理成本0。
7. 测试日志有DCS端口24579与MCP9090冲突，有跨权威端探测。先做实例隔离，不忽略错误刷屏。当前autoload是否解析成功必须重新检查，不沿用旧健康结论。

将旧报告中的“95%确证”“脚本已否证”“线程无解”“540倍架构墙”“B升级条件成立”标为证据不足/待重测。保留旧日志与历史结论，更正报告必须指明纠正原因，不删除不利数据。

## 二、P0：一个健康、能证明运动负载的最小回放

开发只在 `G:/AIRTS/AI_RTS`。先核 `git status`、目标mtime、Movement hash、实际C#DLL、Godot版本和命令行。上次审计Movement是B4E4F4A9，但接手以当前实际文件为准；不要拿备份覆盖共享工作区。

利用项目现有Instance/MatchGroup和manifest端口约定，创建自己的实例、动态端口、run_id和独立产物目录。修正端口分配/实例选择，不杀用户Godot、不改全局插件配置来抢9090；如果插件不支持隔离，使用已有测试模式并记录限制。MCP/bridge/play插件只是操作渠道，不是验收标准。禁用的dev-shell不成为停止理由，用可用Shell/工具；不存在的API不编造。

健康条件：启动无Parse/SCRIPT ERROR，所需权威端可用且match_id一致，生成成功数及ownership正确，无其他性能进程/并行回归；相关端口失败、数据来自其他对局或单位冻结立即判该轮无效。每个自有实例必须有墙钟外部超时、finally清理与cleanup_ok验证；只靠Godot create_timer的模拟时间不能保证严重卡顿时及时退出。

先用100个混合单位验证工具，不立即反复跑18秒一帧的1000单位：

- 用真实出生链路，记录请求/成功/实际存活/在途数。坐标唯一还不够，核对运行时位置、碰撞hull/玩法圈初始重叠、地图边界、资源和建筑占位；调整测试地图/网格，不缩单位来摆下1000人。
- 正常压力使用多队、分散目标/稳定路线和固定命令节拍，保证采样时仍持续运动；另设1000同点汇聚为拥堵诊断，不能把两者混成一个基线。正常负载必须走真实命令入口；核心微基准才可直接设速度。
- 记录每阶段单位位移、实际在途数、到达/卡住/重叠、velocity回调次数、成功开火/命中/资源产出、总单位数、可见数。至少对固定代表单位保存位置时间序列。
- 改采样器输出原始帧间隔、sample_count、墙钟时长、物理帧差分、模拟时间推进、最长帧、hitch数。全保留长帧，不过滤>500ms。
- 预热另列。稳定FPS认证每阶段至少30秒且900个有效渲染帧，3次独立重启同配置比较；灾难性长帧达到墙钟预算就早停，标timeout/insufficient_samples，不强凑分位数或宣称p95可靠。这项样本门槛是本任务工具要求，不是已测产品能力。

修复 `_ScriptAggProfile` 时不要只改参数然后继续把手动调用称“实际帧耗时”。带副作用的方法不能随意重复call当只读测量。把这种工具降级为非等价微基准，主证据来自真实执行路径。

## 三、RVO隔离要拆成两种实验

### 1. 整个游戏管道的诊断开关

在测试专用、默认关闭的诊断模式内关闭RVO时，仍提交preferred movement，保留位置更新/静态推出/旋转/跟踪以及相同寻路查询合同。保证每物理步只提交一次，不同时接受RVO回调和诊断提交。

当前Movement存在step displacement和FLOW_BIT_VEL_UNITS的m/s两种合同。先核 `_flow_adjust_preferred`、`_flow_velocity_in_mps` 和 `_on_velocity_computed`；不要在OFF分支多乘/少乘delta。实验中冻结同一flow配置，不能顺便改速度、避让半径或时间视野。

该OFF仍没有动态避障，轨迹/拥挤会变，只能证明管道差异，不能认证产品优化或求解独占比例。按原始值恢复avoidance等状态，不无差别恢复true；异常路径也应恢复。用独立重启、固定初始状态和固定模拟时刻复测，记录A/B状态漂移；仅同进程ON/OFF/ON不等于同负载。

### 2. 原生求解核心的同输入测量

记录实际positions/preferred velocities/radii/layers/masks/obstacles/邻居参数及delta，通过独立小基准回放同一组输入。分别量map sync、KD-tree/邻居、求解、任务等待、callback dispatch与产品回调；没有工具拿到的字段标unavailable，不能填0。

核对运行时：

```text
navigation/avoidance/thread_model/avoidance_use_multiple_threads
navigation/avoidance/thread_model/avoidance_use_high_priority_threads
```

读取实际值，不只看project.godot有没有显式行。按该引擎版本核对地图初始化和WorkerThreadPool；设置已true不要重复“打开线程”报收益。NavMap构造时读取线程设置，需要在创建地图前设置或独立重启进行A/B。不得把SceneTree节点操作放工作线程。

本机日志版本对应官方源：

- [NavMap3D a13da4feb](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/modules/navigation_3d/nav_map_3d.cpp)
- [NavigationAgent3D a13da4feb](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/scene/3d/navigation/navigation_agent_3d.cpp)
- [GodotNavigationServer3D a13da4feb](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/modules/navigation_3d/3d/godot_navigation_server_3d.cpp)
- [官方线程项目设置](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-navigation-avoidance-thread-model-avoidance-use-multiple-threads)

实际运行版本变更时重新对齐源码，不能把master当本机版本的确定证据。

## 四、P1：只在真实执行路径做归因

可以增加测试开关控制的轻量插桩，不必反复请求用户同意正常诊断编辑。声明写入范围、精确补丁、解析/编译后运行；不开每单位每步打印来观察每单位每步成本。计数/累计缓冲在主线程聚合，有界输出。

至少涵盖：

- Movement physics：恢复、path getter/repair、preferred计算、地形高度。
- velocity回调：旋转、静态推出、最终位置写入、被触发的副作用。
- 静态推出：调用数、候选数、hull取得/变换/最近点成本、缓存命中/失效。
- 动态邻居/恢复：全单位扫描次数和扫描元素总数，触发原因。
- 路径：target赋值次数、同目标重复数、真正query次数、map同步/重建。
- AI/副官/命令与队伍任务、索敌、迷雾、小地图、生产/经济。
- UI/Timer/信号/C#入口、调试端口扫描、stdout/stderr行数、分配/GC。

输出inclusive和exclusive，不重复加嵌套函数；按本帧实际物理步/回调次数折算，跨帧延迟或阻塞等待单独标记。Performance监视器是辅助，不当互斥阶段相加。脚本函数timer未覆盖的时间要追到native栈/同步/线程等待，不凭“剩余都否证了”命名为底盘。

必要时使用实际可用的Godot profiler与Windows CPU采样/线程等待工具。先探测，不擅自安装依赖或无范围抓取其他进程。native时间区分CPU执行与墙钟等待；多线程CPU总和可能大于主线程墙钟，不混加。

优先核查已发现但尚未确证的入口：

1. Movement同目标分支仍写target_position；引擎setter仍请求repath，是否造成重复昂贵路径查询？计数后再修，保留地图更新/堵路修复。
2. `_nearby_unit_stats`全量扫描在密集停滞中是否爆发？索引维护成本与查询一起算。
3. `_push_out_of_static_obstacles`虽然只有2至3个静态候选，是否每mover每step重新量mesh/骨骼/hull？成员数小不能证明成本小。
4. 逐单位G4PERF、恢复打印及错误/调试日志是否造成同步I/O尖峰？量日志负载，不把任何await等同CPU阻塞。
5. 恢复/Timer/回调、跨实例通信是否未被旧manual聚合覆盖？检查火焰图，不认31.2ms为全部脚本。

P0通过后先交付一个真实小规模热点表和首个候选决策，不继续凭错误排除法堆十几个新探针。

## 五、P2：按证据选择能改变增长曲线的候选

不预设所有候选都实施。一次解决最大实测项：

- 静态几何最贵：稳定描述缓存、生命周期/变换/版本失效、保守筛选，不重复量mesh，不漏障碍，不改变顺序相关的推出结果。
- 路径最贵：同任务请求去重与地图版本失效；必要时有界队列/共享路线。群体Flow Field是后续有条件选项，不能随手重写全导航。
- 邻居最贵：按域/队伍的局部空间索引与稳定候选顺序；计维护/更新/查询全部成本，避免每单位全场扫描。
- 命令/AI最贵：批量任务与真实编组、生命周期监控和完成/停滞事件，合并冗余命令，不降低用户输入响应或停掉屏幕外模拟。
- 日志/调试最贵：有界聚合、关默认非必需逐单位诊断、解决错误/重入，玩家必要反馈保留。
- 纯数学最贵：使用现有C#边界批处理稳定快照，再量串行与有界并行；snapshot/version/cancel/main-thread commit完整。
- native RVO确实最贵：同输入核心基准比较后才提出B的具体依赖、版本、许可、故障回退、联机权威/一致性方案和收益证据，请求批准后实施；不要仅因它叫“原生”就替换。

不能通过关避障/碰撞/迷雾、停模拟、缩视野/射程、降低physics tick、删阴影/部队或扩大穿模权限获得认证。既有用户批准的glow关闭与12m建造范围保持，不为本任务改回；其它并行玩法修复保留。

## 六、P3/P4：真正交付，不是让FPS计数变绿

目标定义为真实Match、正常画质、持续模拟和正常军团任务下1000单位 / 30FPS。固定场景/种子/相机/图形档/正常VSync与帧率上限；性能容量探针临时解锁需与生产条件分列。

按100/300/500/1000逐步验证闲置、持续多队移动、对向交错/窄口、交火、采矿/产兵、持续副官命令。1000同点拥堵作为额外稳健性场景，单独报告；不能拿它降载后变快称游戏优化。

记录：帧p50/p95/p99/最长帧/平均与1%low/超预算与hitch数、样本数、物理步/墙秒、模拟时间/墙秒、活跃单位、成功命令/位移/到达/开火/经济产出、各热点与内存。FPS变好而单位不动或模拟变慢是失败。预算33.33ms与采样/VSync误差要事先写明，不用过期27FPS探针绿灯替代目标。

实施候选跑对应脚本/编译、navigation-stability/local-avoidance/movement-recovery、推出等价、生产/经济及实际受影响套件，再执行全量与独立复核；逐项查forbidden输出，rc0不够。打开新鲜截图确认碰撞、移动/交火、迷雾和画面；退局重开确认没有僵尸房。已有采矿失败不能永远标“无关”，用同版本对照归因并列出阻挡完整产品验收的项。

按RSI保存candidate/champion与回绝原因。连续三轮无收益换诊断方向；只能撤销自己的候选，不reset或覆盖共享文件。不能以额度/工具不顺为由声称当前架构无解。

最终更新 `agent/reports/closed-loop/`，给用户：可信根因、改动范围、同合同before/after、热点表、截图已打开、命令/rc/forbidden、未验证项、清理结果和并行风险。未达到1000@30就明确未达到；有错误或样本不足就明确无有效成绩。不要再从不等价探针计算95%或540倍并要求用户降低目标。
