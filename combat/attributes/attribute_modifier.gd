@tool
class_name AttributeModifier
extends Resource
## An immutable-at-runtime adjustment to one registered combat attribute.

## Controls where the modifier participates in an attribute's value calculation.
enum Operation {
	## Adds flat native units before increased and More modifiers.
	ADD = 0,
	## Adds to the combined increased percentage; 20 means 20% increased.
	ADD_PERCENT = 1,
	## Replaces the full derived base while active, before other flat additions.
	SET_BASE = 2,
	## Applies an independent multiplier; 20 means multiply by 1.20.
	MORE_PERCENT = 3,
	## Adds a live contribution to the foundation before an explicit base override.
	ADD_TO_FOUNDATION = 4,
	## Slows final movement speed after the ordinary bonus is clamped. -50 means half speed.
	FINAL_MOVEMENT_PERCENT = 5,
}

## Attribute changed by this adjustment. Instant and periodic effects can change current pools.
## Inspector choices contain only registered attributes.
@export var attribute: int = CombatAttributes.Id.MAGIC_POWER

## Flat additions precede combined increased bonuses, then each More factor multiplies.
## Set Base replaces the full derived foundation, including its primary contribution.
## Final Movement Percent is a separate slow applied to the full speed, from -100 to 0.
@export var operation: Operation = Operation.ADD:
	set(next_operation):
		operation = next_operation
		notify_property_list_changed()

## Native units for Add/Set Base, including percentage points for Resistance, Penetration, critical stats and Movement Speed.
## Movement Speed starts at zero bonus; Add Flat 20 grants 20% faster movement.
## Increased/More use relative percentages (20 means 20%).
## Final Movement Percent uses negative percentages (-50 means half movement speed).
@export var value: float = 0.0

## Optional live target attribute captured for this modifier's magnitude. None uses only Value.
@export var capture_attribute: int = CombatAttributes.Id.NONE:
	set(new_attribute):
		capture_attribute = new_attribute
		notify_property_list_changed()
## Units added to Value per point of the captured target attribute.
@export var capture_coefficient: float = 1.0
## Optional per-application magnitude key. Value is the fallback if the spec has no entry.
@export var set_by_caller_tag: StringName = &""

## All listed context tags must match; a parent tag matches its descendants.
@export var required_context_tags: PackedStringArray = PackedStringArray()

## Any matching context tag prevents this adjustment from participating.
@export var excluded_context_tags: PackedStringArray = PackedStringArray()

var stack_count: int = 1


func _validate_property(property: Dictionary) -> void:
	if property.name == &"capture_coefficient" and not uses_capture():
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name in [&"capture_attribute", &"set_by_caller_tag"] and not supports_dynamic_value():
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == &"attribute" or property.name == &"capture_attribute":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = CombatAttributes.inspector_hint(property.name == &"capture_attribute")
	elif property.name == &"operation":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ("Add Flat:0,Increased Percent:1,Set Base:2,More Percent:3,"
				+ "Add to Derived Base:4,Final Movement Percent:5")


## Final Movement Percent reads a fixed authored slow.
func supports_dynamic_value() -> bool:
	return operation != Operation.FINAL_MOVEMENT_PERCENT


## Reports whether this operation uses the captured attribute and coefficient.
func uses_capture() -> bool:
	return supports_dynamic_value() and capture_attribute != CombatAttributes.Id.NONE


func matches_context(context_tags: PackedStringArray) -> bool:
	for query: String in required_context_tags:
		if not _has_match(context_tags, query):
			return false
	for query: String in excluded_context_tags:
		if _has_match(context_tags, query):
			return false
	return true


func get_magnitude(target: ActorAttributes, context_tags: PackedStringArray) -> float:
	var magnitude := value
	if uses_capture() and capture_attribute != attribute:
		magnitude += target.get_value(capture_attribute, context_tags) * capture_coefficient
	if stack_count > 1:
		match operation:
			Operation.ADD, Operation.ADD_PERCENT, Operation.ADD_TO_FOUNDATION:
				magnitude *= stack_count
			Operation.MORE_PERCENT, Operation.FINAL_MOVEMENT_PERCENT:
				magnitude = (pow(maxf(0.0, 1.0 + magnitude / 100.0), stack_count) - 1.0) * 100.0
	return magnitude if is_finite(magnitude) else 0.0


## Final movement slows apply only to retained, fixed Movement Speed modifiers.
func is_valid_final_movement_percent() -> bool:
	return attribute == CombatAttributes.Id.MOVEMENT_SPEED and value >= -100.0 and value <= 0.0


func copy() -> AttributeModifier:
	var result := AttributeModifier.new()
	result.attribute = attribute
	result.operation = operation
	result.value = value
	result.capture_attribute = capture_attribute
	result.capture_coefficient = capture_coefficient
	result.set_by_caller_tag = set_by_caller_tag
	result.required_context_tags = required_context_tags.duplicate()
	result.excluded_context_tags = excluded_context_tags.duplicate()
	result.stack_count = stack_count
	return result


static func _has_match(tags: PackedStringArray, query: String) -> bool:
	if query.is_empty():
		return false
	for tag: String in tags:
		if tag == query or tag.begins_with(query + "."):
			return true
	return false
