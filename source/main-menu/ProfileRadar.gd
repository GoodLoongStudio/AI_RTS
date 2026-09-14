extends Control

var values := Vector3(0.45, 0.35, 0.55)

func _ready() -> void:
	custom_minimum_size = Vector2(420, 220)
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.34
	var axes := [Vector2.UP, Vector2(0.866, 0.5), Vector2(-0.866, 0.5)]
	for ring in range(1, 4):
		var points := PackedVector2Array()
		for axis in axes:
			points.append(center + axis * radius * ring / 3.0)
			points.append(center + axis.rotated(PI) * radius * ring / 3.0)
		for i in range(points.size()):
			draw_line(points[i], points[(i + 1) % points.size()], Color(0.5, 0.55, 0.65, 0.35), 1.0)
	for axis in axes:
		draw_line(center - axis * radius, center + axis * radius, Color(0.65, 0.7, 0.8, 0.45), 1.0)
	var shape := PackedVector2Array()
	for i in range(3):
		shape.append(center + axes[i] * radius * values[i])
	draw_colored_polygon(shape, Color(0.25, 0.65, 0.95, 0.32))
	for i in range(3):
		draw_circle(shape[i], 5.0, Color(0.45, 0.82, 1.0))
