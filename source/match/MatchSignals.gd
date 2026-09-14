extends Node

# requests
signal deselect_all_units
signal setup_and_spawn_unit(unit, transform, player)
signal place_structure(structure_prototype)
signal schedule_navigation_rebake(domain)
signal navigate_unit_to_rally_point(unit, rally_point)  # currently, only for human players

# notifications
signal match_started
signal match_aborted
signal match_finished_with_victory
signal match_finished_with_defeat
signal terrain_targeted(position)
## 本地玩家的命令指定模式变化（维修/出售/强制移动/攻击…）。
## 供命令光标与命令面板做视觉反馈（2026-09-14 红警式交互），不参与任何玩法判定；
## 空字符串表示已退出指定模式。注意：联机傀儡端的模式切换同样会发出，因为
## 目标选择本来就发生在本地。
signal command_targeting_changed(command_name)
signal unit_spawned(unit)
signal unit_targeted(unit, target_position)
signal unit_selected(unit)
signal unit_deselected(unit)
signal unit_damaged(unit)
signal unit_died(unit)
signal unit_production_started(unit_prototype, producer_unit)
signal unit_production_finished(unit, producer_unit)
signal unit_production_queue_became_empty(producer_unit)
signal unit_construction_finished(unit)
signal not_enough_resources_for_production(player)
signal not_enough_resources_for_construction(player)
## 命令可视化（纯表现层）：权威端把一次命令的动作/目标/下发者广播给表现层。
## payload 结构见 CommandVisualizer.gd：{action, units, target, source, tick}。
## 只影响画面，不参与任何玩法判定。
signal order_visualized(payload)
