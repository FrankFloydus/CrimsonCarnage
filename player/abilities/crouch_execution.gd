extends AbilityExecution
## Owns the stance request. Physical clearance determines when standing succeeds.


func get_validation_error(system: AbilitySystem) -> StringName:
	var crouch := _get_crouch(system)
	if crouch == null:
		return &"missing_crouch"
	if crouch.is_crouching:
		return &""
	var movement := system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
	if movement == null or not movement.is_grounded():
		return &"crouch_unsupported"
	return &""


func begin(cast: AbilityCast) -> void:
	var crouch := _get_crouch(cast.get_system())
	if crouch == null or not crouch.try_set_crouched(true):
		cast.cancel()


func input_released(cast: AbilityCast) -> void:
	var crouch := _get_crouch(cast.get_system())
	if crouch == null or crouch.settings.mode == FirstPersonCrouchSettings.Mode.ONE_SHOT \
			or crouch.try_set_crouched(false):
		cast.finish()


func end(cast: AbilityCast, _cancelled: bool) -> void:
	var crouch := _get_crouch(cast.get_system())
	if crouch != null:
		crouch.request_stand()


static func _get_crouch(system: AbilitySystem) -> FirstPersonCrouch:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Crouch") as FirstPersonCrouch
