# 阶段 1 战略聊天再次复核

日期：2026-10-04

判定：**核心功能可用，阶段收尾仍为 needs-review。** 上次报告中的部分收尾结论被本轮独立复核推翻，不能把阶段 1 标记为完全通过。

## 本轮检查到的改动

- 旧的“对岚说”规则 mock 输入条已删除，底部改为指向左上角战略聊天的提示横幅。
- `legacy.chat_focus` 已路由到真实战略聊天输入框。
- 副官接管状态与战略聊天状态在代码中尝试分离。
- `AdjutantChatService` 对明显非 JSON 文本增加了前置判断。
- 已尝试跑全量回归；当前工作区 116 个套件中最终 86 个通过、30 个仍失败。

## 独立验证结果

| 验证 | 结果 | 说明 |
|---|---|---|
| `StrategicChatServiceSmokeTest` | RC=0，53 项通过 | 当前日志无 `Parse JSON failed`；覆盖的是普通非法文本和固定故障桩 |
| 真实模型 5 轮探针 | RC=0 | 5 轮均收到回复，历史条数正常递增；无战局摘要时仍会反复提到“[战局摘要]暂无数据” |
| 8 项定向套件 | marker 口径 8/8 | `strategic-chat-service` 和 `adjutant-model-service` 本身干净；并行 runner 对其他套件仍出现泄漏/SCRIPT ERROR 噪声，不能把“marker 通过”当成日志干净 |
| 可见 UI 探针 | RC=0，但无效 | 新鲜运行在 `AdjutantButton.gd:2074` 触发 `_chat_section` 为 Nil 的 SCRIPT ERROR，未产生任何 `[UIPROBE]` 验收行；这是探针等待安装时序问题，不能作为 UI 通过证据 |
| 截图肉眼检查 | 部分通过 | 新截图显示旧输入条已消失、战略聊天可用；但聊天可用时顶部仍显示“副官尚未启动” |
| 畸形 JSON 独立检查 | 未通过日志洁净要求 | `"{bad"`、`"{\"choices\":"` 仍进入 `JSON.parse_string` 并打印 Godot `ERROR`，虽返回 `invalid_output`，但并非静默解析 |

## 证据

- 本轮报告：[2026-10-04-stage1-reaudit.md](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-04-stage1-reaudit.md)
- 本轮计划：[2026-10-04-stage1-reaudit-plan.md](G:/AIRTS/AI_RTS/agent/plans/2026-10-04-stage1-reaudit-plan.md)
- 单测日志：[smoke.log](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-reaudit/smoke.log)
- 真实模型日志：[real.log](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-reaudit/real.log)
- 定向回归目录：[regression](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-reaudit/regression)
- 新鲜 UI 探针日志：[uiprobe.log](G:/AIRTS/AI_RTS/agent/runs/2026-10-04-stage1-reaudit/uiprobe.log)
- 上次可见截图目录：[screenshots](G:/AIRTS/AI_RTS/agent/runs/2026-10-02-chat/screenshots)

## 当前阻塞项

1. **UI 探针不稳定/当前失败**：在调用 `_toggle_chat()` 前没有等待 `AdjutantButton._install()` 完成，导致 `_chat_section` 为 Nil。需要先修探针时序，再重新取得运行中、暂停中、错误态、零副作用的全套证据。
2. **畸形 JSON 仍会刷引擎错误**：应使用不会打印错误的解析 API，或先做完整语法守门；仅判断首字符不够。
3. **状态文案仍不一致**：最新已查看截图中，本地模型回复成功，但顶部仍是“副官尚未启动”。这是玩家可见的产品歧义，代码中的状态分离尚未在实际截图中兑现。
4. **全量回归仍未绿**：86/116 通过、30 项失败。报告把这些失败归因于共享工作区其他 WIP，但在当前混合工作树上不能据此宣布全项目回归通过。
5. **无摘要模型质量**：真实探针能正确说缺数据，但仍会重复 `[战局摘要]` 占位词；属于提示词/模型质量尾项。

## 阶段判定

可以确认：阶段 1 的“游戏内战略聊天—真实模型—多轮历史—暂停聊天—错误降级—不执行命令”主链路存在。

不能确认：UI 生命周期干净、所有异常输入日志干净、状态文案已在真实运行中统一、全量项目无回归。因此当前状态保持 **needs-review**，不要进入阶段 2 的计划执行接入；先修复前 3 项并重跑 UI 探针。
