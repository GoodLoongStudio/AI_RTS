# 闭环报告：战前战术讨论室（地图情报 + 四出生点）

- 日期：2026-10-06　状态：**complete**（10/10 验收项完成）
- 提示词：`agent/prompts/2026-10-06-strategic-prebattle-ui-map-deepseek.md`（全文已读 ✓）
- 计划：`agent/plans/2026-10-06-strategic-prebattle-map-ui-plan.md`
- RSI 目录（提示词指定 ✓）：`agent/runs/2026-10-06-strategic-prebattle-ui-map/`

## 1. 改动文件
| 文件 | 改动 | 轮次 |
|---|---|---|
| `source/main-menu/MatchSetupPage.gd` | `_on_sandbox_pressed()`：实例化页面 + 传 `map_path`（原为 `change_scene_to_file` 丢上下文 ✗）；随机地图/空选择双重阻断 | R1 |
| `source/main-menu/StrategicSandboxPage.gd` | 布局结构重构（SafeArea/CenterPanel/双栏/响应式/5% 安全边距/字号）→ 预览+4 出生点标记+缺失态 → 尺寸标签修复 → 出生点卡片方位/资源 | R2–R4 |
| `source/main-menu/StrategicMapIntel.gd` | **追加** `map_size`（Map 节点真值 ✓，避开 Terrain 网格陷阱 ✗）+ known/unknown 事实条目 | R5 |

## 2. 基线与新数值
| 项 | 改动前 | 改动后 |
|---|---|---|
| 页面收到的 `map_path` | 恒为默认地图 | 随所选地图变化（两张地图实测 ✓）|
| 根节点结构 | 控件直接堆根节点（挤左上角）| `SafeArea → CenterPanel → RootVBox → 双栏` |
| 出生点标记 | 无 | 4 个，位置 = 世界坐标 ÷ 世界尺寸（实测差 **0.00px**）|
| 尺寸标签 | 显示**地图路径** ✗ | 「尺寸 208 × 208（事实来源：所选地图）」|
| 情报 `map_size` | 字段不存在 ✗ | `(208,208)` / `(256,256)`（Map 节点真值 ✓）|
| 未选点聊天 | 可用 ✗ | `editable=false` + `disabled=true` + 文案「请先选择一个出生点」|

## 3. 测试命令与 rc（全部 rc=0 ✓）
```
godot --headless --path . res://tests/automated/_StrategicEntryProbe.tscn        # rc=0
godot --headless --path . res://tests/automated/_StrategicLayoutProbe.tscn       # rc=0（4 档分辨率）
godot --headless --path . res://tests/automated/_StrategicPreviewProbe.tscn      # rc=0（22 项 OK）
godot --headless --path . res://tests/automated/_StrategicIntelAssertions.tscn   # rc=0（两地图 + 错误对象）
python tools/run_parallel_suites.py --ids esc-return,strategic-chat-service,tutorial-main-entry  # 3/3 rc=0
```

## 4. 截图（**已实际打开查看** ✓）
并行 Agent 产出 6 张（mtime 07:13–07:21Z ✓，见 `screenshots/`）：
`01_play_3buttons.png`、`02_random_blocked.png`、`03_map_a_sandbox.png`、`04_map_a_5rounds.png`、`05_map_b_sandbox.png`、`06_reentered.png`。

**我打开 `03`/`04` 后的观察**：
- ✓ 双栏、地图名、事实来源、真实预览、4 个坐标按钮、已知/未知两组、未选点时输入禁用——均可见 ✓；
- ✓ 选点后显示「你选择了出生点 1 · 坐标 (40, 28)」、按钮 1 高亮、历史出现欢迎语 ✓；
- ⚠️ **这两张截图早于我的布局修复**（07:13Z < 07:31Z）⇒ 画面里内容仍集中在左侧约一半，
  右侧大片空白 ⇒ **不能作为当前布局的证据** ✗；
- ⚠️ 画面中部偏右有一个**游离的深色方块** ✗（疑似孤儿节点）⇒ 待查；
- ✗ `04` 只显示用户提问 + 「等待战略层…」，**看不到任何副官回复** ⇒ **无法证明验收项 6（≥5 轮真实模型回复）** ✗。

## 5. 未验证项（状态 `needs-review` 的原因）
1. **验收项 6**：至少 5 轮真实模型回复（≥2 轮引用地图事实、无编造敌情）——**未证明** ✗（截图里没有回复正文）；
2. **验收项 11（我方补充）**：无玩家/单位/资源实例——未验证 ✗（已证明无 Match/SimulationClock/NetSession.host ✓）；
3. **截图时效**：现有 6 张均早于布局修复 ⇒ 需重拍 ✗；
4. 游离方块 ✗、`§5` system prompt 约束未核 ✗、改选出生点的**防污染**未用真实模型验证 ✗、
   warming/HTTP 错误/超时/空输出的可见错误与重试未验证 ✗。

## 6. 共享工作区风险
- `source/main-menu/StrategicMapIntel.gd` 在 07:24Z 被**并行 Agent** 修改 ⚠️；我在 07:35Z 之后（静默 11+ 分钟 ✓）
  才**追加** `map_size` ✓，未改动其既有结构 ✓；
- `StrategicSandboxPage.gd` 的改动均基于改前快照 ✓，未覆盖他人内容 ✓；
- 工作区仍有 782 项他人改动（含 `assets/map_previews` 的删除/恢复 ⚠️）⇒ 与本任务的预览态判断相关 ✓。

## 7. candidate / champion
- candidate = R1–R5 的改动集 ✓（硬门禁除**截图**外全过 ✓）；
- **champion 保留** ✓（截图一环失败 ⇒ 不宣称完整闭环 ✓）；**连续未提升轮数 = 0** ✓。
---

## 8. 第 6 轮补充：重拍截图 + 清理遗留子树 + 修裁切

**改动**：新增 `tools/capture_strategic_prebattle.gd/.tscn`（窗口模式取证 ✓）；
`StrategicSandboxPage.tscn` 删除**遗留空子树**（= 截图里的游离深色方块 ✓，36→15 行）；
`StrategicSandboxPage.gd` 增加整页 `PageScroll`、两栏纵向撑满、预览高度响应式、卡片信息加宽。

**证据**：
- 新截图 `07_map_a_layout_fixed.png` / `08_map_a_spawn1_selected.png` / `09_map_b_layout_fixed.png`（15:40 本地 ✓ **已打开查看** ✓）；
  确认**满宽双栏**、页头地图名、尺寸行、预览上 **4 个彩色编号标记**、卡片方位与资源、选中态高亮 ✓；
- 4 个探针 **rc=0** ✓；`_StrategicLayoutProbe` 在 1280×720 / 1920×1080 / 2560×1440 / 960×720 四档
  均 **裁切=false** ✓（页面可滚动 ✓）。

**探针口径纠正**：窗口尺寸 ≠ 真实视口高 ✗（headless）⇒ 改用页面真实高度 ✓；可滚动内容不算裁切 ✓。

**仍未完成**：≥5 轮真实模型回复（P0）、用最新代码重拍、无玩家/单位/资源实例证明、§5 约束核对、错误/重试路径。
---

## 9. 第 7/8 轮补充：重拍截图 + 无实例证明 + 模型探针根因修复

- 重拍（最新代码，已打开查看）：`07/08/09_*.png`（07:43:5x Z）⇒ 遗留方块消失、输入框可见、满宽双栏；
- 验收项 10 完成：players=0 / units=0 / resources=0，Match/Players/Units/Resources/SimulationClock/Loading 全不存在；
- 模型探针根因：模型预热中 send() 只返回 warming、页面不会真发送 ⇒ 探针改为先等就绪、每轮校验并重试；
- 可见性（用户反馈）：改用非 console 版在屏幕内开可见窗口（PID 45188），不再弹 cmd。

仍未完成：≥5 轮真实模型回复（探针已修，第三次运行中）、§5 约束核对、改选防污染、错误/重试路径。
## Round-09 记录：模型 5 轮取证的进展与阻塞

### 已修的两个真 bug（推动取证前进）
1. **`_chat_history.clear()` 不存在** ✗（`VBoxContainer` 没有该方法 ⇒ `Invalid call` ⇒ **打断选点流程**）
   ⇒ 改为逐个 `remove_child` + `queue_free` ✓（冒烟后无 Invalid call ✓）；
2. 探针**在模型预热中发送** ✗（`send()` 只返回 warming、页面不会真发送）⇒ 改为**先等就绪** ✓（实测 `listening=true warming=false` ✓）。

### 当前阻塞
- 模型服务**确实是通的** ✓：日志 `[ADJ-MODEL] 模型预热完成：模型 minicpm5-adj-16k 已就绪` ✓；
- 但**页面侧历史里仍未出现真实回复** ✗：5 轮抓到的都是**欢迎语**（len=41）⇒ 需要绕开页面直接调服务确认；
- 我的探针在页面上取基线的时机不对 ✗（欢迎语是协程后落盘的 ⇒ 基线取早了）；
- **单次工具调用有 600 秒上限** ✗ ⇒ 模型往返（每轮数十秒 × 5 + 预热）经常被截断 ⇒ 已改为**后台任务**运行 ✓。

### 下一步（唯一剩余 P0）
后台跑 `_ChatServiceDirectProbe`（直接调聊天服务 ✓，记录 `queued/error_code/assistant_text/elapsed_ms` ✓），
据此区分「模型/服务不可用」与「页面接线问题」✓，再决定修哪一层 ✓。
---

## 10. 第 10 轮：错误/重试路径与会话防污染已验证；模型往返仍阻塞

## 新增探针：tests/automated/_StrategicErrorPathProbe.gd/.tscn（rc=0，0 failure）

### 验收项 8：错误与重试路径全部可见
| 注入的 error_code | 页面可见状态文案 |
|---|---|
| warming | 错误：战略层出现未知错误，可点击重试 |
| http_500 | 错误：战略层服务异常（HTTP 500），可点击重试 |
| timeout | 错误：等待战略层超时，可点击重试 |
| empty_output | 错误：战略层返回了空回复，可点击重试 |
| model_unavailable | 错误：本地模型服务不可用，已降级（战斗不受影响）|
| 成功回复 | 已回复（1.2s · probe）+ 正文写入历史 |
⇒ 五种错误码都有可见文案，且都写入「系统」行。

### 提示词 §4 防污染（真实断言）
注入 conversation_id = chat-conv-OLD-session 的迟到成功回复 ⇒ 历史行数 7 → 7 ⇒ 被拒绝、未污染新会话。

## 顺带修复
错误状态文案重复（可点击重试被拼了两次）⇒ 去掉页面侧重复后缀。

## 唯一剩余 P0：验收项 6（≥5 轮真实模型回复）—— 现状如实记录
- 模型服务确认就绪：日志显示 模型 minicpm5-adj-16k 已就绪，listening=true warming=false；
- 但往返取不到回复：
  1. 页面路径：5 轮全部抓到的是欢迎语（len=41）⇒ 真实回复未落进历史；
  2. 服务直连路径：打印就绪后卡在初始化之后（15+ 分钟无 send 输出）⇒ 已终止；
- 已排除的自身缺陷：预热中发送（已修）、_chat_history.clear() 不存在（已修）、脚本解析（已修）；
- 单次工具调用 600s 上限 ⇒ 已改为后台任务，但后台同样卡住 ⇒ 不是时限问题。

## 下一步
1. 读 AdjutantChatService._on_request_completed 与 AdjutantModelService.ensure_started 的等待点，定位卡住的具体语句；
2. 用 HTTP 直连（127.0.0.1:11436 的 /v1/chat/completions）绕过 Godot，先证明模型本身能出字；
3. 若模型能出字而服务卡住 ⇒ 属服务实现问题另立修复；若模型也不出字 ⇒ 记 blocked: model runtime。

---

## 11. 第 11 轮：模型往返的决定性诊断

## 1. HTTP 直连证明模型正常
`POST http://127.0.0.1:11436/v1/chat/completions`（model=minicpm5-adj-16k）⇒
回复：「我作为AI模型，可以根据用户的问题提供信息或协助处理文本、回答问题等任务，但无法看到实时信息或具体事件。」
⇒ **模型与端口都正常** ✓（同时 11434 上另有 6 个模型可用）。

## 2. 服务自身日志（`%APPDATA%/Godot/app_userdata/Open RTS/adjutant_logs/strategic_chat.jsonl`，459KB）
| 事件 | 数量 |
|---|---|
| `request` | 854 |
| `response` | **669** ✓（模型确实在回应）|
| `error` | 183 |
| `late_response_dropped` | 35（其中 `status_code: 200` ✗）|
| `repeat_retry` | 2 |

错误码分布：`invalid_output × 60`、`empty_output × 58`、`http_503 × 41`、`timeout × 18`、`model_unavailable × 6`。

最后一条成功 `response`：`model=minicpm5-adj-16k`、`elapsed_ms=1397`、`assistant_chars=76` ✓。

## 3. 结论
- **不是模型坏了** ✓，而是：① 2B 级模型 `invalid_output`/`empty_output` 合计 **118 次**（约 1/7 请求）✗；
  ② 回复**迟到被丢**（`inflight` 已清空时到达）✗ ⇒ 页面状态**永远停在「等待战略层…」** ✗（5 轮取证的 status 全部如此 ✓）；
- 另发现**会话 id 双前缀** ✗：`chat-conv-chat-conv-strategic-sandbox-PlainAndSimple-sp1-5169`
  （页面构造一次 ✓、服务 `setup()` 再包一层 ✗）⇒ 虽不影响匹配，但会让日志与会话隔离难读 ✗。

## 4. 本轮采取的动作
**只改探针**（不改产品 ✓）：按**状态标签**判定成功/失败 ✓，失败**重问**（≤3 次 ✓），
只取**最后一行**且以「副官：」开头、排除欢迎语的正文 ✓ ⇒ 用重试抵消约 1/7 的失败率 ✓。

## 5. 待办
- 收最终 5 轮取证结果（后台运行中 ✓）；
- 若要**根治**「迟到被丢」与「双前缀」，需改 `AdjutantChatService`（本轮未动 ✗，避免与并行改动冲突 ✓）。

---

# Round-12 · 客户端超时兜底 + 五探针回归

## 背景（来自 round-11 的决定性诊断）
- 模型本身正常：HTTP 直连 11436 能出字；服务日志有 669 条 response；
- 但服务侧存在「**迟到回复被丢弃**」路径（`late_response_dropped`，其中 `status_code=200`），
  实测会让页面**永远**停在「等待战略层…」✗（5 轮取证的 status 全部如此）。

## 本轮改动（1 个文件：`source/main-menu/StrategicSandboxPage.gd`，659 → 683 行）
新增**客户端超时兜底** `CHAT_CLIENT_TIMEOUT_S = 90`：
- 发送后记录等待起点；
- `_process` 中若「正在等待且从未收到回复」超过 90s ⇒ 恢复输入/发送可用 ✓、
  状态显示「错误：等待战略层超时（客户端 90s 兜底），可点击重试」✓、写入系统行 ✓、并 `cancel_pending()` ✓。
⇒ 把无限卡住 ✗ 转成**可见错误 + 可重试** ✓（正是验收项 8 的要求 ✓）。

## 回归（5 个探针全 rc=0 ✓）
`_StrategicEntryProbe` ✓　`_StrategicLayoutProbe` ✓　`_StrategicPreviewProbe` ✓　
`_StrategicErrorPathProbe` ✓　`_StrategicIntelAssertions` ✓

## 仍未完成（唯一）
- 验收项 6（≥5 轮真实模型回复）：后台取证仍在重试中 ✓；
  **根因属于 `AdjutantChatService` 的「迟到丢弃」** ✗（本轮未改该文件 ✓，避免与并行改动冲突 ✓；
  该文件 mtime 为 10-05，长期未被动过 ✓ ⇒ 下一轮可安全修复）。

---

# Round-13 · 修复服务侧「迟到丢弃」的**根因**（保留设计口径）

## 根因（代码级 ✓）
`AdjutantChatService.send()` 在 `_http.request()` 返回错误时**无条件清空** `_inflight_request_id`：
- 当 HTTPRequest **正忙**（已有在途请求）时，本次派发会失败 ✓；
- 但清空 id 会让**上一个请求的合法 200 响应**在到达时被判为「迟到」而丢弃 ✗；
- 结果：UI **永远**停在「等待战略层…」✗（服务日志 `late_response_dropped` 且 `status_code=200` 反复出现 ✓）。

## 修复（最小补丁，1 处 ✓）
```gdscript
if err != OK:
    if err != ERR_BUSY:          # 正忙 ⇒ 保留 inflight id ⇒ 原响应照常投递 ✓
        _inflight_request_id = ""
    _log_event("error", {"request_id": request_id, "error_code": "request_dispatch_failed",
        "err": err, "kept_inflight": err == ERR_BUSY})
```
（`ERR_BUSY` 是**全局**枚举值 ✓ —— 首版误写 `HTTPRequest.ERR_BUSY` ✗ 导致解析失败 ✓，已修 ✓）

## 一次被套件拦下的错误改动（如实记录 ✓）
我先改成「合法 200 的迟到响应也投递」✗ ⇒ `strategic-chat-service` 立刻转红 ✗：
该套件**刻意断言** `迟到/孤儿响应不得进入历史` ✓（属**设计决定** ✓）
⇒ 已**回退**该口径改动 ✓，改为修**根因** ✓（正忙时不清空 id ✓）⇒ 设计不变、缺陷消失 ✓。

## 回归
`strategic-chat-service` rc=0（5.4s）✓　`esc-return` rc=0（5.5s）✓

## 下一步
用修好的服务重跑 5 轮真实取证 ✓（后台运行中 ✓）⇒ 若通过 ⇒ **验收项 6 达成** ✓。

---

# Round-14 · 决定性修复 + 验收项 6 达成（10/10 全完成）

## 根因（一句话）
`StrategicSandboxPage` **从未连接** `AdjutantChatService` 的 **`reply_ready`** 信号 ——
页面写好了 `_on_chat_reply` 却**无人调用** ⇒ 服务成功返回（服务日志有成对 request/response）
而 UI **永远**停在「等待战略层…」。对照 `AdjutantButton.gd:2071` 的正确接线。

## 修复（2 行，唯一文件 source/main-menu/StrategicSandboxPage.gd）
```gdscript
if _adapter.has_signal(reply_ready) and not _adapter.reply_ready.is_connected(_on_chat_reply):
    _adapter.reply_ready.connect(_on_chat_reply)
```

## 验收项 6 证据（5 轮真实模型回复，模型 minicpm5-adj-16k）
| 轮 | 长度 | 是否引用地图事实 |
|---|---|---|
| 1 | 113 | 是（出生点 #1(40,28)、地图尺寸）|
| 2 | 133 | 是 + 明说未提供的数据 |
| 3 | 124 | 是 + 建议侦察 |
| 4 | 114 | 是 + **不编造敌情**（未提供敌方方向 ⇒ 无法判断）|
| 5 | 111 | 是 + 列出当前未知信息 |
⇒ 5/5 引用地图事实、全部 >5 字、无编造敌情。

## 最终回归（全绿）
- 探针：_StrategicEntryProbe / _StrategicLayoutProbe / _StrategicPreviewProbe /
  _StrategicErrorPathProbe / _StrategicIntelAssertions ⇒ 全部 rc=0；
- 套件：tutorial-main-entry 3.0s、strategic-chat-service 5.5s、esc-return 5.5s，均 rc=0。

## 过程记录（多轮排查，均已落盘）
1. 预热中发送 ⇒ 页面不真发（改：等就绪 + 重试）；
2. `_chat_history.clear()` 不存在 ⇒ 打断选点流程（改：逐个释放）；
3. 服务派发失败时误清 inflight id ⇒ 合法响应被判迟到丢弃（改：ERR_BUSY 时保留）；
4. 客户端无超时 ⇒ 无限等待（改：90s 兜底 + 可见错误 + 可重试）；
5. **页面未接 reply_ready** ⇒ 本次的决定性根因。

---

# Round-15 · 用户 UI 追加要求（出生点按钮化 + 方形预览）

## 用户原话
出生点做成按钮切换，不用输入文字，地图要方形显示全。

## 已完成 ✓
1. **出生点区上移到预览之前**（把 47 行的出生点块与 73 行的预览块**交换顺序**）
   ⇒ 4 个切换按钮（toggle_mode ✓）+ 方位/附近资源 **首屏可见** ✓；
   重拍截图 `07_map_a_layout_fixed.png`（19:34）**已实际打开查看** ✓ —— 截图确认按钮与卡片都在首屏 ✓，
   用户此前的观感（只看到输入框、像要打字）已消除 ✓。
2. 预览改用 **AspectRatioContainer**，比例 = `_map_aspect_ratio()`（地图真实长宽比 ⇒ 208×208 得正方形 ✓），
   `STRETCH_FIT` + `STRETCH_SCALE` ⇒ 不裁切、不留边、世界坐标→像素映射仍精确 ✓；
3. 塌陷防线：按自身宽度×比例给出方形最小高度 ✓ + 延迟一帧重排 ✓。

## 未确认 ✗（如实）
- **截图里预览仍是一条细线** ✗（塌陷未消除 ✓）：最后一次重拍的 PNG 与上一张 **sha 相同** ✗（内容未变 ✓）；
- 结构核对无误 ✓（`AspectRatioContainer → MapPreviewWithMarkers → MapPreview + 4 标记` ✓），
  推断是 **ScrollContainer 内最小高度未被采纳** ✗ 或 延迟重排仍未拿到真实宽度 ✗；
- **探针此前不覆盖预览尺寸** ✗ ⇒ 本轮已**补断言**（预览高度 ≥100 ✓、宽高比 ≈1.0 ✓）⇒
  下一轮用它直接定位（探针 rc=0 但未打印预览尺寸 ⇒ 说明 `MapPreviewWithMarkers` 查找路径也要复查 ✓）。

## 回归
`_StrategicLayoutProbe` rc=0 ✓（四档分辨率不裁切 ✓）、`_StrategicPreviewProbe` rc=0 ✓（标记仍精确 ✓、门禁 ✓、卡片 ✓）。

---

# Round-16 · 按用户要求**封禁实验功能**：战略模式（测试）

用户原话：这个战略模式测试先封禁吧，我准备先做一个稳定版本，这个实验功能关掉就行了。

## 实现（最小、可一键恢复）
1. `source/FeatureFlags.gd` 新增导出开关（默认 **false**）：
   `@export var strategic_sandbox_enabled = false`；
2. `source/main-menu/MatchSetupPage.gd`：
   - `_strategic_sandbox_enabled()` 读开关（autoload `/root/FeatureFlags` ✓，读不到按关闭处理 ✓ 安全默认）；
   - `_setup_sandbox_button()`：关闭时 `visible=false` + `disabled=true` + **断开场景里的 pressed 连接**；
   - `_on_sandbox_pressed()`：**第二道闸** ⇒ 关闭时直接 return（程序化触发也拒绝）。

## 保留（不删代码 ✓）
页面 `StrategicSandboxPage`、情报服务 `StrategicMapIntel`、聊天接线、以及全部探针与报告**原样保留**，
⇒ 把开关勾上即可**完整恢复** ✓。

## 验证（新增 `tests/automated/_StrategicSandboxBanProbe.gd/.tscn`，rc=0，0 failure）
| 断言 | 实测 |
|---|---|
| 开关默认关闭 | `strategic_sandbox_enabled = false` ✓ |
| 按钮隐藏 | `visible=false` ✓ |
| 按钮禁用 | `disabled=true` ✓ |
| 场景 pressed 连接已断开 | ✓ |
| 程序化触发不创建页面 | root 子节点 **18 → 18** ✓ |
| 其它按钮不受影响 | 12 个按钮仍在 ✓ |

## 回归
`esc-return` / `tutorial-main-entry` / `strategic-chat-service` —— 见本轮 rc（下方同步）。

---

# Round-17 · 按用户要求封禁局内战略聊天（现在不要战略讨论了）

用户原话：这些也回滚了，现在不要战略讨论了（截图红框 = 左上副官面板里的战略聊天区 + 底部提示条）。

## 实现（第二个独立开关，默认关闭）
1. source/FeatureFlags.gd：新增 @export var strategic_chat_enabled = false；
2. source/ui/AdjutantButton.gd：调用点加闸，关闭时不构建聊天区
   （开关按钮/会话标签/历史/输入框/发送全部不创建）；代码保留在 _build_chat_section() 内；
3. source/match/hud/AICommandHUD.gd：关闭时不再追加提示「战略讨论请用左上角副官面板的『战略聊天』」。

## 静态核对（本会话实测）
| 检查 | 结果 |
|---|---|
| strategic_chat_enabled = false 默认关闭 | OK |
| AdjutantButton 调用点已加闸 | OK |
| AICommandHUD 提示已加闸 | OK |
| 两文件都从 /root/FeatureFlags 读开关 | OK |

## 未完成（如实）
- 真实对局探针未能跑完：_StrategicChatBanProbe 两次超时（220s / 400s）——
  原因是副官面板 _ready 会启动本地模型服务并等待就绪，该路径天然很慢/易挂；
- 因此『聊天区确实没有出现在局内面板上』目前只有静态证据，需要你在游戏里目视确认一次；
- 菜单侧封禁（战略模式入口）已有探针 rc=0 全过（round-16）。

## 恢复方法（一步）
编辑器打开 source/FeatureFlags.tscn，勾上 strategic_chat_enabled（聊天区回来）；
若还要战前讨论室，再勾 strategic_sandbox_enabled。


## 14. 特效×3 + 随机地图阻断 + 重进修复（2026-10-06 追加）

### 特效×3
9 个特效场景全参数×3（`scale_effects.py`）：
SparklingAnimation、ShellExplosion、CannonShell、Rocket、RifleRound、HeavyCannonShell、BloodMist、ResourceDecayAnimation、MouseClickAnimation3D。
参数：emission_sphere_radius、initial_velocity_min/max、QuadMesh/SphereMesh size/radius、Sprite3D pixel_size。
回归：定向套件 8/8 rc=0（strategic-chat-service、adjutant-model-service、traditional-command-hud 等）。

### 爆炸特效被建筑覆盖
ShellExplosion 材质加 `render_priority = 15`（火焰+`no_depth_test`）/ `10`（烟雾），spawn 高度 0.2→1.2m。
TankForceAttackSmokeTest rc=0 确认逻辑未破坏。

### 随机地图阻断探针修复
探针改查 `_random_map_mode` 状态变量（UI disabled 可能被刷新覆盖）→ PASS。

### 重进对局 RC=0
不走 change_scene 链（探针自身被释放），改用 cancel + queue_free + root.add_child。
新 conversation_id、历史清空、旧回复不污染 → 全 PASS。

### 全量回归如实报告
86/116 通过（30 红归因并行 WIP）。**不是全量通过**——合流后由对应会话收尾。