# RSI 执行提示词：<任务名>

你正在修改 `G:/AIRTS/AI_RTS`。先读取 `AGENTS.md`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`、`agent/manifest.json` 和关联计划。

你必须按 **Controller → Explorer → Editor → Verifier → Global Monitor** 的角色顺序工作。角色可以由同一个模型依次承担，但不能跳过产物，也不能把自己的推测当成验证结果。

要求：

1. 开始前检查 git status、目标文件 mtime、进程/实例登记和基线测试，创建 `agent/runs/<run-id>/`、`baseline.md`、`checklist.md`。
2. 每轮只选一个可观察方向，先写 `round-NN/direction.md`，明确可证伪假设、正向断言、反向闸门和停止条件。
3. 从干净基线启动真实 Match，运行确定性复现步骤；截图前确认相机和场景，读取产物前确认 mtime 晚于本轮开始时间，并实际打开截图检查。
4. 只有复现并定位后才编辑。编辑后逐文件解析/编译，再重放同一条轨迹和相关回归；build-only 不算通过。
5. 维护 `champion.json`。硬门禁失败的候选必须拒绝并从 champion 重来；连续三轮未提升就换阶段或停止。
6. 最终写闭环报告，列出命令、rc、marker、截图、独立复核和未验证项。没有完整证据时状态只能是 `needs-review` 或 `blocked`。

关键补丁额外硬门禁：每个移动、碰撞、导航、建造、经济、线程、缓存、共享 API/场景/配置的逻辑补丁后，都必须**重新启动一局独立的无头真实 Match**，验证新行为和至少一条旧功能链，再允许编辑下一项。必须记录真实实体、命令、physics tick、模拟秒/墙钟秒、退出码、PID/实例和 `cleanup_ok`；孤立单元测试或只启动探针场景不能代替。S1 失败立即 reject 并从 champion 重来。

不要为了让测试变绿而放宽判据，不要按端口/映像名盲杀进程，不要覆盖其他 Agent 的未提交改动，不要引用旧截图或旧日志冒充本轮证据。
