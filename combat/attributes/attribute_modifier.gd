@tool
class_name AttributeModifier
extends Resource
## An immutable-at-runtime adjustment to one code-defined Combat 2.0 attribute.

enum Operation {
	## Adds flat native units before increased and More modifiers.
	ADD = 0,
	## Adds to the combined increased percentage; 20 means 20% increased.
	ADD_PERCENT = 1,
	## Replaces the full derived base while active, before other flat additions.
	SET_BASE = 2,
	## Applies an independent multiplier; 20 means multiply by 1.20.
	MORE_PERCENT = 3,
}

## Attribute changed by this adjustment. Current pools use explicit resource changes.
## Inspector choices contain only active Combat 2.0 attributes.
@export var attribute: CombatAttributes.Id = CombatAttributes.Id.MAGIC_POWER

## Flat additions precede combined increased bonuses, then each More factor multiplies.
## Set Base replaces the full derived foundation, including its primary contribution.
@export var operation: Operation = Operation.ADD

## Native units for Add/Set Base, including percentage points for Resistance, Penetration, critical stats and Movement Speed.
## Movement Speed starts at zero bonus; Add Flat 20 grants 20% faster movement.
## Increased/More use relative percentages (20 means 20%).
@export var value: float = 0.0

## All listed context tags must match; a parent tag matches its descendants.
@export var required_context_tags: PackedStringArray = PackedStringArray()

## Any matching context tag prevents this adjustment from participating.
@export var excluded_context_tags: PackedStringArray = PackedStringArray()


func _validate_property(property: Dictionary) -> void:
	if property.name == &"attribute":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = CombatAttributes.inspector_hint()
	elif property.name == &"operation":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = "Add Flat:0,Increased Percent:1,Set Base:2,More Percent:3"


func matches_context(context_tags: PackedStringArray) -> bool:
	for query: String in required_context_tags:
		if not _has_match(context_tags, query):
			return false
	for query: String in excluded_context_tags:
		if _has_match(context_tags, query):
			return false
	return true


func copy() -> AttributeModifier:
	var result := AttributeModifier.new()
	result.attribute = attribute
	result.operation = operation
	result.value = value
	result.required_context_tags = required_context_tags.duplicate()
	result.excluded_context_tags = excluded_context_tags.duplicate()
	return result


static func _has_match(tags: PackedStringArray, query: String) -> bool:
	if query.is_empty():
		return false
	for tag: String in tags:
		if tag == query or tag.begins_with(query + "."):
			return true
	return false
