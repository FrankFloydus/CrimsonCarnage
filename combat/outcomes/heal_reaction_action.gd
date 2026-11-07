@tool
class_name HealReactionAction
extends CombatReactionAction
## Requests a centralized heal using the current reaction's typed amount.

## Amount in Health points. Actual Health Damage on a damage trigger provides lifesteal.
@export var amount: AmountDefinition
## Optional scaling and incoming-modifier policy. Empty uses ordinary healing.
@export var healing_profile: HealingProfile


func get_validation_error(trigger: int) -> StringName:
	var error := amount_validation_error(amount, trigger)
	if error.is_empty() and healing_profile != null:
		return healing_profile.get_validation_error()
	return error


func execute(outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes) -> void:
	var requested := amount.evaluate(context.make_amount_context(outcome, recipient))
	if not is_finite(requested) or requested <= 0.0:
		return
	var request := HealingRequest.new(recipient, requested, healing_profile)
	var result := HealingResolver.resolve_and_commit(request)
	if result.committed:
		var event := result.get_event().duplicate()
		event["ability_tags"] = outcome.get_event().get("ability_tags", PackedStringArray())
		CombatOutcomeDispatcher.publish(context, event)
