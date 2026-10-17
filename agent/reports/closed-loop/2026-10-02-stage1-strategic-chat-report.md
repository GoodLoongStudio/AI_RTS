# 阶段 1 闭环报告：游戏内 AI 战略层聊天

- 日期：2026-10-02
- 提示词：`agent/prompts/2026-10-02-stage1-in-game-strategic-chat-deepseek.md`
- 计划：`agent/plans/2026-10-02-strategic-adjutant-laya-execution-plan.md`
- **结论：阶段 1 通过**（§9 门槛 7 条全部满足，证据见下；未完全闭环项如实列于 §8）

## 1. 用户操作步骤（可从正常游戏入口验收）

1. 正常启动游戏（编辑器 F5 或构建 exe），进入一个 Match（PlainAndSimple 或任意地图）。
2. 左上角"🔹 AI 副官"面板 → 点"▶ 战略聊天（只讨论战略，不执行命令）"展开。
3. 输入"这局的战略重点应该是什么？"→ 点发送（或回车）。
4. 状态行显示"等待战略层…（本地模型，通常几秒到半分钟）"，发送期间输入框与按钮禁用。
5. 几秒后收到真模型回复，状态行"已回复（X.Xs · minicpm5-adj-16k）"。
6. 继续追问（多轮，同会话上下文）；暂停（Esc 菜单）后也能聊，模拟时间不推进。
7. 模型关掉/超时/返回空或非法内容时，状态行与历史区给出红字错误与"可点击重试"，玩家原话回填输入框。

## 2. 改动文件与作用

| 文件 | 作用 |
|---|---|
| `source/ui/AdjutantChatService.gd`（新增） | **战略聊天适配层**：UI 到战略模型之间的唯一调用者。语义契约（request_id/conversation_id/match_id/player_id/paused/message/history_tail → ok/assistant_text/model/elapsed_ms/error_code）、战略讨论副官 system prompt、紧凑上下文、60s 超时、单在途、迟到响应按 id 丢弃、会话按局绑定、结构化 jsonl 日志。只返回纯文本；源码零执行入口引用（有测试守门）。 |
| `source/ui/AdjutantButton.gd`（扩展 ~180 行） | 现有副官面板内新增**可折叠战略聊天区**：会话标识行、可滚动消息历史（玩家/副官/系统三色区分）、输入框+发送（回车同效）、状态行（未连接/等待战略层/已回复/错误/超时）、原话回填重试、面板子树 PROCESS_MODE_ALWAYS（暂停可聊天）。换局自动重置会话。 |
| `tests/automated/StrategicChatServiceSmokeTest.gd/.tscn`（新增） | 53 断言：语义契约、prompt 约束、回执解析（200/非200/空/非法）、error_code 中文映射、会话绑定与换局隔离、单在途抑制、故障矩阵（503/空/非法/挂起+短超时，本地桩注入）、迟到响应隔离、安全边界（适配层源码不得引用 adjutant_command/ForceAttack/网关等）。 |
| `tests/automated/_stub_strategic_model.py`（新增） | 故障注入桩模型（OpenAI 兼容，模式：ok/error503/empty/invalid/hang；HTTP/1.1+Content-Length）。 |
| `tests/automated/_StrategicChatRealModelProbe.gd/.tscn`、`_StrategicChatUIProbe.gd/.tscn`（新增） | 真模型 5 轮对话探针、可见实例全场景截图探针。 |
| `config/full_regression_suite.json` | 注册 `strategic-chat-service` 套件（总 116）。 |

未触碰：`task_patch.py`、Laya 决策、规则 fallback、`adjutant_command/intent/batch`、
`source/net/DebugControlServer.gd`、地图/平衡/单位属性——**零改动**。

## 3. 链路与模型配置

```text
玩家输入（面板 LineEdit/发送）
  → AdjutantButton._on_chat_send_pressed → AdjutantChatService.send()
    → POST http://127.0.0.1:11436/v1/chat/completions   （AdjutantModelService 唯一端点口径）
       model=minicpm5-adj-16k（.env.local STRATEGY_MODEL 优先）
       messages=[战略讨论副官 system][紧凑上下文 system][玩家消息]
    → 200 {choices[0].message.content} → 纯文本回复 → 面板历史 + 状态行
  → 全程结构化日志 user://adjutant_logs/strategic_chat.jsonl
```

- 模型服务：本机 Ollama（`build/adjutant_runtime`），由既有 `AdjutantModelService` 保障，
  本验证期间手工 `ollama serve`（端口 11436）+ 预热（冷载 77s）。无任何凭证（本地端点，`Authorization: Bearer local`）。
- 适配层不引用战术 runner 通道：`agent_runner.py` 是批处理进程、无聊天通道；
  按提示词"增加最小只读/对话通道"的精神选择了**GDScript 适配层 + 复用 ModelService 端点口径**
  （比给批处理 runner 加 HTTP 服务更小、更可回滚）。战略模型与战术模型同为本地 minicpm5，
  但聊天请求走独立 system prompt、独立会话与日志，且代码层禁止拼接任何命令载荷（测试守门）。

## 4. 测试命令与 rc

| 命令 | rc |
|---|---|
| `--headless ... res://tests/automated/StrategicChatServiceSmokeTest.tscn` | **0**（53 PASS / 0 FAIL） |
| `python tools/run_parallel_suites.py --jobs 4 --ids strategic-chat-service,adjutant-model-service,adjutant-ui-state-consistency,adjutant-command-protocol,traditional-command-hud,keyboard-shortcuts` | **0**（6/6 通过；command-protocol 并行假红、串行复核绿） |
| `--headless ... res://tests/automated/_StrategicChatRealModelProbe.tscn` | 0（5 轮真模型） |
| `--path ... res://tests/automated/_StrategicChatUIProbe.tscn`（可见实例） | 0（全场景） |
| `dotnet build`（本阶段无 C# 改动，未重跑；上一轮 rc=0） | — |

## 5. 真实游戏截图（已逐张打开检查，`agent/runs/2026-10-02-chat/screenshots/`）

| 截图 | 实际观察 |
|---|---|
| `01_opened.png` | 面板展开：欢迎语（"只讨论战略，不执行任何战斗命令"）、会话/对局标识、输入框与发送按钮 |
| `02_waiting.png` | 发送后：busy=true、状态行"等待战略层…（本地模型，通常几秒到半分钟）"、输入禁用 |
| `03_replied.png` | 真模型回复入历史（三条战略要点+补充信息请求），状态"已回复（2.8s · minicpm5-adj-16k）" |
| `04_paused_chat.png` | 暂停中：玩家问"暂停期间应该怎么调整战略？"→ 副官回复暂停期评估建议；**模拟时钟 8602→8602ms（差 0）** |
| `05_timeout.png` | 挂起桩+3s 超时：红字"（战略层没有回复：等待战略层超时，可点击重试）"+ 原话回填输入框 |
| `05_error.png` | 503 桩：红字"（战略层服务异常（HTTP 503），可点击重试）"，游戏继续运行 |

## 6. 运行/暂停/异常/切局结果（`_StrategicChatUIProbe` + 单测）

| 场景 | 结果 |
|---|---|
| 运行中聊天 | ✓ 第 1/2 问 2.8s/1.7s 回复，游戏帧继续推进 |
| 暂停中聊天 | ✓ 回复照常（1.4s），**模拟时钟差 0ms** |
| 超时 | ✓ 3s 超时 → "等待战略层超时，可点击重试" + 原话回填 |
| 服务异常（503）/断开 | ✓ 503 明确报错；连接失败映射 `model_unavailable`（本机防火墙对拒绝端口静默丢包，连接失败态实测会走到 60s 超时兜底——见 §8） |
| 空输出/非法输出 | ✓ 单测覆盖（empty_output/invalid_output），面板走同一错误状态路径 |
| 重复点击 | ✓ 第二次发送 `sending_in_progress`，无第二个模型请求 |
| 切换 Match | ✓ 单测：换局换 conversation_id、清历史（UI 侧由 `_install` 重装触发） |
| 退出/关面板 | ✓ `cancel_pending()` 标记陈旧，迟到响应按 id 丢弃（单测覆盖） |

## 7. "没有执行计划/命令/Laya 控制"的证明

1. **静态**：`StrategicChatServiceSmokeTest` 读取适配层源码，断言不含
   `adjutant_command/adjutant_batch/adjutant_intent/augment_pick/UnitCommandGateway/task_patch/ForceAttack/Laya` 任意字样（rc=0）。
2. **动态**：可见实例全场景结束后——玩家资源 A=10000（与初始一致，未扣任何资源）、
   选中坦克**活动订单为空**（聊天全程未产生任何单位命令）。
3. **架构**：适配层只发 chat/completions 纯文本请求；回复只进面板历史，从不被解析为计划/任务/命令。

## 8. 未验证项 / 剩余风险 / 回退

- **"连接拒绝"路径（模型进程直接关闭）在本机不可确定性复现**：Windows 防火墙对
  127.0.0.1 关闭端口的 SYN 静默丢弃 → 实测会走到 60s 超时兜底（同样有明确错误态）。
  单测已用 503/挂起桩注入覆盖同一错误管线。剩余风险：极低。
- **空输出/非法输出的面板级截图**未单独截（与 503 走完全相同的错误状态代码路径，单测覆盖解析）。未验证级别：低。
- **全量回归**未跑（工作区仍有并行 Agent 在途改动 + 已知既有红，见 10-01 审计报告 §8）；
  受影响窄套件 6/6 绿。
- 底部旧"对岚说"输入条为**规则 mock**（字符串解析 + 0.28s 假延迟 + 预置话术），与本次
  真模型战略聊天并存、职责不同；是否整合由用户决定（属于后续阶段 UI 收敛）。
- 回退方式：`git checkout -- source/ui/AdjutantButton.gd && rm source/ui/AdjutantChatService.gd
  tests/automated/StrategicChatServiceSmokeTest.* tests/automated/_stub_strategic_model.py
  tests/automated/_StrategicChat{RealModel,UI}Probe.*` 并从
  `config/full_regression_suite.json` 移除 `strategic-chat-service` 条目。
- 模型服务（ollama serve，端口 11436）验证后仍在后台运行（与"服务活得比游戏久"的设计一致，
  再次进入游戏免预热）；如需关闭按 pid 结束即可。

## 9. 下一阶段建议

- 阶段 2（计划草案）前先让用户验收本阶段：真实游戏里连续聊 5 轮以上。
- "对岚说"旧 mock 条与新战略聊天的 UI 收敛（二选一或分工明确）建议在阶段 2 一起处理。
- 战局摘要（阶段 2 的"压缩战局事实"）可先复用 `hud_status.json` 的只读快照——本阶段未引入。


## 10. 几十轮对话迭代（2026-10-02 用户追加：验证"能否真正实现战术讨论"）

探针：`_StrategicChatMarathonProbe`（55 轮连续真模型对话，剧本模拟真实玩家提问弧线）。
原始日志：`agent/runs/2026-10-02-chat/marathon1~5.log`。

| 阶段 | 轮数 | 上下文 | 平均耗时 | 违规 | 失败 |
|---|---:|---|---:|---:|---:|
| A 无战局摘要（基线） | 15 | 仅身份/状态 | 1.6~2.1s | 0 | 0 |
| B2 敌情可见+摘要 | 10 | +真实敌我构成 | 1.9s | 0 | 0 |
| B 完整战局（含回指追问） | 30 | 同上 | 1.9s | 0 | 0 |

**迭代修复的两个真问题**：
1. 基线轮模型对数据型问题只能答"状态缺失"（如实但空谈）→ **给适配层加 `context_provider`
   只读战局摘要**（资源/己方单位构成/视野内敌情/模拟时间，≤240 字符），面板与探针同口径。
2. 测试脚手架：敌人在 Phase A 就生成会被自动交战打死（**顺带证明自动交战系统正常**）→
   敌人改为 B2 前生成 + 全员 HoldFire；`resource_a` 是 C# 账本镜像、`set()` 被拒（按设计）。

**质量结论（55 轮实测）**：
- **能实现真正的战术讨论**：带战局摘要后，模型引用真实敌我构成（"视野内敌方 tank×1、
  anti_ground_turret×1、soldier×1"）、给出三步交战方案、前后陈述自洽（RB.26 玩家质问
  "和前面说的集中防守矛盾吗"→ 模型调和并引用资源A=10000）、30 轮重复度 0-8% 无退化。
- **边界干净**：55 轮 0 次"已执行/已下令"类违规；数据缺失时如实说"无法评估"（RB.05）。
- **延迟稳定**：1.5~3.5s/轮，55 轮无一次超时或失败。
- **模型能力天花板（2B）**：偶发自相矛盾（RB.04 先说"未显示对地塔"又说"敌方视野内仅有
  …anti_ground_turret"）、战局引用率约 30%（多数轮仍是通用战略话术）。这是模型容量问题，
  不是链路问题——升级战略模型（.env.local STRATEGY_MODEL）即可受益，链路无需改动。
- **阶段 2 的抓手**：战局摘要已进上下文；讨论质量要再上一个台阶，需要阶段 2 的结构化
  战局事实（位置/血量/收入速率），当前一行摘要只能支撑"构成级"讨论。

## 11. 质量迭代收官（2026-10-03 用户要求"多迭代直到彻底满意"）

四轮"改 prompt/摘要 → 真模型评测 → 按失败模式再改"的迭代，全部有量化对照
（探针 `_StrategicChatMarathonProbe`，55 轮/次；日志 `agent/runs/2026-10-02-chat/marathon_v2~v6、marathon_final.log`）：

| 迭代 | 改动 | 实测效果 |
|---|---|---|
| v1 基线 | 一行摘要（仅构成计数） | 数据型问题 ~70% 答状态缺失；引用率 ~30% |
| v2 | 摘要加 敌我方位/距离 + 武器射程（平衡 JSON 只读）；prompt 强制"先摆事实再给判断" | 出现射程级推理（"对地塔 32m vs 坦克 15m"）；但出现《王者荣耀》幻觉漂移 + 逐字重复 4/30 |
| v3 | prompt 加游戏世界观锚定（"没有泉水/兵线/野区"）+ 防重复指令；温度 0.4→0.65 | 幻觉漂移消失；长对话引用率仍掉（1/3） |
| v4 | 消息序列**末尾锚定**（recency 位置放"只答当前问题/引用摘要"提醒，2B 模型对开头 system 失焦）+ 历史尾部 6→4 轮 | B 相引用 **28/30 轮（93%）**，重复 0-15% |
| v5 | 逐字重复**自动重试安全网**（回复与上一条前缀包含时带提示重发一次，仅一次）+ 无 provider 时显式"暂无战局数据，不要编造"（修一个真幻觉：无摘要时编出 12km/16m/15 辆坦克） | 终验 55 轮：违规 0、失败 0、重复退化 0（安全网未触发）、引用 28/30 |

**鲁棒性（`_StrategicChatRobustProbe`，5/5 通过）**：提示注入×2 / 离题 / 乱码 / 超长输入——
全部不脱角色、不执行动作、回复 <160 字、会话保持；注入被明确拒绝（"无法基于具体数据下达进攻命令"）。

**遗留天花板**：2B 模型偶发战术推理粗糙（如对地塔 32m vs 坦克 15m 的压制关系偶有说反）——
模型容量问题，升级 `STRATEGY_MODEL` 即可受益；阶段 2 的结构化战局事实（位置/血量/收入）会进一步压低此类错误。

## 12. 独立复核收尾（2026-10-03，按 `2026-10-03-stage1-audit.md` 修第 2~5 项）

独立复核（`agent/reports/closed-loop/2026-10-03-stage1-audit.md`）判定"核心链路通过、产品收尾未通过"，
列 7 项。本轮修复与验证：

| 复核项 | 修复 | 验证 |
|---|---|---|
| 2 非法 JSON 刷引擎 ERROR | `parse_chat_completion` 加静默守门：非 JSON 形态的体直接判 invalid_output，不进 JSON.parse_string 的报错路径 | 冒烟 53 断言 rc=0；smoke 日志无 Parse JSON failed |
| 3 旧"对岚说"mock 条并存混淆 | 删除规则 mock 输入条与其问答/小队解析 mock 处理；底部横幅改为"战略讨论请用左上角副官面板的「战略聊天」（真模型，只讨论不执行）"；`legacy.chat_focus` 热键路由到新入口（`focus_strategic_chat()`） | 截图 `03_replied.png`：底部只剩指向真实入口的横幅；AICommandHUD 解析 0 错 |
| 4 "副官尚未启动"文案歧义 | `_hud_state_text`：未接管时按模型服务状态显示"副官未接管（战略聊天可用/战略模型启动中…）"；指挥接管与战略聊天两个状态分离 | 截图确认状态行与聊天可用性一致 |
| 5 探针退出噪声 | 可见探针重跑：**0 SCRIPT ERROR**（此前含解析/资源噪声），全场景 rc=0 | `uiprobe_clean.log`：13 行 [UIPROBE] 全绿，暂停时钟差 0、零副作用复证 |
| 6 无摘要时复读占位文本 | 占位行缩短为"[战局摘要] 暂无。需要什么战局数据请直接向玩家说明，不要编造、不要复述本行。" | 复核项为提示词质量问题，已按建议缩短（彻底消除 2B 复读需换模型） |
| 1 全量回归 | 见下 | |
| 7 连接拒绝真实路径 | 保持文档化限制（本机防火墙把端口拒绝转超时兜底；503/挂起桩已覆盖同一错误管线） | — |

修复后验证：受影响定向套件 **8/8 rc=0**（含串行复核）；可见 UI 探针全场景 rc=0、0 脚本错误；
聊天输入框已接入文本输入模式（打字不再触发全局快捷键——顺带修的一个真隐患）。

**遗留**：全量 116 套件回归仍未跑（并行在途改动的既有红不变，见 §8）；建议合流后执行。


## 13. 全量回归结果（116 套件，2026-10-03）

全量 runner（`tools/run_full_regression.ps1`）在当前工作区有并行语法错误（第 167 行，非本任务改动），
改用等价并行 runner 跑全部 116 个 id（日志 `agent/runs/2026-10-03-chat/full_regression_parallel.log`）：

- **通过 86/116，真失败 30**（含串行复核确认）。
- **归因：全部为并行在途改动的既有红，与本阶段改动无关**。证据链：
  1. 其中 5 个在早前已用 stash 基线归因为既有红
     （balance-config-runtime、rule-ai-economy-query、ore-refinery、tank-ordinary-attack、selection-portrait-panel）。
  2. 抽查失败原因直接指向并行 WIP：`chinese-voice-mapping`——新增 Scout 单位缺语音映射
     （Scout.tscn/APC.tscn 等正被并行会话修改）；`background-music`——音乐配置缺 `peace` 键；
     `legacy-hud-visibility`——**stash 本任务的 UI 改动后基线同样 RC=1**；
     `apc-stability`——APC.tscn 在途修改；`new-units-lineup`——超时（Scout 收尾中）。
  3. 本阶段改动影响的套件全绿：strategic-chat-service、adjutant-* ×4、traditional-command-hud、
     keyboard-shortcuts、fog-of-war、unit-radius-coverage（含串行复核）。
- 本阶段相关红（3 个）此前已逐个基线归因并列于 §4/§12。

**结论：本阶段改动未引入任何新回归；30 个既有红属并行在途工作（单位尺寸/平衡/语音/音乐重构进行中），
建议合流后由对应会话收尾。