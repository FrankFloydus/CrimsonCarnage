class_name AbilityProjectile
extends Node3D
## Carries outgoing Gameplay Effect Specs to the first swept collision along its path.

signal impacted(collider: Node, world_position: Vector3)

## Travel speed in meters per second along the projectile's local forward axis.
@export_range(0.1, 200.0, 0.1) var speed: float = 18.0
## Maximum flight time in seconds before a projectile expires without a hit.
@export_range(0.1, 60.0, 0.1) var lifetime: float = 5.0
## Physics body layers hit by the swept ray; the source body is excluded at launch.
@export_flags_3d_physics var collision_mask: int = 1

var _context: GameplayEffectContext
var _specs: Array[GameplayEffectSpec] = []
var _excluded: Array[RID] = []
var _elapsed: float = 0.0
var _launched: bool = false
var _direction: Vector3 = Vector3.FORWARD


func launch(
		context: GameplayEffectContext,
		specs: Array[GameplayEffectSpec],
		excluded_body: CollisionObject3D = null
) -> void:
	_context = context
	_specs = specs.duplicate()
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
		var target := AbilitySystem.find_for(collider)
		if target != null and _context != null:
			var hit_context := _context.duplicate_for_hit(0.5)
			hit_context.hit_position = global_position
			hit_context.hit_normal = collision["normal"]
			hit_context.has_hit_result = true
			target.receive_hit_specs(hit_context, _specs)
		impacted.emit(collider, global_position)
		queue_free()
		return
	global_position = destination
	_elapsed += delta
	if _elapsed >= lifetime:
		_launched = false
		queue_free()
