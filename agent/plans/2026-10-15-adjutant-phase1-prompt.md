# 副官第一阶段实施提示词编写

用户本轮要求：只写修改计划第 1～3 项的提示词，供另一个 AI 实施。

范围：新增一份自包含提示词，覆盖决策追踪、可执行闭环、经济恢复与里程碑；不开始产品修改或游戏测试。

- [x] 读取仓库入口、边界、manifest、RSI、闭环规则与既有循环诊断报告。
- [x] 检查 Git 身份、提示词目录状态和新文件不存在；三个编辑目标的边界检查 rc=0。
- [x] 编写实施提示词，分清已核实事实、待实现合同与验收要求；三项分别给出具体实施及正反验收。
- [x] 核验 12 个内容锚点、13 个引用文件与围栏，rc=0；保存 agent/reports/closed-loop/2026-10-15-adjutant-phase1-prompt.md。

诊断来源：agent/reports/closed-loop/2026-10-15-adjutant-loop-trace.md。
产出：agent/prompts/2026-10-15-adjutant-phase1-implementation.md。
本轮文档任务不运行 Match、不改变 champion 或连续未提升计数，原观察审计仍为 18/20、rc=2。
