# 给 DeepSeek Harness 的执行提示词：AI_RTS 多线程与主线程性能闭环

你现在接手的是 `G:/AIRTS/AI_RTS`。目标是解决大部队卡顿，同时重点查清：**主线程是否过载、主线程是否在等待 worker、Godot 避障 worker 是否真的并行、以及哪些纯数据工作能安全迁移到 worker**。

这不是让你凭经验改几行参数，也不是让你关闭避障后报 FPS。必须按项目的 RSI 闭环完成“基线 → 探索 → 假设 → 最小改动 → 重放 → 独立验证”。没有新鲜日志/截图/rc/清理证据，不得说完成。

本会话应执行诊断和有证据支持的实现，不要只再写一份计划让用户选 A/B/C。压力目标保留 1000 单位、正常画质/玩法/模拟速度下稳定 30 FPS；不提前保证可达。解锁容量测试以 p50 约不超过 33.3 ms、p95 不超过 45 ms 为目标，并恢复玩家原 VSync/FPS cap 验证。禁止修改 `G:/AIRTS/打包版`、重新发布或覆盖评审包/GitHub release。

## 先读和先纠正

先读：

1. `AGENTS.md`
2. `skills/airts-workspace-boundaries/SKILL.md`
3. `skills/闭环验证工作法.md`
4. `skills/AI_RSI自校验循环.md`
5. `skills/airts-performance-optimization/SKILL.md` 及 `references/measurement.md`、`references/cpu-candidates.md`
6. `agent/plans/2026-10-09-multithreaded-performance-plan.md`
7. `agent/reports/closed-loop/2026-10-07-rvo-isolation-evidence-review.md`
8. `agent/reports/closed-loop/2026-10-07-rvo-scalability-design-review.md`
9. `agent/manifest.json`、`agent/mcp/` 的当前工具说明；工具能力以实际调用成功为准，插件安装不等于能可靠截图/采样。MCP 不可用时可用正规探针场景和项目实例工具，不将 `eval result:null` 当作执行成功。

先执行 git status、目标文件 mtime/hash、workspace target check。保留所有用户/其它 Agent 改动，不 reset、不 clean、不覆盖、不批量替换。

必须接受这些事实：

- 2026-10-09 `_ThreadCfg` 探针测得 `navigation/avoidance/thread_model/avoidance_use_multiple_threads=true`、`avoidance_use_high_priority_threads=true`、24 个逻辑处理器；这只是配置事实，不等于实际并行效率或新的性能基线，接手重读实际值。
- `physics/3d/run_on_separate_thread` 不得擅自开启。物理服务器独立线程、脚本 process thread group 和导航 worker 不是一回事；该物理开关不会自动把 Movement 的 `_physics_process` 搬到 worker。项目历史注释也不是线程成本证据，不能据此宣布物理成本为零或脚本必然迁到物理线程。
- 旧报告把“关闭 avoidance 后变快”全部归给原生 RVO 的结论已撤回，因为旧 A/B 同时去掉了 velocity 回调中的位置提交、旋转、静态推出和状态变化。
- 旧的“RVO 95%”“引擎不能多线程”“540 倍架构墙”都不能直接复用。先重测当前版本和健康夹具。
- 旧 skills/report 的 measured 数字同样要核验适用版本、计时方法和负载；有已知探针错误的条目不能因为写入技能就直接采信。按计划中的官方文档及版本匹配源码确认 API，不盲抄 master 或旧教程。

## P0：先做线程画像，不先改产品逻辑

建立 `agent/runs/<run-id>/`，写 `baseline.md`、`checklist.md`、`thread-config.json`。用真实 Godot `--path G:/AIRTS/AI_RTS` 和隐藏窗口运行，核对实例身份、端口、退出码和 cleanup。

压力矩阵至少包括：100/200/400/700/1000 单位；正常分散编组、密集汇聚、建筑出口、窄口、持续交战、采矿/生产、副官固定命令回放。修正旧夹具的重复坐标问题，但保留异常拥挤作为 adversarial。记录 active movers、实际位移、到达、卡住、伤害、生产、命令延迟和模拟秒/墙钟秒。

先以 100/200 单位完成归因和小改动，再逐档扩大。性能实例不与构建/回归/其它性能测试并跑。每次有独立进程 watchdog、固定墙钟预算和样本有效性检查；采样不足或灾难性长帧标失败/early-stop，不硬等到 1000 单位、更不删除 >500 ms 长帧。优先使用现有实例管理工具，超时只清理本轮的 PID/端口登记，禁止批量结束用户实例。

在**独立重启进程**中做配置 A/B，不在一局中热切换：

```text
A: 默认配置
B1: avoidance_use_multiple_threads=false
B2: avoidance_use_high_priority_threads=false
```

地图创建前设置并记录实际值；不要把写回旧 ProjectSettings 当成实测。用 `_ThreadCfg` 或等价探针输出设置、CPU 数、引擎版本。

必须使用可用的 Windows CPU 线程画像（WPR/WPA、Visual Studio profiler 或等价工具）与代码插桩配合，得到：

- 主线程 CPU 时间与墙钟时间；
- Navigation/RVO worker 实际 CPU 时间、并发任务数；
- 主线程等待 worker 的时间；
- RVO 请求/返回、`velocity_computed` 回调、静态推出、位置写回、路径查询/同步、AI/C#桥接、GC/日志各自的 exclusive 时间；
- 每帧实际 physics ticks、队列长度、过期结果和长帧。

如果工具无法得到真实线程归属，字段标 `unavailable`、线程归因标 `needs-review`，继续实际调用计时和有依据的等价实验，不虚构线程占比，也不因为缺少 WPR 就停止全部工作。不得自行安装/升级引擎或依赖来绕过现有工具限制。

## P1：按调用处拆成本

只加低开销聚合计时，不逐单位打印。用批次元数据关联 `match_generation/unit_generation/tick/geometry_revision`，不逐调用创建字符串/字典。`TIME_PHYSICS_PROCESS`、`TIME_PROCESS`、导航 monitor 可能重叠，禁止直接相加。

worker CPU 时间可与 main CPU 重叠、总量可超过帧墙钟；不能把两者加 wait 算成帧时间。区分等导航任务、锁、GPU/present 和 VSync/FPS sleep，未知等待明确标未知。用关闭插桩的同场景重跑估计测量开销，用串行热点占比估计并行收益上限，不靠 24 核宣称 24 倍加速。

重点查看 `Movement.gd` 的 `_on_velocity_computed`、`_push_out_of_static_obstacles`、位置/旋转提交和恢复逻辑，以及导航地图同步和路径重置。先证明当前版本哪些是真热点；不要因为报告标题写 RVO 就继续只改 RVO。

## P2：先减主线程工作，再考虑并行

每轮只做一个由数据支持的候选：稳定障碍 AABB/多边形索引、同 tick 纯数据复用、避免重复 shape/hull/transform 查询、去重无效路径请求或已证实的日志/HUD轮询。保守筛选只能减少精算，不能改碰撞、carve、个人空间、速度、射程、视野或单位尺寸。处理 queued deletion、换形状、父变换、施工完成、死亡和换局；未知形状回退旧算法并计数。

## P3：只迁移纯数据到 worker

只有 P1/P2 证明数学热点后才并行：

1. 主线程在 tick 边界建立不可变数组快照；
2. worker 只读快照、写预分配数组；绝不访问 Node、SceneTree、Skeleton3D、NavigationAgent3D、RID、资源对象或共享可变字典；
3. 不按单位创建 Task，不允许无界排队；
4. 主线程校验 generation/tick/revision 后，按原顺序提交位置、旋转、事件；过期结果丢弃；
5. 计入采集、复制、锁、worker、等待、提交、GC 全成本；先同步 oracle 差分，再做有界并行。
6. 选择现有 Godot `WorkerThreadPool` 或 C# 受控批处理执行器中的一种，避免多套线程池争抢 CPU；分块而非逐单位调度，实测 worker 数/批次大小和小部队串行快路径。
7. 检查跨单位读写依赖：同 tick 快照未必等价于原逐单位读写顺序，仅恢复提交顺序还不够。无法证明独立的阶段保持串行；输入输出数组不重叠写，任务异常/取消要安全收尾，禁止持有 worker 所需的锁等待 worker 或提前归还其数组。

不要开启 `physics/3d/run_on_separate_thread`，不要另写 N² 分离力，不要把关闭 RVO 的成绩当正式产品成绩。

P3 后重新画像，按证据选择计划 P4 的共享路径/空间索引/成熟核心评估。原生 RVO 已有 KD-tree 和并行选项，换另一个原生库不自动等于升级；行为改变或新增核心依赖先明确批准，不假借性能需求改碰撞/导航语义。

## 验收门禁

- C# build/GDScript parse 和相关套件 rc=0、预期 marker 存在、forbidden output 为空、无超时/崩溃且证据新鲜；不得改断言阈值来“修绿”。实现后还须按项目规则跑全量回归和关键改动独立探针/复核，历史红项单列前后对照，不能误报全项目通过。
- `movement-push-equivalence`、`navigation-stability`、`movement-recovery`、`local-avoidance` 以及碰撞/建造相关套件通过。
- 正常、异常拥挤、窄口、旋转、静止嵌入、同 tick 删除/换形状有正反断言。
- 100→200→400→700→1000 有效同负载比较至少三次，报告 p50/p95/p99、最长帧、hitch、ticks/frame、main CPU、worker CPU、wait、queue 和行为指标；早停/未测档位单列。1000 单位没有实测通过，就不得声称达标。
- 正常迷雾与全图视野都保留截图并实际打开检查；不以隐藏模型/关闭特效达标。
- 退局重开后无孤儿进程、实例登记残留或僵尸房，`cleanup_ok=true`。
- 连续三轮没有 champion 提升就换高层方向；未达到 30 FPS 或线程归因不完整时状态必须为 `needs-review`。

最后交付：修改文件清单、当前 champion hash、before/after 数据、线程 A/B、主线程/worker/等待分解、截图路径、测试命令与 rc、未验证项和下一步。不要写未经数据支持的“已解决”“RVO占95%”或“多线程已生效”。

完整实施报告写入 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-09-multithreaded-performance-report.md`。没有达到综合目标时仍交付已验证的局部改善和剩余瓶颈，状态 `needs-review`；不能擅自下调目标或把采矿/生产坏了视为无关而宣布产品完成。
