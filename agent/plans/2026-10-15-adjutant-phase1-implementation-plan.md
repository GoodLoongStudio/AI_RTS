# 副官第一阶段实施：追踪、闭环与经济恢复 — 实施计划

- run-id: `2026-10-15-adjutant-phase1`
- 提示词: `agent/prompts/2026-10-15-adjutant-phase1-implementation.md`
- 日期: 2026-10-15
- 分支/HEAD: `yyp_test` @ `4851de361b4c924cde0eacbe2d113b14fc6c9798`（共享 dirty tree，禁止 reset/clean）

## 范围（仅三项 + 必要窄依赖）

1. 运行时决策追踪（`graph/trace.py` 新模块 + graph/nodes/runtime/replay 接线 + 导出工具）
2. 任务分支可执行闭环（`graph/task_loop.py` 新模块 + state/nodes 接线）
3. 经济恢复入口与里程碑判据（`graph/economy_recovery.py` 新模块 + campaign/decision_map 修改）

明确不做：战略整体重构、Laya 训练、模型替换、输出截断修复、上下文全面改造、资金账本重写。

## 顺序与闸门

追踪 → 闭环 → 经济入口。每个逻辑补丁：静态编译/解析 → 新独立进程无头真实 Match（`tools/dev/adjutant_observe.py`，正常菜单入口，真实 MiniCPM+Laya+LangGraph）→ 至少一条已知旧链路回归 → S1/S2/S3。

## 基线事实（2026-10-15 20:20 实测）

- 工作树文件 hash（git hash-object）：
  campaign.py `4851921`、graph.py `10a6ff4`、nodes.py `d22d7c3`、decision_map.py `4669df9`、
  state.py `d33c5dd`、runtime.py `ba7138e`、agent_runner.py `ba7138e`（同 runtime 前缀系巧合，全值见 baseline.md）、progress.py `39bdcca`、replay.py `7cd3ed0`
- 副官 Python 单测基线（tests 目录内 unittest）：
  - `test_campaign_mainline` 1 失败：`test_economy_requires_real_refinery_delivery` —— 工作树里该测试已改为新口径（M01 需真实交付证据），代码未跟上。属"新口径断言待实现"，正是修改 3 的 M01 语义审计对象，不是行为回归。
  - `test_task_progress` ImportError（`capture_build_site` 已不存在）、`test_economy_bootstrap` ImportError（`economy_bootstrap` 模块不存在）：既有陈旧测试，与本次改动无关，记录不修改（除非改动使其相关）。
- 模型服务：11434 已在运行（PID 18700，复用不关闭）；观测工具 venv：`G:/AIRTS/临时文件夹/airts_agent_venv`（langgraph + pydantic 2.13.5）。
- 旧样本结论保持有效：D2 可选 0/374、M01 tick 914 done 依据"采集命令被接受"、原观察审计 18/20 rc=2 不改绿。

## 交付物

- 运行时代码：`graph/trace.py`、`graph/task_loop.py`、`graph/economy_recovery.py` + 接线补丁
- 测试：`tests/test_decision_trace.py`、`tests/test_task_loop.py`、`tests/test_economy_recovery.py`
- 工具：`tools/dev/export_adjutant_runtime_trace.py`（运行时 trace → 中文 MD + 交互 HTML）
- 证据：每轮 `agent/runs/2026-10-15-adjutant-phase1/round-XX/`，600 秒观察另建目录
- 最终闭环报告：`agent/reports/closed-loop/2026-10-15-adjutant-phase1-implementation.md`
