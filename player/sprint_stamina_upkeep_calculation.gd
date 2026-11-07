class_name SprintStaminaUpkeepCalculation
extends GameplayEffectExecution
## Calculates one Stamina debit for completed grounded sprint travel.

## Stamina spent per completed interval. A final paid charge consumes an underfunded remainder.
## Zero allows Sprint without spending Stamina.
@export_range(0.0, 100.0, 0.1, "or_greater") var stamina_per_interval: float = 0.0


func execute(
		spec: GameplayEffectSpec, target: ActorAttributes, target_tags: GameplayTagSet
) -> Array[AttributeModifier]:
	if spec.context.source_id != target.get_instance_id() or target_tags == null \
			or not target_tags.has_tag(&"State.Movement.Sprinting") or target.get_parent() == null:
		return []
	var movement := target.get_parent().get_node_or_null("Movement") as FirstPersonMovement
	if movement == null or movement.attributes != target or not movement.is_grounded():
		return []
	var intervals := movement.get_unpaid_sprint_intervals(spec.period)
	if intervals == 0:
		return []
	var stamina := target.get_value(CombatAttributes.Id.STAMINA)
	var cost := intervals * stamina_per_interval
	if not is_finite(cost) or cost < 0.0 or stamina + cost * 1.0e-9 < cost:
		movement.cancel_sprint_upkeep()
		return []
	movement.consume_sprint_upkeep_intervals(intervals)
	if cost <= 0.0:
		return []
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.STAMINA
	modifier.operation = AttributeModifier.Operation.ADD
	modifier.value = -stamina if stamina - cost < stamina_per_interval else -cost
	return [modifier]
