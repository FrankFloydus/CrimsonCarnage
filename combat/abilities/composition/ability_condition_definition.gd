@tool
class_name AbilityConditionDefinition
extends Resource
## Pure reusable gate for one phase. Invalid targets fail target-scoped tests.

## Actor whose live state supplies the condition's value.
enum Subject {
	## Test the executing actor once for the phase or activation.
	CASTER,
	## Test each selected contact, or the explicit Single target during activation.
	TARGET,
}

## Predicate evaluated against the selected subject.
enum Kind {
	## Match the specified tag or any of its hierarchical descendants.
	HAS_TAG,
	## Require the specified tag and all of its descendants to be absent.
	LACKS_TAG,
	## Require the current resource value or fraction to meet or exceed the threshold.
	RESOURCE_AT_LEAST,
	## Require the current resource value or fraction to be strictly below the threshold.
	RESOURCE_BELOW,
	## Require positive Health.
	IS_ALIVE,
	## Require zero or less Health.
	IS_DEAD,
}

## Caster tests the executing actor. Target tests each contact or the explicitly selected actor.
@export var subject: Subject = Subject.CASTER
## Has Tag and Lacks Tag use hierarchical matching. Resource At Least and Resource Below compare
## against Threshold. Is Alive and Is Dead test whether the actor has positive Health.
@export var kind: Kind = Kind.HAS_TAG:
	set(value):
		kind = value
		notify_property_list_changed()
## Hierarchical actor tag used by tag checks.
@export var tag: StringName = &""
## Current resource used by pool checks.
@export var resource: CombatAttributes.Id = CombatAttributes.Id.HEALTH
## Threshold in points, or a fraction of the maximum when enabled below.
@export var threshold: float = 0.0
## Compare the current resource as a fraction of its maximum capacity.
@export var fraction_of_maximum: bool = false


func _validate_property(property: Dictionary) -> void:
	match property.name:
		&"tag":
			if not _uses_tag():
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"resource", &"threshold", &"fraction_of_maximum":
			if not _uses_resource():
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if subject < Subject.CASTER or subject > Subject.TARGET or kind < Kind.HAS_TAG \
			or kind > Kind.IS_DEAD:
		return &"invalid_condition_kind"
	if _uses_tag() and tag.is_empty():
		return &"missing_condition_tag"
	if _uses_resource() \
			and (not CombatAttributes.is_current_resource(resource) or not is_finite(threshold) \
			or threshold < 0.0 or (fraction_of_maximum and threshold > 1.0)):
		return &"invalid_condition_resource"
	return &""


func _uses_tag() -> bool:
	return kind == Kind.HAS_TAG or kind == Kind.LACKS_TAG


func _uses_resource() -> bool:
	return kind == Kind.RESOURCE_AT_LEAST or kind == Kind.RESOURCE_BELOW


## Evaluates current gameplay state without mutating it or consuming random rolls.
func matches(context: AbilityPhaseContext, target: AbilitySystem = null) -> bool:
	var actor := context.cast.get_system() if subject == Subject.CASTER else target
	return matches_actor(actor)


## Checks a previously resolved actor, including during an activation preview.
func matches_actor(actor: AbilitySystem) -> bool:
	if not is_instance_valid(actor) or not is_instance_valid(actor.attributes):
		return false
	match kind:
		Kind.HAS_TAG:
			return actor.tags.has_tag(tag)
		Kind.LACKS_TAG:
			return not actor.tags.has_tag(tag)
		Kind.IS_ALIVE:
			return actor.attributes.get_value(CombatAttributes.Id.HEALTH) > 0.0
		Kind.IS_DEAD:
			return actor.attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0
	var value := actor.attributes.get_value(resource)
	if fraction_of_maximum:
		var maximum := actor.attributes.get_value(CombatAttributes.maximum_for(resource))
		value = value / maximum if maximum > 0.0 else 0.0
	return value >= threshold if kind == Kind.RESOURCE_AT_LEAST else value < threshold
