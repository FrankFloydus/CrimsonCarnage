@tool
class_name SelectiveResourceSnapshotEffectComponent
extends GameplayEffectComponent
## Captures selected current pools and an optional safe actor transform for later restoration.

## Only these current pools are restored. Capacities and other actor state are unaffected.
@export var pools: Array[AmountDefinition.Pool] = []:
	set(value):
		pools = value
		notify_property_list_changed()
## Capture and restore the target's PhysicsBody3D transform in the same world.
@export var restore_transform: bool = false:
	set(value):
		restore_transform = value
		notify_property_list_changed()
## Maximum distance to the saved transform in meters. Zero permits any distance in the same world.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var maximum_restore_distance: float = 0.0
## Allow a positive Health restoration to trigger ordinary healing reactions.
@export var healing_reactions: bool = false
## Also restore on an explicit manual removal. Dispel, death and replacement always discard.
@export var restore_on_manual_removal: bool = false


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing != GameplayEffectDefinition.Timing.DURATION or definition.duration <= 0.0 \
			or (pools.is_empty() and not restore_transform) \
			or (restore_transform and (not is_finite(maximum_restore_distance) or maximum_restore_distance < 0.0)):
		return &"Effect.InvalidResourceSnapshot"
	var distinct: Array[AmountDefinition.Pool] = []
	for pool in pools:
		if pool not in AmountDefinition.Pool.values() or distinct.has(pool):
			return &"Effect.InvalidResourceSnapshotPool"
		distinct.append(pool)
	return &""


func _validate_property(property: Dictionary) -> void:
	if (property.name == &"maximum_restore_distance" and not restore_transform) \
			or (property.name == &"healing_reactions" and not pools.has(AmountDefinition.Pool.HEALTH)):
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func can_apply(runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> bool:
	return not restore_transform or get_snapshot_body(runtime) != null


static func get_snapshot_body(runtime: GameplayEffectRuntime) -> PhysicsBody3D:
	var system := runtime.get_target_ability_system()
	var body := system.actor_body as PhysicsBody3D if is_instance_valid(system) else null
	if not is_instance_valid(body) or body.is_queued_for_deletion() or not body.is_inside_tree() \
			or body.get_world_3d() == null or not body.global_transform.is_finite():
		return null
	for owner: int in body.get_shape_owners():
		if not body.is_shape_owner_disabled(owner) and body.shape_owner_get_shape_count(owner) > 0:
			return body
	return null
