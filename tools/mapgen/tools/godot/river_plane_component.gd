extends "res://plateau_base.gd"

const OUTPUT := "G:/AIRTS/RTS_Map_Tool/review/G4/kit_samples/river_plane_prototype"
const WIDTH := 150.0
const DEPTH := 110.0
const STEP := 0.625
const RIVER_HALF_WIDTH := 17.0
var river_records: Array = []

func river_center(x: float) -> float:
	return sin(x * 0.070) * 16.0 + sin(x * 0.155 + 1.15) * 4.5

func river_half(x: float) -> float:
	return RIVER_HALF_WIDTH * (0.90 + 0.12 * sin(x * 0.095 + 0.6) + 0.05 * sin(x * 0.22))

func terrain_material(base: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool dry_surface = false;
uniform sampler2D sand_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
varying vec3 p;
void vertex(){p=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
 vec3 sand=texture(sand_tex,p.xz*.05).rgb;
 vec3 grain=texture(rock_tex,p.xz*.23).rgb;
 float wet=p.y>=0.0 ? 1.0-smoothstep(.0,.20,p.y) : 0.0;
 if(dry_surface){wet=0.0;}
 float mottling=texture(rock_tex,p.xz*.032).r;
 vec3 dry=sand*vec3(1.28,.97,.66)+vec3(.085,.065,.035);
 ALBEDO=mix(dry,mix(dry,grain*vec3(.92,.80,.64),.30)*.78,wet);
 ALBEDO*=.92+mottling*.22;
 ROUGHNESS=mix(.98,.67,wet);
 NORMAL_MAP=texture(sand_normal,p.xz*.05).rgb;
 NORMAL_MAP_DEPTH=.48;
}
"""
	m.shader=s
	m.set_shader_parameter("sand_tex",load("res://assets/terrain_pbr/sand_diff.jpg"))
	m.set_shader_parameter("sand_normal",load("res://assets/terrain_pbr/sand_normal.jpg"))
	m.set_shader_parameter("rock_tex",load("res://assets/terrain_pbr/rock_diff.jpg"))
	return m

func water_material() -> ShaderMaterial:
	var m := ShaderMaterial.new(); var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_normal : filter_linear_mipmap, repeat_enable;
uniform bool lake_mode = false;
varying vec3 p;
void vertex(){p=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
 float c=sin(p.x*.070)*16.0+sin(p.x*.155+1.15)*4.5;
 float h=17.0*(.90+.12*sin(p.x*.095+.6)+.05*sin(p.x*.22));
 float edge=max(0.0,h-abs(p.z-c));
 if(lake_mode){
  vec2 q=p.xz/vec2(1.25,.90);
  float angle=atan(q.y,q.x);
  float radius=29.0*(1.0+.13*sin(3.0*angle+.4)+.065*cos(5.0*angle-1.0));
  edge=max(0.0,radius-length(q))*.95;
 }
 vec2 flow=p.xz*vec2(.048,.090);
 vec3 n=texture(rock_tex,flow).rgb;
 float detail=texture(rock_tex,flow*3.1+n.r*.16).r;
 float depth=smoothstep(0.0,7.0,edge);
 vec3 shallow=vec3(.56,.73,.66);
 vec3 deep=vec3(.36,.61,.57);
 vec3 col=mix(shallow,deep,depth);
 col+=vec3(.13,.17,.15)*(n.r-.28)*1.5;
 float foam=(1.0-smoothstep(.05,.75+n.r*1.8,edge))*smoothstep(.10,.40,detail);
 float ripple=smoothstep(.40,.65,detail)*(.18+.20*(1.0-depth));
 col=mix(col,vec3(.83,.88,.77),max(foam*.85,ripple));
 ALBEDO=col;
 ROUGHNESS=.30;
 SPECULAR=.45;
 NORMAL_MAP=texture(sand_normal,flow*.85).rgb;
 NORMAL_MAP_DEPTH=.055;
}
"""
	m.shader=s
	m.set_shader_parameter("rock_tex",load("res://assets/terrain_pbr/rock_diff.jpg"))
	m.set_shader_parameter("sand_normal",load("res://assets/terrain_pbr/sand_normal.jpg"))
	return m

func mesh_from_arrays(parent: Node3D, vertices: Array, indices: Array, material: Material) -> void:
	var expanded := PackedVector3Array()
	for i in range(0,indices.size(),3):
		var a: Vector3=vertices[indices[i]]
		var b: Vector3=vertices[indices[i+1]]
		var c: Vector3=vertices[indices[i+2]]
		if (b-a).cross(c-a).y>0:
			expanded.append_array([a,c,b])
		else:
			expanded.append_array([a,b,c])
	var normals:=PackedVector3Array()
	var tangents:=PackedFloat32Array()
	for vertex in expanded:
		normals.append(Vector3.UP)
		tangents.append_array([1.0,0.0,0.0,1.0])
	var a:=[]; a.resize(Mesh.ARRAY_MAX); a[Mesh.ARRAY_VERTEX]=expanded
	a[Mesh.ARRAY_NORMAL]=normals
	a[Mesh.ARRAY_TANGENT]=tangents
	var mesh:=ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a)
	var node:=MeshInstance3D.new(); node.mesh=mesh; node.material_override=material; node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; parent.add_child(node)

func add_channel(parent: Node3D) -> void:
	var n:=int(round(WIDTH/STEP)); var wv:=[]; var wi:=[]; var sv:=[]; var si:=[]
	for i in range(n+1):
		var x:float=-WIDTH*.5+i*STEP; var c:=river_center(x); var h:=river_half(x)
		wv.append(Vector3(x,-.02,c-h)); wv.append(Vector3(x,-.02,c+h))
		for side in [-1.0,1.0]:
			var inner: float=c+side*h; var shallow: float=c+side*(h+.7); var outer: float=c+side*(h+2.4)
			sv.append(Vector3(x,.0,inner)); sv.append(Vector3(x,.07,shallow)); sv.append(Vector3(x,.27,outer))
	for i in range(n):
		var q:=i*2; wi.append_array([q,q+2,q+3,q,q+3,q+1])
		for side in range(2):
			var s:=i*6+side*3; si.append_array([s,s+6,s+7,s,s+7,s+1,s+1,s+7,s+8,s+1,s+8,s+2])
	mesh_from_arrays(parent,sv,si,terrain_material(Color("a98f78"))); mesh_from_arrays(parent,wv,wi,water_material())
	river_records=[{"kit_id":"river_plane","piece_role":"continuous_channel","step_m":STEP,"width_m":WIDTH,"depth_m":DEPTH},{"kit_id":"river_bank","piece_role":"graded_wet_shore","shore_width_m":2.4}]

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT); root.size=Vector2i(1800,1200); var world:=Node3D.new(); root.add_child(world)
	var env:=WorldEnvironment.new(); env.environment=Environment.new(); env.environment.background_mode=Environment.BG_COLOR; env.environment.background_color=Color("b9c4c4"); env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR; env.environment.ambient_light_color=Color("d6b18a"); env.environment.ambient_light_energy=.4; env.environment.tonemap_exposure=.86; world.add_child(env)
	var sun:=DirectionalLight3D.new(); sun.rotation_degrees=Vector3(-52,-32,0); sun.light_color=Color("ffe0b4"); sun.light_energy=.72; sun.shadow_enabled=true; world.add_child(sun)
	env.environment.ambient_light_color=Color("e4e2dd")
	env.environment.ambient_light_energy=.42
	sun.light_color=Color("fff8ef")
	sun.light_energy=.65
	root.msaa_3d=Viewport.MSAA_4X
	var component:=Node3D.new(); world.add_child(component); var ground:=MeshInstance3D.new(); var plane:=PlaneMesh.new(); plane.size=Vector2(WIDTH,DEPTH); ground.mesh=plane; ground.position.y=-.30; ground.material_override=terrain_material(Color("b58d6d")); component.add_child(ground); add_channel(component)
	var camera:=Camera3D.new(); world.add_child(camera); camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	for view in [{"name":"overview","pos":Vector3(0,118,0),"target":Vector3(0,0,0),"size":106.0},{"name":"iso45","pos":Vector3(82,72,86),"target":Vector3(0,0,0),"size":110.0},{"name":"bank_detail","pos":Vector3(42,48,40),"target":Vector3(0,0,8),"size":55.0}]:
		camera.position=view.pos
		camera.size=view.size
		if view.name == "overview":
			camera.rotation_degrees=Vector3(-90,0,0)
		else:
			camera.look_at(view.target)
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUTPUT+"/"+view.name+".png")
	FileAccess.open(OUTPUT+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({"kit_id":"river_plane","status":"visual_prototype_pending_user_review","geometry":"continuous channel with matched section boundaries and upward-facing triangles","water_level":-.02,"in_channel_decorations":false,"material_paths":["res://assets/terrain_pbr/sand_diff.jpg","res://assets/terrain_pbr/sand_normal.jpg","res://assets/terrain_pbr/rock_diff.jpg"],"instances":river_records},"  ")); quit()
