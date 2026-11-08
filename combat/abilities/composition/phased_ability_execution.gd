@tool
class_name PhasedAbilityExecution
extends AbilityExecution
## Runs authored phase recipes with the ordinary actor's grant, commit and animation APIs.

## Determines which simulation event drives release or completion.
enum CastMode {
	## Release on the next physics step.
	IMMEDIATE,
	## Release on the first physics step at or after the configured windup.
	DELAY,
	## Release at the authored method marker or configured fallback and allow animation recovery.
	ANIMATION,
	## Compatibility for saved Hold Release casts. New casts use the Hold + release gesture and Immediate timing.
	HOLD_RELEASE,
	## Schedule periodic deliveries until the duration ends or the cast is cancelled.
	CHANNEL,
	## Use the active channel interruption phase until an authored phase or domain service ends the cast.
	SUSTAINED,
}

## Internal dispatch path that controls matching and physics-query availability.
enum PhaseRoute {
	## Match an ability, delivery or animation event by exact key.
	LIFECYCLE,
	## Match an actor gameplay tag immediately, allowing only self-directed target queries.
	SYNCHRONOUS_GAMEPLAY,
	## Match an actor gameplay tag from the next physics step, allowing spatial queries.
	QUEUED_GAMEPLAY,
}

## Immediate releases on the next physics step. Delay waits for Cast Duration.
## Animation uses a method marker or its fallback. An ability with the Hold + release gesture starts its timing on button-up.
## Channel repeats at Channel Period. Sustained stays active until a phase or domain service ends it.
@export var cast_mode: CastMode = CastMode.IMMEDIATE:
	set(value):
		cast_mode = value
		notify_property_list_changed()
## Windup for Delay, or maximum duration for Channel, in simulation seconds.
@export_range(0.0, 120.0, 0.01, "or_greater") var cast_duration: float = 0.0
## Seconds between channel deliveries. The first pulse occurs after this interval.
@export_range(0.01, 60.0, 0.01, "or_greater") var channel_period: float = 1.0
## Animation whose method track controls release and whose end completes recovery.
@export var animation_name: StringName = &""
## Method event used as the authoritative release point in Animation mode.
@export var release_event: StringName = &"Event.Combat.ProjectileRelease"
## Seconds before release when the actor has no valid Animation clip. Negative requires the clip.
@export_range(-1.0, 120.0, 0.01, "or_greater") var animation_fallback_seconds: float = -1.0
## Initial actor/world selection. An empty slot defaults to Self for direct delivery.
@export var targeting: AbilityTargetingDefinition
## Caster and explicit Single-target conditions checked before reservation and rechecked at release.
@export var activation_conditions: Array[AbilityConditionDefinition] = []
## Delivery used at release or for each channel pulse. Sustained casts do not release.
@export var delivery: AbilityDeliveryDefinition
## Ordered event listeners with reusable conditions and actions.
@export var phases: Array[AbilityPhaseDefinition] = []


func _validate_property(property: Dictionary) -> void:
	var visible := true
	match property.name:
		&"cast_duration":
			visible = _uses_cast_duration()
		&"channel_period":
			visible = cast_mode == CastMode.CHANNEL
		&"animation_name", &"release_event", &"animation_fallback_seconds":
			visible = cast_mode == CastMode.ANIMATION
		&"delivery":
			visible = cast_mode != CastMode.SUSTAINED
	if not visible:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


## Validates reusable resource wiring without an actor scene or simulation query.
func get_authoring_error() -> StringName:
	if cast_mode < CastMode.IMMEDIATE or cast_mode > CastMode.SUSTAINED:
		return &"invalid_cast_timing"
	if _uses_cast_duration() and (not is_finite(cast_duration) or cast_duration < 0.0):
		return &"invalid_cast_timing"
	if cast_mode == CastMode.ANIMATION:
		if not is_finite(animation_fallback_seconds) or animation_fallback_seconds < -1.0:
			return &"invalid_cast_timing"
		if (animation_name.is_empty() or release_event.is_empty()) and animation_fallback_seconds < 0.0:
			return &"missing_cast_animation"
	if cast_mode == CastMode.CHANNEL and (not is_finite(channel_period) \
			or channel_period < 0.001 or cast_duration < channel_period \
			or cast_duration / channel_period > 10000.0):
		return &"invalid_channel_timing"
	if cast_mode != CastMode.SUSTAINED:
		if delivery == null:
			return &"missing_delivery"
		var delivery_error := delivery.get_validation_error()
		if not delivery_error.is_empty():
			return delivery_error
	var targeting_error := _get_targeting_error()
	if not targeting_error.is_empty():
		return targeting_error
	for condition: AbilityConditionDefinition in activation_conditions:
		if condition == null or not condition.get_validation_error().is_empty():
			return &"invalid_activation_condition"
		if condition.subject == AbilityConditionDefinition.Subject.TARGET \
				and (targeting == null or targeting.shape != AbilityTargetingDefinition.Shape.SINGLE):
			return &"activation_condition_requires_selected_target"
	for phase: AbilityPhaseDefinition in phases:
		if phase == null:
			return &"missing_phase"
		var error := phase.get_validation_error()
		if not error.is_empty():
			return error
		if phase.event_key in [&"ability.requested", &"ability.cast_started",
				&"ability.committed", &"ability.input_released", &"ability.cancelled", &"ability.finished"] \
				and phase.targeting != null \
				and phase.targeting.shape != AbilityTargetingDefinition.Shape.SELF:
			return &"phase_requires_physics_targeting"
	return &""


func get_validation_error(system: AbilitySystem) -> StringName:
	var error := get_authoring_error()
	if not error.is_empty():
		return error
	if cast_mode != CastMode.SUSTAINED and delivery.kind == AbilityDeliveryDefinition.Kind.PROJECTILE \
			and (not is_instance_valid(system.cast_origin) or not system.cast_origin.is_inside_tree()):
		return &"missing_cast_origin"
	if cast_mode == CastMode.ANIMATION and _get_animation(system) == null \
			and animation_fallback_seconds < 0.0:
		return &"missing_valid_cast_animation"
	for phase: AbilityPhaseDefinition in phases:
		if phase.event_key != &"ability.cast_started":
			continue
		for action: AbilityActionDefinition in phase.actions:
			error = action.get_activation_error(system)
			if not error.is_empty():
				return error
	return &""


func get_target_validation_error(system: AbilitySystem, target: AbilitySystem) -> StringName:
	for condition: AbilityConditionDefinition in activation_conditions:
		var subject := system if condition.subject == AbilityConditionDefinition.Subject.CASTER else target
		if not condition.matches_actor(subject):
			return &"activation_condition_failed"
	if targeting == null or targeting.shape != AbilityTargetingDefinition.Shape.SINGLE:
		return &""
	if not targeting.accepts(system, target) or not target.is_inside_tree():
		return &"invalid_selected_target"
	var origin := AbilityTargetingDefinition.actor_spatial(system)
	var recipient := AbilityTargetingDefinition.actor_spatial(target)
	match targeting.origin:
		AbilityTargetingDefinition.Origin.AIM:
			origin = system.aim_origin if is_instance_valid(system.aim_origin) else system.cast_origin
		AbilityTargetingDefinition.Origin.SOCKET:
			origin = system.cast_origin
	if not is_instance_valid(origin) or not is_instance_valid(recipient) \
			or not origin.is_inside_tree() or not recipient.is_inside_tree() \
			or origin.get_world_3d() != recipient.get_world_3d():
		return &"invalid_target_space"
	if origin.global_position.distance_squared_to(recipient.global_position) \
			> targeting.max_range * targeting.max_range:
		return &"selected_target_out_of_range"
	return &""


func request_start(cast: AbilityCast) -> bool:
	var run := PhaseRun.new()
	cast.data[&"phases"] = run
	run.effect_context = cast.context.duplicate_for_hit(0.5)
	var delivery_kind := &"none" if cast_mode == CastMode.SUSTAINED else delivery.get_outcome_kind()
	run.effect_context.outcome_context = cast.context.outcome_context.with_delivery(delivery_kind)
	_dispatch(cast, &"ability.requested", _default_targets(cast), cast.trigger_event_payload)
	return not cast.finished


func begin(cast: AbilityCast) -> void:
	var run := _get_run(cast)
	if cast_mode == CastMode.SUSTAINED:
		cast.phase = AbilityCast.Phase.CHANNEL
	if cast.committed:
		_dispatch(cast, &"ability.committed", _default_targets(cast))
	_dispatch(cast, &"ability.cast_started", _default_targets(cast))
	if not cast.finished and cast_mode == CastMode.ANIMATION and not _waits_for_input_release(cast):
		_start_release_animation(cast, run)


func _start_release_animation(cast: AbilityCast, run: PhaseRun) -> void:
	var animation := _get_animation(cast.get_system())
	if animation == null:
		run.uses_animation_fallback = true
		return
	cast.data[&"release_time"] = AbilityAnimationCast.marker_time(animation, release_event)
	var animation_task := AbilityTaskPlayAnimationAndWait.new(
			animation_name, cast.get_animation_playback_rate(animation.length), true)
	animation_task.completed.connect(_on_animation_completed.bind(cast))
	animation_task.interrupted.connect(cast.cancel)
	cast.start_task(animation_task)


func physics_advance(cast: AbilityCast, delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0 or cast.finished:
		return
	var run := _get_run(cast)
	for handle: AbilityPhaseContext.OwnedHandle in run.owned_handles.duplicate():
		handle.physics_advance(cast, delta)
		if cast.finished:
			return
	var queued_events := run.pending_events
	run.pending_events = []
	for event: Dictionary in queued_events:
		_dispatch(cast, event["tag"], _default_targets(cast), event["payload"], false, null,
				PhaseRoute.QUEUED_GAMEPLAY)
		if cast.finished:
			return
	if _waits_for_input_release(cast) and not run.release_requested:
		return
	run.elapsed += delta
	match cast_mode:
		CastMode.IMMEDIATE, CastMode.HOLD_RELEASE:
			_release(cast)
		CastMode.DELAY:
			if run.elapsed >= cast_duration:
				_release(cast)
		CastMode.ANIMATION:
			if run.uses_animation_fallback and run.elapsed >= animation_fallback_seconds:
				_release(cast)
		CastMode.CHANNEL:
			_advance_channel(cast, run)


func input_released(cast: AbilityCast) -> void:
	var run := _get_run(cast)
	if run == null:
		return
	var hold_release := _waits_for_input_release(cast)
	if hold_release:
		if run.release_requested:
			return
		run.release_requested = true
	_dispatch(cast, &"ability.input_released", _default_targets(cast))
	if not cast.finished and hold_release and cast_mode == CastMode.ANIMATION:
		_start_release_animation(cast, run)


func _waits_for_input_release(cast: AbilityCast) -> bool:
	return cast_mode == CastMode.HOLD_RELEASE or (cast.trigger_event_tag.is_empty() \
			and cast.definition.get_input_gesture() == AbilityDefinition.InputGesture.HOLD_RELEASE)


func advance(cast: AbilityCast, delta: float) -> void:
	var run := _get_run(cast)
	if run == null:
		return
	for handle: AbilityPhaseContext.OwnedHandle in run.owned_handles.duplicate():
		handle.advance(cast, delta)
		if cast.finished:
			return


func handle_event(cast: AbilityCast, event_name: StringName) -> void:
	if cast_mode == CastMode.ANIMATION and event_name == release_event:
		_release(cast)
	elif not event_name.is_empty():
		_dispatch(cast, event_name, _default_targets(cast))


func handle_gameplay_event(cast: AbilityCast, event_tag: StringName, payload: Dictionary) -> void:
	if event_tag.is_empty() or (cast_mode == CastMode.ANIMATION and event_tag == release_event):
		return
	var run := _get_run(cast)
	if run == null:
		return
	var synchronous := false
	var queue := false
	for phase: AbilityPhaseDefinition in phases:
		if not phase.is_lifecycle_event() and GameplayTagSet.matches(event_tag, phase.event_key):
			synchronous = synchronous or phase.runs_synchronously()
			queue = queue or not phase.runs_synchronously()
	if synchronous:
		_dispatch(cast, event_tag, _default_targets(cast), payload, false, null,
				PhaseRoute.SYNCHRONOUS_GAMEPLAY)
	if queue and not cast.finished and run.pending_events.size() < 64:
		run.pending_events.append({"tag": event_tag, "payload": payload.duplicate(true)})
	elif queue and not cast.finished:
		_trace(cast, &"cast_phase", event_tag, _default_targets(cast), &"pending_event_limit")


func end(cast: AbilityCast, cancelled: bool) -> void:
	var run := _get_run(cast)
	if run == null:
		return
	for handle: AbilityPhaseContext.OwnedHandle in run.owned_handles:
		handle.remove()
	run.owned_handles.clear()
	if cancelled and not run.delivery_nodes.is_empty() and not delivery.detach_on_cancel:
		run.delivery_stopped = true
		for reference: WeakRef in run.delivery_nodes:
			var launched: Node = reference.get_ref()
			if is_instance_valid(launched):
				launched.stop()
		run.delivery_nodes.clear()
	_dispatch(cast, &"ability.cancelled" if cancelled else &"ability.finished",
			_default_targets(cast), {}, true)


func get_animation_name() -> StringName:
	return animation_name if cast_mode == CastMode.ANIMATION else &""


func get_windup_progress(cast: AbilityCast) -> float:
	return AbilityAnimationCast.windup_progress(cast, animation_name) \
			if cast_mode == CastMode.ANIMATION else -1.0


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	var result: Array[GameplayEffectDefinition] = []
	for phase: AbilityPhaseDefinition in phases:
		if phase == null:
			continue
		for action: AbilityActionDefinition in phase.actions:
			if action == null:
				continue
			for effect: GameplayEffectDefinition in action.get_effect_payload():
				if not result.has(effect):
					result.append(effect)
	return result


func _get_targeting_error() -> StringName:
	if targeting != null:
		if targeting.origin == AbilityTargetingDefinition.Origin.CONTACT:
			return &"initial_targeting_requires_actor_origin"
		var error := targeting.get_validation_error()
		if not error.is_empty():
			return error
	if cast_mode == CastMode.SUSTAINED:
		return &""
	if delivery.kind in [AbilityDeliveryDefinition.Kind.HITSCAN, AbilityDeliveryDefinition.Kind.BEAM] \
			and (targeting == null or targeting.shape != AbilityTargetingDefinition.Shape.RAY):
		return &"delivery_requires_ray"
	if delivery.kind == AbilityDeliveryDefinition.Kind.PROJECTILE and (targeting == null \
			or targeting.shape not in [AbilityTargetingDefinition.Shape.POINT,
					AbilityTargetingDefinition.Shape.RAY, AbilityTargetingDefinition.Shape.SINGLE]):
		return &"projectile_requires_aim_targeting"
	if delivery.kind == AbilityDeliveryDefinition.Kind.AREA_BURST and (targeting == null \
			or targeting.shape < AbilityTargetingDefinition.Shape.SPHERE):
		return &"burst_requires_area_targeting"
	if delivery.kind in [AbilityDeliveryDefinition.Kind.FIELD, AbilityDeliveryDefinition.Kind.TRAP] \
			and (targeting == null or targeting.shape != AbilityTargetingDefinition.Shape.POINT):
		return &"placement_requires_point_targeting"
	if cast_mode == CastMode.CHANNEL and delivery.is_persistent():
		return &"channel_cannot_place_repeated_fields"
	if delivery.kind == AbilityDeliveryDefinition.Kind.BEAM and cast_mode != CastMode.CHANNEL:
		return &"beam_requires_channel"
	if delivery.kind == AbilityDeliveryDefinition.Kind.CHAIN and (targeting == null \
			or targeting.shape not in [AbilityTargetingDefinition.Shape.RAY, AbilityTargetingDefinition.Shape.SINGLE]):
		return &"chain_requires_initial_actor"
	return &""


func _uses_cast_duration() -> bool:
	return cast_mode == CastMode.DELAY or cast_mode == CastMode.CHANNEL


func _get_animation(system: AbilitySystem) -> Animation:
	if not is_instance_valid(system) or not is_instance_valid(system.animation_player) \
			or not system.animation_player.has_animation(animation_name):
		return null
	var clip := system.animation_player.get_animation(animation_name)
	if clip.loop_mode != Animation.LOOP_NONE or AbilityAnimationCast.marker_time(clip, release_event) < 0.0:
		return null
	return clip


func _on_animation_completed(cast: AbilityCast) -> void:
	if cast.released:
		cast.finish()
	else:
		cast.cancel()


func _release(cast: AbilityCast) -> void:
	if cast.released or cast.finished:
		return
	var run := _get_run(cast)
	if not get_target_validation_error(cast.get_system(), cast.target_request).is_empty():
		cast.cancel()
		return
	var targets := _select_initial_targets(cast)
	if targets.failure.is_empty():
		targets.failure = delivery.get_placement_error(targets)
	_trace(cast, &"target_batch", &"ability.released", targets)
	if cast.finished:
		return
	if not targets.failure.is_empty() or (targeting != null \
			and targeting.shape == AbilityTargetingDefinition.Shape.SINGLE and targets.contacts.is_empty()):
		cast.cancel()
		return
	cast.phase = AbilityCast.Phase.RELEASE
	var was_committed := cast.committed
	if not cast.commit():
		cast.cancel()
		return
	if not was_committed and not cast.finished:
		_dispatch(cast, &"ability.committed", targets)
	if cast.finished:
		return
	cast.released = true
	if cast.finished:
		return
	_prepare_payloads(cast, run)
	_dispatch(cast, &"ability.cast_completed", targets)
	_dispatch(cast, &"ability.released", targets)
	if cast.finished:
		return
	if cast_mode == CastMode.CHANNEL:
		cast.phase = AbilityCast.Phase.CHANNEL
		return
	_deliver(cast, targets)
	if cast.finished:
		return
	if cast_mode == CastMode.ANIMATION and not run.uses_animation_fallback:
		cast.phase = AbilityCast.Phase.RECOVERY
	else:
		cast.finish()


func _advance_channel(cast: AbilityCast, run: PhaseRun) -> void:
	if not cast.released:
		_release(cast)
	var deadline := run.pulse_index * channel_period
	var horizon := minf(run.elapsed, cast_duration)
	while cast.released and not cast.finished and (deadline < horizon or is_equal_approx(deadline, horizon)):
		run.pulse_index += 1
		deadline = run.pulse_index * channel_period
		var targets := _select_initial_targets(cast)
		_trace(cast, &"target_batch", &"ability.channel_tick", targets)
		if cast.finished:
			return
		if not targets.failure.is_empty() or (delivery.kind == AbilityDeliveryDefinition.Kind.BEAM \
				and targets.contacts.is_empty()):
			cast.cancel()
			return
		var pulse := run.effect_context.duplicate_for_hit(0.5)
		pulse.outcome_context = pulse.outcome_context.with_timing(
				CombatOutcomeContext.Timing.CHANNEL_PULSE).for_attack()
		_dispatch(cast, &"ability.channel_tick", targets, {}, false, pulse)
		if not cast.finished:
			_deliver(cast, targets, pulse)
	if not cast.finished and run.elapsed >= cast_duration:
		cast.finish()


func _select_initial_targets(cast: AbilityCast) -> AbilityTargetSet:
	return targeting.select(cast) if targeting != null else _default_targets(cast)


func _default_targets(cast: AbilityCast) -> AbilityTargetSet:
	var result := AbilityTargetSet.new()
	var source := cast.get_system()
	var actor := AbilityTargetingDefinition.actor_spatial(source)
	if is_instance_valid(actor) and actor.is_inside_tree():
		result.transform = actor.global_transform.orthonormalized()
		result.query_space = weakref(actor)
	if is_instance_valid(source) and source.is_inside_tree():
		result.source_id = source.get_instance_id()
		result.source_faction = source.faction_id
		result.hostile_factions.assign(source.hostile_factions)
		result.contacts.append(AbilityTargetContact.new(result.transform.origin, source))
	return result


func _prepare_payloads(cast: AbilityCast, run: PhaseRun) -> void:
	var effects := get_effect_payload()
	cast.context.prime_effects(effects)
	run.effect_context = cast.context.duplicate_for_hit(0.5)
	run.effect_context.outcome_context = run.effect_context.outcome_context.with_delivery(
			delivery.get_outcome_kind()).for_attack()
	for phase: AbilityPhaseDefinition in phases:
		for action: AbilityActionDefinition in phase.actions:
			var specs: Array[GameplayEffectSpec] = []
			for effect: GameplayEffectDefinition in action.get_effect_payload():
				var spec := cast.make_effect_spec(effect)
				if spec != null:
					specs.append(spec)
			if not specs.is_empty():
				run.prepared_payloads[action.get_instance_id()] = specs


func _deliver(
		cast: AbilityCast, targets: AbilityTargetSet, provenance: GameplayEffectContext = null
) -> void:
	match delivery.kind:
		AbilityDeliveryDefinition.Kind.PROJECTILE:
			_spawn_projectile(cast, targets, provenance)
		AbilityDeliveryDefinition.Kind.FIELD, AbilityDeliveryDefinition.Kind.AURA, \
				AbilityDeliveryDefinition.Kind.TRAP:
			_spawn_area(cast, targets)
		AbilityDeliveryDefinition.Kind.NONE:
			return
		AbilityDeliveryDefinition.Kind.CHAIN:
			_deliver_chain(cast, targets, provenance)
		_:
			_impact(cast, targets, provenance)


func _deliver_chain(
		cast: AbilityCast, targets: AbilityTargetSet, provenance: GameplayEffectContext
) -> void:
	var visited: Dictionary[int, bool] = {}
	var confirmed: Dictionary[int, bool] = {}
	var next := targets
	var context := provenance if provenance != null else _get_run(cast).effect_context
	CombatOutcomeDispatcher.begin_batch()
	for hop: int in delivery.chain_hops + 1:
		if cast.finished or next.contacts.is_empty() or not next.failure.is_empty():
			break
		var contact := next.contacts[0]
		if contact.get_target() == null:
			break
		visited[contact.actor_id] = true
		var selected := next.with_contact(contact)
		selected.transform.origin = contact.position
		var phase := _dispatch(cast, &"delivery.impact", selected, {}, false, context)
		if phase != null:
			confirmed.merge(phase.confirmed_targets)
		if cast.finished or hop == delivery.chain_hops \
				or (delivery.stop_chain_on_failed_hit and not confirmed.has(contact.actor_id)):
			break
		next = delivery.chain_targeting.select_from(cast.get_system(), selected, null, 0, visited)
		_trace(cast, &"target_batch", &"delivery.chain_hop", next)
	_publish_batch_complete(context, confirmed.size())
	CombatOutcomeDispatcher.end_batch()


func _spawn_projectile(
		cast: AbilityCast, targets: AbilityTargetSet, provenance: GameplayEffectContext
) -> void:
	var system := cast.get_system()
	if not is_instance_valid(system.cast_origin) or targets.contacts.is_empty():
		return
	var contact := targets.contacts[0]
	var muzzle := system.cast_origin.global_transform.orthonormalized()
	var transform := targets.transform
	transform.origin = muzzle * delivery.spawn_offset
	var direction := contact.position - transform.origin
	var use_forward := targeting.shape == AbilityTargetingDefinition.Shape.POINT \
			and targeting.max_range == 0.0
	if not use_forward and direction.dot(-transform.basis.z) > 0.0:
		var up := transform.basis.y
		if absf(direction.normalized().dot(up)) > 0.999:
			up = transform.basis.x
		transform = transform.looking_at(contact.position, up)
	elif not use_forward and contact.has_geometry:
		_trace(cast, &"cast_phase", &"delivery.blocked", targets, &"muzzle_occluded")
		return
	var projectile := delivery.projectile_scene.instantiate() as AbilityProjectile
	if projectile == null:
		cast.cancel()
		return
	var run := _get_run(cast)
	var world := _delivery_parent(system)
	world.add_child(projectile)
	projectile.global_transform = transform
	_track_delivery(run, projectile)
	var launch := AbilityTargetSet.new()
	launch.copy_origin(targets)
	launch.transform = transform
	launch.query_space = run.delivery_nodes.back()
	cast.data[&"projectile"] = launch.query_space
	projectile.contact_reached.connect(_on_projectile_contact.bind(cast, provenance, launch))
	projectile.expired.connect(_on_projectile_expired.bind(cast, provenance, launch))
	projectile.launch(AbilityTargetingDefinition.actor_body(system))
	_dispatch(cast, &"delivery.spawned", targets, {}, false, provenance)


func _spawn_area(cast: AbilityCast, targets: AbilityTargetSet) -> void:
	var system := cast.get_system()
	var area := AbilityAreaDelivery.new()
	_delivery_parent(system).add_child(area)
	area.phase_reached.connect(_on_area_phase.bind(cast))
	area.start(delivery, cast, targets)
	_track_delivery(_get_run(cast), area)
	_dispatch(cast, &"delivery.spawned", targets)


func _track_delivery(run: PhaseRun, instance: Node) -> void:
	for index in range(run.delivery_nodes.size() - 1, -1, -1):
		if run.delivery_nodes[index].get_ref() == null:
			run.delivery_nodes.remove_at(index)
	run.delivery_nodes.append(weakref(instance))


func _delivery_parent(system: AbilitySystem) -> Node:
	var tree := system.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


func _on_projectile_contact(
		collider: Node, point: Vector3, normal: Vector3,
		cast: AbilityCast, provenance: GameplayEffectContext, launch: AbilityTargetSet
) -> void:
	var target := AbilitySystem.find_for(collider)
	var source := cast.get_system()
	if not targeting.accepts(source, target, launch):
		target = null
	var targets := _point_targets(point, launch)
	targets.contacts.append(AbilityTargetContact.new(point, target, normal, true))
	_impact(cast, targets, provenance)


func _on_projectile_expired(
		point: Vector3, cast: AbilityCast, provenance: GameplayEffectContext, launch: AbilityTargetSet
) -> void:
	_dispatch(cast, &"delivery.expired", _point_targets(point, launch), {}, true, provenance)


func _on_area_phase(event: StringName, targets: AbilityTargetSet, cast: AbilityCast) -> void:
	if event == &"delivery.impact":
		_impact(cast, targets)
		return
	var provenance := _get_run(cast).effect_context.duplicate_for_hit(0.5)
	if event == &"area.tick":
		provenance.outcome_context = provenance.outcome_context.with_timing(
				CombatOutcomeContext.Timing.PERIODIC).for_attack()
	_dispatch(cast, event, targets, {}, true, provenance)


func _point_targets(point: Vector3, launch: AbilityTargetSet) -> AbilityTargetSet:
	var result := AbilityTargetSet.new()
	result.copy_origin(launch)
	result.transform.origin = point
	return result


func _impact(
		cast: AbilityCast, targets: AbilityTargetSet, provenance: GameplayEffectContext = null
) -> void:
	if _get_run(cast).delivery_stopped:
		return
	CombatOutcomeDispatcher.begin_batch()
	var context := _dispatch(cast, &"delivery.impact", targets, {}, true, provenance)
	if context != null and (delivery.kind == AbilityDeliveryDefinition.Kind.AREA_BURST \
			or context.confirmed_targets.size() > 1):
		_publish_batch_complete(context.effect_context, context.confirmed_targets.size())
	CombatOutcomeDispatcher.end_batch()


func _publish_batch_complete(context: GameplayEffectContext, target_count: int) -> void:
	var data := context.create_combat_event(&"batch_complete", null)
	data["unique_target_count"] = target_count
	CombatOutcomeDispatcher.publish(context.outcome_context, data)


func _dispatch(
		cast: AbilityCast, event: StringName, targets: AbilityTargetSet,
		payload: Dictionary = {}, allow_finished: bool = false,
		provenance: GameplayEffectContext = null, route: PhaseRoute = PhaseRoute.LIFECYCLE
) -> AbilityPhaseContext:
	var run := _get_run(cast)
	if run == null or (cast.finished and not allow_finished):
		return null
	var context := AbilityPhaseContext.new(cast, event, run.prepared_payloads,
			provenance if provenance != null else run.effect_context)
	context.owned_handles = run.owned_handles
	context.event_payload = payload.duplicate(true)
	var was_finished := cast.finished
	_trace(cast, &"cast_phase", event, targets)
	if cast.finished and not was_finished:
		return context
	for phase: AbilityPhaseDefinition in phases:
		if not _matches_event(phase, event, route):
			continue
		_run_phase(run, phase, context, targets, was_finished)
		if cast.finished and not was_finished:
			break
	return context


func _matches_event(phase: AbilityPhaseDefinition, event: StringName, route: PhaseRoute) -> bool:
	if route == PhaseRoute.LIFECYCLE:
		return phase.event_key == event and not phase.runs_synchronously()
	return not phase.is_lifecycle_event() \
			and phase.runs_synchronously() == (route == PhaseRoute.SYNCHRONOUS_GAMEPLAY) \
			and GameplayTagSet.matches(event, phase.event_key)


func _run_phase(
		run: PhaseRun, phase: AbilityPhaseDefinition, context: AbilityPhaseContext,
		inherited: AbilityTargetSet, was_finished: bool
) -> void:
	var phase_id := phase.get_instance_id()
	var count := int(run.phase_counts.get(phase_id, 0))
	if (phase.run_once_per_execution and count > 0) or (phase.max_fires > 0 and count >= phase.max_fires):
		return
	for condition: AbilityConditionDefinition in phase.conditions:
		if condition.subject == AbilityConditionDefinition.Subject.CASTER and not condition.matches(context):
			return
	var targets := phase.targeting.select(context.cast, inherited) if phase.targeting != null else inherited
	if phase.targeting != null:
		_trace(context.cast, &"target_batch", phase.event_key, targets)
		if context.cast.finished and not was_finished:
			return
	if not targets.failure.is_empty():
		if phase.failure_policy == AbilityPhaseDefinition.FailurePolicy.CANCEL_CAST:
			context.cast.cancel()
		return
	var seen: Dictionary = run.phase_targets.get(phase_id, {})
	targets = _filter_targets(phase, context, targets, seen)
	if phase.run_once_per_target and targets.contacts.is_empty():
		return
	run.phase_counts[phase_id] = count + 1
	if phase.run_once_per_target:
		run.phase_targets[phase_id] = seen
	for action: AbilityActionDefinition in phase.actions:
		var result := action.execute(context, targets)
		if context.cast.finished and not was_finished:
			return
		if result < 0:
			if phase.failure_policy == AbilityPhaseDefinition.FailurePolicy.CANCEL_CAST:
				context.cast.cancel()
			if phase.failure_policy != AbilityPhaseDefinition.FailurePolicy.CONTINUE:
				return
		if result > 0 and phase.execution_mode == AbilityPhaseDefinition.ExecutionMode.FIRST_SUCCESS:
			return


func _filter_targets(
		phase: AbilityPhaseDefinition, context: AbilityPhaseContext,
		targets: AbilityTargetSet, seen: Dictionary
) -> AbilityTargetSet:
	var result := AbilityTargetSet.new()
	result.copy_origin(targets)
	for contact: AbilityTargetContact in targets.contacts:
		if phase.run_once_per_target and (contact.actor_id == 0 or seen.has(contact.actor_id)):
			continue
		var accepted := true
		for condition: AbilityConditionDefinition in phase.conditions:
			if condition.subject == AbilityConditionDefinition.Subject.TARGET \
					and not condition.matches(context, contact.get_target()):
				accepted = false
				break
		if accepted:
			result.contacts.append(contact)
			if phase.run_once_per_target:
				seen[contact.actor_id] = true
	return result


func _get_run(cast: AbilityCast) -> PhaseRun:
	return cast.data.get(&"phases") as PhaseRun


func _trace(
		cast: AbilityCast, event_type: StringName, phase_key: StringName,
		targets: AbilityTargetSet, reason: StringName = &""
) -> void:
	var system := cast.get_system()
	if not is_instance_valid(system):
		return
	var event := cast.context.create_combat_event(event_type, system.attributes)
	event["phase_key"] = phase_key
	event["target_count"] = targets.contacts.size()
	event["reason"] = reason if not reason.is_empty() else targets.failure
	system.combat_event.emit(event)


class PhaseRun extends RefCounted:
	var elapsed: float = 0.0
	var pulse_index: int = 1
	var release_requested: bool = false
	var uses_animation_fallback: bool = false
	var delivery_stopped: bool = false
	var delivery_nodes: Array[WeakRef] = []
	var owned_handles: Array[AbilityPhaseContext.OwnedHandle] = []
	var effect_context: GameplayEffectContext
	var prepared_payloads: Dictionary = {}
	var phase_counts: Dictionary[int, int] = {}
	var phase_targets: Dictionary[int, Dictionary] = {}
	var pending_events: Array[Dictionary] = []
