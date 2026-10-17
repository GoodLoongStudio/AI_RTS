# 战略层与Laya执行层补充交接

状态：文档交接完成；产品尚待Cursor实现和验证。用户允许战略决策慢一点，要求根据全局态势下准确大目标，Laya稳定指挥部队，减少无目的乱跑。

本轮只读检查了当前主工程战略上下文、计划采纳、运行配置、Laya决策frame/文本、编组与路段保持入口。runner默认战略1800 tick，runtime独立默认3600 tick；实际启动参数未测。模型提示及context要求更大的版本，战略节点采纳后替换active_plan。四列/Laya已有campaign/current_tasks与plan_version绑定、movement已有hop保持、nodes已有重复守卫。以上是静态线索，不是具体乱跑根因或模型实际接通证明。

新增[补充实施提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-strategic-layer-laya-command-discipline.md)与[三阶段验收计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-12-strategic-layer-laya.md)，在原[Cursor接管提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)顶部补充入口。核心要求为可追溯全局摘要、稳定计划/版本/任务、Laya真实输入与合法候选受战略约束、去重与局部紧急处理、非阻塞推理和迟到结果守卫；保留原建筑/经济修复及性能任务。

验证：Git根为G:/AIRTS/AI_RTS，四个文档编辑目标均通过check_workspace_target.py，rc=0；文档引用按本机文件核验。没有修改产品、主测试、DLL、模型运行时或打包版；没有启动游戏、模型或性能回归，没有消息发送给Cursor。沿用用户要求的人工转发方式，原等待/冻结解除保持有效。

本轮不产生新FPS、截图或动态录像成绩，不晋级产品champion。未验证真实模型、现场乱跑根因、Laya对战略目标的服从、计划保持效果及同开CPU/GPU性能；这些都有实施与验收要求，由Cursor完成。共享工程其他改动保留，本轮不会再并行写产品或开测试进程。

## 调度节奏修订

用户进一步要求写好节奏提示词并说明规模。已在原补充文件内替换固定30–60秒建议：程序约1秒检查，战略先10秒复核，再按实测评估5–10秒；重大事件去抖提前触发，保持目标与复核周期分开。为了证明收益，先比较30秒基线、异步15秒、10秒，按需再5秒。考虑20/60Hz地图、暂停、模拟时钟与墙钟区别，限制在途/事件积压并验证模型同开GPU负载。

新增静态证据：nodes的战略propose_plan调用仍等待返回；pydantic_agents内部future.result等待超时，runtime接入tactics_scheduler。故此范围判断为中等规模的现有架构改造：先非阻塞战略调度，再配置/计划稳定/目标映射。单改周期是小补丁，但不能实现用户要求；无需重写移动、导航、渲染或升级模型。本判断没有运行时耗时证明，实际实现由Cursor继续定位。

本次编辑仅提示词、计划和本报告；文档检查及本机引用核验rc=0。没有启动模型、游戏或新的回归，不再冻结Cursor工作。产品行为、推理时长和候选频率尚未验证，不声称性能收益。
