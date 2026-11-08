@tool
class_name AttributeGameplayEventRule
extends Resource
## Authored gameplay events for crossing a threshold between two actor attributes.

## The final, unscoped attribute value checked against the threshold attribute.
@export var attribute: int = CombatAttributes.Id.NONE
## The final, unscoped threshold value. Equality is outside the condition.
@export var threshold_attribute: int = CombatAttributes.Id.NONE
## Gameplay event sent when the attribute first exceeds the threshold.
@export var entered_event: StringName = &""
## Gameplay event sent when the attribute returns to or below the threshold.
@export var exited_event: StringName = &""


func matches(attributes: ActorAttributes) -> bool:
	return is_instance_valid(attributes) \
			and attributes.get_value(attribute) > attributes.get_value(threshold_attribute)


func watches(id: int) -> bool:
	return id == attribute or id == threshold_attribute


func get_validation_error() -> StringName:
	if not CombatAttributes.is_active(attribute) \
			or not CombatAttributes.is_active(threshold_attribute):
		return &"invalid_threshold_attribute"
	if attribute == threshold_attribute:
		return &"identical_threshold_attributes"
	if entered_event == exited_event \
			or not _is_valid_event_tag(entered_event) or not _is_valid_event_tag(exited_event):
		return &"invalid_threshold_event_tags"
	return &""


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"attribute", &"threshold_attribute"]:
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = CombatAttributes.inspector_hint(true)


static func _is_valid_event_tag(tag: StringName) -> bool:
	if tag.is_empty():
		return false
	for segment in String(tag).split("."):
		if not segment.is_valid_identifier():
			return false
	return true
