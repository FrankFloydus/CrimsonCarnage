class_name ActorAttributes
extends Node
## Owns Combat 2.0 primary allocations, resources, continuous recovery and removable modifiers.

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
## Any matching actor tag pauses Stamina recovery while other pools recover normally.
@export var stamina_regeneration_blocked_tags: PackedStringArray = []

var _initialized: bool = false
var _updating_allocations: bool = false
var _currents: Dictionary[int, float] = {}
var _base_overrides: Dictionary[int, float] = {}
var _authored_modifiers: Array[AttributeModifier] = []
var _runtime_modifiers: Dictionary[StringName, Array] = {}
var _regenerating: bool = false
var _regeneration_tags: GameplayTagSet


func _ready() -> void:
	initialize()


func _physics_process(delta: float) -> void:
	advance_regeneration(delta)


## Supplies the actor’s counted tags for the authored Stamina recovery conditions.
func bind_regeneration_tags(tags: GameplayTagSet) -> void:
	_regeneration_tags = tags


## Restores living actors continuously in points per second, subject to authored recovery conditions.
## Manual callers advance only actors outside automatic physics processing to avoid double steps.
func advance_regeneration(delta: float) -> void:
	if _regenerating or not is_finite(delta) or delta <= 0.0:
		return
	initialize()
	if get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return
	_regenerating = true
	for id: int in CombatAttributes.current_ids():
		# Resource-change listeners may kill the actor or change a later pool's modifiers.
		if get_value(CombatAttributes.Id.HEALTH) <= 0.0:
			break
		if id == CombatAttributes.Id.STAMINA and _regeneration_tags != null \
				and _regeneration_tags.has_any(stamina_regeneration_blocked_tags):
			continue
		var rate := get_value(CombatAttributes.regeneration_for(id))
		if not is_finite(rate) or rate <= 0.0:
			continue
		var missing := maxf(0.0, get_value(CombatAttributes.maximum_for(id)) - get_value(id))
		# Clamp overflow from a very large finite rate/delta before applying resource changes.
		var recovered := minf(rate * delta, missing)
		if is_finite(recovered) and recovered > 0.0:
			modify_current(id, recovered)
	_regenerating = false


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
	var totals := _modifier_totals(id, context_tags)
	var value: float = (float(totals.base) + float(totals.additive)) \
			* maxf(0.0, 1.0 + float(totals.percentage)) * float(totals.more)
	return CombatAttributes.clamp_value(id, value)


func get_base_value(id: int, context_tags: PackedStringArray = PackedStringArray()) -> float:
	initialize()
	if not CombatAttributes.is_active(id):
		return 0.0
	if CombatAttributes.is_current_resource(id):
		return get_value(id)
	return _base_value(id, context_tags)


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
	for modifier: AttributeModifier in _authored_modifiers:
		if modifier.attribute != id or not modifier.matches_context(context_tags):
			continue
		match modifier.operation:
			AttributeModifier.Operation.ADD:
				additive += modifier.value
			AttributeModifier.Operation.ADD_PERCENT:
				percentage += modifier.value / 100.0
			AttributeModifier.Operation.MORE_PERCENT:
				more *= maxf(0.0, 1.0 + modifier.value / 100.0)
	for owner: StringName in _runtime_modifiers:
		for modifier: AttributeModifier in _runtime_modifiers[owner]:
			if modifier.attribute != id or not modifier.matches_context(context_tags):
				continue
			match modifier.operation:
				AttributeModifier.Operation.SET_BASE:
					base = modifier.value
				AttributeModifier.Operation.ADD:
					additive += modifier.value
				AttributeModifier.Operation.ADD_PERCENT:
					percentage += modifier.value / 100.0
				AttributeModifier.Operation.MORE_PERCENT:
					more *= maxf(0.0, 1.0 + modifier.value / 100.0)
	return {"base": base, "additive": additive, "percentage": percentage, "more": more}


func _base_value(id: int, context_tags: PackedStringArray) -> float:
	var value := CombatAttributes.default_value(id, level)
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
		CombatAttributes.Id.MAX_HEALTH:
			value += get_value(CombatAttributes.Id.VITALITY) \
					* CombatRules.get_number("vitality_health_per_point")
		CombatAttributes.Id.MAX_STAMINA:
			value += get_value(CombatAttributes.Id.VITALITY) \
					* CombatRules.get_number("vitality_stamina_per_point")
		CombatAttributes.Id.MAX_MANA:
			value += get_value(CombatAttributes.Id.INTELLECT) \
					* CombatRules.get_number("intellect_mana_per_point")
		CombatAttributes.Id.MAGIC_POWER:
			value += get_value(CombatAttributes.Id.INTELLECT, context_tags) \
					* CombatRules.get_number("intellect_magic_power_per_point")
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
		CombatAttributes.Id.CARRY_CAPACITY:
			value += get_value(CombatAttributes.Id.STRENGTH) \
					* CombatRules.get_number("strength_capacity_per_point")
	for modifier: AttributeModifier in _authored_modifiers:
		if modifier.attribute == id and modifier.operation == AttributeModifier.Operation.SET_BASE \
				and modifier.matches_context(context_tags):
			value = modifier.value
	return _base_overrides.get(id, value)


func _copy_modifiers(modifiers: Array[AttributeModifier]) -> Array[AttributeModifier]:
	var result: Array[AttributeModifier] = []
	for modifier: AttributeModifier in modifiers:
		if modifier == null or not CombatAttributes.is_active(modifier.attribute):
			continue
		if CombatAttributes.is_current_resource(modifier.attribute):
			push_warning("Persistent modifiers cannot target current pools; use explicit resource changes.")
			continue
		if not is_finite(modifier.value):
			continue
		result.append(modifier.copy())
	return result


func _before_change() -> Dictionary:
	return _capture_values() if _initialized and not _updating_allocations else {}


func _after_change(previous: Dictionary) -> void:
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
		if not is_equal_approx(old_value, value) or _has_gameplay_event_rule_for(id):
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
