extends RefCounted
## Finds a local roof box for Source Snow using the existing shelter collision mask.

const QUERY_LIMIT := 32
const MAXIMUM_BOX_THICKNESS_RATIO := 0.30

var _shape := BoxShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()


func _init() -> void:
	_query.shape = _shape
	_query.collide_with_areas = false
	_query.collide_with_bodies = true


func decode_roof(observer: Vector3, hit: Dictionary) -> Dictionary:
	var body := hit.get(&"collider") as CollisionObject3D
	if not is_instance_valid(body):
		return {}
	var shape_id: int = hit[&"shape"]
	var owner := body.shape_find_owner(shape_id)
	var shape_transform := body.global_transform * body.shape_owner_get_transform(owner)
	if shape_transform.basis.y.normalized().dot(Vector3.UP) < 0.995:
		return {}
	for local_index: int in body.shape_owner_get_shape_count(owner):
		if body.shape_owner_get_shape_index(owner, local_index) != shape_id:
			continue
		var box := body.shape_owner_get_shape(owner, local_index) as BoxShape3D
		if box == null or box.size.y > minf(box.size.x, box.size.z) * MAXIMUM_BOX_THICKNESS_RATIO:
			return {}
		var box_from_world := shape_transform.affine_inverse()
		var local := box_from_world * observer
		if local.y >= box.size.y * 0.5:
			return {}
		var half_size := box.size * 0.5
		var horizontal_margin := Vector2(absf(local.x) - half_size.x, absf(local.z) - half_size.z)
		var horizontal_scale := Vector2(shape_transform.basis.x.length(), shape_transform.basis.z.length())
		return {
			&"box_from_world": box_from_world,
			&"half_size": half_size,
			&"distance_squared": (horizontal_margin.max(Vector2.ZERO) * horizontal_scale).length_squared(),
		}
	return {}


func find_nearby_roof(
	space: PhysicsDirectSpaceState3D, observer: Vector3, span: float,
	probe_height: float, mask: int, excluded: Array[RID],
) -> Dictionary:
	if mask == 0 or probe_height <= 0.0:
		return {}
	# Include the near-fog footprint and the existing overhead probe's vertical span.
	_shape.size = Vector3(span * 2.0, probe_height + 0.2, span * 2.0)
	_query.transform = Transform3D(Basis.IDENTITY, observer + Vector3.UP * ((probe_height - 0.2) * 0.5))
	_query.collision_mask = mask
	_query.exclude = excluded
	var closest: Dictionary = {}
	var best_distance_squared := INF
	for hit: Dictionary in space.intersect_shape(_query, QUERY_LIMIT):
		var candidate := decode_roof(observer, hit)
		if candidate.is_empty() or candidate[&"distance_squared"] >= best_distance_squared:
			continue
		closest = candidate
		best_distance_squared = candidate[&"distance_squared"]
	return closest
