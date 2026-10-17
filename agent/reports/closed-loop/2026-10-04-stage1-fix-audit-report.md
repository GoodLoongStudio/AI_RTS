# 阶段 1 收尾修复独立复核

日期：2026-10-04

判定：**静默解析已修好，状态文案部分修好；首次冷启动和切局生命周期仍未通过。阶段 1 继续保持 `needs-review`。**

## 本轮证据

| 场景 | 结果 |
|---|---|
| `StrategicChatServiceSmokeTest` | RC=0；0 failures；0 次 `Parse JSON failed`；新增畸形 JSON 用例通过 |
| 真实模型（模型服务已热身） | RC=0；5 轮均有非空回复；`history_tail` 为 2/4/4/4/4；无执行命令 |
| 可见 UI 探针（冷启动） | RC=1；无 `SCRIPT ERROR`，但首条消息在模型预热完成前超时，标题仍为“启动中（战略模型预热中…）”，状态断言失败 |
| 独立切局/迟到响应探针 | RC=1；6 项失败；旧局迟到回复实际进入新局聊天界面，旧适配层仍存在 |
| 定向套件 | 修复报告记录 8/8 marker 通过；其中部分套件仍有引擎泄漏/SCRIPT ERROR 噪声，不能只看 marker |
| 全量回归 | 未重新执行；沿用旧记录 86/116 不能当作本轮新证据 |

## 已确认的正向修复

- `parse_chat_completion()` 已改用 `JSON.new().parse()`，`{bad`、截断 JSON、数组、null、缺字段等用例不会刷 `Parse JSON failed`。
- 模型服务首条成功回复后会调用 `mark_ready()`，热身完成后的截图显示“副官未接管（战略聊天可用）”。
- 可见探针的安装等待已加上，当前不再出现之前的 `_chat_section` Nil 脚本错误。
- 暂停中聊天、503、挂起超时、重复发送抑制和资源/活动订单不变仍能跑通。

## 新发现的阻塞问题

### P0：冷启动时首条消息会超时

聊天区创建时会异步启动/预热模型，但玩家可以立即发送消息。实际可见运行中：

- 第 1 条消息等待约 47 秒后显示“等待战略层超时”；
- 此时顶部仍是“启动中（战略模型预热中…）”；
- 后续请求在模型热身完成后才成功。

这不是单纯测试问题。正常玩家第一次进入游戏也会遇到首条消息失败。应在模型 `starting/warming` 时禁用发送并显示预热状态，或将首条消息排队到 ready 后再发；不能让玩家先得到一次超时。

证据：[ui.log](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/ui.log)，重点是 `[UIPROBE] 第1问回复耗时=47.3s` 和标题断言失败。

### P0：切局没有真正释放旧适配层，迟到回复污染新局

独立探针在第一局启动 8 秒延迟桩请求，随后关闭/结束 Match 并重进。结果：

- 关闭聊天后 `old_adapter.is_busy()` 仍为 true；
- 新局中适配层数量为 2；
- 新局 `busy=true`，旧适配层没有释放；
- 旧局延迟回复“旧局回包审计标记”实际出现在新局聊天界面；
- 探针最终 `failures=6`。

这说明 `AdjutantButton` 的 `tree_exiting` 只把 `_installed` 置回 false，没有销毁旧 `_panel`、`_chat_adapter`、旧 HTTP 请求和相关控件。需要实现明确的 Match teardown，并验证迟到回包永远不能进入新局 UI。

证据：[lifecycle.log](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/lifecycle.log)，重点是 `[AUDIT] FAIL 旧局迟到回复不会写入新局聊天界面`。

## 运行产物

- 单测：[smoke_summary.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/smoke_summary.json)
- 热身后真实模型：[real_summary.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/real_summary.json)
- 冷启动 UI：[ui_summary.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/ui_summary.json)
- 切局独立探针：[lifecycle_summary.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/lifecycle_summary.json)
- 截图目录：[screenshots](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-fix-audit/screenshots)

## 下一步门槛

先只修两个 P0：模型 warming 时首条消息的排队/禁用策略，以及 Match 退出时完整释放旧聊天实例并隔离迟到响应。修复后必须重新跑冷启动可见 UI 探针和独立切局探针；二者均为 RC=0、失败数为 0 后，才可以重新讨论阶段 1 是否可验收。
