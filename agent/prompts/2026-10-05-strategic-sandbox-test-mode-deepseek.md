# 阶段 1 执行提示词：增加“战略模式（测试）”封闭战略层房间

你是 AI_RTS 仓库的代理工程师。请在当前共享工作区直接完成本提示词，交付一个玩家可从正常菜单进入、但完全不创建对局的战略测试房间。不要只报告代码修改，必须完成真实运行、截图、日志和回归闭环。

开始前按顺序阅读：

1. `G:\AIRTS\AI_RTS\AGENTS.md`
2. `G:\AIRTS\AI_RTS\skills\闭环验证工作法.md`
3. `G:\AIRTS\AI_RTS\skills\AI_RSI自校验循环.md`
4. `G:\AIRTS\AI_RTS\agent\manifest.json`
5. `G:\AIRTS\AI_RTS\agent\plans\2026-10-05-strategic-sandbox-test-mode-plan.md`
6. `G:\AIRTS\AI_RTS\agent\reports\closed-loop\2026-10-04-stage1-fix-audit-report.md`
7. `G:\AIRTS\AI_RTS\source\main-menu\MatchSetupPage.gd`
8. `G:\AIRTS\AI_RTS\source\main-menu\Play.gd`
9. `G:\AIRTS\AI_RTS\source\main-menu\MatchSetupPage.tscn`
10. `G:\AIRTS\AI_RTS\source\ui\AdjutantChatService.gd`
11. `G:\AIRTS\AI_RTS\source\ui\AdjutantModelService.gd`
12. `G:\AIRTS\AI_RTS\source\ui\MenuPage.gd`

先检查 `git status`、目标文件 mtime、现有测试和当前模型服务状态。共享工作区有其他 Agent 的未提交改动，禁止 reset、clean、checkout、覆盖或删除无关文件。

## 唯一目标

在截图对应的单机设置页中，按顺序显示：

1. `开始游戏`
2. `战略模式（测试）`
3. `返回`

点击 `战略模式（测试）` 后进入独立的战略讨论实验室：

- 不开始对局；
- 不加载 `Match.tscn`；
- 不生成地图、玩家、单位、资源和 SimulationClock；
- 不调用 `NetSession.host()`；
- 不产生单位命令、任务、租约或 Laya 选择；
- 只运行战略聊天和测试房间 UI。

## 1. 菜单入口

- 优先在 `MatchSetupPage` 的共享布局中增加按钮，使单机 `Play.tscn` 可见、在线页面不误显示。
- 按钮放在“开始游戏”和“返回”之间，沿用当前页面样式、尺寸、间距和焦点顺序。
- 按钮文字必须是“战略模式（测试）”，tooltip 或旁注说明“进入封闭战略讨论，不创建对局”。
- 点击只切换到新的测试页面，例如 `StrategicSandboxPage.tscn`；不要复用开始按钮、Loading 页面或 Match 场景。
- 单独给入口加测试：点击后当前树没有 `Match`，没有 `SimulationClock`，没有玩家/资源节点，且页面标题可见。

## 2. 独立战略测试页面

创建独立页面，继承 `MenuPage.gd` 或遵循同一返回/ESC 契约。页面至少包含：

- 标题：“战略模式（测试）”或“封闭战略层实验室”；
- 明确说明：“当前为封闭测试，没有真实对局；只讨论战略，不执行命令。”；
- 当前会话标识，例如 `strategic-sandbox`；
- 消息历史、输入框、发送按钮、滚动区域；
- 模型预热、等待、已回复、超时、错误、重试状态；
- 返回按钮和 ESC 返回单机设置页。

实现方式可以复用 `AdjutantChatService` 和 `AdjutantModelService`，但不要实例化依赖 Match 的 `AdjutantButton` 面板，也不要调用 `_install()`。如果为了避免 UI 重复需要抽出共享聊天控件，保持改动小，并确保真实 Match 的现有聊天不回归。

测试页面的会话必须使用独立标识（如 `strategic-sandbox`），context 明确写“无真实战局摘要”。禁止编造资源、单位、敌情、地图或执行结果。

## 3. 冷启动和生命周期要求

当前阶段不能再接受以下问题：

- 模型 starting/warming 时玩家首条消息直接发 HTTP，导致第一次使用先超时；
- 关闭测试页面或返回菜单后旧适配层、旧请求、旧回复污染下一次进入；
- 迟到的上一轮回复写入新一轮页面。

请让测试页面在模型 warming 时禁用发送或把首条消息排队到 ready 后自动发送，并给玩家显示明确的“战略模型预热中”。

页面退出时必须取消/陈旧化在途请求并释放页面拥有的聊天适配层；重新进入必须创建新的 `conversation_id`，旧回复不能进入新页面。这个生命周期要求也不能破坏真实 Match 的聊天。

## 4. 严格禁止范围

本次只做阶段 1 封闭测试入口和页面：

- 不实现战略计划 JSON、任务卡、计划确认、任务租约、单位命令或 Laya 控制；
- 不读取真实 Match 的战局摘要；
- 不调用 `adjutant_command`、`adjutant_batch`、`adjutant_intent`、`augment_pick`、`UnitCommandGateway` 或其他执行入口；
- 不修改地图、平衡、单位属性、生产、移动、攻击和资源规则；
- 不通过删除断言、修改 expected marker 或屏蔽错误日志来让测试变绿。

## 5. 必须完成的验收闭环

### 静态检查

- 逐个解析修改的 GDScript；
- 确认新页面和入口没有 preload/instantiate `Match.tscn`、`Loading.tscn` 或 `NetSession.host()`；
- 确认没有执行入口和 Laya 依赖。

### 真实菜单和页面

从正常主菜单进入单机设置页，截图确认三个按钮顺序和视觉布局。点击“战略模式（测试）”后再截图，确认画面没有地图、资源、单位、战斗 HUD 或 Match 内容。

### 真实模型对话

- 冷启动首次进入：发送一条问题，不能先超时；必须排队/禁用到模型 ready 后收到回复；
- 连续至少 5 轮真实战略对话，检查非空回复、history_tail 和 session id；
- 关闭页面、返回、重新进入，确认新会话和旧回复隔离；
- 模型超时、503、空输出、非法输出都有中文错误和重试；
- 回复不得声称已经下令、执行、控制单位或改变资源。

### 无对局证明

探针必须打印并断言：

- 当前场景不是 `Match`；
- 场景树没有 `SimulationClock`、玩家、单位和资源账本；
- 没调用 `NetSession.host()`；
- 返回后没有残留测试页面、HTTP 请求、模型 stub 或旧适配层。

### 相关回归

至少运行：

- 新增战略测试页面/入口套件；
- `strategic-chat-service`；
- `adjutant-model-service`；
- 菜单返回/ESC 相关套件；
- 真实 Match 的战略聊天 UI 探针，确认共享服务没有回归。

每项分别记录命令、RC、expected marker 和 forbidden output。全量回归如果受共享工作区其他改动影响，必须如实列出，不得写成全量通过。

## 6. 交付物

完成后新增或更新：

- `agent/reports/closed-loop/2026-10-05-strategic-sandbox-test-mode-report.md`
- `agent/runs/2026-10-05-strategic-sandbox/` 下的 baseline、checklist、截图、日志、验证记录和 champion 决策。

报告必须说明：改动文件、入口路径、确认没有创建对局的证据、真实对话结果、冷启动结果、返回/重进结果、截图路径、相关套件 RC、未验证项和共享工作区风险。

只有玩家能从单机设置页进入封闭战略房间、完成冷启动和至少 5 轮对话、返回重进无污染，且真实 Match 现有聊天没有回归，阶段 1 才能标记为“可验收”。
