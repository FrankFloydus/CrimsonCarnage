@tool
class_name PeriodicRampEffectComponent
extends GameplayEffectComponent
## Scales successive damage ticks while the owning retained instance remains active.

## Damage multiplier on the first periodic tick.
@export_range(0.0, 10.0, 0.01, "or_greater") var initial_multiplier: float = 1.0
## Additive change to the multiplier after each executed periodic tick.
@export_range(0.0, 10.0, 0.01, "or_greater") var multiplier_per_tick: float = 0.0
## Maximum multiplier reached by the ramp.
@export_range(0.0, 10.0, 0.01, "or_greater") var maximum_multiplier: float = 1.0
## Reset ramp progress when this effect's aggregate stack accepts a reapplication.
@export var reset_on_reapply: bool = false


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.get_effective_period() <= 0.0 or not definition.is_damage_effect() \
			or not is_finite(initial_multiplier) or initial_multiplier < 0.0 \
			or not is_finite(multiplier_per_tick) or multiplier_per_tick < 0.0 \
			or not is_finite(maximum_multiplier) or maximum_multiplier < initial_multiplier:
		return &"Effect.InvalidPeriodicRamp"
	return &""
