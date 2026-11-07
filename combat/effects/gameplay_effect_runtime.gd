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

## Committed reason reported when a retained effect loses its handle.
enum RemovalReason {
	## Explicit removal by a caller or the effect's owning ability.
	MANUAL,
	## The effect reached its natural duration deadline.
	EXPIRED,
	## A valid dispeller removed the effect through the dispel path.
	DISPELLED,
	## Actor death released the affected ownership.
	DEATH,
	## Scene teardown released the handle.
	SCENE_UNLOAD,
	## A successful exclusive application replaced this occupant.
	REPLACED,
	## A finite budget or charge ran out, or a threshold behavior finished.
	DEPLETED,
	## A transfer installed the allowed state on another target.
	TRANSFERRED,
	## A qualifying committed hit or damage transaction broke the effect.
	BROKEN,
	## An external restore discarded effect state that exists only in this session.
	SAVE_INVALIDATED,
}

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
var _exclusive_slots: Dictionary[StringName, Dictionary] = {}
var _outcome_subscription: int = 0


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
	return _is_eligible_spec(spec) and _passes_application_filters(spec)


## Checks structural hit eligibility before the caller samples its weapon or Accuracy stream.
func has_hit_candidate(specs: Array[GameplayEffectSpec]) -> bool:
	for spec in specs:
		if _is_eligible_spec(spec):
			return true
	return false


func _is_eligible_spec(spec: GameplayEffectSpec) -> bool:
	return spec != null and spec.definition != null and spec.context != null and spec.stack_count > 0 \
			and spec.stack_count <= MAX_STACK_COUNT and is_finite(spec.level) and spec.level > 0.0 \
			and can_apply_effect(spec.settings)


func _passes_application_filters(spec: GameplayEffectSpec) -> bool:
	var profile := spec.settings.get_status_profile()
	if profile != null and not _meets_tags(PackedStringArray(), profile.immunity_tags):
		return false
	for filter in _application_filters:
		if filter.is_valid() and not filter.call(spec):
			return false
	return true


func _resolve_status(spec: GameplayEffectSpec) -> StringName:
	var profile := spec.settings.get_status_profile()
	if profile == null:
		return &""
	var resistance := profile.get_resistance_fraction(_attributes,
			spec.settings.get_context_tags(spec.context.ability_tags))
	var chance := profile.chance
	match profile.resistance_effect:
		StatusProfile.ResistanceEffect.CHANCE:
			chance *= 1.0 - resistance
		StatusProfile.ResistanceEffect.DURATION:
			spec.duration_scale = 1.0 - resistance
			if spec.duration <= 0.0:
				return &"resisted"
		StatusProfile.ResistanceEffect.MAGNITUDE:
			spec.modifier_scale = 1.0 - resistance
			if spec.modifier_scale <= 0.0:
				return &"resisted"
	return &"" if roll_application_chance(chance) else &"resisted"


func _notify_rejection(spec: GameplayEffectSpec, outcome: StringName) -> void:
	var event := spec.context.create_combat_event(&"effect_rejected", _attributes, spec.settings)
	event["outcome"] = outcome
	var profile := spec.settings.get_status_profile()
	if profile != null:
		event["status_category"] = profile.category
	_queue_outcome(event, spec)
	_publish_notifications()


func _notify_status_application(spec: GameplayEffectSpec, handle: int) -> void:
	var profile := spec.settings.get_status_profile()
	if profile == null:
		return
	var event := spec.context.create_combat_event(&"status_applied", _attributes, spec.settings)
	event["outcome"] = &"applied"
	event["status_category"] = profile.category
	event["handle"] = handle
	event["duration"] = get_remaining(handle)
	event["magnitude_scale"] = spec.modifier_scale
	_queue_outcome(event, spec)


## Returns a unique positive handle on acceptance, or zero on rejection.
## Instant effects complete immediately. Only retained handles remain removable.
func apply_effect(definition: GameplayEffectDefinition, context: GameplayEffectContext) -> int:
	return apply_effect_spec(make_effect_spec(definition, context))


func apply_effect_spec(outgoing_spec: GameplayEffectSpec, damage_summary: Dictionary = {}) -> int:
	if not _is_eligible_spec(outgoing_spec) or _component_applications.has(outgoing_spec.definition):
		return 0
	var spec := outgoing_spec.copy_for_application()
	var definition := spec.settings
	if not definition.get_exclusive_owner_slot().is_empty() and _get_slot_owner(spec) == null:
		_notify_rejection(spec, &"missing_slot_owner")
		return 0
	if not _passes_application_filters(spec) or _has_damage_immunity(spec):
		_notify_rejection(spec, &"immune")
		return 0
	var status_failure := _resolve_status(spec)
	if not status_failure.is_empty():
		_notify_rejection(spec, status_failure)
		return 0
	for component in definition.components:
		if not component.can_apply(self, spec):
			return 0
	if spec.period > 0.0 and definition.snapshot_source:
		spec.context = spec.context.with_snapshotted_source(definition.get_context_tags(
				spec.context.ability_tags))
	GameplayEffectDamageExecution.capture_amount_inputs(spec, _attributes)
	_mutation_depth += 1
	var stack := _find_stack(spec)
	if not stack.is_empty():
		return _finish_application(_apply_stack(stack, spec))
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or definition.stacking_type == GameplayEffectDefinition.StackingType.INDEPENDENT:
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
		_queue_outcome(event, spec)
		if not damage.is_empty():
			var applied := _apply_damage(spec, event, damage, 0, damage_summary)
			if not damage_summary.is_empty():
				for field in ["health_damage", "blocked_amount", "absorbed_amount"]:
					damage_summary[field] = float(damage_summary[field]) + float(applied[field])
		else:
			_queue_cue(GameplayCueRouter.Event.EXECUTED, spec, 0)
		_execute_modifiers(spec)
		_dispatch_application_components(spec)
		return _finish_application(handle)
	var entry := _make_retained_entry(spec, handle, event)
	_entries[handle] = entry
	_refresh_entry(entry)
	if not _entries.has(handle):
		return _finish_application(0)
	if not is_instance_valid(_attributes):
		remove_effect(handle)
		return _finish_application(0)
	_commit_retained_entry(entry, spec)
	if spec.period > 0.0 and definition.execute_periodic_on_application and not entry["inhibited"]:
		_execute_periodic(spec, handle)
	_dispatch_application_components(spec)
	return _finish_application(handle)


func _make_retained_entry(spec: GameplayEffectSpec, handle: int, event: Dictionary) -> Dictionary:
	var definition := spec.settings
	return {
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
		"behavior_states": _create_behavior_states(spec),
		"complete": false,
		"inhibited": true,
		"cue_active": false,
		"updating": false,
		"refresh_pending": false,
		"event": event,
	}


func _commit_retained_entry(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	entry["complete"] = true
	_update_outcome_subscription()
	_retained_effects_dirty = true
	_queue_outcome(entry["event"], spec)
	_notify_status_application(spec, entry["handle"])
	_install_exclusive_slot(entry)
	_sync_cues(entry)


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
		accuracy_roll: float = -1.0, critical_roll: float = -1.0, confirmed: bool = false
) -> Dictionary:
	var result := {"outcome": &"invalid", "applied_effects": 0, "hit_chance": 0.0,
			"is_critical": false, "critical_multiplier": 1.0, "critical_damage_percent": 0.0,
			"critical_chance": 0.0, "health_damage": 0.0, "blocked_amount": 0.0, "absorbed_amount": 0.0}
	if context == null or not is_instance_valid(_attributes) or not is_finite(accuracy_roll) \
			or not is_finite(critical_roll):
		return result
	var eligible: Array[GameplayEffectSpec] = []
	for spec in specs:
		if _is_eligible_spec(spec):
			var delivered := spec.copy_for_execution()
			delivered.context = context
			eligible.append(delivered)
	if eligible.is_empty():
		return result
	var self_delivery := context.source_id == _attributes.get_instance_id()
	var beneficial := AttributeModifier._has_match(context.ability_tags, "Ability.Beneficial")
	var requires_accuracy := _contains_damage(eligible) or (not self_delivery and not beneficial)
	var chance := 1.0
	if requires_accuracy and not confirmed:
		var accuracy := context.get_source_value(CombatAttributes.Id.ACCURACY_RATING,
				context.ability_tags)
		chance = CombatMath.get_hit_chance(context.source_level, _attributes.level, accuracy)
		var roll := clampf(accuracy_roll, 0.0, 1.0) if accuracy_roll >= 0.0 else randf()
		if chance <= 0.0 or (chance < 1.0 and roll >= chance):
			result["outcome"] = &"resist" if GameplayEffectContext.is_spell_delivery(
					context.ability_tags) else &"miss"
			result["hit_chance"] = chance
			return result
	var prevention := _get_contact_prevention(eligible, context)
	if not prevention.is_empty():
		eligible = _prevent_contact_payload(eligible, context, prevention, result, critical_roll)
		if eligible.is_empty():
			result["outcome"] = result["prevention"]
			result["hit_chance"] = chance
			return result
	var immune := true
	for spec in eligible:
		if _passes_application_filters(spec) and not _has_damage_immunity(spec):
			immune = false
			break
	if immune:
		for spec in eligible:
			_notify_rejection(spec, &"immune")
		result["outcome"] = &"immune"
		result["hit_chance"] = chance
		return result
	var critical := false
	var critical_bonus := 0.0
	var critical_multiplier := 1.0
	var critical_chance := 0.0
	if _contains_damage(eligible):
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
	_mutation_depth += 1
	for outgoing_spec in eligible:
		var spec := outgoing_spec.copy_for_execution()
		spec.context = hit_context
		if apply_effect_spec(spec, result) > 0:
			applied += 1
	result["outcome"] = &"hit"
	result["hit_chance"] = chance
	result["applied_effects"] = applied
	result["is_critical"] = critical
	result["critical_multiplier"] = critical_multiplier
	result["critical_damage_percent"] = critical_bonus
	result["critical_chance"] = critical_chance
	_mutation_depth -= 1
	_publish_notifications()
	return result


static func _contains_damage(specs: Array[GameplayEffectSpec]) -> bool:
	for spec in specs:
		if spec.settings.is_damage_effect():
			return true
	return false


func _prevent_contact_payload(
		specs: Array[GameplayEffectSpec], context: GameplayEffectContext,
		prevention: Dictionary, result: Dictionary, critical_roll: float
) -> Array[GameplayEffectSpec]:
	var defense: DamageDefenseEffectComponent = prevention["component"]
	var state: Dictionary = prevention["state"]
	var reflecting := defense.mode == DamageDefenseEffectComponent.Mode.REFLECT
	var prevented: Array[GameplayEffectSpec] = []
	var remaining: Array[GameplayEffectSpec] = []
	for spec in specs:
		if _defense_applies(defense, spec) or (not spec.settings.is_damage_effect() \
				and (not reflecting or defense.reflect_attached_statuses)):
			prevented.append(spec)
		else:
			remaining.append(spec)
	result["prevention"] = &"reflected" if reflecting else &"deflected"
	result["prevented_effects"] = prevented.size()
	if defense.get_contact_uses() > 0:
		state["uses"] -= 1
	if reflecting:
		var source := context.get_source_system()
		var reflected := context.with_critical_result(false)
		reflected.has_hit_result = false
		if reflected.outcome_context != null:
			reflected.outcome_context = reflected.outcome_context.with_provenance(
					CombatOutcomeContext.Provenance.REFLECTED).with_role(
					CombatOutcomeContext.Role.CREDITED_OWNER, _attributes).for_contact(source.attributes)
		var redirected := source.effects.apply_hit_specs(prevented, reflected, 0.0, critical_roll, true)
		if is_instance_valid(source) and redirected["outcome"] != &"invalid":
			source.publish_hit_outcome(reflected, redirected)
	if defense.get_contact_uses() > 0 and state["uses"] <= 0:
		remove_effect(prevention["handle"], -1, RemovalReason.DEPLETED)
	return remaining


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
func remove_effect(
		handle: int, stacks: int = -1, reason: RemovalReason = RemovalReason.MANUAL,
		dispeller_id: int = 0
) -> bool:
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
	_update_outcome_subscription()
	_release_exclusive_slot(entry)
	if entry["complete"]:
		_retained_effects_dirty = true
		var event: Dictionary = entry["event"].duplicate(true)
		event["type"] = &"effect_removed"
		event["handle"] = handle
		event["stack_count"] = spec.stack_count
		event["removal_reason"] = reason
		event["dispeller_id"] = dispeller_id if reason == RemovalReason.DISPELLED else 0
		_queue_outcome(event, spec)
	_sync_cues(entry, true)
	_release_contributions(entry)
	if entry["complete"]:
		_finish_behavior_removal(entry, reason)
	_mutation_depth -= 1
	_publish_notifications()
	return true


## Clears all retained ownership; applications during cleanup are rejected.
func clear(preserve: Array[int] = [], reason: RemovalReason = RemovalReason.MANUAL) -> void:
	if _clearing:
		return
	_clearing = true
	_mutation_depth += 1
	var handles := _entries.keys()
	for handle: int in handles:
		if not preserve.has(handle):
			remove_effect(handle, -1, reason)
	for handle: int in preserve:
		if _entries.has(handle):
			_refresh_entry(_entries[handle])
	if reason in [RemovalReason.DEATH, RemovalReason.SCENE_UNLOAD, RemovalReason.SAVE_INVALIDATED]:
		for slot_name: StringName in _exclusive_slots.keys():
			if not _exclusive_slots.has(slot_name):
				continue
			var slot: Dictionary = _exclusive_slots[slot_name]
			var reference: WeakRef = slot["runtime"]
			var runtime := reference.get_ref() as GameplayEffectRuntime
			if runtime == self and preserve.has(slot["handle"]):
				continue
			if runtime != null:
				runtime.remove_effect(slot["handle"], -1, reason)
			_exclusive_slots.erase(slot_name)
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


## Removes an effect with explicit dispel attribution for removal reactions.
func dispel_effect(handle: int, dispeller: AbilitySystem) -> bool:
	if not is_instance_valid(dispeller) or not is_instance_valid(dispeller.attributes):
		return false
	return remove_effect(handle, -1, RemovalReason.DISPELLED, dispeller.attributes.get_instance_id())


## Restores one matching manually restorable snapshot. Zero means no matching handle; -1 is invalid.
func restore_snapshot(effect_id: StringName) -> int:
	if effect_id.is_empty() or _clearing or not is_instance_valid(_attributes) \
			or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return -1
	for entry: Dictionary in _entries.values():
		if not entry["complete"] or entry["effect_id"] != effect_id:
			continue
		var spec: GameplayEffectSpec = entry["spec"]
		for index: int in entry["behavior_states"]:
			var component := spec.settings.components[index] as SelectiveResourceSnapshotEffectComponent
			if component == null or not component.restore_on_manual_removal:
				continue
			if entry["inhibited"] or not _can_restore_snapshot(component, entry["behavior_states"][index]):
				return -1
			return 1 if remove_effect(entry["handle"]) else -1
	return 0


## Returns the destination handle on a successful state-preserving transfer.
func transfer_effect(
		handle: int, destination: GameplayEffectRuntime, duration_cap: float = INF,
		stack_cap: int = MAX_STACK_COUNT
) -> int:
	if destination == null or destination == self or not has_retained_effect(handle) \
			or _clearing or is_nan(duration_cap) or duration_cap <= 0.0 or stack_cap <= 0:
		return 0
	var original: Dictionary = _entries[handle]
	var spec: GameplayEffectSpec = original["spec"]
	if not _can_transfer(original, destination, spec):
		return 0
	var transferred := spec.copy_for_execution()
	transferred.stack_count = mini(transferred.stack_count, stack_cap)
	if transferred.context.outcome_context != null:
		transferred.context.outcome_context = transferred.context.outcome_context.with_provenance(
				CombatOutcomeContext.Provenance.TRANSFERRED).with_role(
				CombatOutcomeContext.Role.TARGET, destination._attributes)
	var remaining := minf(get_remaining(handle), duration_cap)
	if remaining <= 0.0:
		return 0
	var destination_handle := destination._next_handle
	destination._next_handle += 1
	var event := transferred.context.create_combat_event(
			&"effect_transferred", destination._attributes, transferred.settings)
	event["handle"] = destination_handle
	event["previous_handle"] = handle
	event["previous_target_id"] = _attributes.get_instance_id()
	event["stack_count"] = transferred.stack_count
	var entry := destination._make_retained_entry(transferred, destination_handle, event)
	entry["expires_at"] = destination._clock + remaining
	entry["next_tick"] = destination._clock + maxf(0.0, float(original["next_tick"]) - _clock)
	entry["behavior_states"] = original["behavior_states"].duplicate(true)
	original["transferring"] = true
	_mutation_depth += 1
	destination._mutation_depth += 1
	CombatOutcomeDispatcher.begin_batch()
	destination._entries[destination_handle] = entry
	destination._refresh_entry(entry)
	if destination._entries.has(destination_handle) and has_retained_effect(handle) \
			and is_instance_valid(destination._attributes):
		destination._commit_retained_entry(entry, transferred)
		remove_effect(handle, -1, RemovalReason.TRANSFERRED)
	else:
		destination.remove_effect(destination_handle)
		destination_handle = 0
	original.erase("transferring")
	_mutation_depth -= 1
	destination._mutation_depth -= 1
	_publish_notifications()
	destination._publish_notifications()
	CombatOutcomeDispatcher.end_batch()
	return destination_handle


func _can_transfer(entry: Dictionary, destination: GameplayEffectRuntime, spec: GameplayEffectSpec) -> bool:
	if not spec.settings.is_transferable() or entry["inhibited"] or entry.get("transferring", false) \
			or not is_instance_valid(_attributes) or not destination.can_apply_spec(spec) \
			or destination._has_damage_immunity(spec) or not destination._find_stack(spec).is_empty() \
			or not destination._meets_tags(spec.settings.ongoing_required_target_tags,
					spec.settings.ongoing_blocked_target_tags):
		return false
	for component in spec.settings.components:
		if component is not DamageDefenseEffectComponent and component is not HealingReceivedEffectComponent \
				and component is not HealingAbsorptionEffectComponent:
			return false
	return true


## Returns detached inspection data without exposing mutable instance records.
func get_active_effects() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in _entries.values():
		var behaviors: Dictionary = entry["behavior_states"].duplicate(true)
		for state: Dictionary in behaviors.values():
			state.erase("paid_attacks")
		result.append({"handle": entry["handle"], "effect_id": entry["effect_id"],
				"remaining": get_remaining(entry["handle"]), "inhibited": entry["inhibited"],
				"stack_count": get_stack_count(entry["handle"]),
				"behaviors": behaviors})
	return result


## Explicitly invalidates session-owned effects when an external save loader replaces actor state.
## Callers can preserve actor-initialization handles that were reconstructed by the scene.
func invalidate_session_effects_for_restore(preserve: Array[int] = []) -> Array[Dictionary]:
	var invalidated: Array[Dictionary] = []
	for entry in get_active_effects():
		if not preserve.has(entry["handle"]):
			entry["reason"] = &"session_only_effect"
			invalidated.append(entry)
	clear(preserve, RemovalReason.SAVE_INVALIDATED)
	return invalidated


func get_remaining(handle: int) -> float:
	return maxf(0.0, float(_entries[handle]["expires_at"]) - _clock) if _entries.has(handle) else 0.0


func get_stack_count(handle: int) -> int:
	return _entries[handle]["spec"].stack_count if _entries.has(handle) else 0


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
	if spec.settings.timing == GameplayEffectDefinition.Timing.INSTANT \
			or stacking_type == GameplayEffectDefinition.StackingType.INDEPENDENT:
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
	_refresh_behavior_states(entry, spec)
	_queue_outcome(event, spec)
	_notify_status_application(spec, handle)
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
		remove_effect(handle, -1, RemovalReason.EXPIRED)
		return
	var deadline := _clock + spec.duration
	if deadline <= _clock:
		remove_effect(handle, -1, RemovalReason.EXPIRED)
		return
	entry["expires_at"] = deadline
	if policy == GameplayEffectDefinition.StackExpirationPolicy.REMOVE_ONE_AND_REFRESH:
		remove_effect(handle, 1, RemovalReason.EXPIRED)
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
	if not spec.settings.tick_at_end and next_tick >= float(entry["expires_at"]) - CLOCK_EPSILON:
		return
	_execute_periodic(spec, entry["handle"])


func _execute_periodic(retained: GameplayEffectSpec, handle: int) -> void:
	if not is_instance_valid(_attributes) or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return
	_mutation_depth += 1
	var spec := retained.copy_for_execution()
	if spec.context.outcome_context != null:
		spec.context.outcome_context = spec.context.outcome_context.with_timing(
				CombatOutcomeContext.Timing.PERIODIC)
	if spec.settings.is_damage_effect():
		var damage := _calculate_damage(spec)
		if not damage.is_empty() and is_finite(float(damage.get("magnitude", 0.0))):
			_apply_tick_ramp(damage, handle)
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
	if result.supports_dynamic_value() and not result.set_by_caller_tag.is_empty():
		result.value = spec.get_set_by_caller_magnitude(result.set_by_caller_tag, result.value)
		result.set_by_caller_tag = &""
	result.value *= spec.modifier_scale
	result.capture_coefficient *= spec.modifier_scale
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
	var execution := spec.settings.get_damage_execution()
	if execution == null:
		return {}
	var result := execution.calculate_damage(spec, _attributes)
	var stack_curve := execution.amount != null and execution.amount.source == AmountDefinition.Source.STACK_PROGRESSION
	if not result.is_empty() and spec.stack_count > 1 and not stack_curve:
		for field in ["magnitude", "raw_magnitude", "critical_magnitude"]:
			result[field] = float(result.get(field, 0.0)) * spec.stack_count
	return result


## Applies active incoming-healing modifiers before ordinary healing clamps to capacity.
func resolve_healing_received(amount: float) -> float:
	for entry: Dictionary in _entries.values():
		if not entry["complete"] or entry["inhibited"]:
			continue
		var spec: GameplayEffectSpec = entry["spec"]
		for component in spec.settings.components:
			if component is HealingReceivedEffectComponent:
				amount *= pow(component.multiplier, spec.stack_count)
	return amount


## Spends healing absorption in priority order. The caller releases depleted handles after commit.
func apply_healing_absorption(amount: float, depleted: Array[int]) -> float:
	if amount <= 0.0 or not is_finite(amount):
		return amount
	var pools: Array[Dictionary] = []
	for entry: Dictionary in _entries.values():
		if not entry["complete"] or entry["inhibited"]:
			continue
		var spec: GameplayEffectSpec = entry["spec"]
		for index in spec.settings.components.size():
			var component := spec.settings.components[index] as HealingAbsorptionEffectComponent
			if component != null:
				pools.append({
					"priority": component.priority,
					"handle": entry["handle"],
					"index": index,
					"state": entry["behavior_states"][index],
					"remove": component.remove_when_depleted,
				})
	pools.sort_custom(_prioritized_component_precedes)
	for pool in pools:
		var state: Dictionary = pool["state"]
		var absorbed := minf(amount, state["remaining"])
		state["remaining"] -= absorbed
		amount -= absorbed
		if absorbed > 0.0 and state["remaining"] <= 0.0 and pool["remove"]:
			depleted.append(pool["handle"])
		if amount <= 0.0:
			break
	return amount


func finish_healing_absorption(depleted: Array[int]) -> void:
	for handle in depleted:
		remove_effect(handle, -1, RemovalReason.DEPLETED)


func _create_behavior_states(spec: GameplayEffectSpec) -> Dictionary[int, Dictionary]:
	var states: Dictionary[int, Dictionary] = {}
	for index in spec.settings.components.size():
		var component := spec.settings.components[index]
		if component is DamageDefenseEffectComponent:
			if component.mode == DamageDefenseEffectComponent.Mode.ABSORB:
				states[index] = {"remaining": component.capacity}
			elif component.get_contact_uses() > 0:
				states[index] = {"uses": component.get_contact_uses()}
		elif component is HealingAbsorptionEffectComponent:
			states[index] = {"remaining": component.capacity}
		elif component is PeriodicRampEffectComponent:
			states[index] = {"ticks": 0}
		elif component is DamageAccumulatorEffectComponent:
			states[index] = {"total": 0.0, "contributions": 0, "fired": false}
		elif component is SelectiveResourceSnapshotEffectComponent:
			var values: Dictionary[int, float] = {}
			for pool in component.pools:
				values[pool] = _attributes.get_value(AmountDefinition.pool_attribute(pool))
			var snapshot := {"pools": values}
			if component.restore_transform:
				var body := SelectiveResourceSnapshotEffectComponent.get_snapshot_body(self)
				if body != null:
					snapshot["transform"] = body.global_transform
					snapshot["body_id"] = body.get_instance_id()
					snapshot["world_id"] = body.get_world_3d().get_instance_id()
			states[index] = snapshot
		elif component is DamageRoutingEffectComponent:
			states[index] = {"remaining": component.capacity if component.capacity > 0.0 else INF}
		elif component is ObserveOutcomeEffectComponent:
			states[index] = component.create_state()
	return states


func _refresh_behavior_states(entry: Dictionary, spec: GameplayEffectSpec) -> void:
	for index: int in entry["behavior_states"]:
		var component := spec.settings.components[index]
		var state: Dictionary = entry["behavior_states"][index]
		if component is DamageDefenseEffectComponent \
				and component.mode == DamageDefenseEffectComponent.Mode.ABSORB \
				and component.recast_capacity > 0.0:
			state["remaining"] = minf(component.recast_capacity, state["remaining"] + component.capacity)
		elif component is PeriodicRampEffectComponent and component.reset_on_reapply:
			state["ticks"] = 0
		elif component is ObserveOutcomeEffectComponent:
			component.refresh_state(state)


func _apply_tick_ramp(damage: Dictionary, handle: int) -> void:
	if not _entries.has(handle):
		return
	var entry: Dictionary = _entries[handle]
	var spec: GameplayEffectSpec = entry["spec"]
	for index: int in entry["behavior_states"]:
		var component := spec.settings.components[index] as PeriodicRampEffectComponent
		if component == null:
			continue
		var state: Dictionary = entry["behavior_states"][index]
		var ticks: int = state["ticks"]
		var multiplier := minf(component.maximum_multiplier,
				component.initial_multiplier + ticks * component.multiplier_per_tick)
		state["ticks"] = ticks + 1
		for field in ["magnitude", "raw_magnitude", "critical_magnitude"]:
			damage[field] = float(damage.get(field, 0.0)) * multiplier


func _update_outcome_subscription() -> void:
	for entry: Dictionary in _entries.values():
		var spec: GameplayEffectSpec = entry["spec"]
		for component in spec.settings.components:
			if component is BreakOnDamageEffectComponent or component is DamageAccumulatorEffectComponent \
					or component is ObserveOutcomeEffectComponent:
				if _outcome_subscription == 0:
					_outcome_subscription = CombatOutcomeDispatcher.subscribe(self, _on_owned_outcome)
				return
	if _outcome_subscription > 0:
		CombatOutcomeDispatcher.unsubscribe(_outcome_subscription)
		_outcome_subscription = 0


func _on_owned_outcome(outcome: CombatOutcome) -> void:
	if not is_instance_valid(_attributes):
		return
	var actor_id := _attributes.get_instance_id()
	var targets_actor := outcome.target_id == actor_id
	var credited_actor := outcome.context.actor_id(CombatOutcomeContext.Role.CREDITED_OWNER) == actor_id
	if not targets_actor and not credited_actor:
		return
	for handle: int in _entries.keys():
		if not _entries.has(handle):
			continue
		var entry: Dictionary = _entries[handle]
		if not entry["complete"] or entry["inhibited"]:
			continue
		var spec: GameplayEffectSpec = entry["spec"]
		for index in spec.settings.components.size():
			var component := spec.settings.components[index]
			if component is ObserveOutcomeEffectComponent:
				_queue_owned_reactions(component, entry, index, outcome, targets_actor, credited_actor)
			elif targets_actor and component is BreakOnDamageEffectComponent \
					and _matches_damage_break(component, spec, outcome):
				remove_effect(handle, -1, RemovalReason.BROKEN)
			elif targets_actor and component is DamageAccumulatorEffectComponent \
					and outcome.kind == CombatOutcome.Kind.DAMAGE:
				_accumulate_damage(entry, index, component, outcome)
			if not _entries.has(handle):
				break


func _queue_owned_reactions(
		component: ObserveOutcomeEffectComponent, entry: Dictionary, index: int,
		outcome: CombatOutcome, targets_actor: bool, credited_actor: bool
) -> void:
	var matches := targets_actor if component.scope == ObserveOutcomeEffectComponent.Scope.TARGET \
			else credited_actor
	if not matches:
		return
	var runtime_ref: WeakRef = weakref(self)
	var handle: int = entry["handle"]
	var active := func() -> bool:
		var owner := runtime_ref.get_ref() as GameplayEffectRuntime
		return owner != null and owner.has_retained_effect(handle) and not owner.is_effect_inhibited(handle)
	var state: Dictionary = entry["behavior_states"][index]
	CombatOutcomeDispatcher.enqueue_scoped(outcome, component.reactions,
			state["attachment_id"], active, component.claim_attack.bind(state))


func _capture_depleted_hit_observers(handle: int, hit_result: Dictionary) -> void:
	if hit_result.is_empty() or not _entries.has(handle):
		return
	var entry: Dictionary = _entries[handle]
	var spec: GameplayEffectSpec = entry["spec"]
	for index in spec.settings.components.size():
		var component := spec.settings.components[index] as ObserveOutcomeEffectComponent
		if component == null or component.scope != ObserveOutcomeEffectComponent.Scope.TARGET:
			continue
		var snapshots: Array = hit_result.get_or_add("_depleted_hit_observers", [])
		snapshots.append({"component": component, "state": entry["behavior_states"][index]})


## Completes observer attachments captured when an absorbing contact depleted their owner.
func dispatch_depleted_hit_observers(outcome: CombatOutcome, snapshots: Array) -> void:
	if not outcome.is_confirmed_hit():
		return
	for snapshot: Dictionary in snapshots:
		var component: ObserveOutcomeEffectComponent = snapshot["component"]
		var state: Dictionary = snapshot["state"]
		var claim := func(contact: CombatOutcome) -> bool:
			return component.claim_attack(contact, state)
		CombatOutcomeDispatcher.enqueue_scoped(outcome, component.reactions, state["attachment_id"],
				Callable(), claim)


static func _matches_damage_break(
		component: BreakOnDamageEffectComponent, spec: GameplayEffectSpec, outcome: CombatOutcome
) -> bool:
	if component.exclude_status_source and spec.context.source_id == outcome.source_id:
		return false
	var ability_tags: PackedStringArray = outcome.get_event().get("ability_tags", PackedStringArray())
	for query in component.excluded_ability_tags:
		if AttributeModifier._has_match(ability_tags, query):
			return false
	match component.predicate:
		BreakOnDamageEffectComponent.Predicate.HEALTH_DAMAGE:
			return outcome.kind == CombatOutcome.Kind.DAMAGE and outcome.get_amount(&"health_damage") > 0.0
		BreakOnDamageEffectComponent.Predicate.ANY_DAMAGE_TRANSACTION:
			return outcome.kind == CombatOutcome.Kind.DAMAGE and outcome.get_event().get("outcome") != &"immune"
		BreakOnDamageEffectComponent.Predicate.CONFIRMED_HIT:
			return outcome.is_confirmed_hit()
	return false


func _accumulate_damage(
		entry: Dictionary, index: int, component: DamageAccumulatorEffectComponent, outcome: CombatOutcome
) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	var state: Dictionary = entry["behavior_states"][index]
	if state["fired"] or (component.contribution_limit > 0 \
			and int(state["contributions"]) >= component.contribution_limit):
		return
	if component.source_scope == DamageAccumulatorEffectComponent.SourceScope.APPLYING_SOURCE \
			and spec.context.source_id != outcome.source_id:
		return
	var derived_flags := CombatOutcomeContext.Provenance.COPIED | CombatOutcomeContext.Provenance.REFLECTED \
			| CombatOutcomeContext.Provenance.TRANSFERRED | CombatOutcomeContext.Provenance.RETALIATION
	if not component.allow_derived_damage and (outcome.context.provenance & derived_flags) != 0:
		return
	var keys := [&"health_damage", &"resolved_amount", &"prevention_input"]
	var amount := outcome.get_amount(keys[component.amount_basis])
	if not is_finite(amount) or amount <= 0.0 or not is_finite(float(state["total"]) + amount):
		return
	state["total"] += amount
	state["contributions"] += 1
	if component.threshold > 0.0 and state["total"] >= component.threshold:
		_publish_accumulator(entry, state, outcome)
		if component.remove_on_threshold:
			remove_effect(entry["handle"], -1, RemovalReason.DEPLETED)
		_publish_notifications()


func _publish_accumulator(entry: Dictionary, state: Dictionary, cause: CombatOutcome = null) -> void:
	if state["fired"]:
		return
	state["fired"] = true
	var retained: GameplayEffectSpec = entry["spec"]
	var spec := retained.copy_for_execution()
	if cause != null and spec.context.outcome_context != null:
		spec.context.outcome_context = spec.context.outcome_context.for_child(cause, _attributes)
	var event := spec.context.create_combat_event(&"effect_threshold", _attributes, spec.settings)
	event["handle"] = entry["handle"]
	event["amount"] = state["total"]
	event["resolved_amount"] = state["total"]
	event["accumulator"] = state["total"]
	event["contributions"] = state["contributions"]
	_queue_outcome(event, spec)


func _finish_behavior_removal(entry: Dictionary, reason: RemovalReason) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	for index: int in entry["behavior_states"]:
		var component := spec.settings.components[index]
		if component is DamageAccumulatorEffectComponent \
				and component.publish_on_expiry and reason == RemovalReason.EXPIRED:
			_publish_accumulator(entry, entry["behavior_states"][index])
		elif component is SelectiveResourceSnapshotEffectComponent and (reason == RemovalReason.EXPIRED \
				or (reason == RemovalReason.MANUAL and component.restore_on_manual_removal and not _clearing)):
			_restore_resource_snapshot(entry, component, entry["behavior_states"][index])


func _restore_resource_snapshot(
		entry: Dictionary, component: SelectiveResourceSnapshotEffectComponent, state: Dictionary
) -> void:
	if not is_instance_valid(_attributes) or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0 \
			or not _can_restore_snapshot(component, state):
		return
	if component.restore_transform:
		var body := SelectiveResourceSnapshotEffectComponent.get_snapshot_body(self)
		body.global_transform = state["transform"]
		body.reset_physics_interpolation()
	var spec: GameplayEffectSpec = entry["spec"]
	for pool in component.pools:
		if not is_instance_valid(_attributes) or _attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
			return
		var attribute := AmountDefinition.pool_attribute(pool)
		var delta := float(state["pools"][pool]) - _attributes.get_value(attribute)
		if is_zero_approx(delta):
			continue
		if pool == AmountDefinition.Pool.HEALTH:
			var request := HealingRequest.new(_attributes, delta)
			request.mode = HealingRequest.Mode.SNAPSHOT_RESTORE
			request.snapshot_triggers_reactions = component.healing_reactions
			var result := HealingResolver.resolve_and_commit(request)
			if result.committed:
				_queue_outcome(result.get_event(), spec)
		else:
			var reason := ResourceRequest.Reason.DRAIN if delta < 0.0 else ResourceRequest.Reason.RESTORE
			var result := ResourceService.resolve_and_commit(ResourceRequest.new(_attributes, delta, pool, reason))
			if result.committed:
				_queue_outcome(result.get_event(), spec)


func _can_restore_snapshot(component: SelectiveResourceSnapshotEffectComponent, state: Dictionary) -> bool:
	if not component.restore_transform:
		return true
	var body := SelectiveResourceSnapshotEffectComponent.get_snapshot_body(self)
	if body == null or not state.has("transform") or body.get_instance_id() != state["body_id"] \
			or body.get_world_3d().get_instance_id() != state["world_id"]:
		return false
	var transform: Transform3D = state["transform"]
	var distance := component.maximum_restore_distance
	if not transform.is_finite() or (distance > 0.0 \
			and body.global_position.distance_squared_to(transform.origin) > distance * distance):
		return false
	# Test the body's current shapes at the candidate. The body's own RID is excluded by body_test_motion.
	return not body.test_move(transform, Vector3.ZERO, null, 0.0, true)


func _get_slot_owner(spec: GameplayEffectSpec) -> GameplayEffectRuntime:
	var source := spec.context.get_source_system()
	if is_instance_valid(source) and source.effects != null and not source.effects.is_clearing() \
			and is_instance_valid(source.attributes) and source.attributes.get_value(CombatAttributes.Id.HEALTH) > 0.0:
		return source.effects
	if is_instance_valid(_attributes) and spec.context.source_id == _attributes.get_instance_id():
		return self
	return null


## Resolves the live, uninhibited recipient of this source's named effect slot.
func get_exclusive_slot_target(slot: StringName) -> ActorAttributes:
	var record: Dictionary = _exclusive_slots.get(slot, {})
	if record.is_empty():
		return null
	var reference: WeakRef = record["runtime"]
	var runtime := reference.get_ref() as GameplayEffectRuntime
	if runtime == null or not runtime.has_retained_effect(record["handle"]) \
			or runtime.is_effect_inhibited(record["handle"]) or not is_instance_valid(runtime._attributes):
		return null
	return runtime._attributes


func _install_exclusive_slot(entry: Dictionary) -> void:
	var spec: GameplayEffectSpec = entry["spec"]
	var slot := spec.settings.get_exclusive_owner_slot()
	if slot.is_empty():
		return
	var owner := _get_slot_owner(spec)
	if owner == null:
		return
	var previous: Dictionary = owner._exclusive_slots.get(slot, {})
	owner._exclusive_slots[slot] = {"runtime": weakref(self), "handle": entry["handle"]}
	entry["slot_owner"] = weakref(owner)
	if not previous.is_empty():
		var reference: WeakRef = previous["runtime"]
		var runtime := reference.get_ref() as GameplayEffectRuntime
		if runtime != null:
			runtime.remove_effect(previous["handle"], -1, RemovalReason.REPLACED)


func _release_exclusive_slot(entry: Dictionary) -> void:
	var owner_ref: WeakRef = entry.get("slot_owner")
	if owner_ref == null:
		return
	var owner := owner_ref.get_ref() as GameplayEffectRuntime
	if owner == null:
		return
	var spec: GameplayEffectSpec = entry["spec"]
	var slot := spec.settings.get_exclusive_owner_slot()
	var record: Dictionary = owner._exclusive_slots.get(slot, {})
	if not record.is_empty():
		var reference: WeakRef = record["runtime"]
		if reference.get_ref() == self and record["handle"] == entry["handle"]:
			owner._exclusive_slots.erase(slot)


func _get_damage_defenses(spec: GameplayEffectSpec) -> Array[Dictionary]:
	var policies: Array[Dictionary] = []
	for entry: Dictionary in _entries.values():
		if not entry["complete"] or entry["inhibited"]:
			continue
		var retained: GameplayEffectSpec = entry["spec"]
		for index in retained.settings.components.size():
			var component := retained.settings.components[index] as DamageDefenseEffectComponent
			if component != null and _defense_applies(component, spec):
				var state: Dictionary = entry["behavior_states"].get(index, {})
				if component.get_contact_uses() > 0 and int(state.get("uses", 0)) <= 0:
					continue
				policies.append({
					"component": component,
					"handle": entry["handle"],
					"index": index,
					"state": state,
				})
	policies.sort_custom(_defense_precedes)
	return policies


func _defense_applies(component: DamageDefenseEffectComponent, spec: GameplayEffectSpec) -> bool:
	if not component.matches(spec) or not _meets_tags(component.required_owner_tags, component.blocked_owner_tags):
		return false
	if component.front_arc_degrees <= 0.0:
		return true
	var owner := _attributes.get_parent() as Node3D
	var attacker: ActorAttributes
	if spec.context.outcome_context != null:
		attacker = spec.context.outcome_context.actor(CombatOutcomeContext.Role.CREDITED_OWNER)
	var source := attacker.get_parent() as Node3D if is_instance_valid(attacker) else null
	if owner == null or source == null or not owner.is_inside_tree() or not source.is_inside_tree() \
			or owner.get_world_3d() != source.get_world_3d():
		return false
	var direction := source.global_position - owner.global_position
	direction.y = 0.0
	var facing := -owner.global_basis.z
	facing.y = 0.0
	return direction.is_zero_approx() or (not facing.is_zero_approx() \
			and facing.normalized().dot(direction.normalized()) >= cos(deg_to_rad(component.front_arc_degrees / 2.0)))


static func _defense_precedes(left: Dictionary, right: Dictionary) -> bool:
	var left_policy: DamageDefenseEffectComponent = left["component"]
	var right_policy: DamageDefenseEffectComponent = right["component"]
	if left_policy.mode != right_policy.mode:
		return left_policy.mode < right_policy.mode
	if left_policy.priority != right_policy.priority:
		return left_policy.priority < right_policy.priority
	if left["handle"] != right["handle"]:
		return left["handle"] < right["handle"]
	return left["index"] < right["index"]


static func _prioritized_component_precedes(left: Dictionary, right: Dictionary) -> bool:
	if left["priority"] != right["priority"]:
		return left["priority"] < right["priority"]
	if left["handle"] != right["handle"]:
		return left["handle"] < right["handle"]
	return left["index"] < right["index"]


func _has_damage_immunity(spec: GameplayEffectSpec) -> bool:
	for policy in _get_damage_defenses(spec):
		var component: DamageDefenseEffectComponent = policy["component"]
		if component.mode == DamageDefenseEffectComponent.Mode.IMMUNITY:
			return true
	return false


func _get_contact_prevention(
		specs: Array[GameplayEffectSpec], context: GameplayEffectContext
) -> Dictionary:
	var best: Dictionary = {}
	var source := context.get_source_system()
	var can_reflect := is_instance_valid(source) and source.effects != null and source.effects != self \
			and not source.effects.is_clearing() and is_instance_valid(source.attributes) \
			and source.attributes.get_value(CombatAttributes.Id.HEALTH) > 0.0 \
			and (context.outcome_context == null or not (context.outcome_context.provenance \
					& CombatOutcomeContext.Provenance.REFLECTED))
	for spec in specs:
		if not _passes_application_filters(spec):
			continue
		for policy in _get_damage_defenses(spec):
			var component: DamageDefenseEffectComponent = policy["component"]
			if component.mode != DamageDefenseEffectComponent.Mode.DEFLECT \
					and (component.mode != DamageDefenseEffectComponent.Mode.REFLECT or not can_reflect):
				continue
			if best.is_empty() or _defense_precedes(policy, best):
				best = policy
	return best


func _apply_damage_defenses(
		spec: GameplayEffectSpec, magnitude: float, rollback: Array[Dictionary] = []
) -> Dictionary:
	var defended := {"magnitude": magnitude, "blocked": 0.0, "absorbed": 0.0,
			"immune": false, "depleted": []}
	for policy in _get_damage_defenses(spec):
		var component: DamageDefenseEffectComponent = policy["component"]
		match component.mode:
			DamageDefenseEffectComponent.Mode.IMMUNITY:
				defended["immune"] = true
				magnitude = 0.0
				break
			DamageDefenseEffectComponent.Mode.BLOCK:
				var blocked := magnitude * component.fraction
				defended["blocked"] += blocked
				magnitude -= blocked
			DamageDefenseEffectComponent.Mode.ABSORB:
				var state: Dictionary = policy["state"]
				var budget: float = state["remaining"]
				var absorbed := minf(budget, magnitude * component.fraction)
				if absorbed > 0.0:
					rollback.append({"state": state, "previous": budget})
				defended["absorbed"] += absorbed
				magnitude -= absorbed
				state["remaining"] = budget - absorbed
				if absorbed > 0.0 and state["remaining"] <= 0.0 and component.remove_when_depleted:
					defended["depleted"].append(policy["handle"])
	defended["magnitude"] = magnitude
	return defended


func _find_damage_route(spec: GameplayEffectSpec, magnitude: float) -> Dictionary:
	var selected: Dictionary = {}
	if magnitude <= 0.0:
		return selected
	for entry: Dictionary in _entries.values():
		if not entry["complete"] or entry["inhibited"]:
			continue
		var retained: GameplayEffectSpec = entry["spec"]
		for index in retained.settings.components.size():
			var component := retained.settings.components[index] as DamageRoutingEffectComponent
			if component == null or not component.matches(spec) \
					or (not selected.is_empty() and component.priority >= int(selected["priority"])):
				continue
			var source := retained.context.get_source_system()
			if not _is_valid_route_recipient(source, component.max_range) \
					or source.effects._has_damage_immunity(spec):
				continue
			var state: Dictionary = entry["behavior_states"][index]
			var routed := minf(magnitude * component.fraction, state["remaining"])
			if component.preserve_source_health:
				routed = minf(routed, source.attributes.get_value(CombatAttributes.Id.HEALTH) - 1.0)
			if routed > 0.0:
				selected = {"runtime": source.effects, "handle": entry["handle"], "amount": routed,
						"priority": component.priority, "state": state}
	return selected


func _is_valid_route_recipient(source: AbilitySystem, max_range: float) -> bool:
	if not is_instance_valid(source) or source.effects == null or source.effects == self \
			or source.effects.is_clearing() or not is_instance_valid(source.attributes) \
			or source.attributes.is_queued_for_deletion() \
			or source.attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return false
	var source_actor := source.attributes.get_parent() as Node3D
	var target_actor := _attributes.get_parent() as Node3D
	if source_actor == null or target_actor == null:
		return max_range <= 0.0
	if not source_actor.is_inside_tree() or not target_actor.is_inside_tree() \
			or source_actor.get_world_3d() != target_actor.get_world_3d():
		return false
	return max_range <= 0.0 or source_actor.global_position.distance_squared_to(
			target_actor.global_position) <= max_range * max_range


func _commit_routed_damage(
		spec: GameplayEffectSpec, damage_event: Dictionary, magnitude: float,
		defended: Dictionary, route: Dictionary, hit_result: Dictionary
) -> bool:
	if route.is_empty():
		return false
	var destination: GameplayEffectRuntime = route["runtime"]
	var recipient := destination._attributes
	var portion: float = route["amount"]
	var budget: Dictionary = route["state"]
	var rollback: Array[Dictionary] = [{"state": budget, "previous": budget["remaining"]}]
	budget["remaining"] -= portion
	var original_defenses := defended.duplicate()
	original_defenses["magnitude"] -= portion
	var routed_defenses := destination._apply_damage_defenses(spec, portion, rollback)
	_cap_nonlethal_damage(spec, original_defenses)
	destination._cap_nonlethal_damage(spec, routed_defenses)
	var routed_spec := spec.copy_for_execution()
	if routed_spec.context.outcome_context != null:
		routed_spec.context.outcome_context = routed_spec.context.outcome_context.with_provenance(
				CombatOutcomeContext.Provenance.TRANSFERRED).with_role(
				CombatOutcomeContext.Role.TARGET, recipient)
	var routed_event := routed_spec.context.create_combat_event(&"damage", recipient, spec.settings)
	routed_event["routed_from_id"] = _attributes.get_instance_id()
	routed_event["is_periodic"] = damage_event["is_periodic"]
	routed_event["raw_magnitude"] = portion
	routed_event["stack_count"] = spec.stack_count
	var requests: Dictionary[ActorAttributes, float] = {
		_attributes: original_defenses["magnitude"],
		recipient: routed_defenses["magnitude"],
	}
	destination._mutation_depth += 1
	var notification_index := destination._notifications.size()
	destination._queue_outcome(routed_event, routed_spec)
	var outcomes := ActorAttributes.commit_damage_batch(requests)
	if outcomes.is_empty():
		destination._notifications.remove_at(notification_index)
		for spend in rollback:
			spend["state"]["remaining"] = spend["previous"]
		destination._mutation_depth -= 1
		return false
	var original: Dictionary = outcomes[_attributes]
	var redirected: Dictionary = outcomes[recipient]
	damage_event["routed_amount"] = portion
	damage_event["routed_to_id"] = routed_event["target_id"]
	_finish_damage_result(spec, damage_event, magnitude, original_defenses,
			original["health_damage"], original["previous"], hit_result)
	destination._finish_damage_result(routed_spec, routed_event, portion, routed_defenses,
			redirected["health_damage"], redirected["previous"])
	if budget["remaining"] <= 0.0:
		remove_effect(route["handle"], -1, RemovalReason.DEPLETED)
	destination._mutation_depth -= 1
	destination._publish_notifications()
	return true


func _apply_damage(
		spec: GameplayEffectSpec, event: Dictionary, result: Dictionary, handle: int = 0,
		hit_result: Dictionary = {}
) -> Dictionary:
	var damage_event := event.duplicate(true)
	damage_event["type"] = &"damage"
	damage_event["is_periodic"] = handle > 0 or (spec.context.outcome_context != null \
			and spec.context.outcome_context.timing == CombatOutcomeContext.Timing.PERIODIC)
	damage_event["stack_count"] = spec.stack_count
	for field in ["raw_magnitude", "critical_magnitude", "armor", "effective_armor",
			"armor_penetration_percent", "flat_armor_penetration", "armor_reduction", "resistance_attribute",
			"resistance_percent", "effective_resistance_percent", "spell_penetration",
			"resistance_multiplier", "resistance_stages"]:
		if result.has(field):
			damage_event[field] = result[field]
	_queue_outcome(damage_event, spec)
	# Queue execution before damage callbacks can remove the effect. Publication sees the actual loss.
	_queue_cue(GameplayCueRouter.Event.EXECUTED, spec, handle, damage_event)
	var magnitude := maxf(0.0, float(result.get("magnitude", 0.0)))
	var defended := _apply_damage_defenses(spec, magnitude)
	var route := _find_damage_route(spec, defended["magnitude"])
	if _commit_routed_damage(spec, damage_event, magnitude, defended, route, hit_result):
		return damage_event
	_cap_nonlethal_damage(spec, defended)
	var resolved: float = defended["magnitude"]
	var previous_health := _attributes.get_value(CombatAttributes.Id.HEALTH)
	var applied := _attributes.apply_damage(resolved)
	_finish_damage_result(spec, damage_event, magnitude, defended, applied["health_damage"], previous_health,
			hit_result)
	return damage_event


func _cap_nonlethal_damage(spec: GameplayEffectSpec, defended: Dictionary) -> void:
	var profile := spec.settings.damage_profile
	if profile == null or not profile.nonlethal:
		return
	var magnitude: float = defended["magnitude"]
	var health := _attributes.get_value(CombatAttributes.Id.HEALTH)
	var capped := minf(magnitude, maxf(0.0, health - 1.0))
	defended["magnitude"] = capped
	defended["nonlethal_prevented"] = magnitude - capped


func _finish_damage_result(
		spec: GameplayEffectSpec, damage_event: Dictionary, magnitude: float, defended: Dictionary,
		actual: float, previous_health: float, hit_result: Dictionary = {}
) -> void:
	var resolved: float = defended["magnitude"]
	damage_event["amount"] = actual
	damage_event["resolved_amount"] = resolved
	damage_event["health_damage"] = actual
	damage_event["prevention_input"] = magnitude
	damage_event["blocked_amount"] = defended["blocked"]
	damage_event["absorbed_amount"] = defended["absorbed"]
	damage_event["nonlethal_prevented"] = defended.get("nonlethal_prevented", 0.0)
	damage_event["overkill"] = maxf(0.0, resolved - actual)
	if defended["immune"]:
		damage_event["outcome"] = &"immune"
	if actual > 0.0 and actual >= previous_health:
		var kill_event := damage_event.duplicate(true)
		kill_event["type"] = &"kill"
		_queue_outcome(kill_event, spec)
	for depleted_handle: int in defended["depleted"]:
		_capture_depleted_hit_observers(depleted_handle, hit_result)
		remove_effect(depleted_handle, -1, RemovalReason.DEPLETED)


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


func _queue_outcome(event: Dictionary, spec: GameplayEffectSpec) -> void:
	_notifications.append({
		"event": event,
		"definition": spec.definition,
		"outcome_context": spec.context.outcome_context,
		"reactions": spec.settings.reactions,
		"clearing": _clearing,
	})


func _publish_notifications() -> void:
	if _publishing or _mutation_depth > 0:
		return
	_publishing = true
	CombatOutcomeDispatcher.begin_batch()
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
			var context: CombatOutcomeContext = notification.get("outcome_context")
			if context != null:
				var outcome := CombatOutcomeDispatcher.publish(context, event, notification["reactions"],
						definition.get_instance_id())
				event = outcome.get_event()
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
	CombatOutcomeDispatcher.end_batch()
	_publish_retained_changes()


func _publish_retained_changes() -> void:
	if _publishing or _mutation_depth > 0 or _clearing or not _retained_effects_dirty:
		return
	_retained_effects_dirty = false
	retained_effects_changed.emit()
