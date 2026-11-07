extends AbilityExecution
## Requests a single takeoff using the movement component's current support and stance.


func get_validation_error(system: AbilitySystem) -> StringName:
	if not is_instance_valid(system.actor_body):
		return &"missing_movement"
	var movement := system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
	if movement == null:
		return &"missing_movement"
	var crouch := system.actor_body.get_node_or_null("Crouch") as FirstPersonCrouch
	return movement.get_jump_failure(crouch != null and crouch.is_crouching)


func begin(cast: AbilityCast) -> void:
	var system := cast.get_system()
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		cast.cancel()
		return
	var movement := system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
	if movement == null or not movement.request_jump(cast):
		cast.cancel()
