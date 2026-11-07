class_name GameplayEffectRuntime
extends RefCounted
## Per-target execution, timers, and owned Gameplay Effect contributions.

signal effect_applied(definition: GameplayEffectDefinition)
signal effect_removed(definition: GameplayEffectDefinition)
signal damage_applied(amount: float, definition: GameplayEffectDefinition)
signal effect_stack_changed(handle: int, previous: int, count: int)
signal combat_event(event: Dictionary)
## A committed retained instance was added or removed. Read the current snapshot in response.
signal retained_effects_changed

const CLOCK_EPSILON: float = 1.0e-9
const MAX_STACK_COUNT: int = 2147483647

var cues := GameplayCueRouter.new()

var _attributes: ActorAttributes
var _tags: GameplayTagSet
var _target_system: WeakRef
var _application_filters: Array[Callable] = []
var _component_applications: Array[GameplayEffectDefinition] = []
var _application_random := RandomNumberGenerator.new()
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
var _fallback_damage_execution := GameplayEffectDamageExecution.new()


func _init(
		target_attributes: ActorAttributes = null, target_tags: GameplayTagSet = null,
		critical_random: RandomNumberGenerator = null, target_system: AbilitySystem = null
) -> void:
	_attributes = target_attributes
	_tags = target_tags
	if target_system != null:
		_target_system = weakref(target_system)
	_critical_random = critical_random if critical_random != null else RandomNumberGenerator.new()
	if _tags != null:
		_tags.changed.connect(_on_target_tag_changed)


func get_target_ability_system() -> AbilitySystem:
	return _target_system.get_ref() as AbilitySystem if _target_system != null else null


## Registers a pure filter accepting a candidate spec. Return false to block its application.
func add_application_filter(filter: Callable) -> void:
	if filter.is_valid() and not _application_filters.has(filter):
		_application_filters.append(filter)


func remove_application_filter(filter: Callable) -> void:
	_application_filters.erase(filter)


func seed_application_randomness(seed_value: int) -> void:
	_application_random.seed = seed_value


## A separate RNG stream for authored effect application chances.
func roll_application_chance(probability: float) -> bool:
	return probability >= 1.0 or (probability > 0.0 and _application_random.randf() < probability)


## Validates the authored effect and target requirements without mutating state.
func can_apply_effect(definition: GameplayEffectDefinition) -> bool:
	if _clearing or definition == null or not is_instance_valid(_attributes) \
			or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return false
	if not definition.get_validation_error().is_empty():
		return false
	return _meets_tags(definition.required_target_tags, definition.blocked_target_tags)


func make_effect_spec(definition: GameplayEffectDefinition, context: GameplayEffectContext) -> GameplayEffectSpec:
	if definition == null or context == null:
		return null
	return GameplayEffectSpec.new(definition, context)


func can_apply_spec(spec: GameplayEffectSpec) -> bool:
	if spec == null or spec.context == null or spec.stack_count <= 0 or spec.stack_count > MAX_STACK_COUNT \
			or not is_finite(spec.level) or spec.level <= 0.0 or not can_apply_effect(spec.settings):
		return false
	for filter in _application_filters:
		if filter.is_valid() and not filter.call(spec):
			return false
	return true


## Returns a unique positive handle on acceptance, or zero on rejection.
## Instant effects complete immediately. Only retained handles remain removable.
func apply_effect(definition: GameplayEffectDefinition, context: GameplayEffectContext) -> int:
	return apply_effect_spec(make_effect_spec(definition, context))


func apply_effect_spec(outgoing_spec: GameplayEffectSpec) -> int:
	if not can_apply_spec(outgoing_spec) or _component_applications.has(outgoing_spec.definition):
		return 0
	var spec := outgoing_spec.copy_for_application()
	var definition := spec.settings
	for component in definition.components:
		if not component.can_apply(self, spec):
			return 0
	_mutation_depth += 1
	var stack := _find_stack(spec)
	if not stack.is_empty():
		return _finish_application(_apply_stack(stack, spec))
	if definition.stacking_type == GameplayEffectDefinition.StackingType.INDEPENDENT:
		spec.stack_count = 1
	elif definition.stack_limit_count > 0 and spec.stack_count > definition.stack_limit_count:
		if definition.deny_overflow_application:
			return _finish_application(0)
		spec.stack_count = definition.stack_limit_count
	var handle := _next_handle
	_next_handle += 1
	var event := spec.context.create_combat_event(&"effect_applied", _attributes, definition)
	event["stack_count"] = spec.stack_count
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT:
		var damage := _calculate_damage(spec) if definition.is_damage_effect() else {}
		if not damage.is_empty() and not is_finite(float(damage.get("magnitude", 0.0))):
			return _finish_application(0)
		_notifications.append({"event": event, "definition": spec.definition})
		if not damage.is_empty():
			_apply_damage(spec, event, damage)
		else:
			_queue_cue(GameplayCueRouter.Event.EXECUTED, spec, 0)
		_execute_modifiers(spec)
		_dispatch_application_components(spec)
		return _finish_application(handle)
	var entry := {
		"handle": handle,
		"definition": spec.definition,
		"spec": spec,
		"effect_id": definition.effect_id,
		"expires_at": _clock + spec.duration if definition.timing == GameplayEffectDefinition.Timing.DURATION \
				and spec.duration > 0.0 else INF,
		"next_tick": _clock + spec.period if spec.period > 0.0 else INF,
		"owner": StringName("effect_%d_%d" % [get_instance_id(), handle]),
		"has_modifiers": false,
		"granted_tags": [],
		"component_cleanups": [],
		"complete": false,
		"inhibited": true,
		"cue_active": false,
		"updating": false,
		"refresh_pending": false,
		"event": event,
	}
	_entries[handle] = entry
	_refresh_entry(entry)
	if not _entries.has(handle):
		return _finish_application(0)
	if not is_instance_valid(_attributes):
		remove_effect(handle)
		return _finish_application(0)
	entry["complete"] = true
	_retained_effects_dirty = true
	_notifications.append({"event": entry["event"], "definition": spec.definition})
	_sync_cues(entry)
	if spec.period > 0.0 and definition.execute_periodic_on_application and not entry["inhibited"]:
		_execute_periodic(spec, handle)
	_dispatch_application_components(spec)
	return _finish_application(handle)


## A connected hostile hit resolves one Accuracy check shared by its entire payload.
## Self modifier effects and explicitly Beneficial modifier-only deliveries bypass the check.
## Optional fractional rolls make tests/replays deterministic; negative values sample their RNG.
## A damaging payload resolves one shared critical only after Accuracy succeeds.
func apply_hit_payload(
		definitions: Array[GameplayEffectDefinition], context: GameplayEffectContext,
		accuracy_roll: float = -1.0, critical_roll: float = -1.0
) -> Dictionary:
	var specs: Array[GameplayEffectSpec] = []
	for definition in definitions:
		var spec := make_effect_spec(definition, context)
		if spec != null:
			specs.append(spec)
	return apply_hit_specs(specs, context, accuracy_roll, critical_roll)


## Applies already-authored outgoing specs using one delivered Hit and critical outcome.
func apply_hit_specs(
		specs: Array[GameplayEffectSpec], context: GameplayEffectContext,
		accuracy_roll: float = -1.0, critical_roll: float = -1.0
) -> Dictionary:
	var result := {"outcome": &"invalid", "applied_effects": 0, "hit_chance": 0.0,
			"is_critical": false, "critical_multiplier": 1.0, "critical_damage_percent": 0.0,
			"critical_chance": 0.0}
	if context == null or not is_instance_valid(_attributes) or not is_finite(accuracy_roll) \
			or not is_finite(critical_roll):
		return result
	var eligible: Array[GameplayEffectSpec] = []
	var has_damage := false
	for spec in specs:
		if can_apply_spec(spec):
			eligible.append(spec)
			has_damage = has_damage or spec.settings.is_damage_effect()
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
	for outgoing_spec in eligible:
		var spec := outgoing_spec.copy_for_application()
		spec.context = hit_context
		if apply_effect_spec(spec) > 0:
			applied += 1
	result["outcome"] = &"hit"
	result["hit_chance"] = chance
	result["applied_effects"] = applied
	result["is_critical"] = critical
	result["critical_multiplier"] = critical_multiplier
	result["critical_damage_percent"] = critical_bonus
	result["critical_chance"] = critical_chance
	return result


## Advances expirations and periodic executions in chronological order.
func advance(delta: float) -> void:
	if _advancing or _clearing or not is_finite(delta) or delta <= 0.0:
		return
	var end_time := _clock + delta
	if not is_finite(end_time):
		return
	_advancing = true
	while not _entries.is_empty():
		var deadline := _next_deadline()
		if not is_finite(deadline) or deadline > end_time + CLOCK_EPSILON:
			break
		_clock = maxf(_clock, deadline)
		var handles := _entries.keys()
		for handle: int in handles:
			if _entries.has(handle):
				_execute_due_period(_entries[handle])
		for handle: int in handles:
			if _entries.has(handle) and float(_entries[handle]["expires_at"]) <= _clock + CLOCK_EPSILON:
				_expire_entry(_entries[handle])
	_clock = maxf(_clock, end_time)
	_publish_notifications()
	_advancing = false


## Removes an aggregate stack count, or the entire retained effect when stacks is -1.
func remove_effect(handle: int, stacks: int = -1) -> bool:
	if not _entries.has(handle) or stacks == 0 or stacks < -1:
		return false
	_mutation_depth += 1
	var entry: Dictionary = _entries[handle]
	var spec: GameplayEffectSpec = entry["spec"]
	if stacks > 0 and stacks < spec.stack_count:
		var previous := spec.stack_count
		spec.stack_count -= stacks
		_update_stack(entry, previous)
		_mutation_depth -= 1
		_publish_notifications()
		return true
	_entries.erase(handle)
	if entry["complete"]:
		_retained_effects_dirty = true
		var event: Dictionary = entry["event"].duplicate(true)
		event["type"] = &"effect_removed"
		event["stack_count"] = spec.stack_count
		_notifications.append({"event": event, "definition": entry["definition"],
				"clearing": _clearing})
	_sync_cues(entry, true)
	_release_contributions(entry)
	_mutation_depth -= 1
	_publish_notifications()
	return true


## Clears all retained ownership; applications during cleanup are rejected.
func clear(preserve: Array[int] = []) -> void:
	if _clearing:
		return
	_clearing = true
	_mutation_depth += 1
	var handles := _entries.keys()
	for handle: int in handles:
		if not preserve.has(handle):
			remove_effect(handle)
	for handle: int in preserve:
		if _entries.has(handle):
			_refresh_entry(_entries[handle])
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


## Removes entire retained stacks with any queried asset tag. Excludes an optional definition.
func remove_effects_by_asset_tags(
		queries: PackedStringArray, except_definition: GameplayEffectDefinition = null
) -> void:
	if queries.is_empty():
		return
	for handle: int in _entries.keys():
		if not _entries.has(handle) or _entries[handle]["definition"] == except_definition:
			continue
		var spec: GameplayEffectSpec = _entries[handle]["spec"]
		for query in queries:
			if AttributeModifier._has_match(spec.settings.asset_tags, query):
				remove_effect(handle)
				break


## Returns detached inspection data without exposing mutable instance records.
func get_active_effects() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in _entries.values():
		result.append({"handle": entry["handle"], "effect_id": entry["effect_id"],
				"remaining": get_remaining(entry["handle"]), "inhibited": entry["inhibited"],
				"stack_count": get_stack_count(entry["handle"])})
	return result


func get_remaining(handle: int) -> float:
	return maxf(0.0, float(_entries[handle]["expires_at"]) - _clock) if _entries.has(handle) else 0.0


func get_stack_count(handle: int) -> int:
	return _entries[handle]["spec"].stack_count if _entries.has(handle) else 0


## Returns the longest active effect granting any queried tag, as used by ability cooldowns.
func get_remaining_for_granted_tags(queries: PackedStringArray) -> float:
	var remaining := 0.0
	for entry: Dictionary in _entries.values():
		if entry["inhibited"]:
			continue
		for grant: StringName in entry["granted_tags"]:
			for query in queries:
				if GameplayTagSet.matches(grant, StringName(query)):
					remaining = maxf(remaining, get_remaining(entry["handle"]))
	return remaining


func is_effect_inhibited(handle: int) -> bool:
	return _entries.has(handle) and _entries[handle]["inhibited"]


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


func _find_stack(spec: GameplayEffectSpec) -> Dictionary:
	var stacking_type := spec.settings.stacking_type
	if stacking_type == GameplayEffectDefinition.StackingType.INDEPENDENT:
		return {}
	if stacking_type == GameplayEffectDefinition.StackingType.AGGREGATE_BY_SOURCE \
			and spec.context.source_id == 0:
		return {}
	for entry: Dictionary in _entries.values():
		if entry["definition"] != spec.definition:
			continue
		var active_spec: GameplayEffectSpec = entry["spec"]
		if active_spec.settings.stacking_type != stacking_type:
			continue
		if stacking_type == GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET \
				or spec.context.source_id == active_spec.context.source_id:
			return entry
	return {}


func _apply_stack(entry: Dictionary, spec: GameplayEffectSpec) -> int:
	if not entry["complete"] or entry["updating"]:
		return 0
	var handle: int = entry["handle"]
	var previous_spec: GameplayEffectSpec = entry["spec"]
	var previous_count := previous_spec.stack_count
	var settings := previous_spec.settings
	var count := mini(previous_count + spec.stack_count, MAX_STACK_COUNT)
	if settings.stack_limit_count > 0 and count > settings.stack_limit_count:
		if settings.deny_overflow_application:
			if settings.clear_stack_on_overflow:
				remove_effect(handle)
			return 0
		count = settings.stack_limit_count
	# Preserve the active effect's frozen authored settings and evaluate the newest application context.
	spec.settings = settings
	spec.stack_count = count
	entry["spec"] = spec
	if settings.timing == GameplayEffectDefinition.Timing.DURATION and spec.duration > 0.0:
		match settings.stack_duration_policy:
			GameplayEffectDefinition.StackDurationPolicy.REFRESH:
				entry["expires_at"] = _clock + spec.duration
			GameplayEffectDefinition.StackDurationPolicy.EXTEND:
				entry["expires_at"] += spec.duration
	var event := spec.context.create_combat_event(&"effect_applied", _attributes, settings)
	event["stack_count"] = count
	entry["event"] = event
	_update_stack(entry, previous_count)
	if not _entries.has(handle):
		return 0
	_notifications.append({"event": event, "definition": spec.definition})
	if spec.period > 0.0 and settings.stack_period_policy == GameplayEffectDefinition.StackPeriodPolicy.RESET:
		entry["next_tick"] = _clock + spec.period
		if settings.execute_periodic_on_application and not entry["inhibited"]:
			_execute_periodic(spec, handle)
	_dispatch_application_components(spec)
	return handle


func _update_stack(entry: Dictionary, previous_count: int) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	if not entry["inhibited"]:
		_grant_modifiers(entry, spec)
	if not _entries.has(entry["handle"]) or not entry["complete"]:
		return
	_retained_effects_dirty = true
	if previous_count == spec.stack_count:
		return
	var event: Dictionary = entry["event"].duplicate(true)
	event["type"] = &"effect_stack_changed"
	event["handle"] = entry["handle"]
	event["previous_stack_count"] = previous_count
	event["stack_count"] = spec.stack_count
	_notifications.append({"event": event, "definition": spec.definition})


func _expire_entry(entry: Dictionary) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	var handle: int = entry["handle"]
	var policy := spec.settings.stack_expiration_policy
	if spec.settings.stacking_type == GameplayEffectDefinition.StackingType.INDEPENDENT \
			or policy == GameplayEffectDefinition.StackExpirationPolicy.CLEAR_ALL \
			or (policy == GameplayEffectDefinition.StackExpirationPolicy.REMOVE_ONE_AND_REFRESH \
				and spec.stack_count == 1):
		remove_effect(handle)
		return
	var deadline := _clock + spec.duration
	if deadline <= _clock:
		remove_effect(handle)
		return
	entry["expires_at"] = deadline
	if policy == GameplayEffectDefinition.StackExpirationPolicy.REMOVE_ONE_AND_REFRESH:
		remove_effect(handle, 1)
	else:
		_retained_effects_dirty = true
		_publish_retained_changes()


func _meets_tags(required: PackedStringArray, blocked: PackedStringArray) -> bool:
	if _tags == null:
		return required.is_empty()
	return _tags.has_all(required) and not _tags.has_any(blocked)


func _on_target_tag_changed(tag: StringName, _present: bool) -> void:
	if _clearing:
		return
	_mutation_depth += 1
	for handle: int in _entries.keys():
		if not _entries.has(handle):
			continue
		var entry: Dictionary = _entries[handle]
		var spec: GameplayEffectSpec = entry["spec"]
		var queries := spec.settings.ongoing_required_target_tags + spec.settings.ongoing_blocked_target_tags
		for query in queries:
			if GameplayTagSet.matches(tag, StringName(query)):
				_refresh_entry(entry)
				break
	_mutation_depth -= 1
	_publish_notifications()


func _refresh_entry(entry: Dictionary) -> void:
	if entry["updating"]:
		entry["refresh_pending"] = true
		return
	var spec: GameplayEffectSpec = entry["spec"]
	var settings := spec.settings
	var inhibit := not _meets_tags(settings.ongoing_required_target_tags,
			settings.ongoing_blocked_target_tags)
	if entry["inhibited"] == inhibit:
		return
	entry["inhibited"] = inhibit
	entry["updating"] = true
	if inhibit:
		_release_contributions(entry)
	else:
		_grant_contributions(entry, spec)
	entry["updating"] = false
	if not _entries.has(entry["handle"]):
		return
	if entry["refresh_pending"]:
		entry["refresh_pending"] = false
		_refresh_entry(entry)
	if not _entries.has(entry["handle"]) or not entry["complete"]:
		return
	_retained_effects_dirty = true
	_sync_cues(entry)
	if not inhibit and not entry["inhibited"] and spec.period > 0.0:
		_resume_period(entry, spec)


func _grant_contributions(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	_grant_modifiers(entry, spec)
	if _tags != null:
		for tag in spec.settings.granted_tags:
			if not _entries.has(entry["handle"]):
				return
			entry["granted_tags"].append(StringName(tag))
			_tags.add_tag(StringName(tag))
	_grant_component_contributions(entry, spec)


func _grant_component_contributions(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	if spec.settings.components.is_empty() or not _entries.has(entry["handle"]):
		return
	_component_applications.append(spec.definition)
	for component in spec.settings.components:
		var cleanup := component.on_active(self, spec, entry["handle"])
		if not _entries.has(entry["handle"]):
			if cleanup.is_valid():
				cleanup.call()
			break
		if cleanup.is_valid():
			entry["component_cleanups"].append(cleanup)
	_component_applications.pop_back()


func _grant_modifiers(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	if spec.period == 0.0 and not spec.modifiers.is_empty() and is_instance_valid(_attributes):
		var modifiers: Array[AttributeModifier] = []
		for authored_modifier in spec.modifiers:
			modifiers.append(_resolve_caller_modifier(authored_modifier, spec))
		# Record ownership before callbacks can clear or remove this pending instance.
		entry["has_modifiers"] = true
		_attributes.set_modifiers(entry["owner"], modifiers)


func _release_contributions(entry: Dictionary) -> void:
	var grants: Array = entry["granted_tags"]
	entry["granted_tags"] = []
	var cleanups: Array = entry["component_cleanups"]
	entry["component_cleanups"] = []
	var had_modifiers: bool = entry["has_modifiers"]
	entry["has_modifiers"] = false
	if had_modifiers and is_instance_valid(_attributes):
		_attributes.remove_modifiers(entry["owner"])
	if _tags != null:
		for tag: StringName in grants:
			_tags.remove_tag(tag)
	for cleanup: Callable in cleanups:
		if cleanup.is_valid():
			cleanup.call()


func _dispatch_application_components(spec: GameplayEffectSpec) -> void:
	if spec.settings.components.is_empty():
		return
	_component_applications.append(spec.definition)
	for component in spec.settings.components:
		component.on_applied(self, spec)
	_component_applications.pop_back()


func _resume_period(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	var policy := spec.settings.period_inhibition_policy
	if policy == GameplayEffectDefinition.PeriodInhibitionPolicy.NEVER_RESET:
		var next_tick: float = entry["next_tick"]
		if next_tick < _clock - CLOCK_EPSILON:
			entry["next_tick"] = next_tick + ceilf((_clock - next_tick) / spec.period) * spec.period
		return
	entry["next_tick"] = _clock + spec.period
	if policy == GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD:
		_execute_periodic(spec, entry["handle"])


func _next_deadline() -> float:
	var deadline := INF
	for entry: Dictionary in _entries.values():
		if entry["complete"]:
			deadline = minf(deadline, float(entry["expires_at"]))
			if not entry["inhibited"]:
				deadline = minf(deadline, float(entry["next_tick"]))
	return deadline


func _execute_due_period(entry: Dictionary) -> void:
	var next_tick: float = entry["next_tick"]
	if not entry["complete"] or entry["inhibited"] or next_tick > _clock + CLOCK_EPSILON \
			or next_tick > float(entry["expires_at"]) + CLOCK_EPSILON:
		return
	var spec: GameplayEffectSpec = entry["spec"]
	var next_deadline := next_tick + spec.period
	entry["next_tick"] = next_deadline if next_deadline > next_tick else INF
	_execute_periodic(spec, entry["handle"])


func _execute_periodic(spec: GameplayEffectSpec, handle: int) -> void:
	if not is_instance_valid(_attributes) or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return
	_mutation_depth += 1
	if spec.settings.is_damage_effect():
		var damage := _calculate_damage(spec)
		if not damage.is_empty() and is_finite(float(damage.get("magnitude", 0.0))):
			var event := spec.context.create_combat_event(&"damage", _attributes, spec.settings)
			_apply_damage(spec, event, damage, handle)
	else:
		_queue_cue(GameplayCueRouter.Event.EXECUTED, spec, handle)
	if _entries.has(handle):
		_execute_modifiers(spec, handle)
	_mutation_depth -= 1
	_publish_notifications()


func _execute_modifiers(spec: GameplayEffectSpec, handle: int = 0) -> void:
	if not is_instance_valid(_attributes) or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return
	var outputs: Array[AttributeModifier] = []
	outputs.append_array(spec.modifiers)
	for execution in spec.executions:
		if execution.is_damage_execution():
			continue
		outputs.append_array(execution.execute(spec, _attributes, _tags))
		if not is_instance_valid(_attributes) or (handle > 0 and not _entries.has(handle)):
			return
	if outputs.is_empty():
		return
	var context_tags := spec.settings.get_context_tags(spec.context.ability_tags)
	var values: Dictionary[int, float] = {}
	for output in outputs:
		if not GameplayEffectDefinition.is_valid_modifier(output, true) or not output.matches_context(context_tags):
			continue
		var modifier := _resolve_caller_modifier(output, spec)
		var amount := modifier.get_magnitude(_attributes, context_tags)
		var id := modifier.attribute
		var base: float = values[id] if values.has(id) else _attributes.get_numeric_base_value(id)
		var value := _modified_base(base, modifier.operation, amount)
		if is_finite(value):
			values[id] = value
	_attributes.apply_numeric_base_values(values)


static func _resolve_caller_modifier(modifier: AttributeModifier, spec: GameplayEffectSpec) -> AttributeModifier:
	var result := modifier.copy()
	result.stack_count = spec.stack_count
	if not result.set_by_caller_tag.is_empty():
		result.value = spec.get_set_by_caller_magnitude(result.set_by_caller_tag, result.value)
		result.set_by_caller_tag = &""
	return result


static func _modified_base(base: float, operation: AttributeModifier.Operation, amount: float) -> float:
	match operation:
		AttributeModifier.Operation.ADD:
			return base + amount
		AttributeModifier.Operation.ADD_PERCENT, AttributeModifier.Operation.MORE_PERCENT:
			return base * maxf(0.0, 1.0 + amount / 100.0)
		AttributeModifier.Operation.SET_BASE:
			return amount
	return base


func _calculate_damage(spec: GameplayEffectSpec) -> Dictionary:
	var calculation := _fallback_damage_execution as GameplayEffectExecution
	for execution in spec.executions:
		if execution.is_damage_execution():
			calculation = execution
			break
	var result := calculation.calculate_damage(spec, _attributes)
	if not result.is_empty() and spec.stack_count > 1:
		for field in ["magnitude", "raw_magnitude", "critical_magnitude"]:
			result[field] = float(result.get(field, 0.0)) * spec.stack_count
	return result


func _apply_damage(spec: GameplayEffectSpec, event: Dictionary, result: Dictionary, handle: int = 0) -> void:
	var damage_event := event.duplicate(true)
	damage_event["type"] = &"damage"
	damage_event["is_periodic"] = handle > 0
	damage_event["stack_count"] = spec.stack_count
	for field in ["raw_magnitude", "critical_magnitude", "armor", "effective_armor",
			"armor_penetration_percent", "armor_reduction", "resistance_attribute",
			"resistance_percent", "effective_resistance_percent", "spell_penetration",
			"resistance_multiplier"]:
		if result.has(field):
			damage_event[field] = result[field]
	_notifications.append({"event": damage_event, "definition": spec.definition})
	# Queue execution before damage callbacks can remove the effect. Publication sees the actual loss.
	_queue_cue(GameplayCueRouter.Event.EXECUTED, spec, handle, damage_event)
	var magnitude := maxf(0.0, float(result.get("magnitude", 0.0)))
	var applied := _attributes.apply_damage(magnitude)
	var actual := float(applied["health_damage"])
	damage_event["amount"] = actual
	damage_event["resolved_amount"] = magnitude
	damage_event["health_damage"] = actual


func _sync_cues(entry: Dictionary, removing: bool = false) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	if spec.settings.gameplay_cue_tags.is_empty():
		return
	var active: bool = not removing and entry["complete"] and not entry["inhibited"]
	if active == entry["cue_active"]:
		return
	entry["cue_active"] = active
	if active:
		_queue_cue(GameplayCueRouter.Event.ACTIVE, spec, entry["handle"])
		_queue_cue(GameplayCueRouter.Event.WHILE_ACTIVE, spec, entry["handle"])
	else:
		_queue_cue(GameplayCueRouter.Event.REMOVED, spec, entry["handle"])


func _queue_cue(
		event: GameplayCueRouter.Event, spec: GameplayEffectSpec, handle: int, details: Dictionary = {}
) -> void:
	if spec.settings.gameplay_cue_tags.is_empty():
		return
	var parameters := details if not details.is_empty() else {}
	parameters["stack_count"] = spec.stack_count
	_notifications.append({"cue_event": event, "spec": spec, "handle": handle,
			"details": parameters, "clearing": _clearing})


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
		var was_clearing := _clearing
		_clearing = _clearing or bool(notification.get("clearing", false))
		if notification.has("cue_event"):
			cues.dispatch_effect(notification["cue_event"], notification["spec"], _attributes,
					notification["handle"], notification["details"])
		else:
			var event: Dictionary = notification["event"]
			var definition: GameplayEffectDefinition = notification["definition"]
			combat_event.emit(event.duplicate(true))
			match StringName(event["type"]):
				&"effect_applied":
					effect_applied.emit(definition)
				&"effect_removed":
					effect_removed.emit(definition)
				&"effect_stack_changed":
					effect_stack_changed.emit(int(event["handle"]), int(event["previous_stack_count"]),
							int(event["stack_count"]))
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
