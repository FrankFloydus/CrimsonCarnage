@tool
class_name RestoreResourceReactionAction
extends CombatReactionAction
## Restores Mana or Stamina to the selected recipient as a resource transaction.

## Points requested before clamping to the recipient's current resource capacity.
@export var amount: AmountDefinition
## Mana or Stamina pool that receives the recovery.
@export var resource: AmountDefinition.Pool = AmountDefinition.Pool.MANA


func _validate_property(property: Dictionary) -> void:
	if property.name == &"resource":
		property.hint_string = "Mana:%d,Stamina:%d" % [
			AmountDefinition.Pool.MANA, AmountDefinition.Pool.STAMINA,
		]


func get_validation_error(trigger: int) -> StringName:
	if resource != AmountDefinition.Pool.MANA and resource != AmountDefinition.Pool.STAMINA:
		return &"invalid_recovery_pool"
	return amount_validation_error(amount, trigger)


func execute(outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes) -> void:
	var requested := amount.evaluate(context.make_amount_context(outcome, recipient))
	if not is_finite(requested) or requested <= 0.0:
		return
	var request := ResourceRequest.new(recipient, requested, resource, ResourceRequest.Reason.REFUND)
	var result := ResourceService.resolve_and_commit(request)
	if result.committed:
		var event := result.get_event().duplicate()
		event["ability_tags"] = outcome.get_event().get("ability_tags", PackedStringArray())
		CombatOutcomeDispatcher.publish(context, event)
