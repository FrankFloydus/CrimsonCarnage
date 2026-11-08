@tool
@abstract
class_name CombatReactionAction
extends Resource
## Immutable behavior template evaluated from a scoped outcome and a live recipient.


func get_validation_error(_trigger: int) -> StringName:
	return &""


@abstract func execute(
		outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes
) -> void


static func amount_validation_error(amount: AmountDefinition, trigger: int) -> StringName:
	if amount == null:
		return &"missing_reaction_amount"
	var error := amount.get_validation_error(AmountDefinition.Unit.POINTS)
	if not error.is_empty():
		return error
	if amount.source == AmountDefinition.Source.UNIQUE_TARGET_COUNT \
			and trigger != ReactionDefinition.Trigger.ON_BATCH_COMPLETE:
		return &"unique_count_requires_batch_complete"
	if amount.source == AmountDefinition.Source.ACCUMULATOR_PERCENT \
			and trigger != ReactionDefinition.Trigger.ON_EFFECT_THRESHOLD:
		return &"accumulator_requires_effect_threshold"
	if amount.source == AmountDefinition.Source.OUTCOME_PERCENT:
		var expected_trigger: int
		match amount.outcome_basis:
			AmountDefinition.OutcomeBasis.ACTUAL_HEALTH_DAMAGE, AmountDefinition.OutcomeBasis.RAW_DAMAGE, \
					AmountDefinition.OutcomeBasis.RESOLVED_DAMAGE:
				expected_trigger = ReactionDefinition.Trigger.ON_HEALTH_DAMAGED
			AmountDefinition.OutcomeBasis.ACTUAL_HEALING, AmountDefinition.OutcomeBasis.SCALED_HEALING, \
					AmountDefinition.OutcomeBasis.OVERHEAL:
				expected_trigger = ReactionDefinition.Trigger.ON_HEAL
			AmountDefinition.OutcomeBasis.ACTUAL_RESOURCE_DELTA:
				expected_trigger = ReactionDefinition.Trigger.ON_RESOURCE_RESTORED
		if trigger != expected_trigger and not (expected_trigger == ReactionDefinition.Trigger.ON_HEALTH_DAMAGED \
				and trigger == ReactionDefinition.Trigger.ON_DAMAGE_RESOLVED):
			return &"incompatible_reaction_outcome_basis"
	return &""
