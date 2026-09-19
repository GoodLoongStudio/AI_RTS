# 单机副官挂上加速 Implementation Plan

## Overview
单机进局后 AI 副官要等很久才显示「运行中」。加载页与模型装配并行，对局就绪后立刻写握手，让面板在进局时就能认到副官。

## Current State Analysis
- 加载页只在上次点过「接管」（`auto_takeover`）时才预热；默认关，冷启动整段落在进局之后。
- `is_attached()` 要 pidfile + 心跳。心跳已在模型装配前写，pidfile 仍在 `setup()` 全部成功后才写，加载页 12 秒上限经常白等。
- runner 等权威口/对局时每轮睡 1 秒。
- 面板「接管」自己再起一份进程，且引导文件不写 `ADJUTANT_SPAWN_TS`。
- `agent_runner.py` 模块顶层就导入 pydantic/langgraph，`_warm_imports` 形同虚设，等对局的循环要等导入完才开始。

## Implementation Strategy
1. 单机加载页默认预热（专用服与 `AIRTS_ADJ_AUTO_TAKEOVER=0` 仍可关）。
2. 对局身份拿到后立刻写 pidfile；装配失败再删，避免残留死握手。
3. 等待轮询改为 0.2 秒；重依赖改懒加载，真正和「等对局」重叠。
4. 面板接管走 `AdjutantRunnerLauncher.start()`，已挂上则不重复拉起。

## Implementation Steps
1. 本计划文档
2. runner：早写 pidfile、加快等待、懒加载
3. 加载页默认预热 + 启动入口去重
4. 契约/守门测试

## Timeline
改完重新开一局单机：加载结束时标题应为「运行中」或最多再等数秒，而不是半分多钟。

## Risk Assessment
- 早写 pidfile：装配失败必须删掉，否则下一局认领死 pid。
- 单机默认预热：点「停止」只停本局，下一局单机仍会挂上；彻底关掉用环境变量。
- 懒加载：故障注入档与 MeteredModel 改为函数内导入，避免顶层再拖 5 秒。

## Success Criteria
- 单机不点接管也会在加载期拉起 runner
- 对局就绪后数秒内 `is_attached()` 为真（不必等模型构造完）
- 点接管不会再起第二个 runner
- 契约测试与守门测试通过

## Progress Tracking
- ✅ 计划
- ⏳ runner 就绪握手
- ⏳ 加载页与面板
- ⏳ 测试

## Related Files
- `AI_RTS/source/adjutant_coordinator/deploy/agent_runner.py`
- `AI_RTS/source/main-menu/Loading.gd`
- `AI_RTS/source/ui/AdjutantRunnerLauncher.gd`
- `AI_RTS/source/ui/AdjutantButton.gd`
- `AI_RTS/source/adjutant_coordinator/tests/test_runner_link_contract.py`
- `AI_RTS/tests/automated/AdjutantAttachSpeedSmokeTest.gd`
