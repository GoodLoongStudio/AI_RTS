extends Node

func _ready() -> void:
	var p = load("res://source/match/Match.tscn")
	print("[SCENE] Match.tscn 加载:", str(p != null))
	if p == null:
		print("[SCENE] ✗ 场景解析失败 ⇒ 必须去掉行尾注释")
	else:
		var n = p.instantiate()
		var env_n = n.get_node_or_null("WorldEnvironment")
		print("[SCENE] 实例化 OK ✓ WorldEnvironment=", str(env_n != null))
		if env_n != null and env_n.environment != null:
			var e = env_n.environment
			print("[SCENE] volumetric enabled=", str(e.volumetric_fog_enabled), " albedo=", str(e.volumetric_fog_albedo), " density=", str(e.volumetric_fog_density), " ambient=", str(e.volumetric_fog_ambient_inject), " length=", str(e.volumetric_fog_length))
		n.queue_free()
	get_tree().quit(0)