@tool
class_name AbilityApplyEffectsAction
extends AbilityActionDefinition
## Applies a payload through one shared hit or through explicit non-hit effect application.

## Selects the resolver used to apply the payload to each contact.
enum Application {
	## Resolve one shared hit for all effects, including hostile Accuracy and eligible criticals.
	DELIVERED_HIT,
	## Apply effects individually through the explicit non-hit effect API.
	DIRECT_EFFECT,
}

## Effects in payload order. A delivered hit shares its Accuracy and critical rolls.
@export var effects: Array[GameplayEffectDefinition] = []
## Delivered Hit resolves hostile Accuracy and eligible criticals once for the whole payload.
## Direct Effect applies each effect through the explicit non-hit API.
@export var application: Application = Application.DELIVERED_HIT:
	set(value):
		application = value
		notify_property_list_changed()
## Retain direct, independently stacked effects only while the cast remains active.
@export var owned_until_cast_ends: bool = false
## Treat zero successful applications as an action failure, using the phase's failure policy.
@export var require_application: bool = false


func _validate_property(property: Dictionary) -> void:
	if property.name == &"owned_until_cast_ends" and application != Application.DIRECT_EFFECT:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if effects.is_empty():
		return &"missing_effect_payload"
	if application < Application.DELIVERED_HIT or application > Application.DIRECT_EFFECT:
		return &"invalid_effect_application"
	for effect: GameplayEffectDefinition in effects:
		if effect == null or not effect.get_validation_error().is_empty():
			return &"invalid_effect_payload"
		if _owns_applied_effects() and (effect.timing == GameplayEffectDefinition.Timing.INSTANT \
				or effect.stacking_type != GameplayEffectDefinition.StackingType.INDEPENDENT):
			return &"owned_effect_requires_independent_retention"
	return &""


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return effects


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	var detached := context.cast.finished
	if _owns_applied_effects() and detached:
		return -1
	var templates: Array[GameplayEffectSpec] = context.prepared_payloads.get(
			get_instance_id(), [] as Array[GameplayEffectSpec])
	if templates.is_empty():
		for effect: GameplayEffectDefinition in effects:
			var spec := context.cast.make_effect_spec(effect)
			if spec == null:
				return -1
			templates.append(spec)
	var affected := 0
	for contact: AbilityTargetContact in targets.contacts:
		if context.cast.finished and not detached:
			break
		var target := contact.get_target()
		if target == null:
			continue
		var provenance := context.effect_context.duplicate_for_hit(0.5)
		provenance.hit_position = contact.position
		provenance.hit_normal = contact.normal
		provenance.has_hit_result = contact.has_geometry
		if application == Application.DELIVERED_HIT:
			var hit := target.receive_hit_specs(provenance, templates)
			if hit.get("outcome") == &"hit":
				context.confirmed_targets[contact.actor_id] = true
				affected += 1
			continue
		for template: GameplayEffectSpec in templates:
			if context.cast.finished and not detached:
				break
			var spec := template.copy_for_application()
			spec.context = provenance
			var handle := target.apply_effect_spec_to_self(spec)
			if owned_until_cast_ends:
				context.own_effect(target, handle)
			if handle != 0:
				affected += 1
	return -1 if require_application and affected == 0 else affected


func _owns_applied_effects() -> bool:
	return application == Application.DIRECT_EFFECT and owned_until_cast_ends
