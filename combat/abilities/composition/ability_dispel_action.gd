class_name AbilityDispelAction
extends AbilityActionDefinition
## Removes matching retained effects using their effect handles and the caster as instigator.

## Optional exact effect ID to remove. When both selectors are set, both must match.
@export var effect_id: StringName = &""
## Eligible asset tags. Any listed tag or its descendants match.
@export var asset_tags: PackedStringArray = PackedStringArray()
## Largest number of matching effects to remove from one actor. Zero removes every match.
@export_range(0, 100, 1, "or_greater") var maximum_per_target: int = 0


func get_validation_error() -> StringName:
	if (effect_id.is_empty() and asset_tags.is_empty()) or asset_tags.has("") or maximum_per_target < 0:
		return &"invalid_dispel_selector"
	return &""


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	var source := context.cast.get_system()
	if not is_instance_valid(source):
		return -1
	var total := 0
	for contact: AbilityTargetContact in targets.contacts:
		var target := contact.get_target()
		if target == null or target.effects == null:
			continue
		var retained := target.effects.get_retained_effects()
		var handles := retained.keys()
		handles.sort()
		var removed := 0
		for handle: int in handles:
			if _matches(retained[handle]) and target.effects.dispel_effect(handle, source):
				removed += 1
				if maximum_per_target > 0 and removed >= maximum_per_target:
					break
		total += removed
	return total


func _matches(effect: GameplayEffectDefinition) -> bool:
	if not effect_id.is_empty() and effect_id != effect.effect_id:
		return false
	if asset_tags.is_empty():
		return true
	for query: String in asset_tags:
		if AttributeModifier._has_match(effect.asset_tags, query):
			return true
	return false
