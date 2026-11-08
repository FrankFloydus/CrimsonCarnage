@tool
class_name ObserveOutcomeEffectComponent
extends GameplayEffectComponent
## Grants reactions while a retained effect is active, across independent executions.

## Selects which attributed role must match the retained effect's holder.
enum Scope {
	## Observes outcomes for which the holder receives source credit.
	CREDITED_SOURCE,
	## Observes outcomes resolved against the holder.
	TARGET,
}

## Credited Source observes outcomes attributed to the holder; Target observes outcomes received by the holder.
@export var scope: Scope = Scope.CREDITED_SOURCE
## Follow-ups applied to matching committed outcomes while this effect is active.
@export var reactions: Array[ReactionDefinition] = []
## Number of distinct eligible attacks empowered for this retained duration. Zero has no use budget.
@export_range(0, 128, 1, "or_greater") var attack_uses: int = 0:
	set(value):
		attack_uses = value
		notify_property_list_changed()
## Refills the use budget when an accepted aggregate reapplication reuses this effect's handle.
## Already paid attacks stay paid.
@export var reset_attack_uses_on_reapply: bool = false


func _validate_property(property: Dictionary) -> void:
	if property.name == &"reset_attack_uses_on_reapply" and attack_uses <= 0:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT:
		return &"outcome_observer_requires_retained_effect"
	if not Scope.values().has(scope) or reactions.is_empty():
		return &"invalid_outcome_observer"
	if attack_uses < 0 or (attack_uses > 0 and definition.timing != GameplayEffectDefinition.Timing.DURATION):
		return &"attack_uses_require_duration"
	for reaction in reactions:
		if reaction == null:
			return &"missing_reaction"
		var error := reaction.get_validation_error()
		if not error.is_empty():
			return error
	return &""


func create_state() -> Dictionary:
	return {
		"attachment_id": CombatOutcomeContext.allocate_id(),
		"attack_uses_remaining": attack_uses,
		"paid_attacks": {} as Dictionary[int, WeakRef],
	}


func refresh_state(state: Dictionary) -> void:
	if attack_uses > 0 and reset_attack_uses_on_reapply:
		state["attack_uses_remaining"] = attack_uses


## Paid attacks may finish every packet, including delayed contacts, before this effect expires.
func claim_attack(outcome: CombatOutcome, state: Dictionary) -> bool:
	if attack_uses == 0:
		return true
	var attack_id := outcome.context.attack_execution_id
	var paid_attacks: Dictionary[int, WeakRef] = state["paid_attacks"]
	if paid_attacks.has(attack_id):
		return true
	if attack_id <= 0 or int(state["attack_uses_remaining"]) <= 0:
		return false
	for id: int in paid_attacks.keys():
		if paid_attacks[id].get_ref() == null:
			paid_attacks.erase(id)
	state["attack_uses_remaining"] -= 1
	paid_attacks[attack_id] = weakref(outcome.context._execution)
	return true
