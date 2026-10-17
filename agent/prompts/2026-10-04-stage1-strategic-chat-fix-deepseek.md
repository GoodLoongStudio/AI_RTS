# 阶段 1 收尾修复提示词：战略聊天生命周期、解析和状态文案

你是 AI_RTS 仓库的代理工程师。当前阶段 1 的主链路已经存在，但独立复核仍发现三个硬问题。请在当前共享工作区直接修复并完成闭环，不要只报告分析结果。

开始前必须阅读：

1. `G:\AIRTS\AI_RTS\AGENTS.md`
2. `G:\AIRTS\AI_RTS\skills\闭环验证工作法.md`
3. `G:\AIRTS\AI_RTS\skills\AI_RSI自校验循环.md`
4. `G:\AIRTS\AI_RTS\agent\manifest.json`
5. `G:\AIRTS\AI_RTS\agent\reports\closed-loop\2026-10-04-stage1-reaudit.md`
6. `G:\AIRTS\AI_RTS\source\ui\AdjutantButton.gd`
7. `G:\AIRTS\AI_RTS\source\ui\AdjutantChatService.gd`
8. `G:\AIRTS\AI_RTS\tests\automated\_StrategicChatUIProbe.gd`
9. `G:\AIRTS\AI_RTS\tests\automated\StrategicChatServiceSmokeTest.gd`

先检查共享工作区状态、目标文件 mtime、当前日志和本地模型服务。禁止 reset、clean、checkout、覆盖或删除其他协作者的未提交改动。

## 唯一目标

把阶段 1 收尾到可以重新验收的状态：

1. 可见 UI 探针稳定等待副官面板安装完成，真实运行中能够完成展开、发送、回复、暂停、超时、503、重复点击和零副作用场景。
2. 任意畸形 JSON 都返回稳定 `invalid_output`，并且不让 Godot 打印 `Parse JSON failed`。
3. 战略聊天已经可用时，游戏内顶部副官状态不能继续显示“副官尚未启动”；必须显示清楚“战略聊天可用/已连接”，并保留“副官接管状态”和“战略聊天状态”的区别。

## 1. 修复 UI 探针生命周期

当前 `_StrategicChatUIProbe` 在 `_toggle_chat()` 时偶发 `_chat_section` 为 Nil，导致：

`SCRIPT ERROR: Invalid assignment ... at AdjutantButton.gd:2074`

请定位真实生命周期原因并做最小修复：

- 探针必须等待 `AdjutantButton._install()` 完成，至少确认 `_chat_section`、`_chat_adapter`、`_chat_input`、`_chat_status_label` 和 `_chat_send_button` 都是有效实例。
- 使用有上限的条件等待；超时必须明确失败并退出非零，不能通过跳过测试伪造成功。
- 不要用固定长 sleep 掩盖竞态。
- 验证关闭/重开聊天、结束 Match、重新进入 Match：旧请求要取消或变成陈旧响应；迟到回复不能写入新局；新局必须拥有新的 `conversation_id` 和新的适配层状态。
- 探针必须真正打印完整 `[UIPROBE]` 验收行，包括暂停时钟差、错误态、重复点击和零副作用；没有这些行不得判定通过。
- 清理本探针自己创建的 stub、Match、HTTP 请求和适配层，避免把探针自己的资源泄漏当成通过。

不要通过删除断言、忽略 `SCRIPT ERROR`、修改 expected marker 或把失败改成 warning 来修复。

## 2. 完整静默解析畸形 JSON

`AdjutantChatService.parse_chat_completion()` 目前只对“不像 JSON”的文本提前返回；`{bad` 和 `{"choices":` 仍进入 `JSON.parse_string` 并刷 Godot 错误。

请：

- 使用不会向引擎日志打印解析错误的 API（例如 `JSON.new().parse()`），读取返回码和 `get_data()`。
- 保持现有错误语义：非 200 为 `http_<code>`；空 content 为 `empty_output`；所有 JSON 语法错误、顶层类型错误、缺少 choices/message/content 都是 `invalid_output`。
- 补充单测，至少覆盖：普通非 JSON 文本、`{bad`、`{"choices":`、`[]`、`null`、缺 choices、空 content。
- 重跑冒烟测试并检查原始日志中没有 `Parse JSON failed`。

不要放宽非法响应判据，也不要把错误响应塞进历史记录。

## 3. 修复真实可见状态文案

最新截图中模型已经回复，但顶部仍显示“副官尚未启动”。请检查 `AdjutantModelService` 的 ready/warming 状态和 `AdjutantButton` 的状态刷新时序，修复实际运行路径，而不是只改字符串或单测。

最低要求：

- 未接管且模型还不可用：显示启动中、未连接或明确的不可用状态。
- 模型服务已经可用，或首条聊天成功返回后：顶部/副官状态区必须显示“战略聊天可用”或等价明确文案，不能再显示“副官尚未启动”。
- “AI 副官：接管”仍表示执行层接管，不得因为战略聊天可用就误显示已经接管。
- 聊天区状态、顶部副官状态和模型服务状态使用同一事实来源，避免一个显示已连接、另一个显示未启动。
- 增加或更新一个可见探针断言与截图，证明首条真实回复后文案已更新。

## 严格边界

本轮只修复阶段 1 收尾问题：

- 不实现战略计划 JSON、任务卡、确认计划、任务租约、Laya 选择、Laya 执行、事件重规划或任何新单位命令。
- 不调用 `adjutant_command`、`adjutant_batch`、`adjutant_intent`、`augment_pick`、`UnitCommandGateway` 或其他执行入口。
- 不修改地图、平衡、单位属性、生产、移动、攻击和资源规则。
- 不删除或放宽现有断言；不为了让 runner 变绿而修改判据。
- 修改范围优先限制在 `source/ui/**`、本阶段测试、`agent/runs/**`、`agent/reports/closed-loop/**` 和本提示词对应的计划文件。

## 必须完成的验证闭环

每次改动都要按 Controller → Explorer → Editor → Verifier 留下证据。至少完成：

1. 逐个解析/编译修改的 GDScript。
2. `StrategicChatServiceSmokeTest.tscn`：RC=0；日志无 `Parse JSON failed`。
3. 受影响定向套件：`strategic-chat-service`、`adjutant-model-service`、`adjutant-ui-state-consistency`、`traditional-command-hud`、`keyboard-shortcuts`、`fog-of-war-sight-range`、`unit-radius-coverage`、`adjutant-command-protocol`；记录每项 RC、marker 和 forbidden output，不能只报 marker。
4. 新鲜运行 `_StrategicChatUIProbe.tscn`：必须有完整 `[UIPROBE]` 行；无 `SCRIPT ERROR`、`Parse Error`、探针自身资源泄漏；确认运行中聊天、暂停聊天、超时、503、重复发送、资源不变、活动订单为空。
5. 真实模型连续 5 轮：记录 RC、回复、history_tail、延迟；确认模型没有产生执行命令。
6. 打开并肉眼查看最新的初始、回复、暂停、错误截图，确认旧 mock 入口不再出现，且顶部状态文案在聊天可用后正确。
7. 如运行全量回归，必须如实报告通过数、失败数和共享工作区归因；不能因为失败看起来与本轮无关就写“全量通过”。

## 交付物

完成后必须新增或更新：

- `agent/reports/closed-loop/2026-10-04-stage1-fix-report.md`
- `agent/runs/2026-10-04-stage1-fix/` 下的日志、截图、checklist 和验证记录

报告必须写明：改动文件、每轮 candidate/champion、测试命令和 RC、日志是否干净、截图路径、全量回归实际结果、未验证项和共享工作区风险。

只有 UI 探针、解析日志、状态文案和定向套件全部达到上述门槛，才能把阶段 1 标记为“可验收”；否则保持 `needs-review`，不要进入阶段 2。
