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
## Counted hierarchical tags initially granted to this actor.
@export var initial_tags: PackedStringArray = PackedStringArray()

var tags := GameplayTagSet.new()
var effects: GameplayEffectRuntime
var _abilities: Dictionary[StringName, AbilityDefinition] = {}
var _ability_weapon_sources: Dictionary[StringName, WeaponDefinition] = {}
var _cooldowns: Dictionary[StringName, float] = {}
var _clock: float = 0.0
var _active_casts: Dictionary[StringName, AbilityCast] = {}
var _animation_cast: AbilityCast
var _animation_step_cast: AbilityCast
var _animation_name: StringName
var _reset_animation_when_ended: bool = false
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
	attributes.bind_regeneration_tags(tags)
	effects = GameplayEffectRuntime.new(attributes, tags, _critical_random)
	effects.combat_event.connect(_on_effect_combat_event)
	effects.retained_effects_changed.connect(_flush_attribute_events)
	for tag in initial_tags:
		tags.add_tag(StringName(tag))
	tags.changed.connect(_on_tags_changed)
	attributes.attribute_changed.connect(_on_attribute_changed)
	for definition in granted_abilities:
		grant_ability(definition)
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
	_attribute_events_ready = false
	_attribute_events_pending = false
	_attribute_event_states.clear()
	_gameplay_events.clear()
	_activation_cleanup_depth -= 1


func advance(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	_clock += delta
	if effects != null:
		effects.advance(delta)
	for cast: AbilityCast in _active_casts.values():
		if _is_active(cast):
			cast.elapsed += delta
			cast.definition.execution.advance(cast, delta)


func create_effect_context(
		context_tags: PackedStringArray = PackedStringArray()
) -> GameplayEffectContext:
	return GameplayEffectContext.capture(attributes, tags, context_tags)


## A delivery shares Accuracy and, on a damaging success, one critical result across its payload.
## Optional nonnegative fractional rolls are deterministic test/replay inputs, not authoring flags.
func receive_hit(
		context: GameplayEffectContext,
		definitions: Array[GameplayEffectDefinition], accuracy_roll: float = -1.0,
		critical_roll: float = -1.0
) -> Dictionary:
	var result := {"outcome": &"invalid", "applied_effects": 0}
	if context == null or effects == null or not is_instance_valid(attributes) \
			or attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0 \
			or not is_finite(accuracy_roll) or not is_finite(critical_roll):
		return result
	var eligible: Array[GameplayEffectDefinition] = []
	for definition in definitions:
		if effects.can_apply_effect(definition):
			eligible.append(definition)
	if eligible.is_empty():
		return result
	var hit_context := context.duplicate_for_hit(_weapon_random.randf())
	var roll := accuracy_roll if accuracy_roll >= 0.0 else _accuracy_random.randf()
	result = effects.apply_hit_payload(eligible, hit_context, roll, critical_roll)
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


## Registers an action with an optional runtime weapon profile. Revoke before replacing a grant.
func grant_ability(definition: AbilityDefinition, weapon_source: WeaponDefinition = null) -> bool:
	if definition == null or definition.ability_id.is_empty() or definition.execution == null:
		return false
	var id := definition.ability_id
	if _abilities.has(id):
		return _abilities[id] == definition and get_ability_weapon_source(id) == weapon_source
	_abilities[id] = definition
	if weapon_source != null:
		_ability_weapon_sources[id] = weapon_source
	_replay_current_attribute_event(definition)
	return true


func revoke_ability(ability_id: StringName) -> void:
	_abilities.erase(ability_id)
	_ability_weapon_sources.erase(ability_id)
	cancel_ability(ability_id)


## Reads the current runtime grant so previews and AI use the actual ability selected.
func get_ability_definition(ability_id: StringName) -> AbilityDefinition:
	return _abilities.get(ability_id)


## Reads the current grant's optional runtime weapon profile.
func get_ability_weapon_source(ability_id: StringName) -> WeaponDefinition:
	return _ability_weapon_sources.get(ability_id)


## Captures a compatible granted action without spending resources, rolling, or activating it.
func create_ability_context(ability_id: StringName) -> GameplayEffectContext:
	var definition := get_ability_definition(ability_id)
	var source := get_ability_weapon_source(ability_id)
	if definition == null or not definition.get_validation_error().is_empty() \
			or not get_weapon_source_error(definition, source).is_empty():
		return null
	return AbilityCast.capture_context(self, definition, source)


func get_activation_failure(ability_id: StringName, event_tag: StringName = &"") -> StringName:
	if not is_instance_valid(attributes) or effects == null:
		return &"missing_attributes"
	if attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return &"actor_dead"
	if not is_inside_tree() or _activation_cleanup_depth > 0:
		return &"activation_unavailable"
	if not _abilities.has(ability_id):
		return &"ability_not_granted"
	var definition: AbilityDefinition = _abilities[ability_id]
	if not definition.activation_event_tag.is_empty() \
			and not GameplayTagSet.matches(event_tag, definition.activation_event_tag):
		return &"requires_gameplay_event"
	var definition_error := definition.get_validation_error()
	if not definition_error.is_empty():
		return definition_error
	var source_error := get_weapon_source_error(definition, get_ability_weapon_source(ability_id))
	if not source_error.is_empty():
		return source_error
	if _active_casts.has(ability_id):
		return &"action_in_progress"
	if tags.has_any(definition.blocked_tags):
		return &"blocked_by_tags"
	if not tags.has_all(definition.required_tags):
		return &"missing_required_tags"
	if not definition.execution.get_animation_name().is_empty() \
			and (_animation_cast != null or _animation_step_cast != null):
		return &"animation_in_use"
	if get_cooldown_remaining(ability_id) > 0.0:
		return &"on_cooldown"
	if definition.cost_attribute != CombatAttributes.Id.NONE \
			and not can_spend_current(definition.cost_attribute, get_resource_cost(definition)):
		return &"insufficient_resource"
	return definition.execution.get_validation_error(self)


func try_activate(ability_id: StringName) -> bool:
	return _try_activate(ability_id)


func _try_activate(
		ability_id: StringName, event_tag: StringName = &"", payload: Dictionary = {}
) -> bool:
	var failure := get_activation_failure(ability_id, event_tag)
	var definition: AbilityDefinition = _abilities.get(ability_id)
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
	var cast := AbilityCast.new(self, definition, get_ability_weapon_source(ability_id))
	cast.trigger_event_tag = event_tag
	cast.trigger_event_payload = payload.duplicate(true)
	_active_casts[ability_id] = cast
	if not definition.execution.get_animation_name().is_empty():
		_animation_cast = cast
	# All authored conflicts must be visible before tags or resource changes notify listeners.
	cast.granted_tags = definition.activation_tags.duplicate()
	tags.add_tags(cast.granted_tags)
	if not _is_active(cast):
		return false
	var cost_attribute := definition.cost_attribute
	var cost := get_resource_cost(definition)
	if cost_attribute != CombatAttributes.Id.NONE and not can_spend_current(cost_attribute, cost):
		cast.cancel()
		return false
	_cooldowns[ability_id] = _clock + maxf(0.0, definition.cooldown)
	if cost_attribute != CombatAttributes.Id.NONE:
		try_spend_current(cost_attribute, cost)
	if not _is_active(cast):
		return false
	ability_started.emit(ability_id)
	combat_event.emit(cast.context.create_combat_event(&"cast", attributes))
	if _is_active(cast):
		definition.execution.begin(cast)
	return true


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
	var grants := _abilities.values()
	var active_at_dispatch := _active_casts.duplicate()
	for cast: AbilityCast in active_at_dispatch.values():
		if _is_active(cast):
			cast.definition.execution.handle_gameplay_event(cast, event_tag, payload.duplicate(true))
	for definition: AbilityDefinition in grants:
		var id := definition.ability_id
		if _abilities.get(id) == definition and not _active_casts.has(id) \
				and not active_at_dispatch.has(id) \
				and GameplayTagSet.matches(event_tag, definition.activation_event_tag):
			_try_activate(id, event_tag, payload)


func _on_effect_combat_event(event: Dictionary) -> void:
	combat_event.emit(event)


func get_resource_cost(definition: AbilityDefinition) -> float:
	return maxf(0.0, definition.cost_amount)


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
	return maxf(0.0, float(_cooldowns.get(ability_id, 0.0)) - _clock)


## Lists the definitions currently registered, in grant order.
func get_granted_ability_definitions() -> Array[AbilityDefinition]:
	return _abilities.values()


## Resolves the active instance for the named ability.
func get_active_cast(ability_id: StringName) -> AbilityCast:
	return _active_casts.get(ability_id)


## Returns the cast that owns the shared animation player.
func get_animation_cast() -> AbilityCast:
	return _animation_cast


## Starts authored playback for the activation that reserved this animation player.
func play_cast_animation(cast: AbilityCast, speed: float, reset_on_end: bool = false) -> bool:
	if cast != _animation_cast or not _is_active(cast) or not _animation_name.is_empty() \
			or not is_instance_valid(animation_player) or not is_finite(speed) or speed <= 0.0:
		return false
	var clip_name := cast.definition.execution.get_animation_name()
	if not animation_player.has_animation(clip_name):
		return false
	animation_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation_player.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	if not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)
	_animation_name = clip_name
	_reset_animation_when_ended = reset_on_end
	animation_player.play(clip_name, -1.0, speed)
	return true


## Advances one playback frame. Remaining callbacks from a cancelled frame keep its old owner.
func advance_animation(delta: float) -> void:
	if _animation_step_cast != null or not _is_active(_animation_cast) \
			or _animation_name.is_empty() or not is_instance_valid(animation_player) \
			or not is_finite(delta) or delta <= 0.0:
		return
	_animation_step_cast = _animation_cast
	animation_player.advance(delta)
	if _animation_cast == null:
		_stop_cast_animation()
	_animation_step_cast = null


func handle_animation_event(event_name: StringName) -> void:
	var cast := _animation_step_cast if _animation_step_cast != null else _animation_cast
	if cast == _animation_cast and _is_active(cast) and not _animation_name.is_empty():
		cast.definition.execution.handle_event(cast, event_name)


## Cancels the activation owning the animation player.
func cancel_animation() -> void:
	complete_cast(_animation_cast, true)


## Forwards an input release or equivalent AI request to the named activation only.
func release_ability(ability_id: StringName) -> void:
	var cast: AbilityCast = _active_casts.get(ability_id)
	if cast != null:
		cast.definition.execution.input_released(cast)


## Cancels a named activation without disturbing unrelated casts.
func cancel_ability(ability_id: StringName) -> void:
	var cast: AbilityCast = _active_casts.get(ability_id)
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
	_active_casts.erase(ability_id)
	if _animation_cast == cast:
		if _animation_step_cast == null:
			_stop_cast_animation()
		_animation_cast = null
	cast.definition.execution.end(cast, cancelled)
	for tag in cast.granted_tags:
		tags.remove_tag(StringName(tag))
	ability_ended.emit(ability_id, cancelled)


func _is_active(cast: AbilityCast) -> bool:
	return cast != null and not cast.finished and _active_casts.get(cast.context.ability_id) == cast


func _on_animation_finished(animation_name: StringName) -> void:
	var cast := _animation_step_cast
	if cast == _animation_cast and _is_active(cast) and _animation_name == animation_name:
		cast.finish()


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
		if effects != null:
			effects.clear()
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


func _replay_current_attribute_event(definition: AbilityDefinition) -> void:
	if not _attribute_events_ready or _owns_dead_tag or _activation_cleanup_depth > 0 \
			or effects.is_clearing() or definition.activation_event_tag.is_empty():
		return
	# A newly granted listener can join a condition already in progress. This is not a broadcast.
	for rule: AttributeGameplayEventRule in _attribute_event_states:
		if _attribute_event_states[rule] and rule.matches(attributes) \
				and GameplayTagSet.matches(rule.entered_event, definition.activation_event_tag):
			_try_activate(definition.ability_id, rule.entered_event, _attribute_event_payload(rule))
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
