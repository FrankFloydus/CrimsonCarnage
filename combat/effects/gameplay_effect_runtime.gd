class_name GameplayEffectRuntime
extends RefCounted
## Per-target direct damage and independently owned timed attribute effects.

signal effect_applied(definition: GameplayEffectDefinition)
signal effect_removed(definition: GameplayEffectDefinition)
signal damage_applied(amount: float, definition: GameplayEffectDefinition)
signal combat_event(event: Dictionary)
## A committed retained instance was added or removed. Read the current snapshot in response.
signal retained_effects_changed

var _attributes: ActorAttributes
var _tags: GameplayTagSet
var _entries: Dictionary[int, Dictionary] = {}
var _clock: float = 0.0
var _next_handle: int = 1
var _advancing: bool = false
var _clearing: bool = false
var _mutation_depth: int = 0
var _notifications: Array[Dictionary] = []
var _publishing: bool = false
var _retained_effects_dirty: bool = false
var _critical_random: RandomNumberGenerator


func _init(
		target_attributes: ActorAttributes = null, target_tags: GameplayTagSet = null,
		critical_random: RandomNumberGenerator = null
) -> void:
	_attributes = target_attributes
	_tags = target_tags
	_critical_random = critical_random if critical_random != null else RandomNumberGenerator.new()


## Validates the authored effect and target requirements without mutating state.
func can_apply_effect(definition: GameplayEffectDefinition) -> bool:
	if _clearing or definition == null or not is_instance_valid(_attributes) \
			or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return false
	if not definition.get_validation_error().is_empty():
		return false
	if definition.kind == GameplayEffectDefinition.Kind.DAMAGE \
			and definition.timing != GameplayEffectDefinition.Timing.INSTANT:
		return false
	if definition.kind == GameplayEffectDefinition.Kind.MODIFIERS \
			and definition.timing != GameplayEffectDefinition.Timing.DURATION:
		return false
	if not definition.required_target_tags.is_empty() \
			and (_tags == null or not _tags.has_all(definition.required_target_tags)):
		return false
	return _tags == null or not _tags.has_any(definition.blocked_target_tags)


## Returns a unique positive handle on acceptance, or zero on rejection.
## Instant damage completes immediately; only duration handles remain removable.
func apply_effect(definition: GameplayEffectDefinition, context: GameplayEffectContext) -> int:
	if context == null or not can_apply_effect(definition):
		return 0
	_mutation_depth += 1
	var handle := _next_handle
	_next_handle += 1
	if definition.kind == GameplayEffectDefinition.Kind.DAMAGE:
		var event := context.create_combat_event(&"effect_applied", _attributes, definition)
		var result := CombatMath.resolve_effect_result(definition, context, _attributes)
		var magnitude := maxf(0.0, float(result.get("magnitude", 0.0)))
		if not is_finite(magnitude):
			return _finish_application(0)
		var damage_event := event.duplicate(true)
		damage_event["type"] = &"damage"
		damage_event["raw_magnitude"] = float(result.get("raw_magnitude", 0.0))
		damage_event["critical_magnitude"] = float(result.get("critical_magnitude", 0.0))
		damage_event["armor"] = float(result.get("armor", 0.0))
		damage_event["effective_armor"] = float(result.get("effective_armor", 0.0))
		damage_event["armor_penetration_percent"] = float(result.get(
				"armor_penetration_percent", 0.0))
		damage_event["armor_reduction"] = float(result.get("armor_reduction", 0.0))
		damage_event["resistance_attribute"] = int(result.get(
				"resistance_attribute", CombatAttributes.Id.NONE))
		damage_event["resistance_percent"] = float(result.get("resistance_percent", 0.0))
		damage_event["resistance_multiplier"] = float(result.get("resistance_multiplier", 1.0))
		_notifications.append({"event": event, "definition": definition})
		_notifications.append({"event": damage_event, "definition": definition})
		var applied := _attributes.apply_damage(magnitude)
		var actual := float(applied.get("health_damage", 0.0))
		damage_event["amount"] = actual
		damage_event["resolved_amount"] = magnitude
		damage_event["health_damage"] = actual
		return _finish_application(handle)
	var entry := {
		"handle": handle,
		"definition": definition,
		"effect_id": definition.effect_id,
		"expires_at": _clock + definition.duration if definition.duration > 0.0 else INF,
		"owner": StringName("effect_%d_%d" % [get_instance_id(), handle]),
		"has_modifiers": false,
		"granted_tags": [],
		"complete": false,
		"event": context.create_combat_event(&"effect_applied", _attributes, definition),
	}
	var modifiers: Array[AttributeModifier] = []
	for modifier in definition.modifiers:
		if modifier != null:
			modifiers.append(modifier.copy())
	var grants := definition.granted_tags.duplicate()
	_entries[handle] = entry
	if not modifiers.is_empty():
		# Record ownership before callbacks can clear or remove this pending instance.
		entry["has_modifiers"] = true
		_attributes.set_modifiers(entry["owner"], modifiers)
	if not _entries.has(handle):
		return _finish_application(0)
	if not is_instance_valid(_attributes):
		remove_effect(handle)
		return _finish_application(0)
	if _tags != null:
		for tag in grants:
			entry["granted_tags"].append(StringName(tag))
			_tags.add_tag(StringName(tag))
			if not _entries.has(handle):
				return _finish_application(0)
	entry["complete"] = true
	_retained_effects_dirty = true
	_notifications.append({"event": entry["event"], "definition": definition})
	return _finish_application(handle)


## A connected hostile hit resolves one Accuracy check shared by its entire payload.
## Self modifier effects and explicitly Beneficial modifier-only deliveries bypass the check.
## Optional fractional rolls make tests/replays deterministic; negative values sample their RNG.
## A damaging payload resolves one shared critical only after Accuracy succeeds.
func apply_hit_payload(
		definitions: Array[GameplayEffectDefinition], context: GameplayEffectContext,
		accuracy_roll: float = -1.0, critical_roll: float = -1.0
) -> Dictionary:
	var result := {"outcome": &"invalid", "applied_effects": 0, "hit_chance": 0.0,
			"is_critical": false, "critical_multiplier": 1.0, "critical_damage_percent": 0.0,
			"critical_chance": 0.0}
	if context == null or not is_instance_valid(_attributes) or not is_finite(accuracy_roll) \
			or not is_finite(critical_roll):
		return result
	var eligible: Array[GameplayEffectDefinition] = []
	var has_damage := false
	for definition in definitions:
		if can_apply_effect(definition):
			eligible.append(definition)
			has_damage = has_damage or definition.kind == GameplayEffectDefinition.Kind.DAMAGE
	if eligible.is_empty():
		return result
	var self_delivery := context.source_id == _attributes.get_instance_id()
	var beneficial := AttributeModifier._has_match(context.ability_tags, "Ability.Beneficial")
	var requires_accuracy := has_damage or (not self_delivery and not beneficial)
	var chance := 1.0
	if requires_accuracy:
		var accuracy := context.get_source_value(CombatAttributes.Id.ACCURACY_RATING,
				context.ability_tags)
		chance = CombatMath.get_hit_chance(context.source_level, _attributes.level, accuracy)
		var roll := clampf(accuracy_roll, 0.0, 1.0) if accuracy_roll >= 0.0 else randf()
		if chance <= 0.0 or (chance < 1.0 and roll >= chance):
			result["outcome"] = &"resist" if GameplayEffectContext.is_spell_delivery(
					context.ability_tags) else &"miss"
			result["hit_chance"] = chance
			return result
	var critical := false
	var critical_bonus := 0.0
	var critical_multiplier := 1.0
	var critical_chance := 0.0
	if has_damage:
		critical_chance = context.get_source_value(CombatAttributes.Id.CRITICAL_CHANCE,
				context.ability_tags)
		critical_chance = clampf(critical_chance,
				CombatRules.get_number("critical_chance_min_percent"),
				CombatRules.get_number("critical_chance_max_percent")) / 100.0 \
				if is_finite(critical_chance) else 0.0
		var roll := clampf(critical_roll, 0.0, 1.0) if critical_roll >= 0.0 else _critical_random.randf()
		critical = critical_chance > 0.0 and (critical_chance >= 1.0 or roll < critical_chance)
		if critical:
			critical_bonus = context.get_source_value(CombatAttributes.Id.CRITICAL_DAMAGE,
					context.ability_tags)
			critical_bonus = maxf(0.0, critical_bonus) if is_finite(critical_bonus) else 0.0
			critical_multiplier = CombatMath.get_critical_multiplier(critical_bonus)
	var hit_context := context.with_critical_result(critical, critical_multiplier, critical_bonus)
	var applied := 0
	for definition in eligible:
		if apply_effect(definition, hit_context) > 0:
			applied += 1
	result["outcome"] = &"hit"
	result["hit_chance"] = chance
	result["applied_effects"] = applied
	result["is_critical"] = critical
	result["critical_multiplier"] = critical_multiplier
	result["critical_damage_percent"] = critical_bonus
	result["critical_chance"] = critical_chance
	return result


## Advances finite modifier lifetimes. Zero duration means explicit removal only.
func advance(delta: float) -> void:
	if _advancing or _clearing or not is_finite(delta) or delta <= 0.0:
		return
	_advancing = true
	_clock += delta
	var handles := _entries.keys()
	for handle: int in handles:
		if _entries.has(handle) and float(_entries[handle]["expires_at"]) <= _clock:
			remove_effect(handle)
	_advancing = false


## Removes one retained effect and only the modifiers and tag counts it owns.
func remove_effect(handle: int) -> bool:
	if not _entries.has(handle):
		return false
	_mutation_depth += 1
	var entry: Dictionary = _entries[handle]
	_entries.erase(handle)
	if entry["complete"]:
		_retained_effects_dirty = true
		var event: Dictionary = entry["event"].duplicate(true)
		event["type"] = &"effect_removed"
		_notifications.append({"event": event, "definition": entry["definition"],
				"clearing": _clearing})
	if entry["has_modifiers"] and is_instance_valid(_attributes):
		_attributes.remove_modifiers(entry["owner"])
	if _tags != null:
		for tag: StringName in entry["granted_tags"]:
			_tags.remove_tag(tag)
	_mutation_depth -= 1
	_publish_notifications()
	return true


## Clears all retained ownership; applications during cleanup are rejected.
func clear() -> void:
	if _clearing:
		return
	_clearing = true
	_mutation_depth += 1
	var handles := _entries.keys()
	for handle: int in handles:
		remove_effect(handle)
	_mutation_depth -= 1
	_publish_notifications()
	_clearing = false
	_publish_retained_changes()


## Reports whether the runtime is removing retained ownership and rejects new applications.
func is_clearing() -> bool:
	return _clearing


## Counts active instances, optionally restricted to an authored effect identifier.
func active_count(effect_id: StringName = &"") -> int:
	if effect_id.is_empty():
		return _entries.size()
	var count := 0
	for entry: Dictionary in _entries.values():
		if entry["effect_id"] == effect_id:
			count += 1
	return count


## Returns detached inspection data without exposing mutable instance records.
func get_active_effects() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in _entries.values():
		result.append({"handle": entry["handle"], "effect_id": entry["effect_id"],
				"remaining": maxf(0.0, float(entry["expires_at"]) - _clock)})
	return result


## Checks whether a committed retained effect is still present by its instance handle.
func has_retained_effect(handle: int) -> bool:
	return _entries.has(handle) and _entries[handle]["complete"]


## Returns a detached handle-to-definition snapshot of committed retained effects.
func get_retained_effects() -> Dictionary[int, GameplayEffectDefinition]:
	var result: Dictionary[int, GameplayEffectDefinition] = {}
	for handle: int in _entries:
		if _entries[handle]["complete"]:
			result[handle] = _entries[handle]["definition"]
	return result


func _finish_application(handle: int) -> int:
	_mutation_depth -= 1
	_publish_notifications()
	return handle


func _publish_notifications() -> void:
	if _publishing or _mutation_depth > 0:
		return
	_publishing = true
	while not _notifications.is_empty():
		var notification: Dictionary = _notifications.pop_front()
		var event: Dictionary = notification["event"]
		var definition: GameplayEffectDefinition = notification["definition"]
		var was_clearing := _clearing
		_clearing = _clearing or bool(notification.get("clearing", false))
		combat_event.emit(event.duplicate(true))
		match StringName(event["type"]):
			&"effect_applied":
				effect_applied.emit(definition)
			&"effect_removed":
				effect_removed.emit(definition)
			&"damage":
				damage_applied.emit(float(event["amount"]), definition)
		_clearing = was_clearing
	_publishing = false
	_publish_retained_changes()


func _publish_retained_changes() -> void:
	if _publishing or _mutation_depth > 0 or _clearing or not _retained_effects_dirty:
		return
	_retained_effects_dirty = false
	retained_effects_changed.emit()
