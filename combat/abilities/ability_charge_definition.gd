@tool
class_name AbilityChargeDefinition
extends Resource
## Authoring profile for an actor's ability charge pool.

## Maximum charges. A fresh pool starts at this capacity.
@export_range(1, 99, 1, "or_greater") var capacity: int = 1:
	set(value):
		capacity = value
		notify_property_list_changed()
## Seconds to restore one charge.
@export_range(0.01, 3600.0, 0.01, "or_greater", "suffix:s") var recharge_seconds: float = 1.0
## Each spent charge recharges independently. Otherwise charges recharge one at a time.
@export var parallel_recharge: bool = false
## Abilities on the same actor can share a group when their recharge profiles agree.
@export var shared_group: StringName


func _validate_property(property: Dictionary) -> void:
	if property.name == &"parallel_recharge" and capacity <= 1:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Multiple charges are needed for parallel and sequential recharge to differ.
func uses_parallel_recharge() -> bool:
	return capacity > 1 and parallel_recharge


func get_validation_error() -> StringName:
	if capacity < 1 or recharge_seconds <= 0.0 or not is_finite(recharge_seconds):
		return &"invalid_charge_profile"
	return &""
