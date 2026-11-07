extends AbilityExecution
## Authorizes the sprint gait and owns the Stamina upkeep effect for one activation.

const UPKEEP_DUE: StringName = &"State.Movement.SprintUpkeepDue"
const UPKEEP_HANDLE: StringName = &"sprint_upkeep_handle"

## Infinite periodic effect that settles completed intervals of grounded Sprint travel.
## Set its Period and the execution's Stamina per Interval to tune upkeep.
@export var upkeep_effect: GameplayEffectDefinition


func get_validation_error(system: AbilitySystem) -> StringName:
	var movement := _get_movement(system)
	if movement == null:
		return &"missing_movement"
	if upkeep_effect == null or upkeep_effect.timing != GameplayEffectDefinition.Timing.INFINITE \
			or not is_finite(upkeep_effect.period) or upkeep_effect.period < 0.01 \
			or upkeep_effect.execute_periodic_on_application \
			or not upkeep_effect.ongoing_required_target_tags.has(String(UPKEEP_DUE)) \
			or upkeep_effect.period_inhibition_policy \
					!= GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD \
			or not system.effects.can_apply_effect(upkeep_effect):
		return &"invalid_sprint_upkeep"
	if not movement.can_move_in_sprint() or not _can_afford(
			system, movement, upkeep_effect.period, _get_stamina_cost(upkeep_effect.executions)):
		return &"sprint_unavailable"
	return &""


func begin(cast: AbilityCast) -> void:
	var system := cast.get_system()
	var movement := _get_movement(system)
	if movement == null or not get_validation_error(system).is_empty():
		cast.cancel()
		return
	var spec := cast.make_effect_spec(upkeep_effect)
	var cost := _get_stamina_cost(spec.executions)
	if not movement.begin_sprint(cast, spec.period,
			_can_continue.bind(cast, movement, spec.period, cost), _report_upkeep_due.bind(system)):
		cast.cancel()
		return
	var input_release := AbilityTaskWaitInputRelease.new()
	input_release.released.connect(cast.finish)
	cast.start_task(input_release)
	var depletion := AbilityTaskWaitGameplayEvent.new(&"Event.Stamina.Depleted")
	depletion.event_received.connect(_cancel_on_depletion.bind(cast))
	cast.start_task(depletion)
	var handle := system.effects.apply_effect_spec(spec)
	if cast.finished:
		system.effects.remove_effect(handle)
		return
	if not system.effects.has_retained_effect(handle):
		cast.cancel()
		return
	cast.data[UPKEEP_HANDLE] = handle


func physics_advance(cast: AbilityCast, _delta: float) -> void:
	var system := cast.get_system()
	if is_instance_valid(system) and not system.effects.has_retained_effect(
			int(cast.data.get(UPKEEP_HANDLE, 0))):
		cast.cancel()


func end(cast: AbilityCast, _cancelled: bool) -> void:
	var system := cast.get_system()
	var movement := _get_movement(system)
	if movement != null:
		movement.end_sprint(cast)
	if is_instance_valid(system) and system.effects != null:
		system.effects.remove_effect(int(cast.data.get(UPKEEP_HANDLE, 0)))


static func _cancel_on_depletion(_tag: StringName, _payload: Dictionary, cast: AbilityCast) -> void:
	cast.cancel()


func _can_continue(
		extra_travel: float, cast: AbilityCast, movement: FirstPersonMovement, interval: float, cost: float
) -> bool:
	var system := cast.get_system()
	return is_instance_valid(system) and system.effects.has_retained_effect(
			int(cast.data.get(UPKEEP_HANDLE, 0))) \
			and _can_afford(system, movement, interval, cost, extra_travel)


static func _can_afford(
		system: AbilitySystem, movement: FirstPersonMovement, interval: float, cost: float,
		extra_travel: float = 0.0
) -> bool:
	var intervals := maxi(1, movement.get_unpaid_sprint_intervals(interval, extra_travel))
	return system.can_spend_current(CombatAttributes.Id.STAMINA, cost * intervals)


static func _report_upkeep_due(due: bool, system: AbilitySystem) -> void:
	if is_instance_valid(system):
		if due:
			system.tags.add_tag(UPKEEP_DUE)
		else:
			system.tags.remove_tag(UPKEEP_DUE)


static func _get_stamina_cost(executions: Array[GameplayEffectExecution]) -> float:
	for execution: GameplayEffectExecution in executions:
		if execution is SprintStaminaUpkeepCalculation:
			return execution.stamina_per_interval
	return -1.0


static func _get_movement(system: AbilitySystem) -> FirstPersonMovement:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
