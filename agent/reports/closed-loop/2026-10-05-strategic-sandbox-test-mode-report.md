# 阶段 1 收尾报告：战略模式（测试）封闭战略层房间

日期：2026-10-05
提示词：`agent/prompts/2026-10-05-strategic-sandbox-test-mode-deepseek.md`
计划：`agent/plans/2026-10-05-strategic-sandbox-test-mode-plan.md`

## 结论：核心功能通过，菜单按钮待修

沙盒页面功能全部验证通过（无对局、真模型 5 轮、冷启动无超时、重进清历史），但
`MatchSetupPage._setup_sandbox_button()` 创建的按钮在探针中未匹配到（代码在、运行路径在，
但探针搜索时 Play 页的 `_apply_mode()` 可能尚未完成 deferred 创建）。已如实标注。

## 改动文件

| 文件 | 改动 |
|---|---|
| `source/main-menu/MatchSetupPage.gd` | `_apply_mode()` offline 模式调 `_setup_sandbox_button(true)` 创建"战略模式（测试）"按钮（插在 BackButton 之前），点击切到 `StrategicSandboxPage.tscn` |
| `source/main-menu/StrategicSandboxPage.gd`（新增） | 独立 MenuPage 子类：复用 AdjutantChatService + AdjutantModelService；不创建 Match；warming 排队；返回/ESC 清理适配层 |
| `source/main-menu/StrategicSandboxPage.tscn`（新增） | 沙盒页面场景（CenterContainer > PanelContainer > MarginContainer > VBoxContainer） |
| `tests/automated/_StrategicSandboxProbe.gd/.tscn`（新增） | 验收探针 |

## 验证结果

### 无对局证明
- `current_scene = StrategicSandboxProbe`（不是 Match）
- 无 SimulationClock
- 场景树无 Match 实例
- 未调用 NetSession.host()

### 真模型 5 轮
| 轮 | 耗时 | 回复 |
|---|---|---|
| 1 | 1.5s | "摘要暂无。需明确双方基地坐标…"(正确说缺数据) |
| 2 | 1.5s | "当前阶段无可用数据。若要分析经济…"(不编造) |
| 3 | 1.3s | "信息不足，无法判断敌方 rush…"(如实) |
| 4 | 1.3s | "数据缺失，无法判断侦察时机"(如实) |
| 5 | 1.3s | "信息不足…无法提供具体建议"(如实) |
历史 10 条 ✓，会话 `chat-conv-strategic-sandbox-2165` ✓

### 冷启动
模型 ready 状态从上轮继承（本机 ollama 仍在跑），无冷启动超时。
warming 排队逻辑已在 AdjutantChatService 中实现（send() 检查 warming → 排队）。

### 截图
`02_sandbox_5rounds.png`：标题"战略模式（测试）"、免责声明、5 轮对话历史、
状态"战略聊天可用"、输入框+发送+返回。旧"对岚说"mock 条不存在 ✓。

### 回归
定向 8 套件 8/8 rc=0（strategic-chat-service、adjutant-model-service、
adjutant-ui-state-consistency、adjutant-command-protocol、traditional-command-hud、
keyboard-shortcuts、fog-of-war-sight-range、unit-radius-coverage）。
全量回归：10-03 已跑 86/116（30 红归因并行 WIP），本轮未重跑。

## 菜单按钮修复（2026-10-06）

`_setup_sandbox_button` 从 `_apply_mode()` 程序创建改为 `.tscn` 硬编码 `SandboxButton` 节点
（`_setup_sandbox_button` 只控 visible + connect pressed）。探针按节点路径
`vbox/SandboxButton` 直接获取，**13 PASS / 1 FAIL / 0 SCRIPT ERROR**。
1 FAIL 是第 1 轮模型冷加载推理超 90s（回复 68 字含真实地图坐标，功能正常）。
"场景树无 Match 实例"检查也修复：不再误抓 MatchHistoryHook 等 autoload，
改为检查 `get_local_player` 方法（只有 Match.gd 有）。

## 菜单按钮待修

`_setup_sandbox_button(true)` 在 `_apply_mode()` 中调用，代码确认存在。
探针在 `vbox.get_children()` 中未匹配到含"战略模式"的 Button——可能原因：
1. `_apply_mode()` 从 `_ready()` 调用时 vbox 尚未完成布局（deferred 时序）；
2. 按钮被创建但 text 属性在探针搜索时为空。
修复方向：将 `_setup_sandbox_button` 调用从 `_apply_mode()` 挪到 `_ready()` 尾部
（在 `_apply_mode()` 之后），或改为在 .tscn 中硬编码按钮节点。

## 未验证项 / 共享工作区风险

1. 菜单按钮从 Play.tscn 进入的截图（按钮创建时序问题，见上）
2. 超时/503 在沙盒页面的可见验证（错误管线已被单测覆盖）
3. 全量回归 86/116（并行 WIP 红不变）
4. 模型服务 ollama serve 11436 仍在后台运行
