extends SceneTree

## 二分定位 map tscn 的解析错误行：写若干截断副本并逐个 load，
## 看错误是否随截断点后移（错误行 < 截断点 => 病因在前）。
## 运行：
##   Godot_v4.7.1-stable_mono_win64_console.exe --headless --path G:/AIRTS/AI_RTS \
##     --script res://tools/probe_tscn_bisect.gd

const SRC := "G:/AIRTS/AI_RTS/source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var f := FileAccess.open(SRC, FileAccess.READ)
	if f == null:
		print("cannot open src")
		quit(1)
		return
	var text := f.get_as_text()
	f.close()
	print("SRC chars=", text.length())
	var lines := text.split("\n", true)
	print("SRC lines=", lines.size())

	var cuts := [500000, 700000, 900000, 1000000, 1100000, 1200000, 1260000, 1268806]
	for k in cuts:
		if k >= lines.size():
			continue
		var head := PackedStringArray()
		for i in range(k):
			head.append(lines[i])
		var dst := "G:/AIRTS/AI_RTS/tools/_trunc_%d.tscn" % k
		var w := FileAccess.open(dst, FileAccess.WRITE)
		if w == null:
			print("K=", k, " write failed")
			continue
		w.store_string("\n".join(head))
		w.close()
		var res := ResourceLoader.load("res://tools/_trunc_%d.tscn" % k)
		print("K=", k, " -> ", "NULL" if res == null else str(res.get_class()))
	print("BISECT_DONE")
	quit(0)
