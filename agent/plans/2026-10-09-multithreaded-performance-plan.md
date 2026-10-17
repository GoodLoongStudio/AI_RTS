# AI_RTS 多线程性能诊断与优化计划

日期：2026-10-09（北京时间）  
状态：needs-review。2026-10-10 续测见 `agent/reports/closed-loop/2026-10-10-multithreaded-performance-report.md`。当前 champion 仍是 400 单位产品路径 6.893 FPS、帧 p50 144.223 ms、步/帧 8。本轮两刀（小函数跳过重推出、预剔除改平方距离）都更慢，已退回。没有达到 1000 单位 30 FPS。10 月 9 日的 6.75 FPS 不是这次的基线。

## 1. 目标与不可改变的产品合同

目标是在保持正常画质、单位尺寸、碰撞、速度、射程、视野、模拟频率和副官行为的前提下，逐步提高大部队容量。压力目标仍为 1000 个单位、持续移动/交战时稳定 30 FPS，但只有真实 Match 的数据达到门禁才能宣布达成。

容量验收在固定硬件/地图/镜头/生产画质下进行：解锁 FPS 的容量测试目标为 frame p50 约不超过 33.3 ms、p95 不超过 45 ms；再恢复实际 VSync/FPS cap 验证持续帧节奏。分位数不能代替平均吞吐、长帧和模拟速度，模拟秒/墙钟秒应保持正常实时运行，不能靠模拟变慢通过。小地图与大型生成图各自原有物理频率单列，不能混测或调低。

必须保留：屏幕外和战争迷雾外单位的权威模拟、攻击/受伤、采矿、生产、命令响应、退局重开和建造/碰撞语义。不得用关避障、缩碰撞盒、放宽净空、减少视野、停模拟、降低 physics tick、提高速度或降画质换 FPS。

## 2. 已知事实与需要纠正的旧结论

- 2026-10-09 的 `_ThreadCfg` 探针报告 Godot 4.7.1 Mono、`navigation/avoidance/thread_model/avoidance_use_multiple_threads=true`、`avoidance_use_high_priority_threads=true`、24 个逻辑处理器。日志为 `agent/runs/thread-config-2026-10-09.out.log`；这不是新的性能基线，新会话仍要重读实际配置。
- `project.godot` 未显式启用 `physics/3d/run_on_separate_thread`，并有禁止盲开的历史注释。注释不是线程画像证据：物理服务器独立线程、SceneTree process thread group、导航 worker 是不同机制，物理线程开关不会自动把全部用户 `_physics_process` 并行化。先查本机版本的实际设置与官方规则，本轮不擅自开启。
- RVO 关闭或断开 `velocity_computed` 的旧 A/B 同时改变了位置落地、旋转、静态推出和后续状态，不能把差值全部归给原生 RVO。
- 旧报告中“RVO 占 95%”“引擎不能并行”“需要 540 倍架构提升”已经被证据复核撤回，必须重新测量。旧 FPS 只作线索，不作当前基线。
- “已启用多线程”也不等于主线程没有负担：主线程可能负责快照、提交、节点更新，并在同步点等待 worker。必须区分主线程执行时间、worker CPU 时间和等待时间。
- 10 月 7 日报告和 skill 的 measured 段落只证明当时版本/负载；其中手动调用画像、回调断开或 monitor 相加的结论仍须按证据复核更正。不能因为资料放在 skills 里就免于审查，也不能恢复旧源码来匹配旧 hash。

## 3. 本轮写入与证据目录

新会话建立自己的 `agent/runs/<run-id>/`，至少包含：

```text
baseline.md
checklist.md
thread-config.json
round-01/direction.md
round-01/exploration.json
round-01/patch.md
round-01/verification.md
round-01/*.log
round-01/*.png
champion.json
```

长期交付写入本计划对应的闭环报告 `agent/reports/closed-loop/2026-10-09-multithreaded-performance-report.md`。不覆盖 10 月 7 日旧报告，不覆盖别的 Agent 的源码改动。

## 4. 分阶段执行

### P0：建立可信基线和线程健康表

1. 读取 `AGENTS.md`、workspace boundaries、manifest、闭环工作法、RSI 和 performance skill；检查 `git status`、目标文件 mtime/hash。
2. 使用真实 `G:/AIRTS/AI_RTS` 工程和 Godot 4.7.1，先跑启动/退出健康检查，确认没有旧实例、端口冲突、僵尸房或跨实例日志。
3. 修正压力夹具：正常分散编队、密集汇聚、建筑出口、窄口、持续交战分别测试；不能用重复坐标把 1000 个请求伪装成 400 个位置，也不能删掉异常堆叠场景。
4. 先以健康的 100/200 单位复现和归因，再按容量逐档扩大至 400/700/1000；正式容量比较每档至少三次。记录预热后的 frame p50/p95/p99、最长帧、hitch 数、实际 physics ticks/frame、模拟秒/墙钟秒、active movers、位移/到达/卡住、伤害/产出/命令延迟。固定种子、命令和采样窗口，不并行运行性能实例、构建和回归；自动画质调节不得悄悄改变 A/B 内容。
   每档须有独立进程 watchdog、墙钟预算和最小样本量；例如稳态目标窗口 30 秒，单次默认硬超时 120 秒，触发时只结束本轮拥有的 PID 并核验清理。样本不足、灾难长帧或超时记录为失败/截断数据，不生成精确 p95，不硬等 1000 单位跑完，更不删除 >500 ms 的长帧。
5. 在独立重启的进程中做线程配置 A/B：
   - 基线：项目默认值；
   - `avoidance_use_multiple_threads=false`；
   - `avoidance_use_high_priority_threads=false`；
   - 如运行时支持，记录 worker 任务数/线程数。
   每个进程在创建导航地图前固定配置，不能在同一局中热切换后直接比较。
6. 使用项目 `_ThreadCfg` 探针或等价探针记录实际配置；使用 Godot profiler/自有插桩配合 Windows CPU trace（WPR/WPA、VS profiler 或机器已有等价工具）记录主线程、导航 worker、其它 worker 的 CPU 时间和等待区间。先检查工具是否可用，不自动安装依赖；没有 OS 线程画像时将对应字段标 `unavailable`、线程归因标 `needs-review`，继续能验证的调用处计时与等价实验，不能靠整机 CPU 占用猜测或停止全部工作。

### P1：拆分“主线程计算”与“主线程等待 worker”

在真实调用处增加低开销、可关闭的聚合计时，不逐单位打印，不把 monitor 值直接相加。至少区分：

- NavigationServer/RVO 请求提交与返回；
- `velocity_computed` 回调本身；
- `_push_out_of_static_obstacles` 的 broadphase、精确形状/hull、连续推出；
- 旋转、位置/变换写回、事件派发；
- 路径查询/重寻路/地图同步/重烘；
- AI/C#桥接、HUD/副官、GC 和日志；
- 主线程在同步点等待 worker 的时间；
- worker 实际 CPU 时间、并行任务数、队列长度和过期/取消任务数。

用批次/采样元数据关联 `match_generation/unit_generation/tick/geometry_revision`，避免每单位每次造字符串或字典。记录 inclusive/exclusive 关系，禁止重复计时。以同一时间轴对账：worker CPU 总量可能大于墙钟，且与主线程工作重叠，不把 main CPU + worker CPU + wait 当串行帧时间相加。区分等导航任务、锁、GPU/present、VSync/FPS sleep；等待对象没有调用栈证据就标未知，不都归给 RVO。

同时用热点比例估算并行收益上限：串行部分不变时，即使纯计算无限并行也有 Amdahl 上限；该估算仅用于选择方向，不当成实测。插桩/线程采样的额外开销要用关闭采样的同场景重跑对照。

### P2：先做不改变语义的主线程减负

只实施被 P1 证明的热点，每轮一个候选：

- 静态障碍的稳定世界 AABB/形状描述与生命周期 dirty 索引；保守筛选只减少精算次数，不能改变碰撞盒或导航 carve；未知形状回退旧算法。
- 同一 tick 内复用稳定纯数据，避免重复 `find_children`、重复 transform inverse、重复蒙皮/hull 采样；处理 queued-for-deletion、换形状、父变换、施工完成、换局和同帧增删。
- 批量位置/事件提交时保持原单位顺序和回调语义；只有“实际值未变且事件合同允许”才能跳过写回。
- 消除确认过的重复路径请求、调试日志、HUD/副官轮询；不能取消有效命令或权威状态更新。

每个候选同时测索引维护成本、fallback 比例、内存、GC 和长帧，不接受只在微基准上变快的方案。

### P3：只迁移纯数据计算到 worker

只有 P2 后仍确认存在稳定纯数学热点时才并行化：

1. 主线程在 tick 边界采集不可变快照：单位位置/朝向、经过验证的碰撞代理、障碍 AABB/多边形、revision 和命令版本。
2. worker 只读快照并写入预分配输出数组；不访问 Node、SceneTree、Skeleton3D、NavigationAgent3D、RID、资源对象或共享可变字典；不在每个单位创建一个 Task。
3. 主线程在有界同步点校验 generation/tick/revision；过期、死亡、退局、换局结果直接丢弃，不能把上一 tick 的碰撞结果提交到当前局。
4. 主线程按原时序提交位置、旋转、事件和导航状态。采集、序列化、锁、worker 等待、提交和 GC 全部算入性能账。
5. 首版先做同步纯数据实现与 oracle 差分，再开启有界并行；同一输入必须记录最大位置/法线/到达/卡住偏差。无法保持合同就拒绝候选。
6. 根据现有代码和实际热点在 Godot `WorkerThreadPool` 或已有 C# 的受控批处理执行器中选择一种，不同时再建多套线程池。不按 24 逻辑处理器直接开满线程；记录与原生 RVO/渲染/副官的线程竞争，实测少量 worker 和批次大小，保留小部队单线程快路径，避免调度/跨语言复制比计算还贵。
7. 并行前验证数据依赖：若后一个单位会读取前一个单位提交后的状态，统一快照可能改变原算法，不能仅恢复提交顺序就宣称等价；保留这段串行或建立可验证的分阶段计算。退局/异常须取消并安全回收任务，不能在等待 worker 时持有其需要的锁，也不能释放仍被 worker 使用的数组。

禁止把 `physics/3d/run_on_separate_thread` 或 process thread group 当捷径；禁止从 worker 直接改 Godot 对象。本轮仅批准纯数据计算并行，线程安全 Server/RID API 是否可调用仍按版本文档确认，不据此扩大本轮对象访问范围。Godot 自带 RVO 多线程已存在时，不另写全军 N² 分离力或未经许可替换成熟核心。

### P4：重新决定群体算法

若线程画像和前述改动后仍不达标，再按数据决定空间索引、编组共享走廊/Flow Field、局部避让分层或成熟原生库评估。高重复目标可以共享路径，但必须保留单位最后一段、真实碰撞、窄口和到达语义。不得用统一软穿模或减少模拟伪造“群体优化”。

## 5. 硬门禁

- 改动文件逐个解析/编译通过；实际依赖套件串行 rc=0、预期 marker 存在、forbidden output 为空、无超时/崩溃，且产物确为本轮。实现线程/移动优化还须按仓库规则跑全量回归和独立探针/复核，历史失败单列对照，不能宣称全项目绿色。
- `movement-push-equivalence`、`navigation-stability`、`movement-recovery`、`local-avoidance` 和相关建造/碰撞套件不因放宽断言而变绿。
- 正常/异常/窄口/旋转/静止嵌入/同 tick 删除换形状均有正反断言。
- 全图视野和正常迷雾各有截图；模型、碰撞、carve、特效和移动反馈没有偷换。
- 100→200→400→700→1000 阶梯有同场景 A/B 数据；有效比较至少三次且有新鲜 mtime。未完成档位和 watchdog 早停如实单列，不拿低档位或病态汇聚结果认证全部场景。
- 报告同时给出 main CPU、worker CPU、wait、queue、ticks/frame，不能只给 FPS。
- 退局重开后 `cleanup_ok=true`，无孤儿进程、实例登记或僵尸房。
- 任何线程安全、行为等价、长帧、内存或画质门禁失败，候选拒绝并回到 champion。

## 6. 停止条件与交付

连续三轮 champion 没有提升就停止堆参数，换诊断方向。未达到目标写 `needs-review`，不得写“已完成”。报告必须列：当前 champion hash、基线/候选数据、线程配置、主线程/worker/等待分解、截图、测试 rc、未验证项和剩余风险。

## 7. 官方资料与版本核验

- [避障线程配置](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-navigation-avoidance-thread-model-avoidance-use-multiple-threads)
- [与现有探针版本匹配的 NavMap3D 源码](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/modules/navigation_3d/nav_map_3d.cpp)
- [Godot 线程安全 API](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)
- [WorkerThreadPool](https://docs.godotengine.org/en/stable/classes/class_workerthreadpool.html)

`stable` 文档可能随引擎发布变化，实施时先核对当前 Godot 构建的版本/commit；插件存在、设置为 true 或 CPU 占用提高都不是性能达标证明。不重打包、不覆盖评审成品、不上传或修改 GitHub release。
