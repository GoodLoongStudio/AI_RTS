extends RefCounted

static var rock_noise: FastNoiseLite = make_noise()

static func make_noise() -> FastNoiseLite:
	var noise:=FastNoiseLite.new()
	noise.seed=91126
	noise.frequency=.10
	noise.fractal_octaves=3
	return noise

# A broad, angular sandstone cap above fluted walls and a short talus skirt.
# Returns relief above the supporting terrain, in the caller's local units.
static func elevation(point: Vector2, half_size: Vector2, height: float, phase: float) -> float:
	var q := point / half_size
	# Unequal cut planes produce fractured sandstone blocks, not repeated
	# scalloped cylinders. Broad erosion and finer gullies use different scales.
	q=q.rotated(sin(phase)*.22)
	var radius:=maxf(maxf(absf(q.x),absf(q.y)),maxf(absf(q.x*.78+q.y*.65)*.87,absf(q.x*.65-q.y*.80)*.82))
	var broad:=rock_noise.get_noise_2d(point.x*.65+phase*30.0,point.y*.65)
	var detail:=rock_noise.get_noise_2d(point.x*2.4+phase*40.0,point.y*2.4)
	var edge:=radius+(broad*.18+detail*.065)*smoothstep(.35,.80,radius)
	var upper:=1.0-smoothstep(.52,.78,edge)
	var middle:=1.0-smoothstep(.76,1.03,edge)
	var apron:=1.0-smoothstep(.94,1.28,edge)
	var cap:=height*(.98+broad*.028)
	return cap*(upper*.60+middle*.31+apron*.09)

static func plateau_specs() -> Array:
	return [
		{"id":"rear_table_ridge", "center":Vector2(-7,-43), "half_size":Vector2(20,9), "height":25.0, "phase":.7},
		{"id":"upper_east_butte", "center":Vector2(25,-37), "half_size":Vector2(10,8), "height":31.0, "phase":2.1},
		{"id":"west_shoulder_butte", "center":Vector2(-38,-13), "half_size":Vector2(9,13), "height":22.0, "phase":4.3}
	]
