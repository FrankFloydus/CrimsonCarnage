class_name AbilityExecution
extends Resource
## Shared execution behavior; put per-cast state in AbilityCast.data rather than this resource.


func get_validation_error(_system: AbilitySystem) -> StringName:
	return &""


## Validates an explicit actor request before creating a cast or paying its costs.
func get_target_validation_error(_system: AbilitySystem, _target: AbilitySystem) -> StringName:
	return &""


## Starts any pre-commit execution phases. False rejects this cast.
func request_start(_cast: AbilityCast) -> bool:
	return true


func begin(cast: AbilityCast) -> void:
	cast.finish()


func handle_event(_cast: AbilityCast, _event_name: StringName) -> void:
	pass


## Observes a gameplay event received while this cast is active. Animation events use handle_event.
func handle_gameplay_event(_cast: AbilityCast, _event_tag: StringName, _payload: Dictionary) -> void:
	pass


func advance(_cast: AbilityCast, _delta: float) -> void:
	pass


func physics_advance(_cast: AbilityCast, _delta: float) -> void:
	pass


## Reacts to the input binding being released, or to the same request from an AI controller.
func input_released(_cast: AbilityCast) -> void:
	pass


func end(_cast: AbilityCast, _cancelled: bool) -> void:
	pass


func get_animation_name() -> StringName:
	return &""


## Returns observable windup progress, or -1 if there is no current windup.
func get_windup_progress(_cast: AbilityCast) -> float:
	return -1.0


## Returns the immutable effects authored on an execution for activation validation.
func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return []
