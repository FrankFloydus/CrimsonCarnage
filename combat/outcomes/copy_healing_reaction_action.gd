@tool
class_name CopyHealingReactionAction
extends CombatReactionAction
## Copies an explicit committed healing basis into a new, independently clamped heal.

## Selects the committed Health-point amount from which the new heal is calculated.
enum HealingBasis {
	## Copies scaled healing before the original recipient's Health capacity clamps it.
	BEFORE_OVERHEAL,
	## Copies the Health points the original recipient actually regained.
	ACTUAL_RESTORATION,
}

## Selects scaled healing before capacity clamping, or the points actually restored.
@export var basis: HealingBasis = HealingBasis.BEFORE_OVERHEAL
## Effectiveness of the copied amount. Empty copies the entire selected basis.
@export var copy_policy: CombatCopyPolicy
## Applies the new target's incoming healing modifiers. The source scaling is already included.
@export var apply_incoming_modifiers: bool = true


func get_validation_error(trigger: int) -> StringName:
	if trigger != ReactionDefinition.Trigger.ON_HEAL or not HealingBasis.values().has(basis):
		return &"copy_requires_healing_outcome"
	return copy_policy.get_validation_error() if copy_policy != null else &""


func execute(outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes) -> void:
	if (context.provenance & CombatOutcomeContext.Provenance.COPIED) != 0:
		return
	var key := &"scaled_healing" if basis == HealingBasis.BEFORE_OVERHEAL else &"actual_restoration"
	var source_amount := outcome.get_amount(key)
	var amount := copy_policy.scale_amount(source_amount) if copy_policy != null else source_amount
	if not is_finite(amount) or amount <= 0.0:
		return
	var profile := HealingProfile.new()
	profile.apply_incoming_modifiers = apply_incoming_modifiers
	var result := HealingResolver.resolve_and_commit(HealingRequest.new(recipient, amount, profile))
	if result.committed:
		CombatOutcomeDispatcher.publish(context.with_provenance(CombatOutcomeContext.Provenance.COPIED),
				result.get_event())
