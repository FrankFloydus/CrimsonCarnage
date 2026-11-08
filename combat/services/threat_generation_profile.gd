@tool
class_name ThreatGenerationProfile
extends Resource
## Converts a committed domain transaction to threat without changing its original outcome.

## Policy schema revision recorded by the caller for diagnostics and replay.
@export_range(1, 2147483647, 1) var version: int = 1
## Threat units credited per committed source unit. Zero disables threat from this profile.
@export_range(0.0, 10.0, 0.01, "or_greater") var multiplier: float = 1.0:
	set(value):
		var visibility_changed := (multiplier <= 0.0) != (value <= 0.0)
		multiplier = value
		if visibility_changed:
			notify_property_list_changed()
## Exact transaction category available to redirect filters, such as Threat.Damage or Threat.Healing.
@export var transaction_tag: StringName = &"Threat.Damage"


func _validate_property(property: Dictionary) -> void:
	if property.name == &"transaction_tag" and multiplier <= 0.0:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
