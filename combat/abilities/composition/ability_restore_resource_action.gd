@tool
class_name AbilityRestoreResourceAction
extends AbilityActionDefinition
## Restores the selected pool to each resolved target through the appropriate resolver.

## Pool to restore. Health uses ordinary healing and Mana/Stamina use resource recovery.
@export var resource: AmountDefinition.Pool = AmountDefinition.Pool.MANA:
	set(value):
		resource = value
		notify_property_list_changed()
## Requested nonnegative recovery in pool points, before incoming policies and capacity.
@export var amount: AmountDefinition
## Optional source scaling and incoming policy for Health restoration.
@export var healing_profile: HealingProfile


func _validate_property(property: Dictionary) -> void:
	if property.name == &"healing_profile" and resource != AmountDefinition.Pool.HEALTH:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not resource in AmountDefinition.Pool.values():
		return &"invalid_recovery_resource"
	if amount == null:
		return &"missing_recovery_amount"
	if amount.source in [
		AmountDefinition.Source.OUTCOME_PERCENT,
		AmountDefinition.Source.ACCUMULATOR_PERCENT,
		AmountDefinition.Source.STACK_PROGRESSION,
		AmountDefinition.Source.UNIQUE_TARGET_COUNT,
	]:
		return &"recovery_amount_requires_reaction_or_effect"
	if amount.source == AmountDefinition.Source.FIXED and amount.evaluate() < 0.0:
		return &"negative_recovery_amount"
	if resource == AmountDefinition.Pool.HEALTH and healing_profile != null:
		var failure := healing_profile.get_validation_error()
		if not failure.is_empty():
			return failure
	return amount.get_validation_error(AmountDefinition.Unit.POINTS)


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	if context == null or context.effect_context == null or targets == null \
			or not get_validation_error().is_empty():
		return -1
	var attribution := context.effect_context.outcome_context
	var count := 0
	CombatOutcomeDispatcher.begin_batch()
	for contact: AbilityTargetContact in targets.contacts:
		var target := contact.get_target()
		if target == null or not is_instance_valid(target.attributes):
			continue
		var evaluation := attribution.make_payload_amount_context(target.attributes) \
				if attribution != null else AmountEvaluationContext.new()
		evaluation.effect_context = context.effect_context
		evaluation.scope_tags = context.effect_context.ability_tags
		evaluation.target = target.attributes
		evaluation.recipient = target.attributes
		if amount.timing == AmountDefinition.Timing.SNAPSHOT and (evaluation.snapshot == null
				or amount.actor in [AmountDefinition.ActorRole.TARGET, AmountDefinition.ActorRole.RECIPIENT]):
			evaluation.snapshot = evaluation.capture()
		var requested := amount.evaluate(evaluation)
		if not is_finite(requested) or requested < 0.0:
			continue
		var event := _restore(target.attributes, requested)
		if not event.is_empty():
			CombatOutcomeDispatcher.publish(attribution, event)
			count += 1
	CombatOutcomeDispatcher.end_batch()
	return count


func _restore(recipient: ActorAttributes, requested: float) -> Dictionary:
	if resource == AmountDefinition.Pool.HEALTH:
		var healing := HealingResolver.resolve_and_commit(
				HealingRequest.new(recipient, requested, healing_profile))
		return healing.get_event() if healing.committed else {}
	var result := ResourceService.resolve_and_commit(ResourceRequest.new(recipient, requested, resource))
	return result.get_event() if result.committed else {}
