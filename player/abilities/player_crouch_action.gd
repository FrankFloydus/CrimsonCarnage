class_name PlayerCrouchAction
extends AbilityActionDefinition
## Requests or releases a physical crouch through the player's stance component.

## Stance request performed by this ability phase.
enum Operation {
	## Requests crouching and owns that stance for the activation.
	ENTER,
	## Releases the activation and requests standing according to the configured input mode and clearance.
	RELEASE,
}

## Enter physical crouch, or release when the stance settings and clearance permit standing.
@export var operation: Operation = Operation.ENTER


func get_validation_error() -> StringName:
	return &"" if Operation.values().has(operation) else &"invalid_crouch_operation"


func get_activation_error(system: AbilitySystem) -> StringName:
	var crouch := _get_crouch(system)
	if crouch == null:
		return &"missing_crouch"
	if crouch.is_crouching or operation == Operation.RELEASE:
		return &""
	var movement := system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
	return &"" if movement != null and movement.is_grounded() else &"crouch_unsupported"


func execute(context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	var crouch := _get_crouch(context.cast.get_system())
	if operation == Operation.RELEASE:
		if crouch == null or crouch.settings.mode == FirstPersonCrouchSettings.Mode.ONE_SHOT \
				or crouch.try_set_crouched(false):
			context.cast.finish()
			return 1
		return 0
	if crouch == null or not crouch.try_set_crouched(true):
		return -1
	var handle := StanceHandle.new()
	handle.crouch_ref = weakref(crouch)
	context.own_handle(handle)
	return 1


static func _get_crouch(system: AbilitySystem) -> FirstPersonCrouch:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Crouch") as FirstPersonCrouch


class StanceHandle extends AbilityPhaseContext.OwnedHandle:
	var crouch_ref: WeakRef

	func remove() -> void:
		var crouch := crouch_ref.get_ref() as FirstPersonCrouch
		if is_instance_valid(crouch):
			crouch.request_stand()
