@tool
class_name ThreatTauntProfile
extends Resource
## Normalization and temporary attention override for one taunt policy.

## Policy schema revision recorded by the caller for diagnostics and replay.
@export_range(1, 2147483647, 1) var version: int = 1
## Raise the taunting actor's threat to at least the selected observer's highest threat.
@export var match_highest_threat: bool = true
## Seconds the observer favors the taunting actor, independent of normalized threat.
@export_range(0.0, 60.0, 0.01, "or_greater") var override_seconds: float = 3.0:
	set(value):
		var visibility_changed := (override_seconds <= 0.0) != (value <= 0.0)
		override_seconds = value
		if visibility_changed:
			notify_property_list_changed()
## Larger priorities win among live overrides. A newer override wins ties.
@export var priority: int = 0


func _validate_property(property: Dictionary) -> void:
	if property.name == &"priority" and override_seconds <= 0.0:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
