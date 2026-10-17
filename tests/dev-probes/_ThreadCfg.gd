extends Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for k in [
		"navigation/avoidance/thread_model/avoidance_use_multiple_threads",
		"navigation/avoidance/thread_model/avoidance_use_high_priority_threads",
		"navigation/avoidance/thread_model",
		"navigation/avoidance/avoidance_use_multiple_threads",
		"navigation/avoidance/avoidance_use_high_priority_threads",
	]:
		print("[THREAD] ", k, " = ", str(ProjectSettings.get_setting(k, "<不存在>")))
		print("[THREAD]    has_setting=", ProjectSettings.has_setting(k))
	print("[THREAD] OS.get_processor_count() = ", OS.get_processor_count())
	get_tree().quit(0)
