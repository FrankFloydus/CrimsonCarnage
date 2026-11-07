@tool
class_name HealingProfile
extends Resource
## Defines source scaling and eligible incoming effects for an ordinary heal.

## Percentage of the requested amount after source scaling. A value of 100 means unchanged.
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:%") var source_percent: float = 100.0:
	set(value):
		source_percent = value
		notify_property_list_changed()
## Applies the recipient's active healing-received effect behaviors before restoring Health.
@export var apply_incoming_modifiers: bool = true
## Allows active healing-absorption effects to consume the scaled amount before capacity clamping.
@export var apply_absorption: bool = true


func _validate_property(property: Dictionary) -> void:
	if source_percent == 0.0 and property.name in [&"apply_incoming_modifiers", &"apply_absorption"]:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not is_finite(source_percent) or source_percent < 0.0:
		return &"invalid_healing_source_percent"
	return &""
