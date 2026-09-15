extends "res://plateau_base.gd"

const OUTPUT = "G:/AIRTS/RTS_Map_Tool/review/G4/kit_samples/modular_plateau_final"
const HEIGHT = 18.0
const RAMP_TOP_Z = 25.0
# 10 m rise over 18 m run is approximately a 29 degree vehicle ramp.
const RAMP_FOOT_Z = 43.0
# Keep the socket visibly narrower than the mesa face while leaving a broad
# vehicle-scale lane; the shoulder geometry supplies the natural transition.
const OPENING_HALF_WIDTH = 22.0
const SIDE_RAMP_EDGE_BAND = 8.0

func segment_distance_poly(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b-a
	var denom = maxf(ab.length_squared(), 0.0001)
	var t = clampf((p-a).dot(ab)/denom, 0.0, 1.0)
	return p.distance_to(a.lerp(b,t))

func edge_distance_poly(p: Vector2, outline: PackedVector2Array) -> float:
	var result = 999.0
	for i in outline.size():
		result = minf(result, segment_distance_poly(p, outline[i], outline[(i+1)%outline.size()]))
	return result

func ramp_value(p: Vector2, a: Vector2, b: Vector2, width_top: float, width_foot: float) -> Vector2:
	# Return the target height and blend weight for one broad, outward ramp.
	# The corridor is allowed to continue outside the mesa polygon, which gives
	# the reference shape its four visible earthen approaches instead of a
	# detached raised island.
	var ab := b-a
	var length := maxf(ab.length(), .001)
	var t := (p-a).dot(ab)/maxf(ab.length_squared(), .001)
	var clamped_t := clampf(t, 0.0, 1.0)
	var lateral := absf(ab.cross(p-a))/length
	var half_width := lerpf(width_top, width_foot, clamped_t)
	var corridor := smoothstep(half_width+4.5, half_width-2.0, lateral)
	var along := smoothstep(-.16, .04, t) * (1.0-smoothstep(.90, 1.12, t))
	return Vector2(HEIGHT*(1.0-clamped_t), corridor*along)

func material(color: Color) -> ShaderMaterial:
	var result = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D sand_tex : source_color;
uniform sampler2D rock_tex : source_color;
uniform sampler2D sand_normal;
uniform sampler2D rock_normal;
uniform vec3 base_color;
varying vec3 world_position;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);}
void vertex(){world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){float n=noise(world_position.xz*.12)*.14+noise(world_position.xz*.55)*.06;ALBEDO=base_color*(.78+n);ROUGHNESS=.97;}
"""
	shader.set("code",shader.code)
	result.shader = shader
	result.set_shader_parameter("base_color",color)
	return result

func add_triangles(parent: Node3D, triangles: Array, color: Color):
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vertex in triangles:
		tool.add_vertex(vertex)
	# Shared vertices give sculpted terrain a continuous normal field instead of
	# visible strips from one normal per individual triangle.
	tool.index()
	tool.generate_normals()
	var instance = MeshInstance3D.new()
	instance.mesh = tool.commit()
	instance.material_override = material(color)
	parent.add_child(instance)

func scifi_cliff(parent: Node3D, name: String, position: Vector3, size: Vector3, yaw: float):
	var instance = load("res://assets/scifi_cliffs/"+name+".fbx").instantiate()
	var boxes: Array = []
	bounds(instance,instance.transform,boxes)
	var box: AABB = boxes[0]
	for candidate in boxes: box=box.merge(candidate)
	var holder=Node3D.new()
	parent.add_child(holder)
	holder.add_child(instance)
	instance.position-=box.get_center()
	holder.scale=size/box.size
	holder.position=position
	holder.rotation.y=yaw
	var texture=load("res://assets/scifi_cliffs/PolygonScifiWorlds_Texture_01_A.png")
	var stack=[instance]
	while stack.size():
		var node=stack.pop_back()
		stack.append_array(node.get_children())
		if node is MeshInstance3D:
			for surface in node.mesh.get_surface_count():
				var mat=StandardMaterial3D.new()
				mat.albedo_texture=texture
				mat.roughness=.92
				node.set_surface_override_material(surface,mat)

func add_plateau(parent: Node3D):
	# The inward notch is the ramp socket. Its back edge is the exact ramp seam.
	var outline = PackedVector2Array([
		Vector2(-51,-30), Vector2(-36,-43), Vector2(-8,-46), Vector2(25,-40),
		Vector2(48,-25), Vector2(53,4), Vector2(45,29), Vector2(26,40),
		Vector2(OPENING_HALF_WIDTH,38), Vector2(OPENING_HALF_WIDTH,RAMP_TOP_Z),
		Vector2(-OPENING_HALF_WIDTH,RAMP_TOP_Z), Vector2(-OPENING_HALF_WIDTH,38),
		Vector2(-39,34), Vector2(-54,15), Vector2(-50,-9)
	])
	var top: Array = []
	var underside: Array = []
	for index in Geometry2D.triangulate_polygon(outline):
		top.append(Vector3(outline[index].x,HEIGHT,outline[index].y))
		underside.append(Vector3(outline[index].x,0,outline[index].y))
	add_triangles(parent,top,Color("5d482a"))
	add_triangles(parent,underside,Color("25170d"))
	var walls: Array = []
	for i in outline.size():
		var a = outline[i]
		var b = outline[(i+1)%outline.size()]
		var bottom_a = Vector3(a.x,0,a.y)
		var bottom_b = Vector3(b.x,0,b.y)
		var top_a = Vector3(a.x,HEIGHT,a.y)
		var top_b = Vector3(b.x,HEIGHT,b.y)
		for vertex in [bottom_a,top_b,top_a,bottom_a,bottom_b,top_b]: walls.append(vertex)
	add_triangles(parent,walls,Color("4b2615"))
	# Rock kit overlays only the exterior walls; the ramp socket remains visibly clear.
	for i in outline.size():
		var a = outline[i]
		var b = outline[(i+1)%outline.size()]
		if a.y == RAMP_TOP_Z and b.y == RAMP_TOP_Z:
			continue
		var delta = b-a
		var count = maxi(1,ceili(delta.length()/13.0))
		for j in count:
			var center = a.lerp(b,(j+.5)/count)
			piece(parent,"SM_Env_Quarry_Wall_Straight_0"+str(1+j%2),Vector3(center.x,HEIGHT*.5,center.y),Vector3(delta.length()/count+1.4,HEIGHT,4.0),PI-atan2(delta.y,delta.x))

func ramp_vertex(t: float, lateral: float) -> Vector3:
	var center_y = HEIGHT * (1.0-smoothstep(0.0,1.0,t))
	# Keep the terrace connection broad, then let the natural apron narrow as it
	# descends.  The previous 16 -> 18 taper made a conspicuous funnel.
	var half_width = lerpf(OPENING_HALF_WIDTH,20.0,smoothstep(0.0,1.0,t))
	# A vehicle lane holds its width; short earth shoulders soften only the outer edges.
	var shoulder = smoothstep(0.76,1.0,absf(lateral))
	var y = center_y * (1.0-shoulder*smoothstep(0.08,1.0,t))
	return Vector3(lateral*half_width,y,lerpf(RAMP_TOP_Z,RAMP_FOOT_Z,t))

func add_ramp(parent: Node3D):
	var surface: Array = []
	var shell: Array = []
	const ROWS = 64
	const COLS = 32
	for row in ROWS:
		for col in COLS:
			var a=ramp_vertex(row/float(ROWS),col/float(COLS)*2.0-1.0)
			var b=ramp_vertex((row+1)/float(ROWS),col/float(COLS)*2.0-1.0)
			var c=ramp_vertex((row+1)/float(ROWS),(col+1)/float(COLS)*2.0-1.0)
			var d=ramp_vertex(row/float(ROWS),(col+1)/float(COLS)*2.0-1.0)
			for vertex in [a,c,b,a,d,c]: surface.append(vertex)
			var aa=Vector3(a.x,-.05,a.z)
			var bb=Vector3(b.x,-.05,b.z)
			var cc=Vector3(c.x,-.05,c.z)
			var dd=Vector3(d.x,-.05,d.z)
			for vertex in [aa,bb,cc,aa,cc,dd]: shell.append(vertex)
	var border: Array[Vector3] = []
	for col in COLS: border.append(ramp_vertex(0.0,col/float(COLS)*2.0-1.0))
	for row in ROWS: border.append(ramp_vertex(row/float(ROWS),1.0))
	for col in COLS: border.append(ramp_vertex(1.0,1.0-col/float(COLS)*2.0))
	for row in ROWS: border.append(ramp_vertex(1.0-row/float(ROWS),-1.0))
	for i in border.size():
		var a=border[i]
		var b=border[(i+1)%border.size()]
		var aa=Vector3(a.x,-.05,a.z)
		var bb=Vector3(b.x,-.05,b.z)
		# Side faces make the ramp a complete solid rather than a terrain sheet.
		for vertex in [a,bb,b,a,aa,bb]: shell.append(vertex)
	add_triangles(parent,surface,Color("72522b"))
	add_triangles(parent,shell,Color("3d1e11"))

func plateau_height(x: float, z: float, outline: PackedVector2Array) -> float:
	var on_plateau = Geometry2D.is_point_in_polygon(Vector2(x,z),outline)
	var ramp_half = lerpf(OPENING_HALF_WIDTH,11.5,clampf((z-RAMP_TOP_Z)/(RAMP_FOOT_Z-RAMP_TOP_Z),0.0,1.0))
	var on_ramp = z >= RAMP_TOP_Z and z <= RAMP_FOOT_Z and absf(x) <= ramp_half
	if on_plateau:
		return HEIGHT
	if on_ramp:
		var t = clampf((z-RAMP_TOP_Z)/(RAMP_FOOT_Z-RAMP_TOP_Z),0.0,1.0)
		var central = HEIGHT*(1.0-smoothstep(0.0,1.0,t))
		var shoulder = smoothstep(.72,1.0,absf(x)/ramp_half)
		return central*(1.0-shoulder*smoothstep(.08,1.0,t))
	return 0.0

func add_continuous_terrain(parent: Node3D):
	# One joined surface: plateau, socket, ramp and foot share the same vertices.
	var outline=PackedVector2Array([
		Vector2(-51,-30),Vector2(-36,-43),Vector2(-8,-46),Vector2(25,-40),
		Vector2(48,-25),Vector2(53,4),Vector2(45,29),Vector2(26,40),
		Vector2(-39,34),Vector2(-54,15),Vector2(-50,-9)
	])
	const MIN_X=-60
	const MAX_X=60
	const MIN_Z=-55
	const MAX_Z=95
	const STEP=2
	var top: Array=[]
	for z in range(MIN_Z,MAX_Z,STEP):
		for x in range(MIN_X,MAX_X,STEP):
			var ha=plateau_height(x,z,outline)
			var hb=plateau_height(x,z+STEP,outline)
			var hc=plateau_height(x+STEP,z+STEP,outline)
			var hd=plateau_height(x+STEP,z,outline)
			# Do not render zero-height cells; the external ground must remain visible.
			if maxf(ha,maxf(hb,maxf(hc,hd))) <= 0.01:
				continue
			var a=Vector3(x,ha,z)
			var b=Vector3(x,hb,z+STEP)
			var c=Vector3(x+STEP,hc,z+STEP)
			var d=Vector3(x+STEP,hd,z)
			for vertex in [a,c,b,a,d,c]: top.append(vertex)
	add_triangles(parent,top,Color("72522b"))
	# Rock-wall kit sits only on the steep outer silhouette, away from the ramp.
	for i in outline.size():
		var a=outline[i]
		var b=outline[(i+1)%outline.size()]
		if a.y > 20.0 and b.y > 20.0: continue
		var delta=b-a
		var count=maxi(1,ceili(delta.length()/13.0))
		for j in count:
			var center=a.lerp(b,(j+.5)/count)
			piece(parent,"SM_Env_Quarry_Wall_Straight_0"+str(1+j%2),Vector3(center.x,HEIGHT*.5,center.y),Vector3(delta.length()/count+1.4,HEIGHT,4.0),PI-atan2(delta.y,delta.x))

func path_point(t: float, side: float) -> Vector3:
	# The drive lane leaves the plateau through a shallow, deliberately asymmetric canyon.
	var center_x = sin(t * PI * .82) * 6.0 - t * 2.0
	var width = lerpf(9.0, 15.0, smoothstep(0.0, 1.0, t))
	var elevation = HEIGHT * (1.0 - smoothstep(0.0, 1.0, t))
	return Vector3(center_x + side * width, elevation, lerpf(16.0, 82.0, t))

func add_path_surface(parent: Node3D):
	var triangles: Array = []
	const ROWS = 96
	const COLS = 20
	for row in ROWS:
		for col in COLS:
			var a = path_point(row / float(ROWS), col / float(COLS) * 2.0 - 1.0)
			var b = path_point((row + 1) / float(ROWS), col / float(COLS) * 2.0 - 1.0)
			var c = path_point((row + 1) / float(ROWS), (col + 1) / float(COLS) * 2.0 - 1.0)
			var d = path_point(row / float(ROWS), (col + 1) / float(COLS) * 2.0 - 1.0)
			for v in [a,c,b,a,d,c]: triangles.append(v)
	add_triangles(parent, triangles, Color("a76e35"))
	# Close the two exposed cut faces down to the ground.  These faces sit behind
	# the rock dressing and prevent the playable slope from reading as a thin sheet.
	var cut_faces: Array = []
	const FACE_ROWS = 96
	for row in FACE_ROWS:
		for side in [-1.0, 1.0]:
			var a = path_point(row / float(FACE_ROWS), side)
			var b = path_point((row + 1) / float(FACE_ROWS), side)
			var aa = Vector3(a.x, 0, a.z)
			var bb = Vector3(b.x, 0, b.z)
			if side < 0:
				for v in [a,b,bb,a,bb,aa]: cut_faces.append(v)
			else:
				for v in [a,bb,b,a,aa,bb]: cut_faces.append(v)
	add_triangles(parent, cut_faces, Color("63391f"))

func add_canyon_berm(parent: Node3D, sign: float):
	# A broad earthen shoulder sits behind each rock wall. It makes the ramp read as cut
	# into the mesa instead of as a board attached to its face.
	var triangles: Array = []
	const ROWS = 72
	const COLS = 8
	for row in ROWS:
		for col in COLS:
			var ta = row / float(ROWS)
			var tb = (row + 1) / float(ROWS)
			var sa = col / float(COLS)
			var sb = (col + 1) / float(COLS)
			var va = path_point(ta, sign)
			var vb = path_point(tb, sign)
			var outward_a = Vector3(sign * (4.0 + 10.0 * ta) * sa, 0, 0)
			var outward_b = Vector3(sign * (4.0 + 10.0 * tb) * sa, 0, 0)
			var outward_c = Vector3(sign * (4.0 + 10.0 * tb) * sb, 0, 0)
			var outward_d = Vector3(sign * (4.0 + 10.0 * ta) * sb, 0, 0)
			var a = va + outward_a; a.y = lerpf(va.y, 0.15, sa)
			var b = vb + outward_b; b.y = lerpf(vb.y, 0.15, sa)
			var c = vb + outward_c; c.y = lerpf(vb.y, 0.05, sb)
			var d = va + outward_d; d.y = lerpf(va.y, 0.05, sb)
			for v in [a,c,b,a,d,c]: triangles.append(v)
	add_triangles(parent, triangles, Color("80502b"))

func add_finished_component(parent: Node3D):
	# An irregular mesa with a long socket cut into its southern edge.
	var plateau_outline = PackedVector2Array([
		Vector2(-52,-34), Vector2(-31,-47), Vector2(2,-46), Vector2(31,-37),
		Vector2(51,-17), Vector2(53,12), Vector2(43,34), Vector2(22,45),
		Vector2(13,42), Vector2(13,16), Vector2(-10,16), Vector2(-10,42),
		Vector2(-35,38), Vector2(-54,19), Vector2(-56,-10)
	])
	var top: Array = []
	var walls: Array = []
	for index in Geometry2D.triangulate_polygon(plateau_outline):
		top.append(Vector3(plateau_outline[index].x, HEIGHT, plateau_outline[index].y))
	for i in plateau_outline.size():
		var a = plateau_outline[i]
		var b = plateau_outline[(i + 1) % plateau_outline.size()]
		var ba = Vector3(a.x, 0, a.y); var bb = Vector3(b.x, 0, b.y)
		var ta = Vector3(a.x, HEIGHT, a.y); var tb = Vector3(b.x, HEIGHT, b.y)
		for v in [ba,tb,ta,ba,bb,tb]: walls.append(v)
	add_triangles(parent, top, Color("c58a45"))
	add_triangles(parent, walls, Color("6f3d22"))
	# Exterior walls and the two canyon jaws use the same sand-stone kit, with varied spans.
	for i in plateau_outline.size():
		var a = plateau_outline[i]; var b = plateau_outline[(i + 1) % plateau_outline.size()]
		var delta = b - a
		var count = maxi(1, ceili(delta.length() / 11.0))
		for j in count:
			var center = a.lerp(b, (j + .5) / count)
			var is_socket = (a.y >= 15.5 and b.y >= 15.5 and absf(a.x) < 15.0 and absf(b.x) < 15.0)
			var asset = "SM_Env_Quarry_Wall_Ramp_01" if is_socket else "SM_Env_Quarry_Wall_Straight_0" + str(1 + (i + j) % 2)
			piece(parent, asset, Vector3(center.x, HEIGHT * .48, center.y), Vector3(delta.length() / count + 1.6, HEIGHT * 1.05, 4.4), PI - atan2(delta.y, delta.x))
	# A continuous drive surface starts inside the socket and ends flush with ground.
	add_path_surface(parent)
	# Three large, varied rock masses form the canyon mouth. The middle section stays
	# open so the vehicle lane remains obvious from the RTS camera.
	for rock in [
		[Vector3(-14,7.2,24), Vector3(13,10,12), -.22],
		[Vector3(15,7.0,24), Vector3(12,10,13), .32],
		[Vector3(-20,3.4,47), Vector3(15,7,13), -.45],
		[Vector3(23,2.8,56), Vector3(16,6,14), .28]
	]:
		piece(parent, "SM_Env_RockFlat_03", rock[0], rock[1], rock[2])
	# Chunky rocks frame the mouth and break the repeated wall silhouette without blocking the lane.
	for p in [Vector3(-13.5,8.2,23), Vector3(15,8.3,24), Vector3(-20,5.7,39), Vector3(24,4.5,52), Vector3(-29,3.7,60), Vector3(31,2.7,69)]:
		piece(parent, "SM_Env_RockFlat_03", p, Vector3(8.5,7.0,7.0), rng.randf_range(-.45,.45))
	for p in [Vector2(-34,-20), Vector2(27,-29), Vector2(38,16), Vector2(-31,24), Vector2(-5,-31)]:
		piece(parent, "SM_Env_RockFlat_03", Vector3(p.x,10.8,p.y), Vector3(rng.randf_range(4,7),rng.randf_range(2,3.5),rng.randf_range(3,5)), rng.randf_range(0,TAU))
	for p in [Vector2(-25,2), Vector2(30,5), Vector2(5,-28)]:
		piece(parent, "SM_Env_Cactus_01", Vector3(p.x,11.0,p.y), Vector3(1.5,3.4,1.5), rng.randf_range(0,TAU))

func terrain_material() -> ShaderMaterial:
	var result = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D sand_tex : source_color;
uniform sampler2D rock_tex : source_color;
uniform sampler2D sand_normal;
uniform sampler2D rock_normal;
varying vec3 world_position;
varying vec3 world_normal;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);}
void vertex(){world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;world_normal=normalize(MODEL_NORMAL_MATRIX*NORMAL);}
void fragment(){
 // Hide the sub-voxel skirt where the sculpted mesh meets the flat basin.
 // Keeping the cutoff above the sampling floor removes the cyan-looking rim
 // without changing the playable ramp surface.
 if(world_position.y < .42){ discard; }
 float up=clamp(world_normal.y,0.0,1.0);
 float top=smoothstep(.72,.91,up)*smoothstep(8.4,9.5,world_position.y);
 float t=clamp((world_position.z-24.0)/19.0,0.0,1.0);
 float path_x=sin(t*3.14159*.70)*3.0-t*1.4;
 float path_half=mix(11.0,9.0,t*t*(3.0-2.0*t));
 float edge_wobble=sin(world_position.z*.26)*1.6+sin(world_position.z*.71+.7)*.7+sin(world_position.z*1.63+.35)*.34;
 float asymmetry=sign(world_position.x-path_x)*(sin(world_position.z*.19+.8)*1.25+sin(world_position.z*.53)*.42);
 float road=(1.0-smoothstep(path_half-1.0,path_half+3.0,abs(world_position.x-path_x)+edge_wobble+asymmetry))*smoothstep(18.0,24.0,world_position.z)*(1.0-smoothstep(41.0,46.0,world_position.z))*step(.22,world_position.y);
 float cliff=(1.0-smoothstep(.42,.73,up))*smoothstep(.20,1.5,world_position.y)*(1.0-road);
 float n=noise(world_position.xz*.14)*.11+noise(world_position.xz*.55)*.045;
 float vertical_breakup=noise(vec2(world_position.x*.12,world_position.y*.36+world_position.z*.045));
 float fissure=smoothstep(.67,.91,noise(vec2(world_position.x*.34+world_position.y*.06,world_position.z*.12)));
 vec2 top_uv=world_position.xz*.050;
 vec2 wall_uv=(abs(world_normal.x)>abs(world_normal.z)?world_position.zy:world_position.xy)*.055;
 vec3 sand=texture(sand_tex,top_uv).rgb;
 vec3 rock=texture(rock_tex,wall_uv).rgb;
	vec3 sand_n=texture(sand_normal,top_uv).rgb;
	vec3 rock_n=texture(rock_normal,wall_uv).rgb;
 // Warm basin soil keeps the exposed toe and mesa edge in the same desert
 // palette; the previous green low color produced an artificial outline.
 vec3 low=vec3(.25,.16,.09); vec3 road_sand=sand*vec3(.76,.51,.29); vec3 mesa=sand*vec3(.84,.61,.37);
 vec3 albedo=mix(low,road_sand,road); albedo=mix(albedo,mesa,top);
 albedo=mix(albedo,rock*vec3(.54,.33,.20)+vertical_breakup*vec3(.030,.016,.007)-fissure*vec3(.060,.035,.018),cliff);
 // Fade the lowest part of the cliff into the basin soil so the mesh edge
 // reads as an eroded toe instead of a colored outline.
 albedo=mix(low,albedo,smoothstep(.35,1.15,world_position.y));
 ALBEDO=albedo+n; ROUGHNESS=.98;
 NORMAL_MAP=mix(sand_n,rock_n,cliff);
 NORMAL_MAP_DEPTH=.48;
}
"""
	shader.set("code", shader.code)
	result.shader = shader
	result.set_shader_parameter("sand_tex",load("res://assets/terrain_pbr/sand_diff.jpg"))
	result.set_shader_parameter("rock_tex",load("res://assets/terrain_pbr/rock_diff.jpg"))
	result.set_shader_parameter("sand_normal",load("res://assets/terrain_pbr/sand_normal.jpg"))
	result.set_shader_parameter("rock_normal",load("res://assets/terrain_pbr/rock_normal.jpg"))
	return result

func valley_material() -> ShaderMaterial:
	var result=ShaderMaterial.new()
	var shader=Shader.new()
	shader.code="""
shader_type spatial;
uniform sampler2D sand_tex : source_color;
varying vec3 world_position;
void vertex(){world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
 vec3 sand=texture(sand_tex,world_position.xz*.038).rgb;
 ALBEDO=sand*vec3(.55,.43,.28); ROUGHNESS=.98;
}
"""
	shader.set("code",shader.code)
	result.shader=shader
	result.set_shader_parameter("sand_tex",load("res://assets/terrain_pbr/sand_diff.jpg"))
	return result

# ---- Reference-matched mesa: rounded irregular blob + four broad earth aprons.
# One continuous height field; the apron corridors and the rounded rim shoulder
# are blended inside the same function, so no seam, shelf or floating chunk can
# appear where a ramp meets the mesa edge.
const MESA_CENTER := Vector2(0.0, -4.0)
const MESA_SX := 1.16
const MESA_SZ := 0.98
const MESA_RADIUS := 46.0
const MESA_EDGE_IN := 3.4
const MESA_EDGE_OUT := 3.4
# azimuth_deg, run_m, half_angle_deg, angular_feather_deg
# Two broad front diagonals plus one outward apron on each rear flank.
# Each apron is a radial sector of the same rim rollover, so the mesa edge
# simply keeps rolling outward instead of meeting a separate corridor.
const MESA_RAMPS := [
	[130.0, 44.0, 26.0, 10.0],
	[50.0, 44.0, 26.0, 10.0],
	[215.0, 40.0, 22.0, 10.0],
	[-35.0, 40.0, 22.0, 10.0]
]

func mesa_radius(theta: float) -> float:
	# Fuller front and back, gently pinched flanks: -cos(2t) peaks at 90/270 deg.
	return MESA_RADIUS*(1.0-.06*cos(theta*2.0)+.06*sin(theta*3.0-1.1)+.045*sin(theta*5.0+2.3)+.025*sin(theta*7.0-.7))

func mesa_ramp_specs() -> Array:
	var specs: Array=[]
	for entry in MESA_RAMPS:
		specs.append({
			"az":deg_to_rad(float(entry[0])),
			"run":float(entry[1]),
			"half_a":deg_to_rad(float(entry[2])),
			"feather_a":deg_to_rad(float(entry[3]))
		})
	return specs

func ramp_profile_height(distance: float, run: float, ease: float=2.0) -> float:
	var t:=clampf(distance,0.0,run)
	var drop:=t-ease*.5
	if t<ease:
		drop=t*t/(2.0*ease)
	elif t>run-ease:
		drop=run-ease-pow(run-t,2.0)/(2.0*ease)
	return HEIGHT*(1.0-drop/(run-ease))

func mesa_height(x: float, z: float, specs: Array) -> float:
	var u:=Vector2((x-MESA_CENTER.x)/MESA_SX,(z-MESA_CENTER.y)/MESA_SZ)
	var r:=u.length()
	var theta:=atan2(u.y,u.x)
	var rb:=mesa_radius(theta)
	var local_scale:=sqrt(pow(MESA_SX*cos(theta),2.0)+pow(MESA_SZ*sin(theta),2.0))
	var d:=(rb-r)*local_scale
	# The rim rolls over both ways; the top stays level until the edge band.
	var h:=HEIGHT*smoothstep(-MESA_EDGE_OUT,MESA_EDGE_IN,d)
	h+=(sin(x*.12+z*.09)+sin(x*.27-z*.13)+sin(x*.55+z*.31)*.5)*.11*smoothstep(.6,3.2,d)
	var s_out:=(r-rb)*local_scale
	var best_w:=0.0
	for spec in specs:
		var delta:=wrapf(theta-float(spec["az"]),-PI,PI)
		var ang:=1.0-smoothstep(float(spec["half_a"]),float(spec["half_a"])+float(spec["feather_a"]),absf(delta))
		# Finish taking over on the flat top, before the cliff rollover starts.
		# Blending after that point creates a dip followed by an uphill lip.
		var walong:=smoothstep(-MESA_EDGE_IN-3.0,-MESA_EDGE_IN-1.0,s_out)
		var w:=ang*walong
		if w>best_w:
			best_w=w
			h=lerpf(h,ramp_profile_height(s_out,float(spec["run"])),w)
	# Eroded rock relief on the cliff band only: keeps the top and the playable
	# ramp faces smooth while the walls gain weathered sandstone character.
	if h > .4 and h < HEIGHT*.94:
		var band:=smoothstep(.05,.22,h/HEIGHT)*(1.0-smoothstep(.78,1.0,h/HEIGHT))
		var relief:=(sin(x*.62+z*.41)+sin(x*.29-z*.77)*.8+sin(x*1.31+z*.93)*.5)
		h+=relief*.42*band*(1.0-best_w)
	return h

func add_sculpted_terrain(parent: Node3D):
	# Shared heightfield for the mesa and its four broad earthen approaches.
	const MIN_X = -88
	const MAX_X = 88
	const MIN_Z = -72
	const MAX_Z = 106
	const STEP = .5
	const WIDTH = 352
	const DEPTH = 356
	var specs:=mesa_ramp_specs()
	var vertices = PackedVector3Array()
	var indices = PackedInt32Array()
	for iz in range(DEPTH + 1):
		var z = MIN_Z + iz * STEP
		for ix in range(WIDTH + 1):
			var x = MIN_X + ix * STEP
			vertices.append(Vector3(x,mesa_height(x,z,specs),z))
	for iz in range(DEPTH):
		for ix in range(WIDTH):
			var a = iz*(WIDTH+1)+ix; var b = a+1; var c = a+(WIDTH+1); var d = c+1
			indices.append_array([a,d,c,a,b,d])
	var arrays=[]
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	# Generate normals through SurfaceTool after indexing so transitions remain smooth.
	var st=SurfaceTool.new(); st.create_from(mesh,0); st.generate_normals(); mesh=st.commit()
	var instance=MeshInstance3D.new()
	instance.mesh=mesh
	instance.material_override=terrain_material()
	parent.add_child(instance)
	# Sparse dressing only: a few small blocks on the top and scattered stones at
	# the cliff toe, all seated with the same height field so nothing floats.
	for p in [Vector2(-14,6),Vector2(11,-7),Vector2(21,10)]:
		var h:=mesa_height(p.x,p.y,specs)
		piece(parent,"SM_Env_RockFlat_03",Vector3(p.x,h+.55,p.y),Vector3(rng.randf_range(2.4,3.4),rng.randf_range(.8,1.2),rng.randf_range(1.9,2.6)),rng.randf_range(0,TAU))
	for p in [Vector2(-58,-24),Vector2(62,2),Vector2(-20,46),Vector2(34,42),Vector2(-3,-52),Vector2(-45,30)]:
		var h:=mesa_height(p.x,p.y,specs)
		piece(parent,"SM_Env_RockFlat_03",Vector3(p.x,h+.35,p.y),Vector3(rng.randf_range(2.2,3.4),rng.randf_range(.9,1.5),rng.randf_range(1.8,2.8)),rng.randf_range(0,TAU))
	for p in [Vector2(-30,26),Vector2(28,24),Vector2(6,-46)]:
		var h:=mesa_height(p.x,p.y,specs)
		piece(parent,"SM_Env_Cactus_01",Vector3(p.x,h+.9,p.y),Vector3(1.0,2.2,1.0),rng.randf_range(0,TAU))

func run():
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	root.size=Vector2i(2000,1400)
	var world=Node3D.new()
	root.add_child(world)
	var environment=WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color("b9c9d0")
	environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	# Warm ambient fill prevents the unlit mesh rim from picking up a cyan cast.
	environment.environment.ambient_light_color=Color("d6a06b")
	environment.environment.ambient_light_energy=.34
	environment.environment.tonemap_exposure=.78
	world.add_child(environment)
	var sun=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.light_energy=.78
	sun.shadow_enabled=true
	world.add_child(sun)
	var ground=MeshInstance3D.new()
	var plane=PlaneMesh.new()
	plane.size=Vector2(260,260)
	ground.mesh=plane
	ground.position.y=-.1
	ground.material_override=valley_material()
	world.add_child(ground)
	var component=Node3D.new()
	world.add_child(component)
	rng.seed=32871
	add_sculpted_terrain(component)
	var camera=Camera3D.new()
	world.add_child(camera)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	var views=[
		{"name":"overview","pos":Vector3(108,96,128),"target":Vector3(0,4,14),"size":138.0},
		{"name":"ramp_socket","pos":Vector3(62,33,88),"target":Vector3(0,5,38),"size":70.0},
		{"name":"low_angle","pos":Vector3(62,17,88),"target":Vector3(0,4,38),"size":70.0}
	]
	for view in views:
		camera.position=view.pos
		camera.size=view.size
		camera.look_at(view.target)
		for frame in 12: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUTPUT+"/"+view.name+".png")
	FileAccess.open(OUTPUT+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({"height_m":HEIGHT,"ramp_length_m":RAMP_FOOT_Z-RAMP_TOP_Z,"socket_width_m":OPENING_HALF_WIDTH*2,"geometry":"closed plateau and closed ramp"},"  "))
	quit()
