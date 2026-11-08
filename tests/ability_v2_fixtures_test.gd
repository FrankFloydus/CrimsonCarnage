extends SceneTree
## Validates saved recipes separately from deterministic combat tests with test-owned tuning.

const BLOOD_LASH_PATH := "res://tests/fixtures/ability_v2/blood_lash.tres"
const CRIMSON_BOLT_PATH := "res://tests/fixtures/ability_v2/crimson_bolt.tres"
const CRIMSON_PROJECTILE_PATH := "res://tests/fixtures/ability_v2/crimson_bolt_projectile.tscn"
const HEALTH := CombatAttributes.Id.HEALTH
const MANA := CombatAttributes.Id.MANA
const MOVEMENT_SPEED := CombatAttributes.Id.MOVEMENT_SPEED
const CRIMSON_PERIODIC_ID := 242

var _arena: Node3D
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_saved_assets()
	_test_validator_diagnostics()
	await _test_blood_lash_targeting()
	await _test_blood_lash_reactions()
	await _test_blood_lash_rejections()
	await _test_crimson_bolt_schedule()
	await _test_crimson_bolt_actual_damage()
	await _test_crimson_bolt_refresh()
	print("Ability v2 fixture checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_saved_assets() -> void:
	var paths := PackedStringArray([BLOOD_LASH_PATH, CRIMSON_BOLT_PATH])
	var issues := CombatResourceValidator.validate_paths(paths)
	_check(issues.is_empty(), "Saved recipes validate: %s" % "\n".join(issues))
	var lash := load(BLOOD_LASH_PATH) as AbilityDefinition
	var bolt := load(CRIMSON_BOLT_PATH) as AbilityDefinition
	if lash == null or bolt == null:
		_check(false, "Both saved recipes reload as AbilityDefinition")
		return
	var lash_execution := lash.execution as PhasedAbilityExecution
	var bolt_execution := bolt.execution as PhasedAbilityExecution
	_check(lash_execution != null and bolt_execution != null, "Both assets use composable executions")
	if lash_execution == null or bolt_execution == null:
		return
	_check(lash_execution.targeting != null
			and lash_execution.targeting.shape == AbilityTargetingDefinition.Shape.DISK
			and lash_execution.targeting.max_targets == 0
			and lash_execution.targeting.allegiance == AbilityTargetingDefinition.Allegiance.HOSTILE,
			"Saved Blood Lash uses an uncapped hostile disk")
	_check(lash.reactions.size() == 1
			and lash.reactions[0].once_policy == ReactionDefinition.OncePolicy.PER_EXECUTION_TARGET,
			"Saved Blood Lash refunds once per target per execution")
	_check(bolt_execution.delivery != null
			and bolt_execution.delivery.kind == AbilityDeliveryDefinition.Kind.PROJECTILE
			and bolt_execution.delivery.projectile_scene != null,
			"Saved Crimson Bolt selects a projectile scene")
	var payload := bolt_execution.get_effect_payload()
	_check(payload.size() == 2 and payload[0].reactions.size() == 1
			and payload[0].reactions[0].timing_filter == ReactionDefinition.TimingFilter.DIRECT
			and payload[1].reactions.is_empty() and not payload[1].execute_periodic_on_application
			and payload[1].tick_at_end and payload[1].period > 0.0,
			"Saved Crimson Bolt scopes lifesteal to impact and schedules delayed ticks")


func _test_validator_diagnostics() -> void:
	var first := _blood_lash()
	var second := _blood_lash()
	second.ability_tags = PackedStringArray(["Ability..Broken"])
	var issues := CombatResourceValidator.validate_definitions([first, second])
	_check(_has_issue(issues, "Duplicate ability ID") and _has_issue(issues, "ability_tags[0]"),
			"Collection validation identifies duplicate IDs and malformed tag fields")
	var conflicting_effect := GameplayEffectDefinition.new()
	conflicting_effect.effect_id = first.ability_id
	issues = CombatResourceValidator.validate_definitions([first, conflicting_effect])
	_check(_has_issue(issues, "Duplicate effect ID"),
			"An ability and an effect cannot share a definition ID")
	_check(_has_issue(CombatResourceValidator.validate_paths(
			PackedStringArray(["res://tests/no_such_ability.tres"])), "Resource file is missing"),
			"Missing definition paths receive a build-time diagnostic")
	var projectile_ability := _crimson_bolt(0.0)
	var execution := projectile_ability.execution as PhasedAbilityExecution
	execution.delivery.projectile_scene = null
	_check(_has_issue(CombatResourceValidator.validate_definitions([projectile_ability]),
			"missing_projectile"), "Projectile authoring reports a missing scene")
	var recursive := GameplayEffectDefinition.new()
	recursive.effect_id = 237
	var additional := AdditionalEffectsComponent.new()
	additional.on_application_effects = [recursive]
	recursive.components = [additional]
	issues = CombatResourceValidator.validate_definitions([recursive])
	additional.on_application_effects.clear()
	_check(_has_issue(issues, "Cyclic resource reference"), "Validation detects a recursive resource graph")


func _test_blood_lash_targeting() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	caster.attributes.set_base_value(MANA, 0.0)
	var targets: Array[AbilitySystem] = []
	for index: int in 99:
		targets.append(_actor(Vector3(float(index % 10) - 4.0, 0.0, float(index) / 10.0 + 1.0), &"enemies"))
	targets.append(_actor(Vector3(20.0, 2.0, 0.0), &"enemies"))
	var outside: Array[AbilitySystem] = [
		_actor(Vector3(20.01, 0.0, 0.0), &"enemies"),
		_actor(Vector3(1.0, 2.01, 0.0), &"enemies"),
		_actor(Vector3(2.0, 0.0, 0.0), &"players"),
		_actor(Vector3(3.0, 0.0, 0.0), &"neutral"),
	]
	for offset: Vector3 in [Vector3.ZERO, Vector3.RIGHT, Vector3.LEFT]:
		_add_hurtbox(targets[0].actor_body, offset)
	var ability := _blood_lash()
	_check(caster.grant_ability(ability), "Grant the in-memory Blood Lash recipe")
	await _activate(caster, ability)
	var damaged := 0
	for target: AbilitySystem in targets:
		if is_equal_approx(target.attributes.get_value(HEALTH), 180.0):
			damaged += 1
	_check(damaged == 100, "Disk damages all 100 unique enemies once, including the boundary and multi-hurtbox target")
	for target: AbilitySystem in outside:
		_near(target.attributes.get_value(HEALTH), 200.0, "Out-of-disk and nonhostile actors take no damage")
	_near(caster.attributes.get_value(MANA), 200.0, "One percent per 100 unique actors reaches capacity")
	_free_arena()


func _test_blood_lash_reactions() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	caster.attributes.set_base_value(MANA, 100.0)
	var ability := _blood_lash()
	_check(caster.grant_ability(ability), "Grant Blood Lash for repeated activations")
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 100.0, "Empty disk requests no recovery")
	var shielded := _actor(Vector3.RIGHT, &"enemies")
	shielded.attributes.set_base_value(MOVEMENT_SPEED, 20.0)
	_apply_defense(shielded, DamageDefenseEffectComponent.Mode.ABSORB)
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 102.0, "An absorbed hit qualifies for a single mana refund")
	_near(shielded.attributes.get_value(HEALTH), 200.0, "The barrier prevents Health damage")
	_near(shielded.attributes.get_value(MOVEMENT_SPEED), -40.0, "Half speed multiplies the full +20% movement result")
	shielded.advance(2.0)
	_near(shielded.attributes.get_value(MOVEMENT_SPEED), 20.0, "Slow expiry releases only the retained movement multiplier")
	var slow_immune := _actor(Vector3.LEFT, &"enemies")
	slow_immune.tags.add_tag(&"State.Immune.Slow")
	_actor(Vector3.FORWARD, &"enemies")
	_actor(Vector3.BACK, &"enemies")
	caster.attributes.attribute_changed.connect(
		func(attribute: int, _previous: float, _value: float) -> void:
			if attribute == MANA:
				caster.attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 300.0),
		CONNECT_ONE_SHOT
	)
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 110.0,
			"Four targets request eight mana from a captured 200 maximum even if capacity changes after the first hit")
	_check(not slow_immune.tags.has_tag(&"State.Slowed")
			and is_equal_approx(slow_immune.attributes.get_value(HEALTH), 180.0),
			"Status immunity prevents only the slow, and the damage still qualifies for recovery")
	caster.attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 200.0)
	caster.attributes.set_base_value(MANA, 199.0)
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 200.0, "Mana restoration clamps to current effective capacity")
	_free_arena()


func _test_blood_lash_rejections() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	caster.attributes.set_base_value(MANA, 50.0)
	var enemy := _actor(Vector3.RIGHT, &"enemies")
	enemy.tags.add_tag(&"State.Immune.Slow")
	_apply_defense(enemy, DamageDefenseEffectComponent.Mode.IMMUNITY)
	var ability := _blood_lash()
	_check(caster.grant_ability(ability), "Grant Blood Lash against an immune target")
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 50.0, "Full payload rejection does not grant mana")
	_near(enemy.attributes.get_value(HEALTH), 200.0, "Damage immunity prevents the damage payload")
	caster.revoke_ability(ability.ability_id)
	enemy.clear_transient_effects()
	_apply_defense(enemy, DamageDefenseEffectComponent.Mode.ABSORB)
	ability = _blood_lash(ReactionDefinition.Trigger.ON_HEALTH_DAMAGED)
	_check(caster.grant_ability(ability), "Grant the positive Health damage variant")
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 50.0, "Positive Health damage variant excludes a fully absorbed hit")
	enemy.clear_transient_effects()
	await _activate(caster, ability)
	_near(caster.attributes.get_value(MANA), 52.0, "Positive Health damage variant counts actual loss")
	_free_arena()


func _test_crimson_bolt_schedule() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	var enemy := _actor(Vector3(0.0, 0.0, -4.0), &"enemies")
	_add_hurtbox(enemy.actor_body, Vector3.ZERO)
	caster.attributes.set_base_value(HEALTH, 40.0)
	enemy.attributes.set_base_value(CombatAttributes.Id.NECROTIC_RESISTANCE, 37.5)
	var damage_events: Array[Dictionary] = []
	enemy.combat_event.connect(func(event: Dictionary) -> void:
		if event["type"] == &"damage":
			damage_events.append(event)
	)
	var ability := _crimson_bolt(40.0)
	_check(caster.grant_ability(ability), "Grant the in-memory Crimson Bolt recipe")
	await _activate(caster, ability)
	_near(enemy.attributes.get_value(HEALTH), 200.0, "Projectile has flight time before impact")
	await _wait_for_impact()
	_near(enemy.attributes.get_value(HEALTH), 175.0, "Impact resolves 40 raw into 25 actual Health damage")
	_near(caster.attributes.get_value(HEALTH), 42.5, "Lifesteal heals for ten percent of the committed loss")
	_check(damage_events.size() == 1, "No periodic damage occurs on application")
	enemy.advance(0.999)
	_near(enemy.attributes.get_value(HEALTH), 175.0, "First tick waits until one elapsed second")
	enemy.advance(0.001)
	_near(enemy.attributes.get_value(HEALTH), 162.5, "First periodic tick resolves through live mitigation")
	enemy.advance(1.0)
	_near(enemy.attributes.get_value(HEALTH), 150.0, "Second periodic tick has the same unmodified basis")
	_near(caster.attributes.get_value(HEALTH), 42.5, "Periodic ticks do not repeat direct lifesteal")
	caster.attributes.set_base_value(HEALTH, 0.0)
	enemy.attributes.set_base_value(CombatAttributes.Id.NECROTIC_RESISTANCE, 25.0)
	for tick: int in range(3, 6):
		enemy.advance(1.0)
		_near(enemy.attributes.get_value(HEALTH), 150.0 - 15.0 * (tick - 2),
				"Tick %d continues after source death and uses new Resistance" % tick)
	_check(enemy.effects.active_count(CRIMSON_PERIODIC_ID) == 0,
			"The fifth tick executes before the effect expires")
	enemy.advance(1.0)
	_check(damage_events.size() == 6, "One direct event plus five periodic events are committed")
	_near(enemy.attributes.get_value(HEALTH), 105.0, "No sixth periodic tick executes")
	_near(caster.attributes.get_value(HEALTH), 0.0, "Detached periodic effects do not heal or revive the source")
	_free_arena()


func _test_crimson_bolt_actual_damage() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	var enemy := _actor(Vector3(0.0, 0.0, -4.0), &"enemies")
	_add_hurtbox(enemy.actor_body, Vector3.ZERO)
	caster.attributes.set_base_value(HEALTH, 40.0)
	enemy.attributes.set_base_value(HEALTH, 6.0)
	enemy.attributes.set_base_value(CombatAttributes.Id.NECROTIC_RESISTANCE, 40.0)
	var ability := _crimson_bolt(100.0)
	_check(caster.grant_ability(ability), "Grant Crimson Bolt with test-owned overkill tuning")
	await _activate(caster, ability)
	await _wait_for_impact()
	_near(enemy.attributes.get_value(HEALTH), 0.0, "Lethal damage clamps to the target's six remaining Health")
	_near(caster.attributes.get_value(HEALTH), 40.6, "Lifesteal is based on the six actual Health lost")
	_free_arena()


func _test_crimson_bolt_refresh() -> void:
	_new_arena()
	var caster := _actor(Vector3.ZERO, &"players")
	var enemy := _actor(Vector3(0.0, 0.0, -4.0), &"enemies")
	_add_hurtbox(enemy.actor_body, Vector3.ZERO)
	caster.attributes.set_base_value(HEALTH, 40.0)
	var ability := _crimson_bolt(0.0)
	_check(caster.grant_ability(ability), "Grant Crimson Bolt with zero direct damage")
	await _activate(caster, ability)
	await _wait_for_impact()
	_near(enemy.attributes.get_value(HEALTH), 200.0, "Zero direct damage does not substitute the periodic magnitude")
	_near(caster.attributes.get_value(HEALTH), 40.0, "Zero direct damage produces zero lifesteal")
	enemy.advance(0.5)
	await _activate(caster, ability)
	await _wait_for_impact()
	_check(enemy.effects.active_count(CRIMSON_PERIODIC_ID) == 1,
			"Reapplication keeps one stack per source")
	enemy.advance(0.5)
	_near(enemy.attributes.get_value(HEALTH), 200.0, "Refresh resets the first periodic deadline")
	enemy.advance(4.5)
	_near(enemy.attributes.get_value(HEALTH), 100.0, "Refresh leaves exactly five new periodic ticks")
	enemy.advance(1.0)
	_near(enemy.attributes.get_value(HEALTH), 100.0, "The refreshed effect leaves no extra ticks")
	_near(caster.attributes.get_value(HEALTH), 40.0, "Zero direct damage cannot turn periodic ticks into lifesteal")
	_free_arena()


func _blood_lash(trigger: ReactionDefinition.Trigger = ReactionDefinition.Trigger.ON_HIT) -> AbilityDefinition:
	var impact := _damage(238, 20.0)
	var slow := GameplayEffectDefinition.new()
	slow.effect_id = 239
	slow.timing = GameplayEffectDefinition.Timing.DURATION
	slow.duration = 2.0
	slow.granted_tags = PackedStringArray(["State.Slowed"])
	slow.status_profile = StatusProfile.new()
	slow.status_profile.category = StatusProfile.Category.SLOW
	slow.status_profile.immunity_tags = PackedStringArray(["State.Immune.Slow"])
	var modifier := AttributeModifier.new()
	modifier.attribute = MOVEMENT_SPEED
	modifier.operation = AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT
	modifier.value = -50.0
	slow.modifiers = [modifier]
	slow.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET
	slow.stack_limit_count = 1
	var ability := _payload_ability(240, [impact, slow])
	var execution := ability.execution as PhasedAbilityExecution
	execution.targeting.shape = AbilityTargetingDefinition.Shape.DISK
	execution.targeting.radius = 20.0
	execution.targeting.half_height = 2.0
	execution.delivery.kind = AbilityDeliveryDefinition.Kind.AREA_BURST
	var restore := RestoreResourceReactionAction.new()
	restore.amount = AmountDefinition.new()
	restore.amount.source = AmountDefinition.Source.RESOURCE_PERCENT
	restore.amount.timing = AmountDefinition.Timing.SNAPSHOT
	restore.amount.percentage = 1.0
	var reaction := ReactionDefinition.new()
	reaction.trigger = trigger
	reaction.once_policy = ReactionDefinition.OncePolicy.PER_EXECUTION_TARGET
	reaction.actions = [restore]
	ability.reactions = [reaction]
	return ability


func _crimson_bolt(direct_damage: float) -> AbilityDefinition:
	var impact := _damage(241, direct_damage)
	var heal := HealReactionAction.new()
	heal.amount = AmountDefinition.new()
	heal.amount.source = AmountDefinition.Source.OUTCOME_PERCENT
	heal.amount.outcome_basis = AmountDefinition.OutcomeBasis.ACTUAL_HEALTH_DAMAGE
	heal.amount.percentage = 10.0
	var reaction := ReactionDefinition.new()
	reaction.trigger = ReactionDefinition.Trigger.ON_HEALTH_DAMAGED
	reaction.timing_filter = ReactionDefinition.TimingFilter.DIRECT
	reaction.actions = [heal]
	impact.reactions = [reaction]
	var periodic := _damage(CRIMSON_PERIODIC_ID, 20.0)
	periodic.timing = GameplayEffectDefinition.Timing.DURATION
	periodic.duration = 5.0
	periodic.period = 1.0
	periodic.execute_periodic_on_application = false
	periodic.tick_at_end = true
	periodic.snapshot_source = true
	periodic.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_SOURCE
	periodic.stack_limit_count = 1
	var ability := _payload_ability(243, [impact, periodic])
	var execution := ability.execution as PhasedAbilityExecution
	execution.targeting.shape = AbilityTargetingDefinition.Shape.POINT
	execution.targeting.origin = AbilityTargetingDefinition.Origin.AIM
	execution.targeting.max_range = 30.0
	execution.delivery.kind = AbilityDeliveryDefinition.Kind.PROJECTILE
	execution.delivery.projectile_scene = load(CRIMSON_PROJECTILE_PATH) as PackedScene
	return ability


func _payload_ability(id: int, effects: Array[GameplayEffectDefinition]) -> AbilityDefinition:
	var apply := AbilityApplyEffectsAction.new()
	apply.effects = effects
	var phase := AbilityPhaseDefinition.new()
	phase.event_key = &"delivery.impact"
	phase.actions = [apply]
	var execution := PhasedAbilityExecution.new()
	execution.targeting = AbilityTargetingDefinition.new()
	execution.targeting.allegiance = AbilityTargetingDefinition.Allegiance.HOSTILE
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.phases = [phase]
	var ability := AbilityDefinition.new()
	ability.ability_id = id
	ability.ability_tags = PackedStringArray(["Ability.Spell", "Ability.Fixture"])
	ability.execution = execution
	return ability


func _damage(id: int, points: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = id
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	effect.magic_school = GameplayEffectDefinition.MagicSchool.NECROTIC
	var calculation := GameplayEffectDamageExecution.new()
	calculation.amount = AmountDefinition.new()
	calculation.amount.fixed_amount = points
	effect.executions = [calculation]
	return effect


func _apply_defense(target: AbilitySystem, mode: DamageDefenseEffectComponent.Mode) -> void:
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	var defense := DamageDefenseEffectComponent.new()
	defense.mode = mode
	defense.capacity = 100.0
	effect.components = [defense]
	_check(target.effects.apply_effect(effect, target.create_effect_context()) > 0, "Install the defense fixture")


func _new_arena() -> void:
	_arena = Node3D.new()
	root.add_child(_arena)
	current_scene = _arena


func _free_arena() -> void:
	current_scene = null
	_arena.free()
	_arena = null


func _actor(position: Vector3, faction: StringName) -> AbilitySystem:
	var body := StaticBody3D.new()
	body.position = position
	var attributes := ActorAttributes.new()
	attributes.name = "Attributes"
	var system := AbilitySystem.new()
	system.name = "AbilitySystem"
	system.attributes = attributes
	system.actor_body = body
	system.cast_origin = body
	system.aim_origin = body
	system.faction_id = faction
	if faction == &"players":
		system.hostile_factions.append(&"enemies")
	body.add_child(attributes)
	body.add_child(system)
	_arena.add_child(body)
	system.set_process(false)
	system.configure_randomness(42)
	attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 200.0)
	attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 200.0)
	attributes.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 1000.0)
	attributes.restore_resources()
	return system


func _add_hurtbox(body: CollisionObject3D, offset: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.35
	shape.shape = sphere
	shape.position = offset
	body.add_child(shape)


func _activate(caster: AbilitySystem, ability: AbilityDefinition) -> void:
	_check(caster.try_activate(ability.ability_id), "Activate %s" % ability.ability_id)
	await physics_frame
	await physics_frame


func _wait_for_impact() -> void:
	for frame: int in 24:
		await physics_frame


func _has_issue(issues: Array[String], substring: String) -> bool:
	for issue: String in issues:
		if issue.contains(substring):
			return true
	return false


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_equal_approx(actual, expected), "%s (expected %.4f, got %.4f)" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
