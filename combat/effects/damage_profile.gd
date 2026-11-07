@tool
class_name DamageProfile
extends Resource
## Authored defense stages and final eligibility to kill a recipient.

## Chooses how the damage resolver selects target defenses.
enum DefenseSelection {
	## Uses the game's damage-type and school rules.
	COMBAT_DEFAULT,
	## Uses this profile's authored armor and resistance stages.
	EXPLICIT,
}

## Combat Default uses the live Armor or matching school formula. Explicit runs only the stages below.
@export var defense_selection: DefenseSelection = DefenseSelection.COMBAT_DEFAULT:
	set(value):
		defense_selection = value
		notify_property_list_changed()
## Enables the live Armor curve before any listed resistance stages in Explicit mode.
@export var use_armor: bool = false:
	set(value):
		use_armor = value
		notify_property_list_changed()
## Armor rating subtracted after source percentage penetration in Explicit mode.
@export_range(0.0, 10000.0, 0.1, "or_greater") var flat_armor_penetration: float = 0.0
## Ordered, independent percentage reductions in Explicit mode. Each resistance can appear once.
@export var resistance_stages: Array[DamageResistanceStage] = []
## Limits committed loss so each living recipient keeps at least one Health point.
@export var nonlethal: bool = false


func get_validation_error() -> StringName:
	if defense_selection not in DefenseSelection.values():
		return &"invalid_damage_profile_selection"
	if defense_selection == DefenseSelection.COMBAT_DEFAULT:
		return &""
	if use_armor and (not is_finite(flat_armor_penetration) or flat_armor_penetration < 0.0):
		return &"invalid_damage_profile_armor"
	var used: Dictionary[int, bool] = {}
	for stage: DamageResistanceStage in resistance_stages:
		if stage == null:
			return &"missing_damage_resistance_stage"
		var error := stage.get_validation_error()
		if not error.is_empty():
			return error
		if used.has(stage.attribute):
			return &"duplicate_damage_resistance_stage"
		used[stage.attribute] = true
	return &""


func _validate_property(property: Dictionary) -> void:
	var explicit := defense_selection == DefenseSelection.EXPLICIT
	match StringName(property.name):
		&"use_armor", &"resistance_stages":
			if not explicit:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"flat_armor_penetration":
			if not explicit or not use_armor:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
