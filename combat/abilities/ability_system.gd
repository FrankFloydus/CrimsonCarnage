class_name AbilitySystem
extends Node
## Coordinates unlocked abilities, authored execution, resource costs and delivered payloads.

signal ability_started(ability_id: StringName)
signal ability_ended(ability_id: StringName, cancelled: bool)
signal activation_failed(ability_id: StringName, reason: StringName)
signal hit_resolved(result: Dictionary)
## Detached per-cast, delivery, and effect telemetry; target events are emitted only here.
signal combat_event(event: Dictionary)


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
## Abilities granted directly to this actor at startup, usable by direct requests or gameplay events.
@export var granted_abilities: Array[AbilityDefinition] = []
## Effects applied to this actor in order at startup. Retained startup handles survive a combat reset.
@export var startup_effects: Array[GameplayEffectDefinition] = []
## Maps Gameplay Cue tags to optional presentation scenes for this actor.
@export var gameplay_cue_bindings: Array[GameplayCueBinding] = []
## Counted hierarchical tags initially granted to this actor.
@export var initial_tags: PackedStringArray = PackedStringArray()

var tags := GameplayTagSet.new()
var effects: GameplayEffectRuntime
var _startup_effect_handles: Array[int] = []
var _ability_specs: Dictionary[int, GameplayAbilitySpec] = {}
var _active_casts: Dictionary[int, AbilityCast] = {}
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


func _ready() -> void:
	if not is_instance_valid(attributes):
		attributes = get_node_or_null("../Attributes") as ActorAttributes
	if not is_instance_valid(attributes):
		push_warning("AbilitySystem requires an ActorAttributes reference.")
		set_process(false)
		set_physics_process(false)
		return
	attributes.initialize()
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
		effects.clear()
	_startup_effect_handles.clear()
	_attribute_events_ready = false
	_attribute_events_pending = false
	_attribute_event_states.clear()
	_gameplay_events.clear()
	_activation_cleanup_depth -= 1


func advance(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
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
	return GameplayEffectContext.capture(attributes, tags, context_tags)


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
	var eligible: Array[GameplayEffectSpec] = []
	for spec: GameplayEffectSpec in specs:
		if effects.can_apply_spec(spec):
			eligible.append(spec)
	if eligible.is_empty():
		return result
	var hit_context := context.duplicate_for_hit(_weapon_random.randf())
	var roll := accuracy_roll if accuracy_roll >= 0.0 else _accuracy_random.randf()
	result = effects.apply_hit_specs(eligible, hit_context, roll, critical_roll)
	if result["outcome"] == &"invalid":
		return result
	hit_resolved.emit(result)
	var event := hit_context.create_combat_event(&"hit_outcome", attributes)
	event.merge(result, true)
	combat_event.emit(event)
	return result


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


## Grants a distinct instance with a level and optional source. Zero means the grant was invalid.
func grant_ability_spec(
		definition: AbilityDefinition, grant_level: int = 1, source_object: Object = null,
		granting_effect_handle: int = 0, set_by_caller: Dictionary[StringName, float] = {}
) -> int:
	if definition == null or definition.ability_id.is_empty() or definition.execution == null or grant_level < 1:
		return 0
	var spec := GameplayAbilitySpec.new(definition, grant_level, source_object, granting_effect_handle, set_by_caller)
	_ability_specs[spec.handle] = spec
	_replay_current_attribute_event(spec)
	return spec.handle


func get_ability_spec(handle: int) -> GameplayAbilitySpec:
	return _ability_specs.get(handle)


func revoke_ability(ability_id: StringName) -> void:
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
func get_ability_definition(ability_id: StringName) -> AbilityDefinition:
	var spec := _get_ability_spec_for_id(ability_id)
	return spec.definition if spec != null else null


## Reads the current grant's optional runtime weapon profile.
func get_ability_weapon_source(ability_id: StringName) -> WeaponDefinition:
	var spec := _get_ability_spec_for_id(ability_id)
	return spec.get_weapon_source() if spec != null else null


func _get_ability_spec_for_id(ability_id: StringName) -> GameplayAbilitySpec:
	for spec: GameplayAbilitySpec in _ability_specs.values():
		if spec.definition.ability_id == ability_id:
			return spec
	return null


## Captures a compatible granted action without spending resources, rolling, or activating it.
func create_ability_context(ability_id: StringName) -> GameplayEffectContext:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec == null or not spec.definition.get_validation_error().is_empty() \
			or not get_weapon_source_error(spec.definition, spec.get_weapon_source()).is_empty():
		return null
	return AbilityCast.capture_context(self, spec.definition, spec.get_weapon_source())


func get_activation_failure(ability_id: StringName, event_tag: StringName = &"") -> StringName:
	return _get_activation_failure(_get_ability_spec_for_id(ability_id), event_tag)


func get_activation_failure_for_spec(handle: int, event_tag: StringName = &"") -> StringName:
	return _get_activation_failure(get_ability_spec(handle), event_tag)


func _get_activation_failure(spec: GameplayAbilitySpec, event_tag: StringName) -> StringName:
	if not is_instance_valid(attributes) or effects == null:
		return &"missing_attributes"
	if attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
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
	if tags.has_any(definition.blocked_tags):
		return &"blocked_by_tags"
	if not tags.has_all(definition.required_tags):
		return &"missing_required_tags"
	if not definition.execution.get_animation_name().is_empty() \
			and (_animation_cast != null or _animation_step_cast != null):
		return &"animation_in_use"
	var cost_spec: GameplayEffectSpec
	if definition.cost_effect != null:
		var context := AbilityCast.capture_context(self, definition, spec.get_weapon_source())
		cost_spec = effects.make_effect_spec(definition.cost_effect, context)
		cost_spec.level = spec.level
		spec.copy_set_by_caller_to(cost_spec)
	var commit_failure := _get_commit_failure(definition, cost_spec)
	if not commit_failure.is_empty():
		return commit_failure
	return definition.execution.get_validation_error(self)


func try_activate(ability_id: StringName) -> bool:
	return _try_activate_spec(_get_ability_spec_for_id(ability_id), &"", {}, ability_id)


func try_activate_spec(handle: int) -> bool:
	return _try_activate_spec(get_ability_spec(handle))


func _try_activate_spec(
		spec: GameplayAbilitySpec, event_tag: StringName = &"", payload: Dictionary = {},
		requested_id: StringName = &""
) -> bool:
	var definition := spec.definition if spec != null else null
	var ability_id := definition.ability_id if definition != null else requested_id
	var failure := _get_activation_failure(spec, event_tag)
	if not failure.is_empty():
		activation_failed.emit(ability_id, failure)
		var context_tags := definition.ability_tags if definition != null else PackedStringArray()
		var failure_context := create_effect_context(context_tags)
		failure_context.ability_id = ability_id
		if definition != null:
			failure_context.ability_name = definition.display_name
		var event := failure_context.create_combat_event(&"cast_failed", attributes)
		event["reason"] = failure
		combat_event.emit(event)
		return false
	var cast := AbilityCast.new(self, spec)
	cast.trigger_event_tag = event_tag
	cast.trigger_event_payload = payload.duplicate(true)
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
		return false
	if definition.execution.should_commit_on_activation() and not cast.commit():
		cast.cancel()
		return false
	if not _is_active(cast):
		return false
	ability_started.emit(ability_id)
	combat_event.emit(cast.context.create_combat_event(&"cast", attributes))
	if _is_active(cast):
		definition.execution.begin(cast)
	return true


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


## Applies cooldown and cost to the owner after rechecking the active cast's eligibility.
func commit_ability(cast: AbilityCast) -> bool:
	if not _is_active(cast) or cast._committing:
		return false
	if cast.committed:
		return true
	var definition := cast.definition
	if not definition.get_validation_error().is_empty():
		return false
	var cooldown_spec := cast.make_effect_spec(definition.cooldown_effect)
	var cost_spec := cast.make_effect_spec(definition.cost_effect)
	if not _get_commit_failure(definition, cost_spec).is_empty():
		return false
	if (cooldown_spec != null and not effects.can_apply_spec(cooldown_spec)) \
			or (cost_spec != null and not effects.can_apply_spec(cost_spec)):
		return false
	cast._committing = true
	var cooldown_handle := effects.apply_effect_spec(cooldown_spec) if cooldown_spec != null else 0
	var cooldown_applied := cooldown_spec == null or effects.has_retained_effect(cooldown_handle)
	var cost_paid := cooldown_applied and _is_active(cast) and (cost_spec == null \
			or (_can_pay_cost(cost_spec) and effects.apply_effect_spec(cost_spec) > 0))
	cast._committing = false
	cast.committed = cost_paid
	if not cost_paid and cooldown_handle > 0:
		effects.remove_effect(cooldown_handle)
	return cost_paid


func _get_commit_failure(definition: AbilityDefinition, cost_spec: GameplayEffectSpec) -> StringName:
	if definition.cooldown_effect != null and tags.has_any(definition.cooldown_effect.granted_tags):
		return &"on_cooldown"
	if cost_spec != null and not _can_pay_cost(cost_spec):
		return &"insufficient_resource"
	return &""


func _can_pay_cost(spec: GameplayEffectSpec) -> bool:
	var costs: Dictionary[int, float] = {}
	var context_tags := spec.settings.get_context_tags(spec.context.ability_tags)
	for modifier in spec.modifiers:
		if not modifier.matches_context(context_tags):
			continue
		var output := modifier.copy()
		output.value = spec.get_set_by_caller_magnitude(output.set_by_caller_tag, output.value)
		var debit := -output.get_magnitude(attributes, context_tags)
		if not is_finite(debit) or debit < 0.0:
			return false
		costs[modifier.attribute] = costs.get(modifier.attribute, 0.0) + debit
	for attribute in costs:
		if not can_spend_current(attribute, costs[attribute]):
			return false
	return true


## Checks an exact current-pool debit, allowing only floating-point roundoff at the boundary.
func can_spend_current(attribute: int, amount: float) -> bool:
	return is_instance_valid(attributes) and CombatAttributes.is_current_resource(attribute) \
			and is_finite(amount) and amount >= 0.0 \
			and attributes.get_value(attribute) + amount * 1.0e-9 >= amount


## Commits one affordable current-pool debit. A rejected amount leaves the pool untouched.
func try_spend_current(attribute: int, amount: float) -> bool:
	if not can_spend_current(attribute, amount):
		return false
	attributes.modify_current(attribute, -amount)
	return true


func get_cooldown_remaining(ability_id: StringName) -> float:
	var spec := _get_ability_spec_for_id(ability_id)
	return get_cooldown_remaining_for_spec(spec.handle) if spec != null else 0.0


func get_cooldown_remaining_for_spec(handle: int) -> float:
	var spec := get_ability_spec(handle)
	if spec == null or spec.definition.cooldown_effect == null or effects == null:
		return 0.0
	return effects.get_remaining_for_granted_tags(spec.definition.cooldown_effect.granted_tags)


## Lists the first grant of each ID, in grant order, for ID-based input and UI.
func get_granted_ability_definitions() -> Array[AbilityDefinition]:
	var definitions: Dictionary[StringName, AbilityDefinition] = {}
	for spec: GameplayAbilitySpec in _ability_specs.values():
		if not definitions.has(spec.definition.ability_id):
			definitions[spec.definition.ability_id] = spec.definition
	return definitions.values()


func get_granted_ability_specs() -> Array[GameplayAbilitySpec]:
	return _ability_specs.values()


## Resolves the active instance of the first grant for this ID.
func get_active_cast(ability_id: StringName) -> AbilityCast:
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
func release_ability(ability_id: StringName) -> void:
	var spec := _get_ability_spec_for_id(ability_id)
	if spec != null:
		release_ability_spec(spec.handle)


func release_ability_spec(handle: int) -> void:
	var cast := get_active_cast_for_spec(handle)
	if _is_active(cast):
		cast._dispatch_task_input_release()
	if _is_active(cast):
		cast.definition.execution.input_released(cast)


## Cancels a named activation without disturbing unrelated casts.
func cancel_ability(ability_id: StringName) -> void:
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


func complete_cast(cast: AbilityCast, cancelled: bool) -> void:
	if not _is_active(cast):
		return
	var ability_id := cast.context.ability_id
	cast.finished = true
	_active_casts.erase(cast.grant_spec.handle)
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
	ability_ended.emit(ability_id, cancelled)


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


func _on_tags_changed(_tag: StringName, _present: bool) -> void:
	for cast: AbilityCast in _active_casts.values():
		if _is_active(cast) and tags.has_any(cast.definition.interruption_tags):
			complete_cast(cast, true)


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
		clear_transient_effects()
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
			if effect != null and effect.use_weapon_damage:
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
