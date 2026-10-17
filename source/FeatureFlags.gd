extends Node

@export_group("Game")
@export var show_logos_on_startup = true
@export var save_user_files_in_tmp = false

@export_group("Match")
@export var handle_match_end = true
## 对局中途海克斯式三选一。单机暂停选牌；联机不冻世界，超时用推荐项。
@export var match_augments = true
@export var show_minimap = true
@export var allow_navigation_rebaking = true
@export var enable_edge_scroll = true

@export_group("Match/History")
## 把真实对局写成详细报告（历史列表页 / 玩家画像 / 对局结算页的唯一数据源）。
## 【2026-09-27 用户"不要伪造了"】默认开启：读不到的字段如实写 null
## （data_completeness 会偏低），也绝不退回 demo 播种的假报告。
## 玩法系统可用 `MatchReportRecorder.contribute()` 逐步补权威数字。
@export var record_match_history = true


@export_group("Match/Debug")
@export var frame_incrementer = false
@export var god_mode = false

@export_group("Experimental")
## 【2026-10-06 用户要求】战略模式（测试）属**实验功能**：做稳定版期间**默认关闭** ✓。
## 关闭时：单机页的入口按钮**隐藏并禁用**、入口函数**双重阻断** ✓；
## 页面实现、探针、报告**全部保留** ✓ ⇒ 需要时把这里勾上即可恢复 ✓。
@export var strategic_sandbox_enabled = false
## 【2026-10-06 用户要求】**局内**右下/左上副官面板里的「战略聊天」也属实验功能：默认关闭 ✓。
## 关闭时：面板不再出现聊天区（含开关按钮/输入框/发送）✓，HUD 也不再提示"请用战略聊天" ✓。
@export var strategic_chat_enabled = false
