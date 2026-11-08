class_name AbilityProjectile
extends Node3D
## Reports the first swept collision or expiration of one projectile flight.

## Contact with the first swept body, including surface geometry for phase targeting.
signal contact_reached(collider: Node, world_position: Vector3, normal: Vector3)
## Flight ended without a contact.
signal expired(world_position: Vector3)

## Travel speed in meters per second along the projectile's local forward axis.
@export_range(0.1, 200.0, 0.1) var speed: float = 18.0
## Maximum flight time in seconds before a projectile expires without a hit.
@export_range(0.1, 60.0, 0.1) var lifetime: float = 5.0
## Physics body layers hit by the swept ray; the source body is excluded at launch.
@export_flags_3d_physics var collision_mask: int = 1

var _excluded: Array[RID] = []
var _elapsed: float = 0.0
var _launched: bool = false
var _direction: Vector3 = Vector3.FORWARD


func launch(excluded_body: CollisionObject3D = null) -> void:
	_excluded.clear()
	if is_instance_valid(excluded_body):
		_excluded.append(excluded_body.get_rid())
	_direction = -global_basis.z.normalized()
	_elapsed = 0.0
	_launched = true


func _physics_process(delta: float) -> void:
	if not _launched:
		return
	var travel_time := minf(delta, maxf(0.0, lifetime - _elapsed))
	var destination := global_position + _direction * speed * travel_time
	var query := PhysicsRayQueryParameters3D.create(
			global_position, destination, collision_mask, _excluded
	)
	query.collide_with_areas = false
	var collision := get_world_3d().direct_space_state.intersect_ray(query)
	if not collision.is_empty():
		global_position = collision["position"]
		_launched = false
		var collider := collision["collider"] as Node
		contact_reached.emit(collider, global_position, collision["normal"])
		queue_free()
		return
	global_position = destination
	_elapsed += delta
	if _elapsed >= lifetime:
		_launched = false
		expired.emit(global_position)
		queue_free()


## Cancels the flight without emitting a contact or expiration phase.
func stop() -> void:
	_launched = false
	queue_free()
