class_name PlayerSprintAction
extends AbilityActionDefinition
## Authorizes sprint movement and attaches one upkeep effect to the activation.

const UPKEEP_DUE: StringName = &"State.Movement.SprintUpkeepDue"

## Infinite periodic effect that settles completed intervals of grounded sprint travel.
## Set its Period and calculation's Stamina per Interval to tune upkeep.
@export var upkeep_effect: GameplayEffectDefinition


func get_validation_error() -> StringName:
	if upkeep_effect == null or upkeep_effect.timing != GameplayEffectDefinition.Timing.INFINITE \
			or not is_finite(upkeep_effect.period) or upkeep_effect.period < 0.01 \
			or upkeep_effect.execute_periodic_on_application \
			or not upkeep_effect.ongoing_required_target_tags.has(String(UPKEEP_DUE)) \
			or upkeep_effect.period_inhibition_policy \
					!= GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD \
			or upkeep_effect.stacking_type != GameplayEffectDefinition.StackingType.INDEPENDENT \
			or not upkeep_effect.get_validation_error().is_empty() \
			or not is_finite(_get_stamina_cost(upkeep_effect.executions)) \
			or _get_stamina_cost(upkeep_effect.executions) < 0.0:
		return &"invalid_sprint_upkeep"
	return &""


func get_activation_error(system: AbilitySystem) -> StringName:
	var movement := _get_movement(system)
	if movement == null:
		return &"missing_movement"
	if not system.effects.can_apply_effect(upkeep_effect):
		return &"invalid_sprint_upkeep"
	if not movement.can_move_in_sprint() or not SprintHandle.can_afford(
			system, movement, upkeep_effect.period, _get_stamina_cost(upkeep_effect.executions)):
		return &"sprint_unavailable"
	return &""


func execute(context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	var cast := context.cast
	var system := cast.get_system()
	if not get_activation_error(system).is_empty():
		return -1
	var movement := _get_movement(system)
	var spec := cast.make_effect_spec(upkeep_effect)
	if spec == null:
		return -1
	var handle := SprintHandle.new()
	handle.cast_ref = weakref(cast)
	handle.movement = weakref(movement)
	handle.period = spec.period
	handle.cost = _get_stamina_cost(spec.executions)
	if not movement.begin_sprint(cast, handle.period, handle.can_continue, handle.report_upkeep_due):
		return -1
	context.own_handle(handle)
	var retained := system.effects.apply_effect_spec(spec)
	if cast.finished:
		system.remove_active_effect(retained)
		return -1
	if not system.effects.has_retained_effect(retained):
		return -1
	handle.effect = retained
	return 1


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return [upkeep_effect]


static func _get_stamina_cost(executions: Array[GameplayEffectExecution]) -> float:
	for execution: GameplayEffectExecution in executions:
		if execution is SprintStaminaUpkeepCalculation:
			return execution.stamina_per_interval
	return -1.0


static func _get_movement(system: AbilitySystem) -> FirstPersonMovement:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Movement") as FirstPersonMovement


class SprintHandle extends AbilityPhaseContext.OwnedHandle:
	var cast_ref: WeakRef
	var movement: WeakRef
	var period: float
	var cost: float
	var effect: int

	func physics_advance(cast: AbilityCast, _delta: float) -> void:
		var system := cast.get_system()
		if is_instance_valid(system) and not system.effects.has_retained_effect(effect):
			cast.cancel()

	func can_continue(extra_travel: float) -> bool:
		var cast := cast_ref.get_ref() as AbilityCast
		var mover := movement.get_ref() as FirstPersonMovement
		var system := cast.get_system() if cast != null else null
		return is_instance_valid(system) and is_instance_valid(mover) \
				and system.effects.has_retained_effect(effect) \
				and can_afford(system, mover, period, cost, extra_travel)

	static func can_afford(
			system: AbilitySystem, mover: FirstPersonMovement, interval: float, stamina: float,
			extra_travel: float = 0.0
	) -> bool:
		var intervals := maxi(1, mover.get_unpaid_sprint_intervals(interval, extra_travel))
		return system.can_spend_current(CombatAttributes.Id.STAMINA, stamina * intervals)

	func report_upkeep_due(due: bool) -> void:
		var cast := cast_ref.get_ref() as AbilityCast
		var system := cast.get_system() if cast != null else null
		if is_instance_valid(system):
			if due:
				system.tags.add_tag(UPKEEP_DUE)
			else:
				system.tags.remove_tag(UPKEEP_DUE)

	func remove() -> void:
		var cast := cast_ref.get_ref() as AbilityCast
		var mover := movement.get_ref() as FirstPersonMovement
		if cast == null:
			return
		if is_instance_valid(mover):
			mover.end_sprint(cast)
		var system := cast.get_system()
		if is_instance_valid(system):
			system.remove_active_effect(effect)
