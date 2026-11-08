class_name ActorAttributes
extends Node
## Owns Combat 2.0 base attributes, primary allocations, pools and modifier aggregation.

signal attribute_changed(attribute: int, previous: float, value: float)

## Character level used by earned points and attack/spell accuracy; ranges from 1 through 60.
@export_range(1, 60, 1) var level: int = 1:
	set(value):
		var previous := _before_change()
		level = clampi(value, 1, int(CombatRules.get_number("max_level")))
		_after_change(previous)

## Invested Strength points; adds Brutality Physical Power/accuracy and Carry Capacity.
## Authored test/NPC profiles may exceed the player budget; redistribution validates it.
@export_range(0, 1000, 1, "or_greater") var allocated_strength: int = 0:
	set(value):
		var previous := _before_change()
		allocated_strength = maxi(0, value)
		_after_change(previous)

## Invested Dexterity points; adds Finesse Physical Power and accuracy, including bow shots.
@export_range(0, 1000, 1, "or_greater") var allocated_dexterity: int = 0:
	set(value):
		var previous := _before_change()
		allocated_dexterity = maxi(0, value)
		_after_change(previous)

## Invested Intellect points; adds flat Magic Power, maximum Mana and spell accuracy.
@export_range(0, 1000, 1, "or_greater") var allocated_intellect: int = 0:
	set(value):
		var previous := _before_change()
		allocated_intellect = maxi(0, value)
		_after_change(previous)

## Invested Vitality points; adds flat maximum Health and maximum Stamina.
@export_range(0, 1000, 1, "or_greater") var allocated_vitality: int = 0:
	set(value):
		var previous := _before_change()
		allocated_vitality = maxi(0, value)
		_after_change(previous)

## Inline starting adjustments, copied at initialization. Add is an ordinary flat bonus;
## Set Base overrides the full derived foundation, including its primary contribution.
@export var initial_modifiers: Array[AttributeModifier] = []
## Gameplay events published as final attribute values cross their authored thresholds.
@export var gameplay_event_rules: Array[AttributeGameplayEventRule] = []

var _initialized: bool = false
var _updating_allocations: bool = false
var _currents: Dictionary[int, float] = {}
var _base_values: Dictionary[int, float] = {}
var _base_overrides: Dictionary[int, float] = {}
var _authored_modifiers: Array[AttributeModifier] = []
var _runtime_modifiers: Dictionary[StringName, Array] = {}
var _evaluating: Dictionary[int, bool] = {}


func _ready() -> void:
	initialize()


func initialize() -> void:
	if _initialized:
		return
	_initialized = true
	_authored_modifiers = _copy_modifiers(initial_modifiers)
	for id: int in CombatAttributes.current_ids():
		_currents[id] = get_value(CombatAttributes.maximum_for(id))


func get_value(id: int, context_tags: PackedStringArray = PackedStringArray()) -> float:
	initialize()
	if not CombatAttributes.is_active(id):
		return 0.0
	if CombatAttributes.is_current_resource(id):
		return _currents.get(id, 0.0)
	# An invalid capture cycle cannot recurse indefinitely or count its own magnitude twice.
	if _evaluating.has(id):
		return 0.0
	_evaluating[id] = true
	var totals := _modifier_totals(id, context_tags)
	_evaluating.erase(id)
	var value: float = (float(totals.base) + float(totals.additive)) \
			* maxf(0.0, 1.0 + float(totals.percentage)) * float(totals.more)
	var clamped := CombatAttributes.clamp_value(id, value)
	if id == CombatAttributes.Id.MOVEMENT_SPEED and totals.final_movement < 1.0:
		return (100.0 + clamped) * float(totals.final_movement) - 100.0
	return clamped


func get_base_value(id: int, context_tags: PackedStringArray = PackedStringArray()) -> float:
	initialize()
	if not CombatAttributes.is_active(id):
		return 0.0
	if CombatAttributes.is_current_resource(id):
		return get_value(id)
	return _base_value(id, context_tags)


## Intrinsic base before allocations, retained modifiers and developer overrides.
func get_numeric_base_value(id: int) -> float:
	initialize()
	if CombatAttributes.is_current_resource(id):
		return _currents.get(id, 0.0)
	return _base_values.get(id, 0.0)


func set_numeric_base_value(id: int, value: float) -> void:
	apply_numeric_base_values({id: value})


## Commits an instant or periodic effect's base outputs before notifying listeners.
func apply_numeric_base_values(values: Dictionary[int, float]) -> void:
	if values.is_empty():
		return
	initialize()
	var previous := _capture_values()
	for id: int in values:
		if CombatAttributes.is_active(id) and not CombatAttributes.is_current_resource(id) \
				and is_finite(values[id]):
			_base_values[id] = values[id]
	for id: int in CombatAttributes.current_ids():
		if values.has(id) and is_finite(values[id]):
			_currents[id] = maxf(0.0, values[id])
	_after_change(previous, true)


## Replaces the derived foundation for an authored actor or a Playground override.
func set_base_value(id: int, value: float) -> void:
	initialize()
	if not is_finite(value) or not CombatAttributes.is_active(id):
		return
	if CombatAttributes.is_current_resource(id):
		modify_current(id, value - get_value(id))
		return
	var previous := _capture_values()
	_base_overrides[id] = value
	_after_change(previous)


func modify_current(id: int, amount: float) -> float:
	initialize()
	if not CombatAttributes.is_current_resource(id) or not is_finite(amount):
		return 0.0
	var previous := get_value(id)
	var value := clampf(previous + amount, 0.0, get_value(CombatAttributes.maximum_for(id)))
	_currents[id] = value
	if previous != value:
		attribute_changed.emit(id, previous, value)
	return value - previous


## Spends nonnegative amounts as one transaction, recording actual deltas in the caller's dictionary.
func commit_resource_spend(costs: Dictionary[int, float], spent: Dictionary[int, float]) -> bool:
	initialize()
	for id: int in costs:
		if not CombatAttributes.is_current_resource(id) or not is_finite(costs[id]) \
				or costs[id] < 0.0 or costs[id] > _currents[id]:
			return false
	var previous: Dictionary[int, float] = {}
	var committed: Dictionary[int, float] = {}
	var actual: Dictionary[int, float] = {}
	for id: int in CombatAttributes.current_ids():
		var cost := costs.get(id, 0.0) as float
		if cost <= 0.0:
			continue
		previous[id] = _currents[id]
		committed[id] = previous[id] - cost
		actual[id] = previous[id] - committed[id]
		if actual[id] <= 0.0:
			return false
	spent.assign(actual)
	for id: int in committed:
		_currents[id] = committed[id]
	for id: int in committed:
		attribute_changed.emit(id, previous[id], committed[id])
	return true


## Removes Health directly, returning actual Health loss separately from requested damage.
## Invalid damage and damage delivered to an already dead actor have no effect.
func apply_damage(amount: float) -> Dictionary:
	initialize()
	var result := {"health_damage": 0.0, "resolved_amount": 0.0}
	if not is_finite(amount) or amount <= 0.0 or get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return result
	result.health_damage = -modify_current(CombatAttributes.Id.HEALTH, -amount)
	result.resolved_amount = amount
	return result


## Commits all validated routed losses before any recipient's attribute observers run.
## The resolver supplies a dictionary keyed by ActorAttributes. Referencing this script as a
## local loop type in its own static method retains the script at Godot shutdown.
static func commit_damage_batch(requests: Dictionary) -> Dictionary:
	var outcomes := {}
	for recipient: Node in requests:
		var requested: float = requests[recipient]
		if not is_instance_valid(recipient) or recipient.is_queued_for_deletion() \
				or not is_finite(requested) or requested < 0.0:
			return {}
		var previous: float = recipient.get_value(CombatAttributes.Id.HEALTH)
		if previous <= 0.0:
			return {}
		var remaining := maxf(0.0, previous - requested)
		outcomes[recipient] = {"previous": previous, "current": remaining,
				"health_damage": previous - remaining}
	for recipient in outcomes:
		recipient._currents[CombatAttributes.Id.HEALTH] = outcomes[recipient]["current"]
	for recipient: Node in outcomes:
		var outcome: Dictionary = outcomes[recipient]
		if is_instance_valid(recipient) and outcome["health_damage"] > 0.0:
			recipient.attribute_changed.emit(CombatAttributes.Id.HEALTH,
					outcome["previous"], outcome["current"])
	return outcomes


func set_modifiers(owner: StringName, modifiers: Array[AttributeModifier]) -> void:
	initialize()
	var previous := _capture_values()
	_runtime_modifiers[owner] = _copy_modifiers(modifiers)
	_after_change(previous)


func remove_modifiers(owner: StringName) -> void:
	initialize()
	if not _runtime_modifiers.has(owner):
		return
	var previous := _capture_values()
	_runtime_modifiers.erase(owner)
	_after_change(previous)


## Explicit test/reset operation. Increasing a capacity alone never restores its current pool.
func restore_resources() -> void:
	initialize()
	for id: int in CombatAttributes.current_ids():
		modify_current(id, get_value(CombatAttributes.maximum_for(id)) - get_value(id))


func allocation_budget() -> int:
	return int(CombatRules.get_number("creation_points") \
			+ CombatRules.get_number("points_per_level") * (level - 1))


func allocated_points() -> int:
	return allocated_strength + allocated_dexterity + allocated_intellect + allocated_vitality


func try_set_allocations(
		strength_points: int,
		dexterity_points: int,
		intellect_points: int,
		vitality_points: int
) -> bool:
	var budget := allocation_budget()
	for points: int in [strength_points, dexterity_points, intellect_points, vitality_points]:
		if points < 0 or points > budget:
			return false
	if strength_points + dexterity_points + intellect_points + vitality_points > budget:
		return false
	var previous := _before_change()
	_updating_allocations = true
	allocated_strength = strength_points
	allocated_dexterity = dexterity_points
	allocated_intellect = intellect_points
	allocated_vitality = vitality_points
	_updating_allocations = false
	_after_change(previous)
	return true


func _modifier_totals(id: int, context_tags: PackedStringArray) -> Dictionary:
	var base := _base_value(id, context_tags)
	var additive := 0.0
	var percentage := 0.0
	var more := 1.0
	var final_movement := 1.0
	for modifier: AttributeModifier in _authored_modifiers:
		if modifier.attribute != id or not modifier.matches_context(context_tags):
			continue
		match modifier.operation:
			AttributeModifier.Operation.ADD:
				additive += modifier.get_magnitude(self, context_tags)
			AttributeModifier.Operation.ADD_PERCENT:
				percentage += modifier.get_magnitude(self, context_tags) / 100.0
			AttributeModifier.Operation.MORE_PERCENT:
				more *= maxf(0.0, 1.0 + modifier.get_magnitude(self, context_tags) / 100.0)
			AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT:
				final_movement *= 1.0 + modifier.get_magnitude(self, context_tags) / 100.0
	for owner: StringName in _runtime_modifiers:
		for modifier: AttributeModifier in _runtime_modifiers[owner]:
			if modifier.attribute != id or not modifier.matches_context(context_tags):
				continue
			match modifier.operation:
				AttributeModifier.Operation.SET_BASE:
					base = modifier.get_magnitude(self, context_tags)
				AttributeModifier.Operation.ADD:
					additive += modifier.get_magnitude(self, context_tags)
				AttributeModifier.Operation.ADD_PERCENT:
					percentage += modifier.get_magnitude(self, context_tags) / 100.0
				AttributeModifier.Operation.MORE_PERCENT:
					more *= maxf(0.0, 1.0 + modifier.get_magnitude(self, context_tags) / 100.0)
				AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT:
					final_movement *= 1.0 + modifier.get_magnitude(self, context_tags) / 100.0
	return {
		"base": base,
		"additive": additive,
		"percentage": percentage,
		"more": more,
		"final_movement": final_movement,
	}


func _base_value(id: int, context_tags: PackedStringArray) -> float:
	if _base_overrides.has(id):
		return _base_overrides[id]
	var value := get_numeric_base_value(id)
	var governing := CombatAttributes.governing_attribute(context_tags)
	match id:
		CombatAttributes.Id.STRENGTH:
			value += allocated_strength
		CombatAttributes.Id.DEXTERITY:
			value += allocated_dexterity
		CombatAttributes.Id.INTELLECT:
			value += allocated_intellect
		CombatAttributes.Id.VITALITY:
			value += allocated_vitality
		CombatAttributes.Id.PHYSICAL_POWER:
			if governing == CombatAttributes.Id.STRENGTH:
				value += get_value(governing, context_tags) \
						* CombatRules.get_number("strength_physical_power_per_point")
			elif governing == CombatAttributes.Id.DEXTERITY:
				value += get_value(governing, context_tags) \
						* CombatRules.get_number("dexterity_physical_power_per_point")
		CombatAttributes.Id.ACCURACY_RATING:
			if governing != CombatAttributes.Id.NONE:
				value += get_value(governing, context_tags) \
						* CombatRules.get_number("governing_accuracy_per_point")
	for modifiers: Array in _runtime_modifiers.values():
		for modifier: AttributeModifier in modifiers:
			if modifier.attribute == id and modifier.operation == AttributeModifier.Operation.ADD_TO_FOUNDATION \
					and modifier.matches_context(context_tags):
				value += modifier.get_magnitude(self, context_tags)
	for modifier: AttributeModifier in _authored_modifiers:
		if modifier.attribute == id and modifier.operation == AttributeModifier.Operation.SET_BASE \
				and modifier.matches_context(context_tags):
			value = modifier.get_magnitude(self, context_tags)
	return value


func _copy_modifiers(modifiers: Array[AttributeModifier]) -> Array[AttributeModifier]:
	var result: Array[AttributeModifier] = []
	for modifier: AttributeModifier in modifiers:
		if modifier == null or not CombatAttributes.is_active(modifier.attribute):
			continue
		if CombatAttributes.is_current_resource(modifier.attribute):
			push_warning("Persistent modifiers cannot target current pools; use explicit resource changes.")
			continue
		if not is_finite(modifier.value) or (
				modifier.uses_capture() and not is_finite(modifier.capture_coefficient)):
			continue
		if modifier.operation == AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT \
				and not modifier.is_valid_final_movement_percent():
			continue
		result.append(modifier.copy())
	return result


func _before_change() -> Dictionary:
	return _capture_values() if _initialized and not _updating_allocations else {}


func _after_change(previous: Dictionary, emit_small_pool_changes: bool = false) -> void:
	if not _initialized or _updating_allocations:
		return
	for id: int in CombatAttributes.current_ids():
		_currents[id] = minf(_currents.get(id, 0.0), get_value(CombatAttributes.maximum_for(id)))
	var current := _capture_values()
	for id: int in current:
		var value: float = current[id]
		var old_value: float = previous.get(id, value)
		if old_value == value:
			continue
		if not is_equal_approx(old_value, value) or _has_gameplay_event_rule_for(id) \
				or (emit_small_pool_changes and CombatAttributes.is_current_resource(id)):
			attribute_changed.emit(id, old_value, value)


func _has_gameplay_event_rule_for(id: int) -> bool:
	# Even a sub-epsilon change can cross an authored strict threshold.
	for rule: AttributeGameplayEventRule in gameplay_event_rules:
		if rule != null and rule.watches(id):
			return true
	return false


func _capture_values() -> Dictionary:
	var result: Dictionary = {}
	for id: int in CombatAttributes.all_ids():
		result[id] = get_value(id)
	return result
