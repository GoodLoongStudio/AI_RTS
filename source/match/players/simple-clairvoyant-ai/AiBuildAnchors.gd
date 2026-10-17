extends RefCounted

## Pure own-observation planning, shared by economy and production.
## Construction state and positions come from the existing query boundary.
static func completed_centers(entities: Array) -> Array:
	return entities.filter(func(entity):
		var site = entity.get("construction", null)
		return entity.get("type_id", "") == "command_center" and site != null \
			and site.get("state", "") == "Completed")


static func nearest_center(entity: Dictionary, centers: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	for center in centers:
		var distance: float = entity["position"].distance_squared_to(center["position"])
		if distance < best_distance:
			best_distance = distance
			best = center
	return best


## Assign each existing refinery to its nearest completed HQ. Pending sites
## count too, so a slow remote build cannot cause duplicate requests.
static func refinery_anchor(entities: Array) -> Vector3:
	var centers := completed_centers(entities)
	var served := {}
	for entity in entities:
		if entity.get("type_id", "") == "ore_refinery" and not centers.is_empty():
			served[nearest_center(entity, centers)["id"]] = true
	for center in centers:
		if not served.has(center["id"]):
			return center["position"]
	return Vector3.INF


## Production stays at the opening HQ; expansions serve ore and defense.
## If that HQ is lost, continue at the closest surviving completed HQ.
static func production_anchor(entities: Array, home: Vector3 = Vector3.INF) -> Vector3:
	var centers := completed_centers(entities)
	if centers.is_empty():
		return Vector3.INF
	if home.is_finite():
		return nearest_center({"position": home}, centers)["position"]
	return centers[0]["position"]


## Assign towers to their nearest HQ and protect the least defended base.
static func defense_anchor(entities: Array, type_id: String) -> Vector3:
	var centers := completed_centers(entities)
	if centers.is_empty():
		return Vector3.INF
	var loads := {}
	for center in centers:
		loads[center["id"]] = 0
	for entity in entities:
		if entity.get("type_id", "") != type_id:
			continue
		var center := nearest_center(entity, centers)
		loads[center["id"]] += 1
	var best: Dictionary = centers[0]
	for center in centers:
		if loads[center["id"]] < loads[best["id"]]:
			best = center
	return best["position"]
