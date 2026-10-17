# AI 长帧与保画质 GPU 优化：交接文档校验

日期：2026-10-12。范围：用户要求的提示词和实施计划；未实施游戏优化。

交付文件：

- [完整实施提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-ai-stutter-gpu-quality-optimization.md)
- [常驻实施计划与验收表](G:/AIRTS/AI_RTS/agent/plans/2026-10-12-ai-stutter-gpu-quality-optimization.md)

证据来自 [本日单人对局诊断](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-12-singleplayer-live-performance.md)：约 649ms 的帧与规则 AI 约 639ms 仲裁执行链同帧关联；主视口 GPU 平均约 1.9ms，尚无 pass 独占证据。提示词要求先拆长任务内部，再对 GPU 做实测、逐候选截图审阅；同时保留副官、玩法合同和后台不干扰要求。

本轮检查：主工程 Git 根正确；三个实际文件目标 `check_workspace_target.py --mode develop` 均 rc=0。文档读回、本地链接、必需约束及 15 个测试 ID 检查通过，组合校验命令 rc=0；`git diff --check -- <三份文件>` rc=0。文件尚未跟踪，另逐文件执行 `git diff --no-index --check -- NUL <文件>`，无 whitespace 报错，rc=1 表示新增内容与 NUL 有差异，不是校验失败。没有把历史 FPS、受污染样本或未运行的工具分支写成新优化成绩。

本轮仅新增以上三份 Markdown，未编辑产品代码/场景/画质配置，未启动游戏、录像、编译或回归。因此没有本轮画面截图、性能前后值或产品 candidate/champion 晋级；文档任务允许跳过真实 Match，实施 AI 必须按计划补齐全部门禁。共享工作区存在其他未提交改动，未回滚或清理。

交接状态：文档交付；游戏优化待实施。三次 10 分钟、GPU 收益和画质矩阵是后续验收目标，不是本轮结果。
