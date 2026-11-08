class_name AbilitySpendResourceAction
extends AbilityActionDefinition
## Pays an explicit additional cost, such as one channel pulse, from the casting actor.

## Current pool debited for each successful action.
@export var pool: AmountDefinition.Pool = AmountDefinition.Pool.MANA
## Amount paid in points. Phase policy determines what happens when it cannot be paid.
@export var amount: AmountDefinition


func get_validation_error() -> StringName:
	if not AmountDefinition.Pool.values().has(pool) or amount == null:
		return &"invalid_spend_resource_action"
	return amount.get_validation_error(AmountDefinition.Unit.POINTS)


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	var source := context.cast.get_system()
	if not is_instance_valid(source):
		return -1
	var target: AbilitySystem = targets.contacts[0].get_target() if not targets.contacts.is_empty() else null
	var basis := context.effect_context.outcome_context.make_payload_amount_context(
			target.attributes if target != null else null)
	var debit := amount.evaluate(basis)
	if not is_finite(debit) or debit < 0.0:
		return -1
	return 1 if source.try_spend_current(AmountDefinition.pool_attribute(pool), debit) else -1
