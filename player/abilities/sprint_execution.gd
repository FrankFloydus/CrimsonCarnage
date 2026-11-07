extends AbilityExecution
## Authorizes the movement component to use its sprint gait while the action is active.

## Stamina paid after each completed interval of grounded Sprint travel. The last charge also spends any remainder that cannot fund another charge. Zero makes Sprint free.
@export_range(0.0, 100.0, 0.1, "or_greater") var stamina_per_charge: float = 2.0
## Grounded movement time required for each charge, in seconds. Partial time survives a release.
@export_range(0.01, 10.0, 0.01, "or_greater") var charge_interval: float = 0.1


func get_validation_error(system: AbilitySystem) -> StringName:
	var movement := _get_movement(system)
	if movement == null:
		return &"missing_movement"
	if not movement.can_move_in_sprint() or not is_finite(charge_interval) \
			or charge_interval < 0.01 or _quote_charge(system) < 0.0:
		return &"sprint_unavailable"
	return &""


func begin(cast: AbilityCast) -> void:
	var system := cast.get_system()
	var movement := _get_movement(system)
	if movement == null or not movement.begin_sprint(
			cast, charge_interval, _quote_charge.bind(system), _commit_charge.bind(cast)
	):
		cast.cancel()


func input_released(cast: AbilityCast) -> void:
	cast.finish()


func handle_gameplay_event(cast: AbilityCast, event_tag: StringName, _payload: Dictionary) -> void:
	if event_tag == &"Event.Stamina.Depleted":
		cast.cancel()


func end(cast: AbilityCast, _cancelled: bool) -> void:
	var movement := _get_movement(cast.get_system())
	if movement != null:
		movement.end_sprint(cast)


func _quote_charge(system: AbilitySystem) -> float:
	return stamina_per_charge if is_instance_valid(system) \
			and system.can_spend_current(CombatAttributes.Id.STAMINA, stamina_per_charge) else -1.0


func _commit_charge(amount: float, cast: AbilityCast) -> bool:
	var system := cast.get_system()
	if is_instance_valid(system) and is_instance_valid(system.attributes):
		var stamina := system.attributes.get_value(CombatAttributes.Id.STAMINA)
		var remainder := stamina - amount
		var debit := stamina if remainder > 0.0 and remainder < amount else amount
		if system.try_spend_current(CombatAttributes.Id.STAMINA, debit):
			return true
	cast.cancel()
	return false


static func _get_movement(system: AbilitySystem) -> FirstPersonMovement:
	if not is_instance_valid(system) or not is_instance_valid(system.actor_body):
		return null
	return system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
