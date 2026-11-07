extends SceneTree
## Checks authored delivery, pulse scheduling, conditions and cast ownership.

const HEALTH := CombatAttributes.Id.HEALTH
const MANA := CombatAttributes.Id.MANA
const PULSE := &"ability.channel_tick"
const MARK := &"State.Test.Mark"
const FIREBALL_PATH := "res://examples/fireball/fireball.tres"

var _arena: Node3D
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_inspector_visibility()
	_test_saved_fireball_targeting_visibility()
	await _test_beam_pulse_cost()
	await _test_detached_projectile_channel()
	_test_aura_occupancy()
	await _test_trap_arming()
	_test_chain_hops()
	_test_conditions_and_owned_cleanup()
	print("Ability v2 delivery checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(1 if _failures > 0 else 0)


func _test_inspector_visibility() -> void:
	var execution := PhasedAbilityExecution.new()
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.cast_duration = -5.0
	execution.animation_fallback_seconds = -2.0
	_check_fields(execution, [&"delivery"],
			[&"cast_duration", &"channel_period", &"animation_name", &"animation_fallback_seconds"])
	_check(execution.get_authoring_error().is_empty(), "Immediate ignores hidden timing fields")
	execution.cast_mode = PhasedAbilityExecution.CastMode.DELAY
	_check_fields(execution, [&"cast_duration"], [&"channel_period", &"animation_name"])
	_check(execution.get_authoring_error() == &"invalid_cast_timing",
			"Switching to Delay restores the previously stored duration and its validation")
	execution.cast_mode = PhasedAbilityExecution.CastMode.CHANNEL
	_check_fields(execution, [&"cast_duration", &"channel_period"], [&"animation_name"])
	execution.cast_mode = PhasedAbilityExecution.CastMode.ANIMATION
	_check_fields(execution, [&"animation_name", &"release_event", &"animation_fallback_seconds"],
			[&"cast_duration", &"channel_period"])
	execution.cast_mode = PhasedAbilityExecution.CastMode.SUSTAINED
	_check_fields(execution, [], [&"delivery", &"cast_duration", &"animation_name"])
	execution.delivery = null
	_check(execution.get_authoring_error().is_empty(), "Sustained requires no automatic delivery")

	var delivery := AbilityDeliveryDefinition.new()
	_check_fields(delivery, [&"kind"], [&"projectile_scene", &"lifetime", &"chain_hops", &"detach_on_cancel"])
	delivery.kind = AbilityDeliveryDefinition.Kind.PROJECTILE
	_check_fields(delivery, [&"projectile_scene", &"spawn_offset", &"detach_on_cancel"],
			[&"lifetime", &"period", &"chain_hops"])
	delivery.kind = AbilityDeliveryDefinition.Kind.FIELD
	delivery.area_targeting = _area()
	delivery.arm_delay = 10.0
	_check_fields(delivery, [&"area_targeting", &"lifetime", &"period", &"maximum_surface_slope"],
			[&"projectile_scene", &"arm_delay"])
	_check(delivery.get_validation_error().is_empty(), "A field ignores the hidden trap arm delay")
	delivery.kind = AbilityDeliveryDefinition.Kind.TRAP
	_check_fields(delivery, [&"arm_delay", &"maximum_surface_slope"], [&"period"])
	_check(delivery.get_validation_error() == &"invalid_delivery_timing",
			"Switching to Trap restores its stored arm delay")
	delivery.kind = AbilityDeliveryDefinition.Kind.AURA
	_check_fields(delivery, [&"period"], [&"maximum_surface_slope", &"arm_delay"])
	delivery.kind = AbilityDeliveryDefinition.Kind.CHAIN
	_check_fields(delivery, [&"chain_hops", &"chain_targeting", &"stop_chain_on_failed_hit"],
			[&"area_targeting", &"detach_on_cancel"])
	delivery.chain_hops = 0
	_check_fields(delivery, [&"chain_hops"], [&"chain_targeting", &"stop_chain_on_failed_hit"])

	var targeting := AbilityTargetingDefinition.new()
	var refreshes: Array[bool] = []
	targeting.property_list_changed.connect(func() -> void: refreshes.append(true))
	targeting.up_axis = Vector3.ZERO
	_check_fields(targeting, [&"origin"],
			[&"max_range", &"radius", &"half_height", &"collision_mask", &"require_line_of_sight"])
	_check(targeting.get_validation_error().is_empty(), "Self ignores hidden geometry")
	targeting.shape = AbilityTargetingDefinition.Shape.DISK
	_check_fields(targeting, [&"radius", &"half_height", &"up_axis", &"max_targets", &"require_line_of_sight"],
			[&"max_range", &"angle_degrees", &"half_extents", &"allow_world_surfaces"])
	_check(targeting.get_validation_error() == &"invalid_targeting_axes",
			"Disk reuses and validates its stored up axis")
	targeting.shape = AbilityTargetingDefinition.Shape.BOX
	_check_fields(targeting, [&"half_extents"], [&"radius", &"half_height", &"up_axis"])
	targeting.shape = AbilityTargetingDefinition.Shape.RAY
	_check_fields(targeting, [&"max_range", &"allow_world_surfaces"],
			[&"radius", &"max_targets", &"require_line_of_sight"])
	_check(refreshes.size() == 3, "Targeting mode switches notify the Inspector to refresh")

	var condition := AbilityConditionDefinition.new()
	_check_fields(condition, [&"tag"], [&"resource", &"threshold", &"fraction_of_maximum"])
	condition.kind = AbilityConditionDefinition.Kind.RESOURCE_AT_LEAST
	_check_fields(condition, [&"resource", &"threshold", &"fraction_of_maximum"], [&"tag"])
	condition.kind = AbilityConditionDefinition.Kind.IS_ALIVE
	_check_fields(condition, [&"subject", &"kind"], [&"tag", &"resource", &"threshold"])

	var payload := _damage_action()
	payload.owned_until_cast_ends = true
	_check_fields(payload, [], [&"owned_until_cast_ends"])
	_check(payload.get_validation_error().is_empty(), "A delivered hit ignores direct effect ownership")
	payload.application = AbilityApplyEffectsAction.Application.DIRECT_EFFECT
	_check_fields(payload, [&"owned_until_cast_ends"], [])
	_check(payload.get_validation_error() == &"owned_effect_requires_independent_retention",
			"Direct effect mode restores and validates its stored ownership flag")

	var restore := AbilityRestoreResourceAction.new()
	_check_fields(restore, [], [&"healing_profile"])
	restore.resource = AmountDefinition.Pool.HEALTH
	_check_fields(restore, [&"healing_profile"], [])

	var phase := _phase(&"ability.cast_started", AbilityFinishAction.new())
	phase.synchronous_gameplay_event = true
	_check_fields(phase, [&"max_fires"], [&"synchronous_gameplay_event"])
	_check(not phase.runs_synchronously(), "A stored gameplay dispatch option does not affect a lifecycle phase")
	phase.event_key = &"Event.Fixture"
	_check_fields(phase, [&"synchronous_gameplay_event"], [])
	_check(phase.runs_synchronously(), "A gameplay event phase restores its stored synchronous option")
	phase.run_once_per_execution = true
	_check_fields(phase, [], [&"max_fires"])


func _check_fields(
		resource: Resource, visible: Array[StringName], hidden: Array[StringName]
) -> void:
	var usage_by_name: Dictionary[StringName, int] = {}
	for property: Dictionary in resource.get_property_list():
		usage_by_name[StringName(property.name)] = int(property.usage)
	for name: StringName in visible:
		_check(usage_by_name.get(name, 0) & PROPERTY_USAGE_EDITOR != 0,
				"%s exposes %s in this mode" % [resource.get_script().get_global_name(), name])
	for name: StringName in hidden:
		var usage := int(usage_by_name.get(name, 0))
		_check(usage & PROPERTY_USAGE_EDITOR == 0 and usage & PROPERTY_USAGE_STORAGE != 0,
				"%s hides %s without removing storage" % [resource.get_script().get_global_name(), name])


func _test_saved_fireball_targeting_visibility() -> void:
	var ability := ResourceLoader.load(
			FIREBALL_PATH, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as AbilityDefinition
	var execution := ability.execution as PhasedAbilityExecution if ability != null else null
	var targeting := execution.targeting if execution != null else null
	_check(targeting != null and targeting.shape == AbilityTargetingDefinition.Shape.POINT,
			"Saved Fireball uses an embedded Point targeting resource")
	if targeting == null:
		return
	_check(targeting.get_script().is_tool(), "The saved targeting runs property validation in the editor")
	_check_fields(targeting, [&"origin", &"max_range", &"collision_mask"],
			[&"radius", &"half_height", &"up_axis", &"half_extents", &"max_targets"])

	var refreshes: Array[bool] = []
	targeting.property_list_changed.connect(func() -> void: refreshes.append(true))
	targeting.shape = AbilityTargetingDefinition.Shape.DISK
	_check_fields(targeting, [&"radius", &"half_height", &"up_axis"], [&"max_range"])
	targeting.radius = 7.25
	targeting.half_height = 3.5
	targeting.shape = AbilityTargetingDefinition.Shape.POINT
	_check_fields(targeting, [&"max_range"], [&"radius", &"half_height"])
	_check(refreshes.size() == 2, "Both mode switches refresh the saved Fireball target's property list")

	var save_path := "user://ability_v2_targeting_%d_%d.tres" % [OS.get_process_id(), Time.get_ticks_usec()]
	var saved := ResourceSaver.save(ability, save_path)
	_check(saved == OK, "Save the Fireball resource and its embedded Point targeting to a temporary file")
	if saved != OK:
		return
	var reloaded := ResourceLoader.load(
			save_path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as AbilityDefinition
	var removed := DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	_check(removed == OK, "Remove the temporary targeting roundtrip file")
	var reloaded_execution := reloaded.execution as PhasedAbilityExecution if reloaded != null else null
	var reloaded_targeting := reloaded_execution.targeting if reloaded_execution != null else null
	_check(reloaded_targeting != null and reloaded_targeting != targeting \
			and reloaded_targeting.shape == AbilityTargetingDefinition.Shape.POINT,
			"Roundtrip loads a fresh embedded Point targeting resource")
	if reloaded_targeting == null:
		return
	_check_fields(reloaded_targeting, [&"max_range"], [&"radius", &"half_height"])
	reloaded_targeting.shape = AbilityTargetingDefinition.Shape.DISK
	_check_fields(reloaded_targeting, [&"radius", &"half_height"], [&"max_range"])
	_near(reloaded_targeting.radius, 7.25, "Saving Point preserves the hidden radius")
	_near(reloaded_targeting.half_height, 3.5, "Saving Point preserves the hidden half height")


func _test_beam_pulse_cost() -> void:
	_create_arena()
	var source := _actor(Vector3.ZERO, &"ally")
	var target := _actor(Vector3(0.0, 0.0, -5.0), &"enemy", true)
	source.attributes.set_base_value(MANA, 5.0)
	await physics_frame
	await physics_frame
	var execution := _execution(AbilityDeliveryDefinition.Kind.BEAM,
			AbilityTargetingDefinition.Shape.RAY)
	execution.cast_mode = PhasedAbilityExecution.CastMode.CHANNEL
	execution.cast_duration = 0.75
	execution.channel_period = 0.25
	var spend := AbilitySpendResourceAction.new()
	spend.amount = AmountDefinition.new()
	spend.amount.fixed_amount = 2.0
	var cost := _phase(PULSE, spend)
	cost.failure_policy = AbilityPhaseDefinition.FailurePolicy.CANCEL_CAST
	execution.phases = [cost, _phase(&"delivery.impact", _damage_action())]
	var cast := _activate(source, execution, &"test_beam")
	if cast != null:
		execution.physics_advance(cast, 0.24)
		_near(target.attributes.get_value(HEALTH), 100.0, "No pulse before its first deadline")
		execution.physics_advance(cast, 0.51)
		_near(target.attributes.get_value(HEALTH), 80.0, "Each paid pulse resolves one hit")
		_near(source.attributes.get_value(MANA), 1.0, "Only the two affordable pulses spend Mana")
		_check(cast.finished and source.get_active_cast(&"test_beam") == null,
				"Resource exhaustion cancels the channel before its unpaid pulse")
	_free_arena()


func _test_detached_projectile_channel() -> void:
	_create_arena()
	var source := _actor(Vector3.ZERO, &"ally")
	var target := _actor(Vector3(0.0, 0.0, -5.0), &"enemy", true)
	await physics_frame
	await physics_frame
	var execution := _execution(AbilityDeliveryDefinition.Kind.PROJECTILE,
			AbilityTargetingDefinition.Shape.POINT)
	execution.cast_mode = PhasedAbilityExecution.CastMode.CHANNEL
	execution.cast_duration = 1.0
	execution.channel_period = 0.25
	execution.delivery.projectile_scene = _projectile_scene()
	execution.targeting.allegiance = AbilityTargetingDefinition.Allegiance.HOSTILE
	execution.phases = [_phase(&"delivery.impact", _damage_action())]
	var timings: Array[int] = []
	var attacks: Array[int] = []
	target.combat_event.connect(func(event: Dictionary) -> void:
		if event.get("type") == &"damage":
			timings.append(event["timing"])
			attacks.append(event["attack_execution_id"])
	)
	var cast := _activate(source, execution, &"test_missiles")
	if cast != null:
		execution.physics_advance(cast, 0.5)
		_check(_deliveries(AbilityProjectile).size() == 2, "Each due pulse spawns its own projectile")
		var source_body := source.actor_body
		source_body.free()
		for frame: int in 15:
			await physics_frame
		_near(target.attributes.get_value(HEALTH), 80.0,
				"Released projectiles retain hostile eligibility and payloads after the caster despawns")
		_check(timings == [CombatOutcomeContext.Timing.CHANNEL_PULSE,
				CombatOutcomeContext.Timing.CHANNEL_PULSE] and attacks.size() == 2 \
				and attacks[0] != attacks[1],
				"Each detached projectile retains channel timing and its own attack identity")
	_free_arena()


func _test_aura_occupancy() -> void:
	_create_arena()
	var source := _actor(Vector3.ZERO, &"ally")
	var target := _actor(Vector3.RIGHT, &"enemy")
	var execution := _execution(AbilityDeliveryDefinition.Kind.AURA,
			AbilityTargetingDefinition.Shape.SELF)
	execution.delivery.area_targeting = _area()
	execution.delivery.lifetime = 1.0
	execution.delivery.period = 0.25
	execution.delivery.arm_delay = 10.0
	var entry := _phase(&"target.entered", _damage_action())
	entry.run_once_per_target = true
	execution.phases = [entry, _phase(&"area.tick", _damage_action())]
	var cast := _activate(source, execution, &"test_aura")
	if cast != null:
		execution.physics_advance(cast, 0.01)
		var deliveries := _deliveries(AbilityAreaDelivery)
		_check(deliveries.size() == 1 and cast.finished, "Aura owns its lifetime after activation")
		if not deliveries.is_empty():
			var area := deliveries[0] as AbilityAreaDelivery
			area._physics_process(0.25)
			_near(target.attributes.get_value(HEALTH), 80.0, "An initial occupant enters and receives the first tick")
			source.actor_body.position = Vector3(10.0, 0.0, 0.0)
			area._physics_process(0.25)
			_near(target.attributes.get_value(HEALTH), 80.0, "An aura moves with its caster and drops old occupants")
			source.actor_body.position = Vector3.ZERO
			area._physics_process(0.25)
			_near(target.attributes.get_value(HEALTH), 70.0,
					"Reentry cannot repeat an action limited to once per target")
			area._physics_process(0.25)
			_check(area.is_queued_for_deletion(), "Aura expiration owns its scene cleanup")
			_near(target.attributes.get_value(HEALTH), 70.0, "Aura has no accidental terminal tick")
	_free_arena()


func _test_trap_arming() -> void:
	_create_arena()
	var source := _actor(Vector3(0.0, 3.0, 0.0), &"ally")
	source.actor_body.rotation.x = -PI / 2.0
	var target := _actor(Vector3.RIGHT, &"enemy")
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	_arena.add_child(floor_body)
	await physics_frame
	await physics_frame
	var execution := _execution(AbilityDeliveryDefinition.Kind.TRAP,
			AbilityTargetingDefinition.Shape.POINT)
	execution.delivery.area_targeting = _area()
	execution.delivery.arm_delay = 0.25
	execution.delivery.lifetime = 1.0
	execution.phases = [_phase(&"delivery.impact", _damage_action())]
	var cast := _activate(source, execution, &"test_trap")
	if cast != null:
		execution.physics_advance(cast, 0.01)
		var deliveries := _deliveries(AbilityAreaDelivery)
		_check(deliveries.size() == 1 and cast.finished, "World-surface targeting places a saved trap recipe")
		if not deliveries.is_empty():
			var trap := deliveries[0] as AbilityAreaDelivery
			trap._physics_process(0.20)
			_near(target.attributes.get_value(HEALTH), 100.0, "Occupants do not detonate an unarmed trap")
			trap._physics_process(0.05)
			trap._physics_process(0.50)
			_near(target.attributes.get_value(HEALTH), 90.0, "An armed trap detonates once")
			_check(trap.is_queued_for_deletion(), "Detonation releases the trap node")
	var ability := _ability(execution, &"test_trap_placement")
	ability.interruption_policy = AbilityInterruptionPolicy.new()
	ability.interruption_policy.cost_timing = AbilityInterruptionPolicy.CommitTiming.ON_RELEASE
	var cost := AbilityResourceCost.new()
	cost.amount = AmountDefinition.fixed(8.0)
	ability.resource_costs = [cost]
	source.actor_body.rotation.x = 0.0
	_check(source.grant_ability(ability) and source.try_activate(ability.ability_id),
			"Placement validation runs at the release query")
	cast = source.get_active_cast(ability.ability_id)
	if cast != null:
		execution.physics_advance(cast, 0.01)
		_check(cast.finished and not cast.released, "Aiming at open space cannot place the trap")
		_near(source.attributes.get_value(MANA), 50.0, "A rejected placement preserves release-based Mana")
	_free_arena()


func _test_chain_hops() -> void:
	_create_arena()
	var source := _actor(Vector3.ZERO, &"ally")
	var first := _actor(Vector3.RIGHT, &"enemy")
	var second := _actor(Vector3.RIGHT * 2.0, &"enemy")
	var third := _actor(Vector3.RIGHT * 3.5, &"enemy")
	var outside := _actor(Vector3.RIGHT * 6.0, &"enemy")
	var execution := _execution(AbilityDeliveryDefinition.Kind.CHAIN,
			AbilityTargetingDefinition.Shape.SINGLE)
	execution.delivery.chain_hops = 2
	execution.delivery.chain_targeting = _area()
	execution.delivery.chain_targeting.shape = AbilityTargetingDefinition.Shape.SPHERE
	execution.delivery.chain_targeting.radius = 2.0
	execution.delivery.chain_targeting.max_targets = 1
	execution.phases = [_phase(&"delivery.impact", _damage_action())]
	var ability := _ability(execution, &"test_chain")
	var targets: Array[int] = []
	var attacks: Array[int] = []
	for actor: AbilitySystem in [first, second, third, outside]:
		actor.combat_event.connect(func(event: Dictionary) -> void:
			if event.get("type") == &"damage":
				targets.append(event["target_id"])
				attacks.append(event["attack_execution_id"])
		)
	_check(source.grant_ability(ability) and source.try_activate_target(ability.ability_id, first),
			"Chain starts at its explicit target")
	var cast := source.get_active_cast(ability.ability_id)
	if cast != null:
		execution.physics_advance(cast, 0.01)
		_check(targets == [first.attributes.get_instance_id(), second.attributes.get_instance_id(),
				third.attributes.get_instance_id()],
				"Chain selects the nearest unvisited actor before applying the target cap")
		_check(attacks.size() == 3 and attacks[0] == attacks[1] and attacks[1] == attacks[2],
				"Chain contacts share one attack identity")
		_near(outside.attributes.get_value(HEALTH), 100.0, "Chain obeys the hop limit and range")
	_free_arena()


func _test_conditions_and_owned_cleanup() -> void:
	_create_arena()
	var source := _actor(Vector3.ZERO, &"ally")
	var target := _actor(Vector3.RIGHT, &"enemy")
	source.attributes.set_base_value(MANA, 20.0)
	var execution := _execution(AbilityDeliveryDefinition.Kind.DIRECT,
			AbilityTargetingDefinition.Shape.SINGLE)
	execution.cast_mode = PhasedAbilityExecution.CastMode.HOLD_RELEASE
	var condition := AbilityConditionDefinition.new()
	condition.subject = AbilityConditionDefinition.Subject.TARGET
	condition.kind = AbilityConditionDefinition.Kind.RESOURCE_BELOW
	condition.fraction_of_maximum = true
	condition.threshold = 0.5
	execution.activation_conditions = [condition]
	var marker := GameplayEffectDefinition.new()
	marker.timing = GameplayEffectDefinition.Timing.INFINITE
	marker.granted_tags = PackedStringArray([String(MARK)])
	var own := AbilityApplyEffectsAction.new()
	own.application = AbilityApplyEffectsAction.Application.DIRECT_EFFECT
	own.owned_until_cast_ends = true
	own.effects = [marker]
	execution.phases = [_phase(&"ability.cast_started", own), _phase(&"delivery.impact", _damage_action())]
	var ability := _ability(execution, &"test_execute")
	ability.interruption_policy = AbilityInterruptionPolicy.new()
	ability.interruption_policy.cost_timing = AbilityInterruptionPolicy.CommitTiming.ON_RELEASE
	var cost := AbilityResourceCost.new()
	cost.amount = AmountDefinition.fixed(5.0)
	ability.resource_costs = [cost]
	_check(source.grant_ability(ability), "Grant condition-gated ability")
	_check(source.get_target_activation_failure(ability.ability_id, target) == &"activation_condition_failed",
			"Target threshold rejects activation before commitment")
	target.attributes.set_base_value(HEALTH, 40.0)
	_check(source.try_activate_target(ability.ability_id, target), "A target below the threshold can be selected")
	_check(source.tags.has_tag(MARK), "Cast applies its independently retained effect at windup")
	var cast := source.get_active_cast(ability.ability_id)
	if cast != null:
		target.attributes.set_base_value(HEALTH, 60.0)
		source.release_ability(ability.ability_id)
		execution.physics_advance(cast, 0.01)
		_near(source.attributes.get_value(MANA), 20.0, "Release rechecks target threshold before spending")
		_near(target.attributes.get_value(HEALTH), 60.0, "Rejected release does not deliver damage")
		_check(cast.finished and not source.tags.has_tag(MARK),
				"Rejection releases the cast's retained effect handle")
	_free_arena()


func _create_arena() -> void:
	_arena = Node3D.new()
	root.add_child(_arena)
	current_scene = _arena


func _free_arena() -> void:
	current_scene = null
	_arena.free()


func _actor(point: Vector3, faction: StringName, collidable: bool = false) -> AbilitySystem:
	var body := StaticBody3D.new()
	body.position = point
	if collidable:
		var hurtbox := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 0.5
		hurtbox.shape = shape
		body.add_child(hurtbox)
	var attributes := ActorAttributes.new()
	var system := AbilitySystem.new()
	system.attributes = attributes
	system.actor_body = body
	system.cast_origin = body
	system.aim_origin = body
	system.faction_id = faction
	system.hostile_factions = [&"enemy"]
	body.add_child(attributes)
	body.add_child(system)
	_arena.add_child(body)
	system.set_process(false)
	system.set_physics_process(false)
	attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 100.0)
	attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 50.0)
	attributes.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 1000.0)
	attributes.restore_resources()
	return system


func _execution(kind: int, shape: int) -> PhasedAbilityExecution:
	var execution := PhasedAbilityExecution.new()
	execution.targeting = AbilityTargetingDefinition.new()
	execution.targeting.shape = shape
	execution.targeting.origin = AbilityTargetingDefinition.Origin.AIM
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.delivery.kind = kind
	return execution


func _phase(event: StringName, action: AbilityActionDefinition) -> AbilityPhaseDefinition:
	var phase := AbilityPhaseDefinition.new()
	phase.event_key = event
	phase.actions = [action]
	return phase


func _damage_action() -> AbilityApplyEffectsAction:
	var effect := GameplayEffectDefinition.new()
	var damage := GameplayEffectDamageExecution.new()
	damage.amount = AmountDefinition.fixed(10.0)
	effect.executions = [damage]
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	var action := AbilityApplyEffectsAction.new()
	action.effects = [effect]
	return action


func _ability(execution: PhasedAbilityExecution, id: StringName) -> AbilityDefinition:
	var ability := AbilityDefinition.new()
	ability.ability_id = id
	ability.ability_tags = PackedStringArray(["Ability.Spell"])
	ability.execution = execution
	return ability


func _activate(
		source: AbilitySystem, execution: PhasedAbilityExecution, id: StringName
) -> AbilityCast:
	_check(source.grant_ability(_ability(execution, id)), "Grant %s" % id)
	_check(source.try_activate(id), "Activate %s" % id)
	return source.get_active_cast(id)


func _projectile_scene() -> PackedScene:
	var scene := PackedScene.new()
	var projectile := AbilityProjectile.new()
	projectile.speed = 60.0
	projectile.lifetime = 1.0
	var packed := scene.pack(projectile)
	projectile.free()
	_check(packed == OK, "Create an in-memory projectile scene")
	return scene


func _area() -> AbilityTargetingDefinition:
	var targeting := AbilityTargetingDefinition.new()
	targeting.origin = AbilityTargetingDefinition.Origin.CONTACT
	targeting.shape = AbilityTargetingDefinition.Shape.DISK
	targeting.radius = 3.0
	targeting.half_height = 2.0
	targeting.allegiance = AbilityTargetingDefinition.Allegiance.HOSTILE
	return targeting


func _deliveries(script: Script) -> Array[Node]:
	var result: Array[Node] = []
	for child: Node in _arena.get_children():
		if child.get_script() == script:
			result.append(child)
	return result


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_equal_approx(actual, expected), "%s (expected %s, got %s)" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
