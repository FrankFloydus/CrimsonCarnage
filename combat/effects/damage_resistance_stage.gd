@tool
class_name DamageResistanceStage
extends Resource
## One independent percentage-resistance multiplier in an explicit damage profile.

## Actor resistance read by this stage. Choices use the existing Combat 2.0 catalogue.
@export var attribute: CombatAttributes.Id = CombatAttributes.Id.FIRE_RESISTANCE
## Effective minimum after optional penetration. Negative values permit vulnerability.
@export_range(-100.0, 100.0, 0.1, "suffix:%") var minimum_percent: float = 0.0
## Effective maximum after optional penetration. 75 means at most 75% mitigation.
@export_range(-100.0, 100.0, 0.1, "suffix:%") var maximum_percent: float = 75.0
## Subtracts source Spell Penetration on a direct magic spell component.
@export var apply_spell_penetration: bool = false


func get_validation_error() -> StringName:
	if not CombatAttributes.is_resistance(attribute):
		return &"invalid_damage_resistance_attribute"
	if not is_finite(minimum_percent) or not is_finite(maximum_percent) \
			or minimum_percent < -100.0 or maximum_percent > 100.0 \
			or minimum_percent > maximum_percent:
		return &"invalid_damage_resistance_bounds"
	return &""


func _validate_property(property: Dictionary) -> void:
	if property.name != &"attribute":
		return
	var choices := PackedStringArray()
	for id: int in CombatAttributes.resistance_ids():
		choices.append("%s:%d" % [CombatAttributes.display_name(id), id])
	property.hint = PROPERTY_HINT_ENUM
	property.hint_string = ",".join(choices)
