class_name AbilitySystem
extends Node
## Coordinates unlocked abilities, authored execution, resource costs and delivered payloads.

signal ability_started(ability_id: int)
signal ability_ended(ability_id: int, cancelled: bool)
signal activation_failed(ability_id: int, reason: StringName)
signal hit_resolved(result: Dictionary)
## Detached per-cast, delivery, and effect telemetry; target events are emitted only here.
signal combat_event(event: Dictionary)

const COMBAT_DEFINITION_JSON = preload("res://combat/abilities/combat_definition_json.gd")

## The actor's single attribute component, used for costs and effect calculations.
## If empty, resolves the actor's sibling node named Attributes when entering the scene.
@export var attributes: ActorAttributes
## Animation player used by authored execution behaviors and method-track events.
## This system advances it on physics ticks and routes immediate callbacks to the owning cast.
## Physical weapon animations follow their authored base attack cycle.
@export var animation_player: AnimationPlayer
## Scene origin whose local transform supplies the projectile spawn position.
@export var cast_origin: Node3D
## Optional aiming transform; when omitted, the casting origin also supplies direction.
@export var aim_origin: Node3D
## Source physics body excluded from its own projectile collision queries.
@export var actor_body: CollisionObject3D
## Ability JSON files granted directly to this actor at startup, in list order.
@export_file("*.ability.json") var granted_ability_files: Array[String] = []
## Effect JSON files applied to this actor at startup. Retained startup handles survive a combat reset.
@export_file("*.effect.json") var startup_effect_files: Array[String] = []
## Maps Gameplay Cue tags to optional presentation scenes for this actor.
@export var gameplay_cue_bindings: Array[GameplayCueBinding] = []
## Counted hierarchical tags initially granted to this actor.
@export var initial_tags: PackedStringArray = PackedStringArray()
## Faction identity used by authored friendly and hostile target filters.
@export var faction_id: StringName
## Factions this actor treats as hostile. Unlisted, different factions are neutral.
@export var hostile_factions: Array[StringName] = []

var tags := GameplayTagSet.new()
var effects: GameplayEffectRuntime
var _startup_effect_handles: Array[int] = []
var _ability_specs: Dictionary[int, GameplayAbilitySpec] = {}
var _active_casts: Dictionary[int, AbilityCast] = {}
var _charge_pools: Dictionary[Variant, AbilityChargePool] = {}
var _school_lockouts: Dictionary[int, Dictionary] = {}
var _next_lockout: int = 1
var _blocked_ability_tags := GameplayTagSet.new()
var _animation_cast: AbilityCast
var _animation_step_cast: AbilityCast
var _animation_name: StringName
var _reset_animation_when_ended: bool = false
var _animation_finished_on_step: bool = false
var _activation_cleanup_depth: int = 0
var _owns_dead_tag: bool = false
var _gameplay_events: Array[Dictionary] = []
var _dispatching_gameplay_events: bool = false
var _attribute_event_states: Dictionary[AttributeGameplayEventRule, bool] = {}
var _attribute_events_ready: bool = false
var _attribute_events_pending: bool = false
var _weapon_random := RandomNumberGenerator.new()
var _accuracy_random := RandomNumberGenerator.new()
var _critical_random := RandomNumberGenerator.new()
var _loaded_grants := false
var _loaded_startup := false

## Runtime definitions, with an in-memory override for isolated behavior fixtures.
var granted_abilities: Array[AbilityDefinition]:
	get:
		if not _loaded_grants:
			_loaded_grants = true
			for path: String in granted_ability_files:
				var definition := COMBAT_DEFINITION_JSON.load_definition(path) as AbilityDefinition
				if definition != null:
					granted_abilities.append(definition)
		return granted_abilities
	set(value):
		_loaded_grants = true
		granted_abilities = value

## Runtime startup effects, with an in-memory override for isolated behavior fixtures.
var startup_effects: Array[GameplayEffectDefinition]:
	get:
		if not _loaded_startup:
			_loaded_startup = true
			for path: String in startup_effect_files:
				var definition := COMBAT_DEFINITION_JSON.load_definition(path) as GameplayEffectDefinition
				if definition != null:
					startup_effects.append(definition)
		return startup_effects
	set(value):
		_loaded_startup = true
		startup_effects = value


func _ready() -> void:
	if not is_instance_valid(attributes):
		attributes = get_node_or_null("../Attributes") as ActorAttributes
	if not is_instance_valid(attributes):
		push_warning("AbilitySystem requires an ActorAttributes reference.")
		set_process(false)
		set_physics_process(false)
		return
	attributes.initialize()
	add_to_group(&"ability_actors")
	effects = GameplayEffectRuntime.new(attributes, tags, _critical_random, self)
	effects.cues.configure(gameplay_cue_bindings)
	for tag in initial_tags:
		tags.add_tag(StringName(tag))
	for definition: GameplayEffectDefinition in startup_effects:
		var spec := effects.make_effect_spec(definition, create_effect_context())
		var handle := effects.apply_effect_spec(spec)
		if handle == 0:
			push_error("Unable to apply a startup Gameplay Effect on %s: %s" % [get_path(), definition])
		elif effects.has_retained_effect(handle):
			_startup_effect_handles.append(handle)
	if not startup_effects.is_empty():
		attributes.restore_resources()
	effects.combat_event.connect(_on_effect_combat_event)
	effects.retained_effects_changed.connect(_flush_attribute_events)
	tags.changed.connect(_on_tags_changed)
	attributes.attribute_changed.connect(_on_attribute_changed)
	for definition in granted_abilities:
		grant_ability_spec(definition)
	_update_death_state(attributes.get_value(CombatAttributes.Id.HEALTH))
	_attribute_events_ready = true
	_reconcile_attribute_events()


func _process(delta: float) -> void:
	advance(delta)


func _physics_process(delta: float) -> void:
	for cast: AbilityCast in _active_casts.values():
		if _is_active(cast):
			cast.definition.execution.physics_advance(cast, delta)
	advance_animation(delta)


func _exit_tree() -> void:
	_activation_cleanup_depth += 1
	cancel_all_abilities()
	if effects != null and is_instance_valid(attributes):
		effects.clear([], GameplayEffectRuntime.RemovalReason.SCENE_UNLOAD)
	_startup_effect_handles.clear()
	_school_lockouts.clear()
	_attribute_events_ready = false
	_attribute_events_pending = false
	_attribute_event_states.clear()
	_gameplay_events.clear()
	_activation_cleanup_depth -= 1


func advance(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	for pool in _charge_pools.values():
		pool.advance(delta)
	for handle: int in _school_lockouts.keys():
		var lockout := _school_lockouts[handle]
		lockout["remaining"] -= delta
		if float(lockout["remaining"]) <= 1.0e-9:
			_school_lockouts.erase(handle)
	if effects != null:
		effects.advance(delta)
	for cast: AbilityCast in _active_casts.values():
		if _is_active(cast):
			cast.elapsed += delta
			cast._advance_tasks(delta)
		if _is_active(cast):
			cast.definition.execution.advance(cast, delta)


func create_effect_context(
		context_tags: PackedStringArray = PackedStringArray()
) -> GameplayEffectContext:
	var context := GameplayEffectContext.capture(attributes, tags, context_tags)
	context._source_system = weakref(self)
	return context


## Builds a per-application spec on the source before it is delivered to a target.
func make_outgoing_spec(definition: GameplayEffectDefinition, context: GameplayEffectContext = null) -> GameplayEffectSpec:
	if effects == null:
		return null
	return effects.make_effect_spec(definition, context if context != null else create_effect_context())


## Applies a spec directly to this actor without a hostile hit roll.
func apply_effect_spec_to_self(spec: GameplayEffectSpec) -> int:
	return effects.apply_effect_spec(spec) if effects != null else 0


## Delivers an outgoing spec directly to another ASC. Use receive_hit_specs for hostile hits.
func apply_effect_spec_to_target(spec: GameplayEffectSpec, target: AbilitySystem) -> int:
	return target.apply_effect_spec_to_self(spec) if is_instance_valid(target) else 0


## Removes stacks from a retained effect or removes the entire handle when stacks is -1.
func remove_active_effect(handle: int, stacks: int = -1) -> bool:
	return effects != null and effects.remove_effect(handle, stacks)


## Removes transient effects while leaving startup derivations and recovery in place.
func clear_transient_effects() -> void:
	if effects != null:
		effects.clear(_startup_effect_handles)


## A delivery shares Accuracy and, on a damaging success, one critical result across its payload.
## Optional nonnegative fractional rolls are deterministic test/replay inputs, not authoring flags.
func receive_hit(
		context: GameplayEffectContext,
		definitions: Array[GameplayEffectDefinition], accuracy_roll: float = -1.0,
		critical_roll: float = -1.0
) -> Dictionary:
	var specs: Array[GameplayEffectSpec] = []
	if effects != null:
		for definition in definitions:
			specs.append(effects.make_effect_spec(definition, context))
	return receive_hit_specs(context, specs, accuracy_roll, critical_roll)


## Delivers specs prepared by the source and resolves one shared Hit and critical roll.
func receive_hit_specs(
		context: GameplayEffectContext, specs: Array[GameplayEffectSpec],
		accuracy_roll: float = -1.0, critical_roll: float = -1.0
) -> Dictionary:
	var result := {"outcome": &"invalid", "applied_effects": 0}
	if context == null or effects == null or not is_instance_valid(attributes) \
			or attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0 \
			or not is_finite(accuracy_roll) or not is_finite(critical_roll):
		return result
	if not effects.has_hit_candidate(specs):
		return result
	var hit_context := context.duplicate_for_hit(_weapon_random.randf())
	if hit_context.outcome_context == null:
		hit_context.outcome_context = CombatOutcomeContext.create(null)
	hit_context.outcome_context = hit_context.outcome_context.for_contact(attributes)
	var roll := accuracy_roll if accuracy_roll >= 0.0 else _accuracy_random.randf()
	CombatOutcomeDispatcher.begin_batch()
	result = effects.apply_hit_specs(specs, hit_context, roll, critical_roll)
	publish_hit_outcome(hit_context, result)
	CombatOutcomeDispatcher.end_batch()
	return result


## Queues a resolved contact, including observer state retained from depleted barriers.
func publish_hit_outcome(context: GameplayEffectContext, result: Dictionary) -> void:
	if result.get("outcome", &"invalid") == &"invalid":
		return
	var observers: Array = result.get("_depleted_hit_observers", [])
	result.erase("_depleted_hit_observers")
	var event := context.create_combat_event(&"hit_outcome", attributes)
	event.merge(result, true)
	CombatOutcomeDispatcher.begin_batch()
	var outcome := CombatOutcomeDispatcher.publish(context.outcome_context, event)
	if not observers.is_empty():
		effects.dispatch_depleted_hit_observers(outcome, observers)
	hit_resolved.emit(result)
	combat_event.emit(outcome.get_event())
	CombatOutcomeDispatcher.end_batch()


## Seeds independent weapon damage, Accuracy and critical streams for tests and replays.
func configure_randomness(seed_value: int) -> void:
	_weapon_random.seed = seed_value
	_accuracy_random.seed = seed_value ^ 0x5A17
	_critical_random.seed = seed_value ^ 0xC817
	if effects != null:
		effects.seed_application_randomness(seed_value ^ 0x8F91)


## Registers the first grant for an ID. Use grant_ability_spec for independent additional grants.
func grant_ability(definition: AbilityDefinition, weapon_source: WeaponDefinition = null) -> bool:
	if definition == null:
		return false
	var existing := _get_ability_spec_for_id(definition.ability_id)
	if existing != null:
		return existing.definition == definition and existing.source_object == weapon_source
	return grant_ability_spec(definition, 1, weapon_source) > 0


## Grants a distinct instance with a level and optional source.
## Returns zero if the grant is invalid or a different definition already owns its ID.
func grant_ability_spec(
		definition: AbilityDefinition, grant_level: int = 1, source_object: Object = null,
		granting_effect_handle: int = 0, set_by_caller: Dictionary[StringName, float] = {}
) -> int:
	if definition == null or definition.ability_id <= 0 or definition.execution == null or grant_level < 1:
		return 0
	var existing := _get_ability_spec_for_id(definition.ability_id)
	if existing != null and existing.definition != definition:
		return 0
	var spec := GameplayAbilitySpec.new(definition, grant_level, source_object, granting_effect_handle, set_by_caller)
	_ability_specs[spec.handle] = spec
	_replay_current_attribute_event(spec)
	return spec.handle


func get_ability_spec(handle: int) -> GameplayAbilitySpec:
	return _ability_specs.get(handle)


func revoke_ability(ability_id: int) -> void:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec != null:
		revoke_ability_spec(spec.handle)


## Removes this exact grant and cancels only its active cast.
func revoke_ability_spec(handle: int) -> void:
	if _ability_specs.erase(handle):
		cancel_ability_spec(handle)


## Lets an existing activation finish and removes its grant afterward. Idle grants are removed immediately.
func remove_ability_spec_on_end(handle: int) -> void:
	var spec := get_ability_spec(handle)
	if spec == null:
		return
	if get_active_cast_for_spec(handle) == null:
		revoke_ability_spec(handle)
	else:
		spec.remove_on_end = true


## Reads the current runtime grant so previews and AI use the actual ability selected.
func get_ability_definition(ability_id: int) -> AbilityDefinition:
	var spec := _get_ability_spec_for_id(ability_id)
	return spec.definition if spec != null else null


## Reads the current grant's optional runtime weapon profile.
func get_ability_weapon_source(ability_id: int) -> WeaponDefinition:
	var spec := _get_ability_spec_for_id(ability_id)
	return spec.get_weapon_source() if spec != null else null


func _get_ability_spec_for_id(ability_id: int) -> GameplayAbilitySpec:
	if ability_id <= 0:
		return null
	for spec: GameplayAbilitySpec in _ability_specs.values():
		if spec.definition.ability_id == ability_id:
			return spec
	return null


## Captures a compatible granted action without spending resources, rolling, or activating it.
func create_ability_context(ability_id: int) -> GameplayEffectContext:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec == null or not spec.definition.get_validation_error().is_empty() \
			or not get_weapon_source_error(spec.definition, spec.get_weapon_source()).is_empty():
		return null
	return AbilityCast.capture_context(self, spec.definition, spec.get_weapon_source())


func get_activation_failure(ability_id: int, event_tag: StringName = &"") -> StringName:
	return _get_activation_failure(_get_ability_spec_for_id(ability_id), event_tag)


func get_activation_failure_for_spec(handle: int, event_tag: StringName = &"") -> StringName:
	return _get_activation_failure(get_ability_spec(handle), event_tag)


func _get_activation_failure(
		spec: GameplayAbilitySpec, event_tag: StringName, target: AbilitySystem = null
) -> StringName:
	if not is_instance_valid(attributes) or effects == null:
		return &"missing_attributes"
	if attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0 or tags.has_tag(&"State.Dead"):
		return &"actor_dead"
	if not is_inside_tree() or _activation_cleanup_depth > 0:
		return &"activation_unavailable"
	if spec == null or get_ability_spec(spec.handle) != spec:
		return &"ability_not_granted"
	if spec.remove_on_end:
		return &"ability_pending_removal"
	var definition := spec.definition
	if not definition.activation_event_tag.is_empty() \
			and not GameplayTagSet.matches(event_tag, definition.activation_event_tag):
		return &"requires_gameplay_event"
	var definition_error := definition.get_validation_error()
	if not definition_error.is_empty():
		return definition_error
	var source_error := get_weapon_source_error(definition, spec.get_weapon_source())
	if not source_error.is_empty():
		return source_error
	if _active_casts.has(spec.handle):
		return &"action_in_progress"
	if _matches_any_ability_tag(definition, _blocked_ability_tags.get_tags()):
		return &"blocked_by_ability_tags"
	var policy := definition.interruption_policy
	if policy != null:
		if policy.blocks_activation(tags):
			return &"blocked_by_tags"
		if is_school_locked(policy.school):
			return &"school_locked"
		for active in _active_casts.values():
			if policy.conflicts_with(active.definition.interruption_policy):
				return &"execution_channel_occupied"
	if not tags.has_all(definition.required_tags):
		return &"missing_required_tags"
	if not definition.execution.get_animation_name().is_empty() \
			and (_animation_cast != null or _animation_step_cast != null):
		return &"animation_in_use"
	var error := definition.execution.get_validation_error(self)
	if not error.is_empty():
		return error
	error = definition.execution.get_target_validation_error(self, target)
	if not error.is_empty():
		return error
	var pool := _get_charge_pool(definition)
	if pool != null:
		if not pool.matches(definition.charge_pool):
			return &"conflicting_charge_profile"
		if pool.available() <= 0:
			return &"no_charges"
	if not definition.resource_costs.is_empty() and not _can_pay_debits(_read_costs(spec, target)):
		return &"insufficient_resource"
	return &""


func try_activate(ability_id: int) -> bool:
	return _try_activate_spec(_get_ability_spec_for_id(ability_id), &"", {}, ability_id) != null


func try_activate_spec(handle: int) -> bool:
	return try_activate_input_spec(handle) != null


## Returns the exact accepted activation for the input that started it, or null on rejection.
func try_activate_input_spec(handle: int) -> AbilityCast:
	return _try_activate_spec(get_ability_spec(handle))


## Requests a granted ability using an explicitly selected actor.
func try_activate_target(ability_id: int, target: AbilitySystem) -> bool:
	return _try_activate_spec(_get_ability_spec_for_id(ability_id), &"", {}, ability_id, target) != null


## Inspects a targeted request without reserving a charge, spending, or rolling.
func get_target_activation_failure(ability_id: int, target: AbilitySystem) -> StringName:
	return _get_activation_failure(_get_ability_spec_for_id(ability_id), &"", target)


func _try_activate_spec(
		spec: GameplayAbilitySpec, event_tag: StringName = &"", payload: Dictionary = {},
		requested_id: int = 0, target: AbilitySystem = null
) -> AbilityCast:
	var definition := spec.definition if spec != null else null
	var ability_id := definition.ability_id if definition != null else requested_id
	var failure := _get_activation_failure(spec, event_tag, target)
	if not failure.is_empty():
		activation_failed.emit(ability_id, failure)
		var context_tags := definition.ability_tags if definition != null else PackedStringArray()
		var failure_context := create_effect_context(context_tags)
		failure_context.ability_id = ability_id
		if definition != null:
			failure_context.ability_name = definition.display_name
		var event := failure_context.create_combat_event(&"cast_failed", attributes)
		event["reason"] = failure
		if failure == &"blocked_by_tags" or failure == &"missing_required_tags":
			event["actor_tags"] = tags.get_tags()
		combat_event.emit(event)
		return null
	var cast := AbilityCast.new(self, spec, target)
	cast.trigger_event_tag = event_tag
	cast.trigger_event_payload = payload.duplicate(true)
	if not _reserve_cast(cast):
		activation_failed.emit(ability_id, &"commit_reservation_failed")
		return null
	_active_casts[spec.handle] = cast
	if not definition.execution.get_animation_name().is_empty():
		_animation_cast = cast
	# All authored conflicts must be visible before tags or resource changes notify listeners.
	cast.granted_tags = definition.activation_tags.duplicate()
	cast.blocked_ability_tags = definition.block_ability_tags.duplicate()
	block_abilities_by_tags(cast.blocked_ability_tags)
	tags.add_tags(cast.granted_tags)
	if _is_active(cast):
		_cancel_matching_abilities(cast)
	if not _is_active(cast):
		return null
	if not cast._reserved_costs.is_empty() or cast._charge_pool != null:
		var reservation := cast.context.create_combat_event(&"cast_reserved", attributes)
		reservation["resources"] = cast._reserved_costs.duplicate()
		reservation["reserved_charge"] = cast._charge_pool != null
		combat_event.emit(reservation)
	if not _is_active(cast):
		return null
	if not definition.execution.request_start(cast):
		cast.cancel()
		return null
	if not _is_active(cast):
		return null
	if not _commit_cast(cast, AbilityInterruptionPolicy.CommitTiming.ON_START):
		cast.cancel()
		return null
	if not _is_active(cast):
		return null
	ability_started.emit(ability_id)
	combat_event.emit(cast.context.create_combat_event(&"cast", attributes))
	if _is_active(cast):
		cast._start_casting_cue()
	if _is_active(cast):
		definition.execution.begin(cast)
	return cast


func _cancel_matching_abilities(initiator: AbilityCast) -> void:
	var queries := initiator.definition.cancel_ability_tags
	if queries.is_empty():
		return
	for other: AbilityCast in _active_casts.values():
		if not _is_active(initiator):
			return
		if other != initiator and _is_active(other) and _matches_any_ability_tag(other.definition, queries):
			other.cancel()


static func _matches_any_ability_tag(definition: AbilityDefinition, queries: PackedStringArray) -> bool:
	for query in queries:
		if AttributeModifier._has_match(definition.ability_tags, query):
			return true
	return false


## Adds a counted contribution that blocks activation by ability asset tags.
func block_abilities_by_tags(blocked_tags: PackedStringArray) -> void:
	_blocked_ability_tags.add_tags(blocked_tags)


## Removes only this contribution. Other owners of the same tag keep blocking.
func unblock_abilities_by_tags(blocked_tags: PackedStringArray) -> void:
	for tag in blocked_tags:
		_blocked_ability_tags.remove_tag(StringName(tag))


## Delivers a gameplay event to this actor. Events sent during dispatch are delivered in order.
func send_gameplay_event(event_tag: StringName, payload: Dictionary = {}) -> void:
	if event_tag.is_empty() or not is_inside_tree() or _activation_cleanup_depth > 0:
		return
	_gameplay_events.append({"tag": event_tag, "payload": payload.duplicate(true)})
	if _dispatching_gameplay_events:
		return
	_dispatching_gameplay_events = true
	while not _gameplay_events.is_empty():
		var event: Dictionary = _gameplay_events.pop_front()
		_dispatch_gameplay_event(event["tag"], event["payload"])
	_dispatching_gameplay_events = false


func _dispatch_gameplay_event(event_tag: StringName, payload: Dictionary) -> void:
	var grants := _ability_specs.values()
	var active_at_dispatch := _active_casts.duplicate()
	for cast: AbilityCast in active_at_dispatch.values():
		if _is_active(cast):
			cast._dispatch_task_gameplay_event(event_tag, payload)
		if _is_active(cast):
			cast.definition.execution.handle_gameplay_event(cast, event_tag, payload.duplicate(true))
	for spec: GameplayAbilitySpec in grants:
		if get_ability_spec(spec.handle) == spec and not _active_casts.has(spec.handle) \
				and not active_at_dispatch.has(spec.handle) \
				and GameplayTagSet.matches(event_tag, spec.definition.activation_event_tag):
			_try_activate_spec(spec, event_tag, payload)


func _on_effect_combat_event(event: Dictionary) -> void:
	combat_event.emit(event)


## Commits the active cast's release-based costs and charge once.
func commit_ability(cast: AbilityCast) -> bool:
	if not _is_active(cast):
		return false
	if cast.phase == AbilityCast.Phase.WINDUP:
		return cast.committed
	return _commit_cast(cast, AbilityInterruptionPolicy.CommitTiming.ON_RELEASE)


func _commit_cast(cast: AbilityCast, timing: AbilityInterruptionPolicy.CommitTiming) -> bool:
	if not _is_active(cast) or cast._committing:
		return false
	if cast.committed:
		return true
	var policy := cast.definition.interruption_policy
	var default_timing := AbilityInterruptionPolicy.CommitTiming.ON_START
	var cost_timing := policy.cost_timing if policy != null else default_timing
	var cooldown_timing := policy.cooldown_timing if policy != null else default_timing
	var pay_cost := not cast._cost_committed and not cast._reserved_costs.is_empty() \
			and cost_timing == timing
	var spend_charge := not cast._cooldown_committed and cast._charge_pool != null \
			and cooldown_timing == timing
	if pay_cost and not _can_pay_debits(cast._reserved_costs, cast):
		return false

	cast._committing = true
	if spend_charge:
		cast._charge_receipt = cast._charge_pool.spend(cast.get_instance_id())
		cast._cooldown_committed = cast._charge_receipt > 0
	var charge_spent := not spend_charge or cast._cooldown_committed
	var cost_paid := not pay_cost or (charge_spent and _pay_cast_cost(cast))
	cast._committing = false
	if spend_charge and not cost_paid:
		_refund_cast_cooldown(cast)
	if cast._cancelled:
		_refund_cancelled_cast(cast)
	cast.committed = ((cast._cost_committed or cast._reserved_costs.is_empty())
			and (cast._cooldown_committed or cast._charge_pool == null))
	return cost_paid and charge_spent


func _pay_cast_cost(cast: AbilityCast) -> bool:
	cast._cost_committed = true
	cast.spend_receipt = ResourceService.commit_spend(attributes, cast._reserved_costs)
	if cast.spend_receipt == null:
		cast._cost_committed = false
		return false
	cast.context.outcome_context.set_spend_receipt(cast.spend_receipt)
	var event := cast.context.create_combat_event(&"cast_spent", attributes)
	event["resources"] = cast.spend_receipt.get_amounts()
	combat_event.emit(event)
	return true


func _reserve_cast(cast: AbilityCast) -> bool:
	var definition := cast.definition
	cast._reserved_costs = _read_costs(cast.grant_spec, cast.target_request)
	if not _can_pay_debits(cast._reserved_costs):
		return false
	if definition.charge_pool != null:
		var pool := _get_charge_pool(definition, true)
		if not pool.matches(definition.charge_pool) or not pool.reserve(cast.get_instance_id()):
			return false
		cast._charge_pool = pool
	return true


func _get_charge_pool(definition: AbilityDefinition, create: bool = false) -> AbilityChargePool:
	var profile := definition.charge_pool
	if profile == null:
		return null
	var key: Variant = definition.ability_id if profile.shared_group.is_empty() else profile.shared_group
	if create and not _charge_pools.has(key):
		_charge_pools[key] = AbilityChargePool.new(profile)
	return _charge_pools.get(key)


func _read_costs(spec: GameplayAbilitySpec, target: AbilitySystem) -> Dictionary[int, float]:
	var costs: Dictionary[int, float] = {}
	if spec.definition.resource_costs.is_empty():
		return costs
	var context := AmountEvaluationContext.new()
	context.source = attributes
	context.payer = attributes
	context.target = target.attributes if is_instance_valid(target) else null
	context.scope_tags = spec.definition.get_context_tags()
	context.rank = spec.level
	var weapon := spec.get_weapon_source()
	if weapon != null:
		context.scope_tags.append_array(weapon.get_context_tags())
	for cost in spec.definition.resource_costs:
		if context.snapshot == null and not cost.uses_payment_pool() \
				and cost.amount.timing == AmountDefinition.Timing.SNAPSHOT:
			context.snapshot = context.capture()
		var attribute := cost.get_attribute()
		var debit := cost.get_debit(_unreserved_current(attribute), context)
		if debit != 0.0:
			costs[attribute] = debit
	return costs


func _unreserved_current(attribute: int, except: AbilityCast = null) -> float:
	var available := attributes.get_value(attribute)
	for cast in _active_casts.values():
		if cast != except and not cast._cost_committed:
			available -= float(cast._reserved_costs.get(attribute, 0.0))
	return maxf(available, 0.0)


func _can_pay_debits(costs: Dictionary[int, float], cast: AbilityCast = null) -> bool:
	for attribute in costs:
		var amount := costs[attribute]
		if not CombatAttributes.is_current_resource(attribute) or not is_finite(amount) or amount < 0.0:
			return false
		var available := _unreserved_current(attribute, cast)
		if available + amount * 1.0e-9 < amount:
			return false
	return true


## Checks an exact current-pool debit, allowing only floating-point roundoff at the boundary.
func can_spend_current(attribute: int, amount: float) -> bool:
	return is_instance_valid(attributes) and _can_pay_debits({ attribute: amount })


## Commits one affordable current-pool debit. A rejected amount leaves the pool untouched.
func try_spend_current(attribute: int, amount: float) -> bool:
	if not can_spend_current(attribute, amount):
		return false
	attributes.modify_current(attribute, -amount)
	return true


func get_cooldown_remaining(ability_id: int) -> float:
	var spec := _get_ability_spec_for_id(ability_id)
	return get_cooldown_remaining_for_spec(spec.handle) if spec != null else 0.0


func get_cooldown_remaining_for_spec(handle: int) -> float:
	var spec := get_ability_spec(handle)
	var pool := _get_charge_pool(spec.definition) if spec != null else null
	return pool.get_remaining() if pool != null and pool.available() <= 0 else 0.0


## Returns the charges available for another reservation, excluding in-flight casts.
func get_available_charges(ability_id: int) -> int:
	var definition := get_ability_definition(ability_id)
	if definition == null or definition.charge_pool == null:
		return 0
	var pool := _get_charge_pool(definition)
	return pool.available() if pool != null else definition.charge_pool.capacity


## Captures recharge clocks for a granted ability's pool, excluding reservations.
func capture_charge_recharge(ability_id: int) -> Array[float]:
	var definition := get_ability_definition(ability_id)
	var pool := _get_charge_pool(definition) if definition != null else null
	return pool.capture_recharge() if pool != null else []


## Restores clocks on an idle actor. Shared groups refer to the same saved pool.
func restore_charge_recharge(ability_id: int, clocks: Array[float]) -> bool:
	var definition := get_ability_definition(ability_id)
	if definition == null or definition.charge_pool == null or not _active_casts.is_empty() \
			or not definition.charge_pool.get_validation_error().is_empty():
		return false
	var pool := _get_charge_pool(definition, true)
	return pool.matches(definition.charge_pool) and pool.restore_recharge(clocks)


## Lists the first grant of each ID, in grant order, for ID-based input and UI.
func get_granted_ability_definitions() -> Array[AbilityDefinition]:
	var definitions: Dictionary[int, AbilityDefinition] = {}
	for spec: GameplayAbilitySpec in _ability_specs.values():
		if not definitions.has(spec.definition.ability_id):
			definitions[spec.definition.ability_id] = spec.definition
	return definitions.values()


func get_granted_ability_specs() -> Array[GameplayAbilitySpec]:
	return _ability_specs.values()


## Resolves the active instance of the first grant for this ID.
func get_active_cast(ability_id: int) -> AbilityCast:
	var spec := _get_ability_spec_for_id(ability_id)
	return get_active_cast_for_spec(spec.handle) if spec != null else null


func get_active_cast_for_spec(handle: int) -> AbilityCast:
	return _active_casts.get(handle)


## Returns the cast that owns the shared animation player.
func get_animation_cast() -> AbilityCast:
	return _animation_cast


## Starts playback for this activation when the shared animation player is available.
func play_cast_animation(cast: AbilityCast, speed: float, reset_on_end: bool = false,
		clip_name: StringName = &"") -> bool:
	if (_animation_cast != null and cast != _animation_cast) or not _is_active(cast) \
			or _animation_step_cast != null or not _animation_name.is_empty() \
			or not is_instance_valid(animation_player) or not is_finite(speed) or speed <= 0.0:
		return false
	if clip_name.is_empty():
		clip_name = cast.definition.execution.get_animation_name()
	if not animation_player.has_animation(clip_name):
		return false
	animation_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation_player.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	if not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)
	_animation_cast = cast
	_animation_name = clip_name
	_reset_animation_when_ended = reset_on_end
	animation_player.play(clip_name, -1.0, speed)
	return true


## Advances one playback frame. Remaining callbacks from a cancelled frame keep its old owner.
func advance_animation(delta: float) -> void:
	if _animation_step_cast != null or not _is_active(_animation_cast) \
			or _animation_name.is_empty() or not is_finite(delta) or delta <= 0.0:
		return
	var cast := _animation_cast
	if not is_instance_valid(animation_player) or not animation_player.is_playing() \
			or animation_player.current_animation != _animation_name:
		_animation_cast = null
		_animation_name = &""
		_reset_animation_when_ended = false
		if not cast._complete_animation_task(true):
			cast.cancel()
		return
	_animation_step_cast = cast
	_animation_finished_on_step = false
	animation_player.advance(delta)
	_animation_step_cast = null
	if _animation_cast == null:
		_stop_cast_animation()
	elif _animation_finished_on_step:
		stop_cast_animation(cast)
		if not cast._complete_animation_task(false):
			cast.finish()


## Delivers a method-track event only to the activation that owns the current animation frame.
func handle_animation_event(event_name: StringName) -> void:
	var cast := _animation_step_cast if _animation_step_cast != null else _animation_cast
	if cast == _animation_cast and _is_active(cast) and not _animation_name.is_empty():
		cast._dispatch_task_gameplay_event(event_name, {})
		if _is_active(cast) and cast == _animation_cast:
			cast.definition.execution.handle_event(cast, event_name)


## Releases this cast's playback slot without ending the ability.
func stop_cast_animation(cast: AbilityCast) -> void:
	if cast == null or cast != _animation_cast:
		return
	_animation_cast = null
	if _animation_step_cast == null:
		_stop_cast_animation()


## Cancels the activation owning the animation player.
func cancel_animation() -> void:
	complete_cast(_animation_cast, true)


## Forwards an input release or equivalent AI request to the named activation only.
func release_ability(ability_id: int) -> void:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec != null:
		release_ability_spec(spec.handle)


func release_ability_spec(handle: int) -> void:
	release_cast_input(get_active_cast_for_spec(handle))


## Releases the captured cast only. A later use of the same grant has its own lifetime.
func release_cast_input(cast: AbilityCast) -> void:
	if _is_active(cast):
		cast._dispatch_task_input_release()
	if _is_active(cast):
		cast.definition.execution.input_released(cast)
	if _is_active(cast) and cast.definition.get_input_gesture() == AbilityDefinition.InputGesture.HOLD:
		cast.finish()


## Cancels a named activation without disturbing unrelated casts.
func cancel_ability(ability_id: int) -> void:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec != null:
		cancel_ability_spec(spec.handle)


func cancel_ability_spec(handle: int) -> void:
	var cast := get_active_cast_for_spec(handle)
	if cast != null:
		complete_cast(cast, true)


## Cancels all active instances and rejects reentrant activation during cleanup.
func cancel_all_abilities() -> void:
	_activation_cleanup_depth += 1
	for cast: AbilityCast in _active_casts.values():
		complete_cast(cast, true)
	_activation_cleanup_depth -= 1


## Interrupts the earliest eligible cast or channel. Lockout applies only to actual schools stopped.
func interrupt_cast(
		lockout_seconds: float = 0.0, all_eligible: bool = false,
		source: AbilitySystem = null
) -> AbilityInterruptResult:
	var result := AbilityInterruptResult.new()
	if not is_finite(lockout_seconds) or lockout_seconds < 0.0:
		result.reason = &"invalid_lockout_duration"
		return result
	result.reason = &"no_interruptible_cast"
	for cast: AbilityCast in _active_casts.values():
		if not _is_active(cast):
			continue
		var policy := cast.definition.interruption_policy
		if policy == null or not policy.interruptible_by_action \
				or not policy.permits_interruption(cast.phase):
			result.reason = &"uninterruptible_phase"
			continue
		if not policy.school.is_empty():
			if not result.interrupted_schools.has(policy.school):
				result.interrupted_schools.append(policy.school)
			_add_school_lockout(policy.school, lockout_seconds, source)
		result.interrupted_abilities.append(cast.definition.ability_id)
		complete_cast(cast, true, &"interrupt_action")
		if not all_eligible:
			break
	if result.is_success():
		result.reason = &""
	return result


## Reports whether an independent timed restriction covers this school.
func is_school_locked(school: StringName) -> bool:
	for lockout in _school_lockouts.values():
		if GameplayTagSet.matches(school, lockout["school"]):
			return true
	return false


## Handles movement intent and reports whether a remaining cast locks locomotion.
func handle_movement_intent(requested: bool) -> bool:
	var locked := false
	for cast: AbilityCast in _active_casts.values():
		if not _is_active(cast):
			continue
		var policy := cast.definition.interruption_policy
		if policy == null:
			continue
		match policy.get_movement_rule(cast.phase):
			AbilityInterruptionPolicy.MovementRule.LOCK:
				locked = true
			AbilityInterruptionPolicy.MovementRule.CANCEL_ON_REQUEST:
				if requested:
					complete_cast(cast, true, &"movement_requested")
	return locked


func _add_school_lockout(school: StringName, seconds: float, source: AbilitySystem) -> void:
	if seconds <= 0.0:
		return
	_school_lockouts[_next_lockout] = {
		"school": school,
		"remaining": seconds,
		"source_id": source.get_instance_id() if is_instance_valid(source) else 0,
	}
	_next_lockout += 1


func complete_cast(
		cast: AbilityCast, cancelled: bool, reason: StringName = &"cancelled"
) -> void:
	if not _is_active(cast):
		return
	var ability_id := cast.context.ability_id
	cast.finished = true
	cast._cancelled = cancelled
	_active_casts.erase(cast.grant_spec.handle)
	if cast._charge_pool != null:
		cast._charge_pool.release(cast.get_instance_id())
	if _animation_cast == cast:
		if _animation_step_cast == null:
			_stop_cast_animation()
		_animation_cast = null
	cast._stop_tasks(cancelled)
	cast.definition.execution.end(cast, cancelled)
	if cast.grant_spec.remove_on_end:
		_ability_specs.erase(cast.grant_spec.handle)
	unblock_abilities_by_tags(cast.blocked_ability_tags)
	for tag in cast.granted_tags:
		tags.remove_tag(StringName(tag))
	if cancelled and not cast._committing:
		_refund_cancelled_cast(cast)
	var event := cast.context.create_combat_event(&"cast_ended", attributes)
	event["reason"] = reason if cancelled else &"completed"
	event["phase"] = cast.phase
	cast._stop_casting_cue()
	combat_event.emit(event)
	ability_ended.emit(ability_id, cancelled)


func _refund_cancelled_cast(cast: AbilityCast) -> void:
	var policy := cast.definition.interruption_policy
	if policy == null:
		return
	if policy.refund_cooldown_on_cancel:
		_refund_cast_cooldown(cast)
	if policy.refund_cost_on_cancel and cast.spend_receipt != null and is_instance_valid(attributes):
		var receipt := cast.spend_receipt
		cast.spend_receipt = null
		var refunded := ResourceService.refund_spend(attributes, receipt)
		var event := cast.context.create_combat_event(&"cast_refunded", attributes)
		event["resources"] = refunded
		event["reason"] = &"cancelled"
		combat_event.emit(event)


func _refund_cast_cooldown(cast: AbilityCast) -> void:
	if cast._charge_receipt > 0:
		cast._charge_pool.refund(cast._charge_receipt)
		cast._charge_receipt = 0
	cast._cooldown_committed = false


func _is_active(cast: AbilityCast) -> bool:
	return cast != null and not cast.finished and get_active_cast_for_spec(cast.grant_spec.handle) == cast


func _on_animation_finished(animation_name: StringName) -> void:
	var cast := _animation_step_cast
	if cast == _animation_cast and _is_active(cast) and _animation_name == animation_name:
		_animation_finished_on_step = true


func _stop_cast_animation() -> void:
	if _animation_name.is_empty():
		return
	_animation_name = &""
	var reset := _reset_animation_when_ended
	_reset_animation_when_ended = false
	if not is_instance_valid(animation_player):
		return
	animation_player.stop()
	if reset and animation_player.has_animation(&"RESET"):
		animation_player.play(&"RESET")
		animation_player.advance(0.0)
		animation_player.stop()


func _on_tags_changed(tag: StringName, present: bool) -> void:
	if not present:
		return
	for cast: AbilityCast in _active_casts.values():
		if not _is_active(cast):
			continue
		var policy := cast.definition.interruption_policy
		if policy == null or not policy.permits_interruption(cast.phase):
			continue
		for query in policy.cancel_on_tags:
			if GameplayTagSet.matches(tag, StringName(query)):
				complete_cast(cast, true, &"interrupting_tag")
				break


func _on_attribute_changed(attribute: int, previous: float, value: float) -> void:
	if attribute == CombatAttributes.Id.HEALTH:
		_update_death_state(value)
		if previous <= 0.0 and value > 0.0:
			_reconcile_attribute_events()
			return
	if attribute == CombatAttributes.Id.STAMINA and previous > 0.0 and value <= 0.0:
		send_gameplay_event(&"Event.Stamina.Depleted", {"attribute": attribute, "value": value})
	_reconcile_attribute_events(attribute)


func _update_death_state(health: float) -> void:
	if health <= 0.0 and not _owns_dead_tag:
		_activation_cleanup_depth += 1
		_attribute_event_states.clear()
		_attribute_events_pending = false
		_owns_dead_tag = true
		tags.add_tag(&"State.Dead")
		cancel_all_abilities()
		if effects != null:
			effects.clear(_startup_effect_handles, GameplayEffectRuntime.RemovalReason.DEATH)
		_activation_cleanup_depth -= 1
	elif health > 0.0 and _owns_dead_tag:
		_owns_dead_tag = false
		tags.remove_tag(&"State.Dead")


func _reconcile_attribute_events(changed: int = CombatAttributes.Id.NONE) -> void:
	if not _attribute_events_ready or _owns_dead_tag or _activation_cleanup_depth > 0 \
			or attributes.gameplay_event_rules.is_empty():
		return
	# Bulk effect removal can change several attributes before it reaches its final state.
	if effects.is_clearing():
		if not _attribute_events_pending:
			_attribute_events_pending = true
			_flush_attribute_events.call_deferred()
		return
	for rule: AttributeGameplayEventRule in attributes.gameplay_event_rules:
		if _owns_dead_tag:
			return
		if rule == null or (changed != CombatAttributes.Id.NONE and not rule.watches(changed)) \
				or not rule.get_validation_error().is_empty():
			continue
		var above := rule.matches(attributes)
		if above == _attribute_event_states.get(rule, false):
			continue
		_attribute_event_states[rule] = above
		var event_tag := rule.entered_event if above else rule.exited_event
		send_gameplay_event(event_tag, _attribute_event_payload(rule))


func _flush_attribute_events() -> void:
	if _attribute_events_pending:
		_attribute_events_pending = false
		_reconcile_attribute_events()


func _replay_current_attribute_event(spec: GameplayAbilitySpec) -> void:
	var definition := spec.definition
	if not _attribute_events_ready or _owns_dead_tag or _activation_cleanup_depth > 0 \
			or effects.is_clearing() or definition.activation_event_tag.is_empty():
		return
	# A newly granted listener can join a condition already in progress. This is not a broadcast.
	for rule: AttributeGameplayEventRule in _attribute_event_states:
		if _attribute_event_states[rule] and rule.matches(attributes) \
				and GameplayTagSet.matches(rule.entered_event, definition.activation_event_tag):
			_try_activate_spec(spec, rule.entered_event, _attribute_event_payload(rule))
			return


func _attribute_event_payload(rule: AttributeGameplayEventRule) -> Dictionary:
	return {"attribute": rule.attribute, "value": attributes.get_value(rule.attribute),
			"threshold_attribute": rule.threshold_attribute,
			"threshold": attributes.get_value(rule.threshold_attribute)}


## Validates the optional runtime weapon profile against the action's delivery and payload.
static func get_weapon_source_error(ability: AbilityDefinition, source: WeaponDefinition) -> StringName:
	var weapon_damage := false
	if ability.execution != null:
		for effect in ability.execution.get_effect_payload():
			var damage := effect.get_damage_execution() if effect != null else null
			if damage != null and damage.use_weapon_damage:
				weapon_damage = true
				break
	if source == null:
		return &"missing_weapon_profile" if weapon_damage else &""
	if not source.get_validation_error().is_empty():
		return &"invalid_weapon_profile"

	var spell := GameplayEffectContext.is_spell_delivery(ability.get_context_tags())
	if not source.is_physical_weapon() and not spell:
		return &"caster_weapon_requires_spell"
	if weapon_damage and (not source.is_physical_weapon() or spell):
		return &"weapon_damage_requires_physical_attack"
	return &""


static func find_for(node: Node) -> AbilitySystem:
	var candidate := node
	while candidate != null:
		if candidate is AbilitySystem:
			return candidate as AbilitySystem
		for child in candidate.get_children():
			if child is AbilitySystem:
				return child as AbilitySystem
		candidate = candidate.get_parent()
	return null
