class_name PlayerJumpAction
extends AbilityActionDefinition
## Requests one takeoff through the player's movement component.


func get_validation_error() -> StringName:
	return &""


func get_activation_error(system: AbilitySystem) -> StringName:
	var movement := _get_movement(system)
	if movement == null:
		return &"missing_movement"
	var crouch := system.actor_body.get_node_or_null("Crouch") as FirstPersonCrouch
	return movement.get_jump_failure(crouch != null and crouch.is_crouching)


func execute(context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	var movement := _get_movement(context.cast.get_system())
	return 1 if movement != null and movement.request_jump(context.cast) else -1


static func _get_movement(system: AbilitySystem) -> FirstPersonMovement:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
