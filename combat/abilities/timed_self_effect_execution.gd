class_name TimedSelfEffectExecution
extends AbilityExecution
## Applies a finite modifier effect whose duration outlives this activation.

## Effect applied to the ability owner. Its own duration controls expiry.
@export var effect: GameplayEffectDefinition


func get_validation_error(_system: AbilitySystem) -> StringName:
	if effect == null:
		return &"missing_effect_payload"
	if effect.kind != GameplayEffectDefinition.Kind.MODIFIERS \
			or effect.timing != GameplayEffectDefinition.Timing.DURATION or effect.duration <= 0.0:
		return &"effect_must_be_timed"
	return effect.get_validation_error()


func begin(cast: AbilityCast) -> void:
	var system := cast.get_system()
	if system == null or system.effects.apply_effect(effect, cast.context) == 0:
		cast.cancel()
	else:
		cast.finish()


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return [effect] if effect != null else []
