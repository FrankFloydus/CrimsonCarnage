class_name AbilityTargetContact
extends RefCounted
## One actor or world point selected by a delivery or query.

var position: Vector3
var normal: Vector3
var has_geometry: bool
var actor_id: int
var _target: WeakRef


func _init(
		point: Vector3, target: AbilitySystem = null,
		surface_normal: Vector3 = Vector3.ZERO, has_surface: bool = false
) -> void:
	position = point
	normal = surface_normal
	has_geometry = has_surface
	if is_instance_valid(target):
		actor_id = target.get_instance_id()
		_target = weakref(target)


## Resolves the actor while it remains available in the scene tree.
func get_target() -> AbilitySystem:
	var target := _target.get_ref() as AbilitySystem if _target != null else null
	return target if is_instance_valid(target) and target.is_inside_tree() else null
