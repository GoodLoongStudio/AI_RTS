# 给 Grok 4.7 的执行提示词：AI_RTS 安全修复闭环

你接手的工程是 `G:/AIRTS/AI_RTS`。你的首要目标不是尽快改出一个“看起来修好”的截图，而是修复游戏问题，同时证明没有拆东墙补西墙。

先读取：

1. `G:/AIRTS/AI_RTS/AGENTS.md`
2. `G:/AIRTS/AI_RTS/skills/airts-workspace-boundaries/SKILL.md`
3. `G:/AIRTS/AI_RTS/skills/闭环验证工作法.md`
4. `G:/AIRTS/AI_RTS/skills/AI_RSI自校验循环.md`
5. `G:/AIRTS/AI_RTS/skills/airts-performance-optimization/SKILL.md`
6. `G:/AIRTS/AI_RTS/agent/manifest.json`
7. `G:/AIRTS/AI_RTS/agent/plans/2026-10-10-grok47-safe-game-fix-plan.md`

不要只输出计划；按计划实际诊断和实施。不要覆盖 `G:/AIRTS/打包版`、不要修改 GitHub release、不要 reset/clean 或覆盖其他 Agent 的未提交改动。

## 绝对规则：每个关键补丁后重新开无头真实对局

下列任何改动都算关键补丁：移动、避障、碰撞、出生/缩放、建造、导航、攻击/射程/视野、采矿/生产、对局生命周期、网络、线程、缓存、共享 API、场景或配置。

每个关键补丁必须严格执行：

1. 先记录当前 champion hash、文件 mtime、基线结果和本轮唯一假设。
2. 只改一个逻辑方向；不要同时重构多个系统。
3. 编辑后立即解析/编译。失败就停止，不能继续改其他文件。
4. **重新启动新的独立 Godot headless 进程运行真实 Match**，不能复用上一局，也不能用孤立函数、假节点、静态 JSON 或只启动探针场景代替。必须真实生成单位/建筑、执行命令并推进 physics tick。
5. 验证新行为：正向断言 + 反向断言；同时重放至少一条旧功能轨迹。例如移动改动要验证实际位移/到达、碰撞/窄口、攻击或采矿/生产中至少一条；经济改动要验证移动、出生、建造和退局；性能改动要验证模拟速度和命令延迟。
6. 记录真实实体数、命令数、位移/到达、伤害或资源产出、physics ticks、模拟秒/墙钟秒、错误日志、退出码、PID、端口、实例登记和 `cleanup_ok`。设置 watchdog；超时只清理本轮拥有的进程并保留原始日志。
7. 读取 JSON/日志/截图前验证产物 mtime 晚于本轮开始时间。旧产物、旧截图、旧日志一律不能当证据。
8. S1 失败立即 `reject`，停止在坏候选上继续补丁，从 champion 重新开始。不要为了测试变绿放宽判据或关闭功能。

## 阶段流程

### S0 基线

先检查 `git status`、目标 mtime/hash、引擎版本和活动实例。启动当前 champion 的真实 Match，确认可出生、可移动、可攻击/生产、可退局重开且无僵尸房。建立 `agent/runs/<run-id>/baseline.md`、`checklist.md`、`champion.json`。

### S1 单补丁循环

为每轮写 `round-NN/direction.md`，包含可证伪假设、影响范围、正向/反向断言、停止条件。Explorer 没复现不得编辑。Editor 只做该轮补丁。补丁后必须按上面的无头真实对局闸门执行，并写 `patch.md`、`headless_match.json`、`verification.md`。

### S2 阶段复验

每完成一个功能阶段，跑相关套件和边界场景，至少覆盖正常、异常拥挤、窄口、旋转、静止嵌入、同 tick 删除/换形状、退局重开。移动/碰撞/导航改动必须跑 `movement-push-equivalence`、`navigation-stability`、`movement-recovery`、`local-avoidance` 及相关建造/出生套件。禁止改断言阈值“修绿”。

### S3 晋级

用独立会话/独立探针复核，跑全量回归，比较 candidate 与 champion：目标行为、旧功能、视觉、错误/内存、帧时间、模拟速度、命令延迟。任何硬门禁失败都拒绝晋级。连续三轮无提升换高层诊断方向；连续两轮新功能通过但旧功能退化，暂停编辑并重画调用链。

## 性能和多线程特别要求

- 不要把开启 Godot avoidance 多线程配置当成优化完成；必须测主线程计算、worker CPU、主线程等待和模拟速度。
- 不要擅自开启 `physics/3d/run_on_separate_thread`，不要从 worker 访问 Node、SceneTree、Skeleton3D、NavigationAgent3D、RID 或共享可变对象。
- 先删重复主线程工作，再把稳定纯数据按批次迁移到一个受控线程池；先同步 oracle 差分，再并行。计入快照、复制、锁、调度、等待、提交和 GC 成本。
- 性能变快但模拟变慢、单位不转向、碰撞/导航退化、攻击/采矿/生产丢失，候选一律拒绝。

## 最终交付

写 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/<date>-grok47-safe-fix.md`。报告必须列修改文件、每轮 candidate/champion hash、无头真实 Match 命令和 rc、实际行为数值、截图、相关/全量回归、清理结果、未验证项和回滚方式。没有 S3 证据只能写 `needs-review` 或 `blocked`，不能写“已修好”。
