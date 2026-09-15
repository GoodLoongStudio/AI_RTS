extends RefCounted

const Butte = preload("res://tools/godot/sandstone_butte.gd")

# Every entry in a mass list is a broken ridge family, never a mesa.  The shape
# field now only selects which family the mass uses (ridge length and summit
# count); height stays the summit magnitude in the caller's local units.
static func catalog() -> Array:
	return [
		{"id":"SquareTopMountain","position":Vector3(7,0,61),"masses":[
			{"center":Vector2(-2,-1),"size":Vector2(16,11),"height":17.0,"shape":"ridge","phase":1.3},
			{"center":Vector2(10,3),"size":Vector2(9,8),"height":10.0,"shape":"ridge_short","phase":3.1}]},
		{"id":"TerracedMassif","position":Vector3(65,0,65),"masses":[
			{"center":Vector2(-9,-3),"size":Vector2(17,12),"height":23.0,"shape":"ridge","phase":2.0},
			{"center":Vector2(5,1),"size":Vector2(15,13),"height":19.0,"shape":"ridge_forked","phase":2.9},
			{"center":Vector2(18,5),"size":Vector2(10,9),"height":12.0,"shape":"ridge_short","phase":4.0}]},
		{"id":"MixedMountainRange","position":Vector3(22,0,135),"masses":[
			{"center":Vector2(-18,1),"size":Vector2(12,11),"height":14.0,"shape":"ridge_short","phase":.6},
			{"center":Vector2(-4,-5),"size":Vector2(15,12),"height":25.0,"shape":"ridge","phase":2.2},
			{"center":Vector2(11,-1),"size":Vector2(12,10),"height":19.0,"shape":"ridge_forked","phase":3.5},
			{"center":Vector2(24,5),"size":Vector2(11,9),"height":18.0,"shape":"ridge","phase":4.7}]}
	]

# One mass -> one continuous, fractured ridge.  Multi-summit crest, saddles,
# cross-ridge gullies, an irregular branch spur and a low deposition skirt; the
# top is nowhere a constant-height cap.
static func mass_relief(delta: Vector2, mass: Dictionary) -> float:
	var size: Vector2 = mass.size
	var phase: float = mass.phase
	var shape: String = str(mass.get("shape","ridge"))
	var q := Vector2(delta.x/size.x,delta.y/size.y).rotated(sin(phase*1.31)*.9)

	var ridge_angle := phase*1.7
	var along_len := .88
	var across_half := .68
	var peaks := 3
	if shape=="ridge_short":
		ridge_angle += .8
		along_len = .58
		across_half = .72
		peaks = 2
	elif shape=="ridge_forked":
		ridge_angle -= .5
		along_len = 1.00
		across_half = .58
		peaks = 3

	var axis := Vector2(cos(ridge_angle),sin(ridge_angle))
	var along := q.dot(axis)
	var across := q.dot(Vector2(-axis.y,axis.x))

	# Plan-form: the crest snakes and its half-width swells into buttresses.
	var crest := .26*sin(along*2.4+phase)+.12*sin(along*5.3-phase*1.7)
	var d_across := across-crest
	var broad := Butte.rock_noise.get_noise_2d(along*1.7+phase*23.0,d_across*1.7)
	var fine := Butte.rock_noise.get_noise_2d(along*4.3+phase*11.0,d_across*4.3)
	var w := maxf(across_half*(.86+.14*broad+.08*fine),.14)
	var pu := clampf(1.0-absf(d_across)/w,0.0,1.0)
	var prof := pu*pu*(3.0-2.0*pu)
	var taper := 1.0-smoothstep(along_len*.75,along_len*1.05,absf(along))

	# 2-3 summits of unequal height, all carried by one connected crest spine so
	# the mass reads as a broken ridge with saddles instead of separate cones.
	var summit := .58+.14*(.5+.5*broad)
	var top := 0.0
	var defs: Array=[]
	var spread := .66 if peaks<3 else .80
	for k in peaks:
		var t := 0.0 if peaks<2 else float(k)/float(peaks-1)
		var side := absf(t-.5)*2.0
		var c := (t*2.0-1.0)*along_len*spread
		var hh := 1.0-.28*side+.10*sin(phase*2.7+float(k)*2.3)
		var ww := maxf(along_len*(.48+.14*sin(phase*1.9+float(k)*2.1)),.18)
		defs.append(Vector3(c,hh,ww))
		top = maxf(top,hh)
	for d in defs:
		var u := clampf(1.0-absf((along-d.x)/d.z),0.0,1.0)
		summit = maxf(summit,(d.y/maxf(top,1.0e-4))*u*u*(3.0-2.0*u))

	# Narrow gullies bite across the ridge, deepening the saddles and cropping
	# the flank spurs without flattening the summits themselves.
	var notch := 0.0
	for spot in [-.40,.40,.92]:
		var sf: float = spot
		var nc := sf*along_len+.16*sin(phase*5.1+sf*3.3)
		var nw := .11+.05*sin(phase*1.3+sf)
		var nd := .16+.10*(.5+.5*sin(phase*3.7+sf*2.1))
		var u := clampf(1.0-absf((along-nc)/maxf(nw,.04)),0.0,1.0)
		notch = maxf(notch,nd*u*u*(3.0-2.0*u))
	notch *= .30+.70*prof

	var ridge: float = mass.height*prof*taper*summit*(1.0-notch)

	# A short, low spur branches off at an angle: an irregular buttress, not a
	# second wall.
	var sq := q.rotated(-(ridge_angle+.95+.45*sin(phase*2.1)))
	var su := clampf(1.0-absf(sq.y-.34)/.28,0.0,1.0)
	var spur_prof := su*su*(3.0-2.0*su)
	var spur_taper := 1.0-smoothstep(.30,.80,absf(sq.x))
	var spur: float = mass.height*.52*spur_prof*spur_taper*(.85+.30*broad)

	# Low-frequency deposition fan: a wide, low skirt that lifts the desert floor
	# into the mass, so the mountain grows out of the ground instead of being
	# sliced off vertically at its foot.
	var fan_noise := Butte.rock_noise.get_noise_2d(delta.x*.22+phase*13.0,delta.y*.22+phase*7.0)
	var fan_warp := Butte.rock_noise.get_noise_2d(delta.x*.35+phase*31.0,delta.y*.35-phase*17.0)
	var fan_reach := 1.55+.35*fan_noise
	# Decays linearly from the very centre outwards, so the apron is a continuous
	# cone of sediment with no constant-height plinth under the mass.
	var fan := clampf(1.0-(q.length()+fan_warp*.18)/fan_reach,0.0,1.0)
	var skirt: float = mass.height*(.085+.05*(.5+.5*fan_noise))*fan

	return maxf(maxf(ridge,spur),skirt)

static func elevation(p: Vector2, masses: Array) -> float:
	var height:=0.0
	for mass in masses:
		var value:=maxf(mass_relief(p-mass.center,mass),0.0)
		# Smooth unions join neighbouring feet and saddles instead of exposing
		# intersecting primitives. Zero-height ground remains exactly zero.
		var overlap:=maxf(0.0,1.5-absf(height-value))/1.5
		height=maxf(height,value)+overlap*overlap*.375*smoothstep(0.0,2.0,minf(height,value))
	# Keep the kit inside its sampling grid: the footprint edge must be exactly
	# zero so the tile boundary never lifts or sinks the surrounding ground.
	height *= (1.0-smoothstep(41.5,43.4,absf(p.x)))*(1.0-smoothstep(21.5,24.4,absf(p.y)))
	return maxf(height,0.0)

static func build(spec: Dictionary, material: Material) -> Node3D:
	var root:=Node3D.new()
	root.name=spec.id
	root.position=spec.position
	var vertices:=PackedVector3Array()
	var indices:=PackedInt32Array()
	const STEP:=.5
	const NX:=176
	const NZ:=100
	for iz in range(NZ+1):
		for ix in range(NX+1):
			var p:=Vector2((ix-NX*.5)*STEP,(iz-NZ*.5)*STEP)
			vertices.append(Vector3(p.x,elevation(p,spec.masses),p.y))
	for iz in range(NZ):
		for ix in range(NX):
			var a:=iz*(NX+1)+ix
			var b:=a+1
			var c:=a+NX+1
			var d:=c+1
			if maxf(maxf(vertices[a].y,vertices[b].y),maxf(vertices[c].y,vertices[d].y))>.001:
				indices.append_array([a,b,c,b,d,c])
	var arrays:=[]
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh:=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var surface:=SurfaceTool.new()
	surface.create_from(mesh,0)
	surface.generate_normals()
	var instance:=MeshInstance3D.new()
	instance.name="ContinuousMountain"
	instance.mesh=surface.commit()
	instance.material_override=material
	root.add_child(instance)
	root.set_meta("masses",spec.masses)
	return root
