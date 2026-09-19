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
## 把真实对局写成详细报告（历史列表页与玩家画像的数据来源）。
## 默认关闭：对局层目前还没有 difficulty / 副官类型 / 权威伤害数字，
## 打开后产生的是"诚实的稀疏报告"（缺失字段为 null，data_completeness 会很低）。
@export var record_match_history = false


@export_group("Match/Debug")
@export var frame_incrementer = false
@export var god_mode = false
