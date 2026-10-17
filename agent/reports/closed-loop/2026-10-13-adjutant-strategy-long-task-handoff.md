# 副官战略多方案长任务交付记录

日期：2026-10-13（北京时间）。状态：**方案与长任务文件已校验，游戏实验待用户启动另一AI执行。**

用户要求准备多套组合，让另一个AI开局长期尝试。本轮已形成五套本地方案及当前/强模型对照，安排服务与执行地板→小接口pilot→筛选→多seed开局→跨图长局→最终回归，提供停止/转向、记录和可回退合同。

## 文件入口

- [直接交给执行AI的长任务提示词](../../prompts/2026-10-13-adjutant-strategy-long-task.md)
- [完整方案、预算与验收计划](../../plans/2026-10-13-adjutant-strategy-long-experiment-plan.md)
- [可续跑的实验跟踪表](../../plans/2026-10-13-adjutant-strategy-experiment-tracker.md)

方案是A规则战略+Laya、B 2B模板+Laya、C合法候选+2B选择+Laya、D评分+2B歧义仲裁+Laya、E条件两步窄任务+Laya；K0为执行时当前完整规划基线，T为可选既有强模型离线参照。优先B/C/D，E依证据决定。训练后置；不需要先写完所有备用方案。

预算采用24快照pilot、独立24快照×3排列验证、最多9个短局和12个配对局，再各1长局；预算是计划，实际时间由吞吐和用户长任务配置决定。先测服务、原始输入/响应和规则执行，避免把所有失败归因2B容量。

## 新核验的工程事实

本轮读取仓库规则、实验计划skill及输出协议、temporal/performance规则和相关源码/测试。当前主根 `G:/AIRTS/AI_RTS`，Git与主工程定位rc=0。四份文档的绝对目标检查均allow/rc=0。

读盘时发现其他会话刚更新 `campaign.py`、`agent_runner.py` 与 `nodes.py`，源码已有 `RulesSafeStrategy/rules_safe_plan` 和 runner `--strategy-mode rules`，测试 `test_rules_safe_plan.py`验证第一次采纳及第二次保持。本轮只阅读，没有运行该测试，也没有认证这条新路径已在真实Match有效；执行AI必须重新核验及复验，不能沿用之前的旧源码判断。

本轮实际读取 `config/full_regression_suite.json` 的 `godot_tests`：128项，计划中定向测试ID均从当前清单选取；最终全量按执行时清单。旧headless验收脚本只有墙钟等待和强制收尾，提示词明确不能认证正常单人UI/对战/退重开。

## 本轮验证

验证记录：[文档与事实核验](../../runs/20261013-adjutant-strategy-long-task-handoff/validation.json)。

- `git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel`：rc=0。
- `python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target <文档绝对路径>`：四份均rc=0。
- `python -` 文档引用、方案/场景/阶段覆盖、预算算术、现有测试/源码入口与全量manifest核验：rc=0，11个本机引用有效、8类场景/18项跟踪记录完整、14个定向ID和相关Python测试文件均存在；详细结果见验证JSON。

本轮只新增上述计划、跟踪表、执行提示词和本报告，没有修改产品/模型配置/测试断言/打包产物，未创建新聊天、发送任务消息或启动自动化。按用户意图提供人工启动入口。

没有新真实Match、推理、FPS/策略改善、游戏截图/录像、编译、相关回归或全量产品复核。既有诊断的5/5超时仍只是历史基线，新数值为空。文档无需启动游戏验收；方案运行和产品质量均待执行。没有产品candidate/champion晋级，连续未提升轮数不适用。

共享工程存在活跃修改，已保留。本轮新文档与已有产品工作互不覆盖；未来执行者需核验mtime/hash、实例所有权与版本污染。后台资格或独立复核不能完成时应交部分证据、needs-review和续跑状态。
