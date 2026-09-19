# 单机副官无法停止 Implementation Plan

## Overview
单机点「AI 副官：停止」后副官仍在指挥。停止必须杀掉本机 runner、收回租约，并且面板不能再把残留租约认成「还在跑」。

## Current State Analysis
加载页用 `AdjutantRunnerLauncher.start()` 预热副官。对局面板的停止只杀自己记下的 `_runner_pid`；加载页拉起的进程常常没被认领。杀完后 `_query_status` 仍会因权威端租约/意图把 `_active` 重新点亮。`auto_takeover` 也从未在点停止时关掉。

## Implementation Strategy
1. 停止走 `AdjutantRunnerLauncher.stop()`，必要时按进程树杀掉。
2. 权威端新增 `adjutant_release`：清空本玩家租约与意图，并让受令单位停下。
3. 玩家点停止后加闩锁，状态轮询不得再靠心跳或租约把按钮点亮；点接管才解开。

## Implementation Steps
1. 本计划
2. 权威端 release
3. 面板停止与闩锁
4. 冒烟：release 后租约为空

## Timeline
本轮只修停止，不改副官决策。

## Risk Assessment
`OS.is_process_running` 对外部进程恒 false，所以不能靠它判断杀没杀掉。Windows 用 `taskkill /T` 清子进程。

## Success Criteria
- 点停止后按钮回到「接管」
- 本机 runner 进程结束
- 权威端该玩家租约/意图为空，部队不再接受副官新命令

## Progress Tracking
- ✅ 计划
- ✅ 权威端
- ✅ 面板
- ✅ 冒烟

## Related Files
- `source/net/DebugControlServer.gd`
- `source/ui/AdjutantButton.gd`
- `source/ui/AdjutantRunnerLauncher.gd`
- `tests/automated/AdjutantCommandProtocolSmokeTest.gd`
