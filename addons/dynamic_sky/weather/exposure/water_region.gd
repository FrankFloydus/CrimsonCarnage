@tool
class_name DynamicSkyWaterRegion
extends Area3D
## The node origin defines a horizontal water surface within a Box or Sphere footprint.

const GROUP := &"dynamic_sky_water_regions"

## Enables this water surface for local observer queries.
@export var enabled: bool = true
## Box X/Z bounds or Sphere radius defining the surface footprint. Vertical size is ignored.
@export var region: Shape3D:
	set(value):
		region = value
		if is_node_ready():
			_update_shape()


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		add_to_group(GROUP)


func _ready() -> void:
	_update_shape()


func _get_configuration_warnings() -> PackedStringArray:
	if not region is BoxShape3D and not region is SphereShape3D:
		return ["Assign a BoxShape3D or SphereShape3D footprint for the water surface."]
	if is_inside_tree() and global_basis.y.normalized().dot(Vector3.UP) < 0.9999:
		return ["Water regions use horizontal surfaces. Keep rotation around the world Y axis."]
	return []


## Returns the surface height within the footprint, or negative infinity outside it.
func get_water_level_at(world_position: Vector3) -> float:
	if (
		not enabled or not world_position.is_finite() or not is_inside_tree()
		or absf(global_basis.determinant()) < 0.000001
		or global_basis.y.normalized().dot(Vector3.UP) < 0.9999
	):
		return -INF
	var point := to_local(Vector3(world_position.x, global_position.y, world_position.z))
	if region is BoxShape3D:
		var size := (region as BoxShape3D).size
		if absf(point.x) <= size.x * 0.5 and absf(point.z) <= size.z * 0.5:
			return global_position.y
	elif region is SphereShape3D:
		var radius := (region as SphereShape3D).radius
		if Vector2(point.x, point.z).length_squared() <= radius * radius:
			return global_position.y
	return -INF


func _update_shape() -> void:
	var marker := get_node_or_null(^"Region") as CollisionShape3D
	if marker != null:
		marker.shape = region
		marker.disabled = true
	update_configuration_warnings()
