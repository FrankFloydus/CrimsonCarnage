extends SceneTree
## Tests committed v2 effect outcomes with in-memory actor and effect fixtures.

const ATTRIBUTES = preload("res://tests/attribute_fixture.gd")
const HEALTH: CombatAttributes.Id = CombatAttributes.Id.HEALTH
const MANA: CombatAttributes.Id = CombatAttributes.Id.MANA

var _checks: int = 0
var _failures: int = 0
var _actors: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_barriers_and_reflection()
	_test_shield_observes_its_final_hit()
	_test_block_owner_and_facing()
	_test_routing_commits_both_recipients()
	_test_transfer_preserves_remaining_budget()
	_test_status_and_break_predicates()
	_test_accumulator_and_exclusive_slot()
	_test_dispel_snapshot_and_save_invalidation()
	_test_resistance_timing_and_cleanup()
	_test_inspector_modes_preserve_authored_data()
	await _test_snapshot_transform()
	for actor in _actors:
		actor.free()
	print("Effect v2 runtime checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_barriers_and_reflection() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var other := _new_actor()
	var barrier := _barrier(30.0)
	var first := _apply(target, target, barrier)
	var second := _apply(other, other, barrier)
	var result := _hit(source, target, _damage(20.0))
	_check(result.outcome == &"hit" and result.absorbed_amount == 20.0 \
			and result.health_damage == 0.0, "Full absorption preserves confirmed contact")
	_check(_remaining_budget(target, first) == 10.0 and _remaining_budget(other, second) == 30.0,
			"Two actors applying one asset own independent budgets")

	var reflect := _defense(DamageDefenseEffectComponent.Mode.REFLECT)
	var reflection := reflect.components[0] as DamageDefenseEffectComponent
	reflection.contact_uses = 1
	var reflect_handle := _apply(target, target, reflect)
	_apply(source, source, _defense(DamageDefenseEffectComponent.Mode.REFLECT))
	var original_health := source.attributes.get_value(HEALTH)
	var reflected_damage: Array[Dictionary] = []
	source.combat_event.connect(func(event: Dictionary) -> void:
		if event.type == &"damage":
			reflected_damage.append(event))
	result = _hit(source, target, _damage(12.0))
	_check(result.outcome == &"reflected" and _remaining_budget(target, first) == 10.0 \
			and source.attributes.get_value(HEALTH) == original_health - 12.0 \
			and not target.effects.has_retained_effect(reflect_handle),
			"Reflection resolves once against the source and leaves the original barrier intact")
	_check(reflected_damage.size() == 1 and (reflected_damage[0].provenance \
			& CombatOutcomeContext.Provenance.REFLECTED) != 0 \
			and reflected_damage[0].credited_owner_id == target.attributes.get_instance_id(),
			"Reflected damage preserves provenance and credits the reflector")

	var deflect := _defense(DamageDefenseEffectComponent.Mode.DEFLECT)
	_apply(other, other, deflect)
	result = _hit(source, other, _damage(12.0))
	_check(result.outcome == &"deflected" and _remaining_budget(other, second) == 30.0 \
			and source.attributes.get_value(HEALTH) == original_health - 12.0,
			"Deflection preserves shields and produces no redirected attack")


func _test_shield_observes_its_final_hit() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var shield := _barrier(20.0)
	var observer := ObserveOutcomeEffectComponent.new()
	observer.scope = ObserveOutcomeEffectComponent.Scope.TARGET
	var react := ReactionDefinition.new()
	react.trigger = ReactionDefinition.Trigger.ON_HIT
	react.recipient = ReactionDefinition.Recipient.ORIGINAL_SOURCE
	var mark_attacker := ApplyEffectReactionAction.new()
	mark_attacker.effect = _retained()
	mark_attacker.effect.granted_tags = PackedStringArray(["State.Test.BarrierContact"])
	react.actions.append(mark_attacker)
	observer.reactions.append(react)
	shield.components.append(observer)
	var handle := _apply(target, target, shield)
	var result := _hit(source, target, _damage(20.0))
	_check(handle > 0 and result.outcome == &"hit" and result.health_damage == 0.0 \
			and not result.has("_depleted_hit_observers") and not target.effects.has_retained_effect(handle),
			"The final hit consumes the barrier and keeps observer state out of public hit results")
	_check(source.tags.has_tag(&"State.Test.BarrierContact"),
			"The depleted barrier's committed hit reaction applies the authored state")


func _test_block_owner_and_facing() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var source_actor := source.get_parent() as Node3D
	source_actor.position = Vector3(0.0, 0.0, -2.0)
	var effect := _defense(DamageDefenseEffectComponent.Mode.BLOCK)
	var policy := effect.components[0] as DamageDefenseEffectComponent
	policy.fraction = 0.5
	policy.front_arc_degrees = 120.0
	policy.required_owner_tags = PackedStringArray(["Equipment.Shield"])
	_apply(target, target, effect)
	var result := _hit(source, target, _damage(10.0))
	_check(result.health_damage == 10.0, "Block requires the authored owner equipment tag")
	target.tags.add_tag(&"Equipment.Shield")
	result = _hit(source, target, _damage(10.0))
	_check(result.health_damage == 5.0 and result.blocked_amount == 5.0,
			"An eligible attack from the front uses the owned block policy")
	source_actor.position = Vector3(0.0, 0.0, 2.0)
	result = _hit(source, target, _damage(10.0))
	_check(result.health_damage == 10.0 and result.blocked_amount == 0.0,
			"A rear attack remains outside the authored block arc")


func _test_routing_commits_both_recipients() -> void:
	var attacker := _new_actor()
	var protected_actor := _new_actor()
	var protector := _new_actor()
	protected_actor.attributes.set_base_value(HEALTH, 25.0)
	protector.attributes.set_base_value(HEALTH, 100.0)
	var route := DamageRoutingEffectComponent.new()
	route.fraction = 0.6
	route.capacity = 30.0
	var route_handle := _apply(protector, protected_actor, _retained(route))
	var shield_handle := _apply(protector, protector, _barrier(10.0))
	var local_shield := _apply(protected_actor, protected_actor, _barrier(5.0))
	var health_seen_at_signal: Array[float] = []
	protected_actor.attributes.attribute_changed.connect(func(id: int, _old: float, _value: float) -> void:
		if id == HEALTH:
			health_seen_at_signal.append(protector.attributes.get_value(HEALTH)))
	var result := _hit(attacker, protected_actor, _damage(50.0))
	_check(result.health_damage == 18.0 and result.absorbed_amount == 5.0 \
			and protected_actor.attributes.get_value(HEALTH) == 7.0 \
			and protector.attributes.get_value(HEALTH) == 83.0,
			"Local absorption precedes routing and the redirected portion uses the recipient's barrier")
	_check(health_seen_at_signal == [83.0] and protected_actor.effects.has_retained_effect(route_handle) \
			and not protected_actor.effects.has_retained_effect(local_shield) \
			and not protector.effects.has_retained_effect(shield_handle),
			"Both Health losses commit before callbacks and only depleted budgets remove their handles")

	protected_actor.attributes.set_base_value(HEALTH, 50.0)
	protector.attributes.set_base_value(HEALTH, 0.0)
	_apply(protector, protected_actor, _retained(route))
	result = _hit(attacker, protected_actor, _damage(30.0))
	_check(result.health_damage == 30.0 and protected_actor.attributes.get_value(HEALTH) == 20.0,
			"An invalid route recipient leaves all damage on the original target")


func _test_transfer_preserves_remaining_budget() -> void:
	var source := _new_actor()
	var destination := _new_actor()
	var attacker := _new_actor()
	var shield := _barrier(40.0)
	shield.transferable = true
	shield.timing = GameplayEffectDefinition.Timing.DURATION
	shield.duration = 10.0
	shield.required_target_tags = PackedStringArray(["State.ShieldAllowed"])
	source.tags.add_tag(&"State.ShieldAllowed")
	var handle := _apply(source, source, shield)
	_hit(attacker, source, _damage(12.0))
	source.effects.advance(2.0)
	_check(source.effects.transfer_effect(handle, destination.effects) == 0 \
			and _remaining_budget(source, handle) == 28.0,
			"Rejected transfer leaves the original handle, remaining time and budget intact")
	destination.tags.add_tag(&"State.ShieldAllowed")
	var new_handle := source.effects.transfer_effect(handle, destination.effects, 3.0)
	_check(new_handle > 0 and not source.effects.has_retained_effect(handle) \
			and destination.effects.get_remaining(new_handle) == 3.0 \
			and _remaining_budget(destination, new_handle) == 28.0,
			"Successful transfer installs remaining state under a fresh destination handle")
	var damage := _hit(attacker, destination, _damage(30.0))
	_check(damage.absorbed_amount == 28.0 and damage.health_damage == 2.0 \
			and not destination.effects.has_retained_effect(new_handle),
			"Transferred shields do not refill their already spent capacity")


func _test_status_and_break_predicates() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var status := _retained(BreakOnDamageEffectComponent.new())
	status.granted_tags = PackedStringArray(["State.Control.Sleep"])
	status.status_profile = StatusProfile.new()
	status.status_profile.category = StatusProfile.Category.INCAPACITATION
	status.status_profile.immunity_tags = PackedStringArray(["State.Control.Immune"])
	target.tags.add_tag(&"State.Control.Immune")
	var packet: Array[GameplayEffectDefinition] = [_damage(10.0), status]
	var result := target.receive_hit(source.create_effect_context(), packet, 0.0, 1.0)
	_check(result.outcome == &"hit" and result.health_damage == 10.0 and result.applied_effects == 1 \
			and not target.tags.has_tag(&"State.Control.Sleep"),
			"Status immunity rejects control independently of health damage")
	target.tags.remove_tag(&"State.Control.Immune")
	var handle := _apply(source, target, status)
	_apply(target, target, _barrier(10.0))
	_hit(source, target, _damage(10.0))
	_check(target.effects.has_retained_effect(handle), "A Health loss predicate ignores absorbed contacts")
	_hit(source, target, _damage(1.0))
	_check(not target.effects.has_retained_effect(handle) and not target.tags.has_tag(&"State.Control.Sleep"),
			"Committed Health loss releases only the owned control grant")

	_apply(target, target, _defense(DamageDefenseEffectComponent.Mode.IMMUNITY))
	result = _hit(source, target, _damage(10.0))
	_check(result.outcome == &"immune" and result.health_damage == 0.0,
			"Damage immunity is distinct from an absorbed hit")


func _test_accumulator_and_exclusive_slot() -> void:
	var source := _new_actor()
	var other_source := _new_actor()
	var target := _new_actor()
	var replacement := _new_actor()
	var accumulator := DamageAccumulatorEffectComponent.new()
	accumulator.threshold = 20.0
	accumulator.publish_on_expiry = true
	var effect := _retained(accumulator)
	effect.effect_id = &"test.accumulator"
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 1.0
	var threshold_events: Array[Dictionary] = []
	target.combat_event.connect(func(event: Dictionary) -> void:
		if event.type == &"effect_threshold":
			threshold_events.append(event))
	var handle := _apply(source, target, effect)
	_hit(other_source, target, _damage(20.0))
	_check(threshold_events.is_empty() and target.effects.has_retained_effect(handle),
			"An accumulator rejects damage from another execution's source")
	var periodic := _damage(20.0)
	periodic.timing = GameplayEffectDefinition.Timing.DURATION
	periodic.duration = 1.0
	periodic.period = 1.0
	periodic.execute_periodic_on_application = false
	_apply(source, target, periodic)
	target.effects.advance(1.0)
	_check(threshold_events.size() == 1 and threshold_events[0].amount == 20.0 \
			and not target.effects.has_retained_effect(handle),
			"A threshold reached on the expiry tick publishes exactly one detonation outcome")

	var marker := _retained()
	marker.exclusive_owner_slot = &"test.marker"
	marker.required_target_tags = PackedStringArray(["State.Markable"])
	target.tags.add_tag(&"State.Markable")
	var first := _apply(source, target, marker)
	_check(_apply(source, replacement, marker) == 0 and target.effects.has_retained_effect(first) \
			and source.effects.get_exclusive_slot_target(&"test.marker") == target.attributes,
			"A rejected exclusive application preserves the prior target")
	replacement.tags.add_tag(&"State.Markable")
	var last := _apply(source, replacement, marker)
	_check(last > 0 and not target.effects.has_retained_effect(first) \
			and source.effects.get_exclusive_slot_target(&"test.marker") == replacement.attributes,
			"A successful exclusive replacement swaps ownership and clears the prior handle")
	source.attributes.set_base_value(HEALTH, 0.0)
	_check(not replacement.effects.has_retained_effect(last),
			"Source death releases remote exclusive ownership")
	_check(_apply(source, replacement, marker) == 0,
			"A detached application cannot leave a new exclusive owner slot on a dead source")


func _test_dispel_snapshot_and_save_invalidation() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var dispeller := _new_actor()
	var reaction := ReactionDefinition.new()
	reaction.trigger = ReactionDefinition.Trigger.ON_EFFECT_REMOVED
	reaction.recipient = ReactionDefinition.Recipient.REMOVAL_INSTIGATOR
	reaction.removal_reason = ReactionDefinition.RemovalFilter.DISPELLED
	var backlash := ApplyEffectReactionAction.new()
	backlash.effect = _damage(12.0)
	backlash.retaliation = true
	reaction.actions.append(backlash)
	var effect := _retained()
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 1.0
	effect.reactions.append(reaction)
	var before := dispeller.attributes.get_value(HEALTH)
	_apply(source, target, effect)
	target.effects.advance(1.0)
	_check(dispeller.attributes.get_value(HEALTH) == before, "Natural expiry does not trigger a dispel reaction")
	var handle := _apply(source, target, effect)
	_check(target.effects.dispel_effect(handle, dispeller) \
			and dispeller.attributes.get_value(HEALTH) == before - 12.0,
			"Dispel attribution applies the authored backlash only to the dispeller")

	var capture := SelectiveResourceSnapshotEffectComponent.new()
	capture.pools = [AmountDefinition.Pool.HEALTH, AmountDefinition.Pool.MANA]
	var snapshot := _retained(capture)
	snapshot.timing = GameplayEffectDefinition.Timing.DURATION
	snapshot.duration = 1.0
	target.attributes.set_base_value(HEALTH, 70.0)
	target.attributes.set_base_value(MANA, 30.0)
	_apply(target, target, snapshot)
	target.attributes.set_base_value(HEALTH, 80.0)
	target.attributes.set_base_value(MANA, 10.0)
	target.effects.advance(1.0)
	_check(target.attributes.get_value(HEALTH) == 70.0 and target.attributes.get_value(MANA) == 30.0,
			"Selective expiry restores exact captured pools through typed transactions")

	_apply(target, target, snapshot)
	target.attributes.set_base_value(MANA, 5.0)
	var invalidated := target.effects.invalidate_session_effects_for_restore()
	_check(not invalidated.is_empty() and invalidated.back()["reason"] == &"session_only_effect" \
			and target.effects.active_count() == 0 and target.attributes.get_value(MANA) == 5.0,
			"Restore explicitly invalidates session effects without replaying their expiry actions")


func _test_resistance_timing_and_cleanup() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var status := _retained()
	status.timing = GameplayEffectDefinition.Timing.DURATION
	status.duration = 4.0
	status.status_profile = StatusProfile.new()
	status.status_profile.resistance_attribute = CombatAttributes.Id.FIRE_RESISTANCE
	status.status_profile.resistance_effect = StatusProfile.ResistanceEffect.DURATION
	target.attributes.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	var handle := _apply(source, target, status)
	_check(target.effects.get_remaining(handle) == 2.0 and status.duration == 4.0,
			"Status duration resistance scales the application without editing the asset")
	target.effects.advance(2.0)
	_check(not target.effects.has_retained_effect(handle), "A resisted status expires at its scaled deadline")

	var ramp := PeriodicRampEffectComponent.new()
	ramp.multiplier_per_tick = 1.0
	ramp.maximum_multiplier = 2.5
	var periodic := _damage(10.0)
	periodic.timing = GameplayEffectDefinition.Timing.DURATION
	periodic.duration = 3.0
	periodic.period = 1.0
	periodic.execute_periodic_on_application = false
	periodic.components.append(ramp)
	var before := target.attributes.get_value(HEALTH)
	handle = _apply(source, target, periodic)
	target.effects.advance(3.0)
	_check(before - target.attributes.get_value(HEALTH) == 55.0 \
			and not target.effects.has_retained_effect(handle),
			"Periodic ramp respects independent per-tick progress, cap and inclusive expiry")
	periodic.tick_at_end = false
	before = target.attributes.get_value(HEALTH)
	_apply(source, target, periodic)
	target.effects.advance(3.0)
	_check(before - target.attributes.get_value(HEALTH) == 30.0,
			"Excluding the expiry tick leaves no final periodic transaction")

	var nonlethal := _damage(1000.0)
	nonlethal.damage_profile = DamageProfile.new()
	nonlethal.damage_profile.nonlethal = true
	var result := _hit(source, target, nonlethal)
	_check(target.attributes.get_value(HEALTH) == 1.0 and result.health_damage > 0.0,
			"Nonlethal profiles cap the final Health loss after prevention")

	var cleanup := _retained()
	cleanup.granted_tags = PackedStringArray(["State.Test.Cycle"])
	var count := target.effects.active_count()
	var repeated_cleanup := true
	for _cycle in 1000:
		handle = _apply(source, target, cleanup)
		if handle <= 0 or not target.tags.has_tag(&"State.Test.Cycle") \
				or not target.effects.remove_effect(handle) or target.tags.has_tag(&"State.Test.Cycle"):
			repeated_cleanup = false
			break
	_check(repeated_cleanup and target.effects.active_count() == count,
			"One thousand retained application and removal cycles release all counted ownership")


func _test_inspector_modes_preserve_authored_data() -> void:
	var source := _new_actor()
	var target := _new_actor()
	var effect := _damage(12.0)
	effect.duration = 3.0
	effect.period = 1.0
	effect.granted_tags = PackedStringArray(["State.Test.SavedMode"])
	effect.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_SOURCE
	effect.stack_limit_count = 2
	effect.deny_overflow_application = true
	effect.status_profile = StatusProfile.new()
	_check(_stored_but_hidden(effect, &"period") and _stored_but_hidden(effect, &"duration") \
			and _stored_but_hidden(effect, &"granted_tags") and _stored_but_hidden(effect, &"stacking_type") \
			and _shown(effect, &"executions") and _stored_but_hidden(effect, &"magic_school"),
			"Instant physical effects show execution controls and retain hidden state settings")
	var path := "user://effect_mode_visibility_test_%d.tres" % OS.get_process_id()
	var saved := ResourceSaver.save(effect, path)
	var restored := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) \
			as GameplayEffectDefinition if saved == OK else null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(restored != null and restored.period == 1.0 and restored.duration == 3.0 \
			and restored.status_profile != null and restored.stack_limit_count == 2,
			"Inspector-hidden effect properties survive a ResourceSaver round trip")
	if restored == null:
		return
	var result := _hit(source, target, restored)
	_check(result.health_damage == 12.0 and not target.tags.has_tag(&"State.Test.SavedMode") \
			and restored.get_damage_timing_tag() == "Damage.Direct",
			"Instant runtime ignores its saved period, stack policy, status and granted tags")

	restored.timing = GameplayEffectDefinition.Timing.DURATION
	restored.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	_check(_shown(restored, &"duration") and _shown(restored, &"period") and _shown(restored, &"tick_at_end") \
			and _shown(restored, &"magic_school") and _shown(restored, &"clear_stack_on_overflow") \
			and _stored_but_hidden(restored, &"status_profile"),
			"Periodic Magic duration effects restore their active lifetime, school and aggregate controls")
	restored.period = 0.0
	restored.stacking_type = GameplayEffectDefinition.StackingType.INDEPENDENT
	_check(_stored_but_hidden(restored, &"executions") and _stored_but_hidden(restored, &"damage_type") \
			and _stored_but_hidden(restored, &"stack_limit_count") and _stored_but_hidden(restored, &"tick_at_end") \
			and _shown(restored, &"status_profile"),
			"Nonperiodic independent statuses hide stored damage, stack and tick controls")
	var before := target.attributes.get_value(HEALTH)
	var handle := _apply(source, target, restored)
	_check(handle > 0 and target.attributes.get_value(HEALTH) == before \
			and target.tags.has_tag(&"State.Test.SavedMode"),
			"Nonperiodic runtime retains its status but leaves stored damage executions inactive")

	var profile := DamageProfile.new()
	profile.use_armor = true
	profile.flat_armor_penetration = -1.0
	_check(_stored_but_hidden(profile, &"use_armor") and _stored_but_hidden(profile, &"flat_armor_penetration") \
			and profile.get_validation_error().is_empty(),
			"Default damage rules hide and ignore explicit Armor settings")
	profile.defense_selection = DamageProfile.DefenseSelection.EXPLICIT
	_check(_shown(profile, &"flat_armor_penetration") and not profile.get_validation_error().is_empty(),
			"Enabling explicit Armor exposes and validates the saved penetration")
	profile.use_armor = false
	_check(_stored_but_hidden(profile, &"flat_armor_penetration") and profile.get_validation_error().is_empty(),
			"Disabling explicit Armor preserves the stored penetration without applying it")

	var defense := DamageDefenseEffectComponent.new()
	defense.capacity = -1.0
	defense.mode = DamageDefenseEffectComponent.Mode.REFLECT
	_check(_shown(defense, &"contact_uses") and _shown(defense, &"reflect_attached_statuses") \
			and _stored_but_hidden(defense, &"capacity") and defense.get_validation_error(_retained()).is_empty(),
			"Reflection exposes contact settings without validating stale absorption capacity")
	defense.capacity = 20.0
	defense.contact_uses = -1
	defense.mode = DamageDefenseEffectComponent.Mode.ABSORB
	_check(_shown(defense, &"capacity") and _stored_but_hidden(defense, &"contact_uses") \
			and defense.get_contact_uses() == 0 and defense.get_validation_error(_retained()).is_empty(),
			"Absorption exposes its capacity and ignores a stored contact-use limit")

	var status := StatusProfile.new()
	_check(_stored_but_hidden(status, &"resistance_attribute") and status.get_validation_error().is_empty(),
			"Statuses without a resistance effect hide the attribute selector")
	status.resistance_effect = StatusProfile.ResistanceEffect.CHANCE
	_check(_shown(status, &"resistance_attribute") and not status.get_validation_error().is_empty(),
			"Selecting a resistance effect exposes and validates the attribute selector")

	var execution := effect.get_damage_execution()
	execution.weapon_power_share = -1.0
	_check(_shown(execution, &"power_coefficient") and _stored_but_hidden(execution, &"weapon_power_share") \
			and execution.get_validation_error(effect).is_empty(),
			"Ordinary damage ignores hidden weapon sharing")
	execution.use_weapon_damage = true
	_check(_shown(execution, &"weapon_power_share") and _stored_but_hidden(execution, &"power_coefficient") \
			and not execution.get_validation_error(effect).is_empty(),
			"Weapon damage exposes and validates its share of the weapon contribution")

	var snapshot := SelectiveResourceSnapshotEffectComponent.new()
	snapshot.pools = [AmountDefinition.Pool.MANA]
	_check(_stored_but_hidden(snapshot, &"healing_reactions") \
			and _stored_but_hidden(snapshot, &"maximum_restore_distance"),
			"Mana-only snapshots hide Health reactions and transform range")
	snapshot.pools = [AmountDefinition.Pool.HEALTH]
	snapshot.restore_transform = true
	_check(_shown(snapshot, &"healing_reactions") and _shown(snapshot, &"maximum_restore_distance"),
			"Health and transform snapshots expose their specific settings")


func _test_snapshot_transform() -> void:
	var body := CharacterBody3D.new()
	var shape_node := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.25
	capsule.height = 1.0
	shape_node.shape = capsule
	body.add_child(shape_node)
	var caster := _new_actor(body)
	var capture := SelectiveResourceSnapshotEffectComponent.new()
	capture.pools = [AmountDefinition.Pool.HEALTH]
	capture.restore_transform = true
	capture.maximum_restore_distance = 5.0
	capture.restore_on_manual_removal = true
	var effect := _retained(capture)
	effect.effect_id = &"test.snapshot"
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 10.0
	var toggle := AbilitySnapshotToggleAction.new()
	toggle.snapshot_effect = effect
	var phase := AbilityPhaseDefinition.new()
	phase.actions.append(toggle)
	var execution := PhasedAbilityExecution.new()
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.phases.append(phase)
	var definition := AbilityDefinition.new()
	definition.ability_id = &"test.snapshot.toggle"
	definition.execution = execution
	caster.attributes.set_base_value(HEALTH, 70.0)
	var granted := caster.grant_ability(definition)
	var activated := caster.try_activate(definition.ability_id)
	caster._physics_process(0.01)
	_check(granted and activated and caster.effects.active_count(effect.effect_id) == 1,
			"The authored toggle captures the caster's current transform on first activation")
	body.global_position = Vector3(10.0, 0.0, 0.0)
	caster.attributes.set_base_value(HEALTH, 40.0)
	caster.attributes.set_base_value(MANA, 15.0)
	_check(caster.effects.restore_snapshot(effect.effect_id) == -1 \
			and caster.effects.active_count(effect.effect_id) == 1,
			"An out-of-range reactivation leaves the snapshot available for another attempt")

	body.global_position = Vector3(2.0, 0.0, 0.0)
	var obstacle := StaticBody3D.new()
	var obstacle_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	obstacle_shape.shape = box
	obstacle.add_child(obstacle_shape)
	root.add_child(obstacle)
	await physics_frame
	await physics_frame
	_check(caster.effects.restore_snapshot(effect.effect_id) == -1 \
			and caster.attributes.get_value(HEALTH) == 40.0 and body.global_position.x == 2.0,
			"An occupied destination rejects the entire snapshot without restoring Health")
	obstacle.free()
	await physics_frame
	await physics_frame
	var mana_before := caster.attributes.get_value(MANA)
	activated = caster.try_activate(definition.ability_id)
	caster._physics_process(0.01)
	_check(activated and body.global_position.is_zero_approx() \
			and caster.attributes.get_value(HEALTH) == 70.0 \
			and caster.attributes.get_value(MANA) == mana_before \
			and caster.effects.active_count(effect.effect_id) == 0,
			"The next safe activation restores selected fields once and leaves Mana alone")


func _new_actor(body: CharacterBody3D = null) -> AbilitySystem:
	var actor: Node3D = body if body != null else Node3D.new()
	var attributes := ActorAttributes.new()
	attributes.name = "Attributes"
	var system := AbilitySystem.new()
	system.name = "AbilitySystem"
	system.attributes = attributes
	system.actor_body = body
	ATTRIBUTES.configure(system)
	actor.add_child(attributes)
	actor.add_child(system)
	root.add_child(actor)
	_actors.append(actor)
	return system


static func _retained(component: GameplayEffectComponent = null) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	if component != null:
		effect.components.append(component)
	return effect


static func _defense(mode: DamageDefenseEffectComponent.Mode) -> GameplayEffectDefinition:
	var component := DamageDefenseEffectComponent.new()
	component.mode = mode
	return _retained(component)


static func _barrier(capacity: float) -> GameplayEffectDefinition:
	var component := DamageDefenseEffectComponent.new()
	component.capacity = capacity
	return _retained(component)


static func _damage(amount: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(amount)
	effect.executions.append(execution)
	return effect


static func _apply(source: AbilitySystem, target: AbilitySystem, effect: GameplayEffectDefinition) -> int:
	return target.apply_effect_spec_to_self(source.make_outgoing_spec(effect))


static func _hit(source: AbilitySystem, target: AbilitySystem, damage: GameplayEffectDefinition) -> Dictionary:
	var packet: Array[GameplayEffectDefinition] = [damage]
	return target.receive_hit(source.create_effect_context(), packet, 0.0, 1.0)


static func _remaining_budget(actor: AbilitySystem, handle: int) -> float:
	for entry in actor.effects.get_active_effects():
		if entry["handle"] == handle:
			return entry["behaviors"][0]["remaining"]
	return 0.0


static func _stored_but_hidden(resource: Resource, property_name: StringName) -> bool:
	var usage := _property_usage(resource, property_name)
	return usage & PROPERTY_USAGE_STORAGE != 0 and usage & PROPERTY_USAGE_EDITOR == 0


static func _shown(resource: Resource, property_name: StringName) -> bool:
	return _property_usage(resource, property_name) & PROPERTY_USAGE_EDITOR != 0


static func _property_usage(resource: Resource, property_name: StringName) -> int:
	for property in resource.get_property_list():
		if property.name == property_name:
			return int(property.usage)
	return 0


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
