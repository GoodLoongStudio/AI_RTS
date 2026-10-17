# 阶段 1 收尾修复报告

日期：2026-10-04
提示词：`agent/prompts/2026-10-04-stage1-strategic-chat-fix-deepseek.md`
复核输入：`agent/reports/closed-loop/2026-10-04-stage1-reaudit.md`

## 结论：阶段 1 达到"可验收"状态

reaudit 的 3 个阻塞项（探针生命周期、畸形 JSON 引擎报错、状态文案不一致）全部修复，
可见探针 18 PASS / 0 FAIL / 0 SCRIPT ERROR，冒烟 rc=0 无 Parse JSON failed，
定向套件 8/8 rc=0，真模型 5 轮 rc=0。全量回归 86/116（30 红归因并行 WIP，见 §6）。

## 改动文件

| 文件 | 改动 |
|---|---|
| `source/ui/AdjutantChatService.gd` | JSON.parse_string → JSON.new().parse()（静默）；缺 content 键 → invalid_output（与空 content → empty_output 语义拆分）；mark_ready 联动 |
| `source/ui/AdjutantModelService.gd` | 新增 `mark_ready(model)` 静态方法：聊天首条成功回复确认端点可用 |
| `source/ui/AdjutantButton.gd` | ①聊天区创建时调 ensure_started（模型服务自动保障覆盖聊天路径）；②`_on_chat_reply` 成功后立即 `_update_status_line()`；③`_update_status_line`/`current_state_text` 未接管+模型就绪 → "已停止（战略聊天可用）"；④聊天输入框接入文本输入模式（防打字触发快捷键）；⑤`focus_strategic_chat()` 热键落点 |
| `source/match/hud/AICommandHUD.gd` | 删除旧"对岚说"规则 mock 输入条（字符串解析+假延迟+预置话术）；底部横幅指向真实入口；`legacy.chat_focus` 热键路由到战略聊天；清理 `_input`/`_mock_agent_busy`/`_ask_mock_agent`/`_respond_to_ai_question`/`_parse_ai_question`/`player_text_submitted` 残留 |
| `tests/automated/_StrategicChatUIProbe.gd` | 生命周期修复：有界等待安装（30s/0.25s 轮询，超时非零退出）；headless 直接失败；状态文案断言；关闭/重开/重进场景；[UIPROBE-PASS/FAIL] 逐项打点 |
| `tests/automated/StrategicChatServiceSmokeTest.gd` | 新增 7 个畸形 JSON 用例（{bad/{"choices":/[]/null/缺choices/缺content/空content）+ 缺content→invalid_output 与 空 content→empty_output 语义拆分 |

## 三个阻塞项修复明细

### 1. UI 探针生命周期（`_chat_section` Nil）

**根因**：复核把探针跑在 headless——`_install()` 开头 `if DisplayServer.get_name() == "headless": return`，
面板/聊天区在 headless 永不创建 → `_toggle_chat()` 必然 Nil。

**修复**：探针开头检测 headless → FAIL 退出非零（这是产品语义而非测试绕过）；
`_wait_for_install()` 有界等待（30s / 0.25s 轮询），检查 `_panel`、`_chat_adapter`、
`_chat_section`、`_chat_input`、`_chat_status_label`、`_chat_send_button` 全部有效。
产品侧 `_toggle_chat()` 加空值防护。

### 2. 畸形 JSON 静默解析

**根因**：`JSON.parse_string()` 失败时引擎必然打印 `Parse JSON failed`（无法关闭）。

**修复**：改用 `var json := JSON.new(); json.parse(trimmed); json.get_data()` —
实例方法不打印引擎错误，错误码由调用方读取。`{bad`、`{"choices":` 等语法坏体
不再产生任何引擎日志。语义拆分：缺 content 键（结构错误）→ invalid_output；
content 键存在但值空白 → empty_output。

### 3. 状态文案不一致

**根因**：聊天路径（无 runner）从不调用 `ensure_started()`，模型服务状态机停在 ""，
`is_ready()` 恒 false → 顶部恒"副官尚未启动"，即使聊天已成功回复。

**修复**（运行路径，非字符串替换）：
①聊天区创建 → `ensure_started(self)`（Ollama 运行中 → warming → ready）；
②首条成功回复 → `mark_ready()` + `model_confirmed_ready` 信号；
③面板 `_on_chat_reply` → 立即 `_update_status_line()`（不等 5s 轮询）；
④`_update_status_line` 未接管 + `is_ready()` → 标题 "🔹 已停止（战略聊天可用）"。
探针截图验证：标题 "🔹 已停止（战略聊天可用）"，"岚"标题 "● 副官未接管（战略聊天可用）"。

## 测试命令与 RC

| 命令 | rc | 关键输出 |
|---|---|---|
| `--headless ... StrategicChatServiceSmokeTest.tscn` | **0** | 0 failures，**0 次 Parse JSON failed** |
| `--headless ... _StrategicChatRealModelProbe.tscn` | **0** | 5 轮 rc=0 |
| `--path ... _StrategicChatUIProbe.tscn`（可见） | **0** | 18 PASS / 0 FAIL / 0 SCRIPT ERROR |
| `python tools/run_parallel_suites.py --jobs 4 --ids`（8 套件） | **0** | 8/8 通过（含串行复核） |
| `dotnet build`（本阶段无 C# 改动） | — | — |

## 定向套件明细（RC + marker + forbidden output）

| id | rc | marker | forbidden output |
|---|---|---|---|
| strategic-chat-service | 0 | `completed: 0 failure(s)` | 无 |
| adjutant-model-service | 0 | `completed: 0 failure(s)` | 无 |
| adjutant-ui-state-consistency | 0 | `completed: 0 failure(s)` | ObjectDB leaked（引擎退出噪声） |
| adjutant-command-protocol | 0（串行复核） | `completed: 0 failure(s)` | ObjectDB/RID leaked（同上） |
| traditional-command-hud | 0 | `completed: 0 failure(s)` | 无 |
| keyboard-shortcuts | 0 | `completed: 0 failure(s)` | ObjectDB/RID leaked（同上） |
| fog-of-war-sight-range | 0 | `completed: 0 failure(s)` | 无 |
| unit-radius-coverage | 0 | `completed: 0 failure(s)` | SCRIPT ERROR（既有，非本阶段） |

## 全量回归（116 套件，2026-10-03 数据 + 本轮复核）

86/116 通过，30 红。30 红归因并行在途 WIP（证据链见 10-03 报告 §13）：
音乐配置缺 `peace` 键、新增 Scout 单位缺语音映射、APC.tscn 在途修改、
rule-ai-economy-query 基线同红（stash 归因）等。本阶段改动影响的套件全绿。
**不因此宣布"全项目回归通过"**——合流后由对应会话收尾。

## 真模型 5 轮

| 轮 | history_tail | 回复摘要 |
|---|---:|---|
| 1 | 2 | 引用 [战局摘要] 说明缺乏数据支撑 |
| 2 | 4 | 同上，追问经济优先级 |
| 3 | 4 | 引用摘要说明无法判断资源紧张程度 |
| 4 | 4 | 引用摘要说明无法判断北侧派兵 |
| 5 | 4 | 引用摘要说明缺乏资源配置数据 |

注：本轮无战局摘要（探针无 provider），模型正确说"摘要中没有"而**没有编造**——
这正是"无摘要幻觉防护"的预期行为。有摘要时的引用行为见 55 轮马拉松（§11）。

## 截图

`agent/runs/2026-10-04-stage1-fix/screenshots/`：
`01_opened.png` `02_waiting.png` `03_replied.png` `04_paused_chat.png` `05_timeout.png` `05_error.png`
全部已实际打开检查。

## 状态文案截图确认

- 顶部（岚面板）："● 副官未接管（战略聊天可用：展开下方聊天区）" ✓
- 面板标题："🔹 已停止（战略聊天可用）" ✓
- 聊天区状态行："已回复（1.8s · minicpm5-adj-16k）" ✓
- "AI 副官：接管"按钮文本不变（仍表示执行层接管）✓
- 不再出现"副官尚未启动" ✓

## 未验证项 / 共享工作区风险

1. **全量回归 30 红**：并行在途 WIP（单位尺寸/平衡/语音/音乐），合流后由对应会话收尾。
2. **连接拒绝真实路径**：本机防火墙把端口拒绝转超时兜底（503/挂起桩覆盖同一管线）。
3. **并行会话编辑 Movement.gd / Tank.tscn / Infantry.tscn**：本任务不触碰这些文件；
   `Tank.tscn` 在 10-02 01:09 被并行修改过。
4. **模型服务（ollama serve 11436）**：仍在后台运行。如需关闭按 pid 结束即可。

## 回退方式

```bash
git checkout -- source/ui/AdjutantChatService.gd source/ui/AdjutantButton.gd \
  source/ui/AdjutantModelService.gd source/match/hud/AICommandHUD.gd \
  tests/automated/StrategicChatServiceSmokeTest.gd tests/automated/_StrategicChatUIProbe.gd
# 新增文件（不受 git 管理）：rm 各探针/桩/套件文件
# config/full_regression_suite.json 移除 strategic-chat-service 条目
```


## 14. 第二轮收尾（2026-10-05，按 `2026-10-04-stage1-fix-audit-report.md` 修两个 P0）

独立复核发现两个新 P0，已修复并重新验收：

### P0-1 冷启动首条消息超时

**根因**：聊天区创建时 `ensure_started()` 异步启动模型预热，但 `send()` 不检查预热状态，
HTTP 请求直接发到正在冷加载的 Ollama（首次载入 ~47s），60s 超时先到 → 首条必然超时。

**修复**：`send()` 开头检查 `ModelService.state() in ["starting","warming"]` → 不发 HTTP，
排队消息到 `_warming_queued_message`，启动 2s 轮询 timer 等 `is_ready()` 后自动发送。
面板状态行显示"等待战略层…"（现有逻辑已覆盖）。`error_text("model_warming")` 也已加。

### P0-2 切局不释放旧适配层 / 迟到回复污染新局

**根因**：`_build_chat_section()` 每次创建新 `AdjutantChatService.new()` 但**不释放旧实例**——
旧适配层挂在 AdjutantButton（autoload）下永不释放，其 `reply_ready` 信号仍连着
`_on_chat_reply`，迟到回复直接写入新局 UI。`_exit_tree()` 也不清理适配层。

**修复**：
①`_build_chat_section()` 创建新适配层前：`cancel_pending()` + 断开 `reply_ready` + `queue_free()` 旧实例；
②`_exit_tree()` 释放适配层；
③`_on_chat_reply` 开头加 `conversation_id` 守门（新旧不匹配 → 丢弃）。

## 验证（修复后）

| 场景 | 结果 |
|---|---|
| 冒烟 53 断言 | rc=0 |
| 可见探针 11 场景 | **0 FAIL / 0 SCRIPT ERROR / 18 PASS** |
| 暂停时钟 | 差 0 ✓ |
| 零副作用 | 资源未扣、订单空 ✓ |
| 重进对局 | 新 conversation_id、历史清空 ✓ |
| 定向 8 套件 | 8/8 rc=0 |

## 截图

`agent/runs/2026-10-04-stage1-fix/screenshots/01_opened.png`（初始态含旧入口已移除、指向性横幅、
聊天区状态行"未连接（发送后自动连接本地战局模型）"）等已打开检查。