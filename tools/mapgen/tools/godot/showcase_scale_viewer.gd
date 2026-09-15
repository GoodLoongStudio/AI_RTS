extends SceneTree

const FOLDER := "res://review/G4/kit_samples/all_kits_showcase"
var world: Node3D
var camera: Camera3D
var views: Array
var zoom: HSlider
var dragging := false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.title = "RTS Scale Review"
	root.size = Vector2i(1440,960)
	root.msaa_3d = Viewport.MSAA_4X
	world = load(FOLDER+"/all_kits.tscn").instantiate()
	root.add_child(world)
	camera = world.get_node("InspectionCamera")
	views = JSON.parse_string(FileAccess.get_file_as_string(FOLDER+"/component.json")).views
	var layer := CanvasLayer.new()
	world.add_child(layer)
	var canvas := Control.new()
	layer.add_child(canvas)
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.gui_input.connect(handle_input)
	var bar := HFlowContainer.new()
	canvas.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 16
	bar.offset_top = 16
	bar.offset_right = -16
	bar.add_theme_constant_override("h_separation",8)
	var tabs := ButtonGroup.new()
	for entry in [["combat_plateau","Plateau"],["main_ramp","Main Ramp"],["left_ramp_junction","Side Ramp"],["plateau_buttes","Flat-top Rocks"],["mountain_varieties","Mountains"],["combat_ridge","Ridge"],["combat_bridge","Bridge"],["combat_units","Units"],["overview","Overview"]]:
		var button := Button.new()
		button.text = entry[1]
		button.custom_minimum_size = Vector2(100,36)
		button.toggle_mode = true
		button.button_group = tabs
		button.button_pressed = entry[0]=="combat_plateau"
		button.pressed.connect(select_view.bind(entry[0]))
		bar.add_child(button)
	var unit_toggle := CheckButton.new()
	unit_toggle.text = "Units"
	unit_toggle.button_pressed = true
	unit_toggle.toggled.connect(func(value: bool): world.get_node("ScaleUnits").visible=value)
	bar.add_child(unit_toggle)
	var base_toggle := CheckButton.new()
	base_toggle.text = "Base"
	base_toggle.button_pressed = true
	base_toggle.toggled.connect(func(value: bool): world.get_node("ScaleBase").visible=value)
	bar.add_child(base_toggle)
	zoom = HSlider.new()
	zoom.custom_minimum_size = Vector2(180,36)
	zoom.min_value = 8
	zoom.max_value = 400
	zoom.step = 1
	zoom.tooltip_text = "Camera span"
	zoom.value_changed.connect(func(value: float): camera.size=value)
	bar.add_child(zoom)
	select_view("combat_plateau")
	if "--smoke" in OS.get_cmdline_user_args():
		for view in ["main_ramp","left_ramp_junction","plateau_buttes","mountain_varieties","combat_ridge","combat_bridge","combat_units"]:
			select_view(view)
			for frame in 3: await process_frame
			assert(camera.size>=8 and camera.size<=400)
		unit_toggle.button_pressed=false
		assert(not world.get_node("ScaleUnits").visible)
		unit_toggle.button_pressed=true
		base_toggle.button_pressed=false
		assert(not world.get_node("ScaleBase").visible)
		base_toggle.button_pressed=true
		zoom.value=30
		assert(camera.size==30)
		select_view("combat_plateau")
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(FOLDER+"/scale_viewer.png")
		print("SCALE_VIEWER_CONTROLS_PASS")
		world.queue_free()
		await process_frame
		await process_frame
		call_deferred("quit")

func vector(value: String) -> Vector3:
	var fields := value.trim_prefix("(").trim_suffix(")").split(",")
	return Vector3(float(fields[0]),float(fields[1]),float(fields[2]))

func select_view(id: String) -> void:
	for view in views:
		if view.name==id:
			camera.position=vector(view.pos)
			camera.look_at(vector(view.target))
			zoom.value=view.size
			camera.size=view.size
			return

func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_MIDDLE:
			dragging=event.pressed
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_UP:
			zoom.value=maxf(8,camera.size*.9)
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_DOWN:
			zoom.value=minf(400,camera.size/ .9)
	if event is InputEventMouseMotion and dragging:
		var right:=camera.global_basis.x
		var forward:=Vector3(camera.global_basis.z.x,0,camera.global_basis.z.z).normalized()
		camera.position+=(-right*event.relative.x-forward*event.relative.y)*camera.size/root.size.y

