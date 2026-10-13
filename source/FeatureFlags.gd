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
