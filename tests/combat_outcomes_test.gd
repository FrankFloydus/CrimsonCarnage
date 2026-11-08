extends SceneTree
## Scoped committed outcomes, weak attribution, replay and reaction ordering.

const HEALTH := CombatAttributes.Id.HEALTH
const MANA := CombatAttributes.Id.MANA
const MAX_HEALTH := CombatAttributes.Id.MAX_HEALTH
const MAX_MANA := CombatAttributes.Id.MAX_MANA

var _checks: int = 0
var _failures: int = 0
var _observed: Array[CombatOutcome] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var handle := CombatOutcomeDispatcher.subscribe(self, _record)
	_test_per_target_snapshot_and_replay()
	_test_damage_lifesteal()
	_test_queue_order_and_immutable_values()
	_test_once_per_attack()
	_test_linked_damage_echo()
	_test_linked_healing_copy()
	_test_one_empowerment_use_per_attack()
	_test_inspector_modes()
	CombatOutcomeDispatcher.unsubscribe(handle)
	print("Combat outcome checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_per_target_snapshot_and_replay() -> void:
	var caster := _actor(200.0)
	var other_caster := _actor(300.0)
	var targets := [_actor(), _actor(), _actor(), _actor()]
	var reaction := _mana_reaction()
	var cast := CombatOutcomeContext.create(caster).with_delivery(&"area_burst")
	cast.set_execution_reactions([reaction])
	cast.capture_amount_basis()
	var other_cast := CombatOutcomeContext.create(other_caster)
	other_cast.set_execution_reactions([reaction])
	other_cast.capture_amount_basis()
	caster.set_numeric_base_value(MAX_MANA, 400.0)
	CombatOutcomeDispatcher.begin_batch()
	var first: CombatOutcome
	for target: ActorAttributes in targets:
		var hit := _hit(cast.for_contact(target), target)
		if first == null:
			first = hit
	_hit(cast.for_contact(targets[0]), targets[0])
	_hit(other_cast.for_contact(targets[0]), targets[0])
	CombatOutcomeDispatcher.publish_committed(first)
	_check(caster.get_value(MANA) == 0.0, "Reactions wait for the entire burst to commit")
	CombatOutcomeDispatcher.end_batch()
	_check(caster.get_value(MANA) == 8.0,
			"Four unique confirmed hits refund 1% of captured capacity even after capacity changes")
	_check(other_caster.get_value(MANA) == 3.0, "A different root uses its own captured values and claims")
	_check(first.context.root_execution_id == cast.root_execution_id and first.context.contact_id > 0,
			"Contact retains the root and assigns an independent identity")
	_check(_observed.count(first) == 1, "Replayed committed identity reaches each subscriber once")
	var refund := _find_child(first)
	_check(refund != null and refund.target_id == caster.get_instance_id()
			and refund.context.parent_event_id == first.id
			and first.target_id == targets[0].get_instance_id(),
			"Child transaction records its parent and recipient without replacing the hit target")
	caster.free()
	_check(first.context.actor(CombatOutcomeContext.Role.CREDITED_OWNER) == null,
			"Detached outcomes resolve deleted actors safely")
	other_caster.free()
	for target: ActorAttributes in targets:
		target.free()


func _test_damage_lifesteal() -> void:
	var caster := _actor()
	var other_caster := _actor()
	var target := _actor()
	caster.set_base_value(HEALTH, 50.0)
	other_caster.set_base_value(HEALTH, 50.0)
	var reaction := ReactionDefinition.new()
	reaction.trigger = ReactionDefinition.Trigger.ON_HEALTH_DAMAGED
	reaction.timing_filter = ReactionDefinition.TimingFilter.DIRECT
	var action := HealReactionAction.new()
	action.amount = AmountDefinition.new()
	action.amount.source = AmountDefinition.Source.OUTCOME_PERCENT
	action.amount.outcome_basis = AmountDefinition.OutcomeBasis.ACTUAL_HEALTH_DAMAGE
	action.amount.percentage = 10.0
	reaction.actions = [action]
	var cast := CombatOutcomeContext.create(caster).for_contact(target).with_delivery(&"projectile")
	var second_cast := CombatOutcomeContext.create(other_caster).for_contact(target)
	var direct := _damage(cast, target, 6.0, reaction)
	_damage(second_cast, target, 13.0, reaction)
	var periodic := cast.with_timing(CombatOutcomeContext.Timing.PERIODIC)
	var periodic_copy := periodic.with_provenance(CombatOutcomeContext.Provenance.COPIED)
	_damage(periodic, target, 20.0, reaction)
	_damage(periodic_copy, target, 20.0, reaction)
	_damage(cast.with_provenance(CombatOutcomeContext.Provenance.REFLECTED), target, 20.0, reaction)
	_damage(cast, target, 0.0, reaction)
	_check(is_equal_approx(caster.get_value(HEALTH), 50.6),
			"Lifesteal uses 10% of 6 actual lost Health; periodic, reflected and fully prevented damage give none")
	_check(is_equal_approx(other_caster.get_value(HEALTH), 51.3), "Other casts heal only their credited owner")
	_check(periodic.tick_id > 0 and periodic_copy.timing == CombatOutcomeContext.Timing.PERIODIC
			and periodic_copy.provenance & CombatOutcomeContext.Provenance.COPIED,
			"Copied provenance is independent of periodic timing and identity")
	var heal := _find_child(direct)
	_check(heal != null and is_equal_approx(heal.get_amount(&"requested_healing"), 0.6),
			"Healing records the correctly scoped requested amount")
	reaction.trigger = ReactionDefinition.Trigger.ON_HIT
	_check(reaction.get_validation_error() == &"incompatible_reaction_outcome_basis",
			"Validation catches damage amounts attached to contact instead of damage")
	caster.free()
	other_caster.free()
	target.free()


func _test_queue_order_and_immutable_values() -> void:
	var caster := _actor()
	var target := _actor()
	var cast := CombatOutcomeContext.create(caster)
	var log: Array[StringName] = []
	var observer := func(event: CombatOutcome) -> void:
		log.append(StringName(event.get_event()["type"]))
		if event.get_event()["type"] == &"queue_test_parent":
			CombatOutcomeDispatcher.publish(event.context.for_child(event, target),
					{"type": &"queue_test_child"})
			log.append(&"parent_callback_finished")
	var handle := CombatOutcomeDispatcher.subscribe(self, observer)
	var metadata := {"nested": [{"value": 3.0}]}
	var parent := CombatOutcomeDispatcher.publish(cast,
			{"type": &"queue_test_parent", "metadata": metadata})
	metadata["nested"][0]["value"] = 8.0
	var snapshot: Dictionary = parent.get_event()["metadata"]
	_check(log == [&"queue_test_parent", &"parent_callback_finished", &"queue_test_child"],
			"Nested commits dispatch only after the publishing subscriber returns")
	_check(parent.get_event().is_read_only() and snapshot.is_read_only()
			and snapshot["nested"].is_read_only() and snapshot["nested"][0]["value"] == 3.0,
			"Committed event data is a recursively read-only snapshot")
	CombatOutcomeDispatcher.unsubscribe(handle)
	caster.free()
	target.free()


func _test_once_per_attack() -> void:
	var caster := _actor(200.0)
	var target := _actor()
	var reaction := _mana_reaction()
	reaction.once_policy = ReactionDefinition.OncePolicy.PER_ATTACK
	var cast := CombatOutcomeContext.create(caster)
	cast.set_execution_reactions([reaction])
	cast.capture_amount_basis()
	var first_attack := cast.for_attack()
	_hit(first_attack.for_contact(target), target)
	_hit(first_attack.for_contact(target), target)
	_hit(cast.for_attack().for_contact(target), target)
	_check(caster.get_value(MANA) == 4.0, "Multiple contacts share an explicit attack identity")
	caster.free()
	target.free()


func _test_linked_damage_echo() -> void:
	var caster := _combat_actor()
	var primary := _combat_actor()
	var secondary := _combat_actor()
	caster.attributes.set_base_value(CombatAttributes.Id.MAGIC_POWER, 20.0)
	primary.attributes.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 25.0)
	secondary.attributes.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	var action := EchoDamageReactionAction.new()
	action.copy_policy = CombatCopyPolicy.new()
	action.copy_policy.effectiveness_percent = 50.0
	var observation := _linked_observation(ReactionDefinition.Trigger.ON_DAMAGE_RESOLVED, action)
	_install_observer(caster, secondary, observation)
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = 249
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(20.0)
	execution.power_coefficient = 1.0
	effect.executions = [execution]
	var context := caster.create_effect_context(PackedStringArray(["Ability.Spell"]))
	var event_index := _observed.size()
	primary.receive_hit(context, [effect], 0.0, 1.0)
	_check(is_equal_approx(primary.attributes.get_value(HEALTH), 70.0),
			"Primary damage resolves its source scaling and resistance")
	_check(is_equal_approx(secondary.attributes.get_value(HEALTH), 90.0),
			"Echo uses 50% of the evaluated source packet and independently resolves secondary resistance")
	var original := _find_kind_after(CombatOutcome.Kind.DAMAGE, event_index)
	var echo := _find_child(original) if original != null else null
	_check(echo != null and echo.target_id == secondary.attributes.get_instance_id()
			and echo.context.provenance & CombatOutcomeContext.Provenance.COPIED,
			"Echo has copied provenance and the original damage parent")
	caster.get_parent().free()
	primary.get_parent().free()
	secondary.get_parent().free()


func _test_linked_healing_copy() -> void:
	var caster := _combat_actor()
	var primary := _combat_actor()
	var secondary := _combat_actor()
	secondary.attributes.set_base_value(HEALTH, 94.0)
	var incoming := HealingReceivedEffectComponent.new()
	incoming.multiplier = 0.5
	var reduction := GameplayEffectDefinition.new()
	reduction.effect_id = 250
	reduction.timing = GameplayEffectDefinition.Timing.INFINITE
	reduction.components = [incoming]
	secondary.apply_effect_spec_to_self(secondary.make_outgoing_spec(reduction))

	var action := CopyHealingReactionAction.new()
	action.copy_policy = CombatCopyPolicy.new()
	action.copy_policy.effectiveness_percent = 50.0
	var observation := _linked_observation(ReactionDefinition.Trigger.ON_HEAL, action)
	_install_observer(caster, secondary, observation)
	var profile := HealingProfile.new()
	profile.source_percent = 200.0
	var original := HealingResolver.resolve_and_commit(HealingRequest.new(primary.attributes, 20.0, profile))
	var event := CombatOutcomeDispatcher.publish(CombatOutcomeContext.create(caster.attributes), original.get_event())
	var copy := _find_child(event)
	_check(original.actual_restoration == 0.0 and copy != null and copy.get_amount(&"requested_healing") == 20.0,
			"Before-overheal copying can copy fully capped source healing")
	_check(copy != null and copy.get_amount(&"scaled_healing") == 10.0
			and copy.get_amount(&"actual_restoration") == 6.0 and copy.get_amount(&"overheal") == 4.0,
			"Copied healing evaluates incoming effects once and clamps against the new recipient")
	_check(copy != null and _find_child(copy) == null, "Copied healing cannot copy itself")
	caster.get_parent().free()
	primary.get_parent().free()
	secondary.get_parent().free()


func _test_one_empowerment_use_per_attack() -> void:
	var caster := _combat_actor()
	var primary := _combat_actor()
	var second := _combat_actor()
	var third := _combat_actor()
	(second.get_parent() as Node3D).position = Vector3(1.0, 0.0, 0.0)
	(third.get_parent() as Node3D).position = Vector3(2.0, 0.0, 0.0)
	var reaction := ReactionDefinition.new()
	reaction.trigger = ReactionDefinition.Trigger.ON_DAMAGE_RESOLVED
	reaction.recipient = ReactionDefinition.Recipient.NEARBY_TARGETS
	reaction.nearby_targeting = AbilityTargetingDefinition.new()
	reaction.nearby_targeting.shape = AbilityTargetingDefinition.Shape.DISK
	reaction.nearby_targeting.radius = 5.0
	reaction.nearby_targeting.max_targets = 2
	reaction.actions = [EchoDamageReactionAction.new()]
	var behavior := ObserveOutcomeEffectComponent.new()
	behavior.reactions = [reaction]
	behavior.attack_uses = 1
	var buff := GameplayEffectDefinition.new()
	buff.effect_id = 251
	buff.timing = GameplayEffectDefinition.Timing.DURATION
	buff.duration = 5.0
	buff.components = [behavior]
	var handle := caster.apply_effect_spec_to_self(caster.make_outgoing_spec(buff))
	_check(handle > 0, "Temporary per-attack empowerment retains one owned effect handle")
	var damage := GameplayEffectDefinition.new()
	damage.effect_id = 252
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(10.0)
	damage.executions = [execution]
	var first_attack := caster.create_effect_context()
	first_attack.outcome_context = first_attack.outcome_context.for_attack()
	var another_attack := caster.create_effect_context()
	var suppressed: Array[Dictionary] = []
	caster.combat_event.connect(func(event: Dictionary) -> void:
		if event["type"] == &"reaction_suppressed":
			suppressed.append(event))
	primary.receive_hit(first_attack, [damage], 0.0, 1.0)
	primary.receive_hit(another_attack, [damage], 0.0, 1.0)
	primary.receive_hit(first_attack, [damage], 0.0, 1.0)
	_check(primary.attributes.get_value(HEALTH) == 70.0
			and second.attributes.get_value(HEALTH) == 80.0
			and third.attributes.get_value(HEALTH) == 80.0,
			"Two packets from the same paid attack cleave both nearby recipients; a different attack cannot use it")
	_check(suppressed.size() == 1 and suppressed[0]["reason"] == &"attack_use_budget"
			and suppressed[0]["parent_event_id"] > 0,
			"An exhausted attack budget emits a causal suppression reason")
	caster.advance(5.0)
	primary.receive_hit(first_attack, [damage], 0.0, 1.0)
	_check(not caster.effects.has_retained_effect(handle)
			and second.attributes.get_value(HEALTH) == 80.0 and third.attributes.get_value(HEALTH) == 80.0,
			"Expiry revokes the paid attack and prevents later packets from echoing")
	for system in [caster, primary, second, third]:
		system.get_parent().free()


func _test_inspector_modes() -> void:
	var reaction := _mana_reaction()
	var refreshes := [0]
	reaction.property_list_changed.connect(func() -> void: refreshes[0] += 1)
	_check((_property_usage(reaction, &"removal_reason") & PROPERTY_USAGE_EDITOR) == 0
			and (_property_usage(reaction, &"link_slot") & PROPERTY_USAGE_EDITOR) == 0
			and (_property_usage(reaction, &"nearby_targeting") & PROPERTY_USAGE_EDITOR) == 0,
			"Ordinary hit reactions hide removal, linked actor, and nearby actor fields")
	reaction.trigger = ReactionDefinition.Trigger.ON_EFFECT_REMOVED
	reaction.removal_reason = ReactionDefinition.RemovalFilter.DISPELLED
	_check((_property_usage(reaction, &"removal_reason") & PROPERTY_USAGE_EDITOR) != 0,
			"Effect removal reactions expose the removal reason")
	reaction.recipient = ReactionDefinition.Recipient.REMOVAL_INSTIGATOR
	reaction.removal_reason = ReactionDefinition.RemovalFilter.EXPIRED
	var context := CombatOutcomeContext.create()
	var expired := CombatOutcome.new(context, {"type": &"effect_removed",
			"removal_reason": GameplayEffectRuntime.RemovalReason.EXPIRED})
	var dispelled := CombatOutcome.new(context, {"type": &"effect_removed",
			"removal_reason": GameplayEffectRuntime.RemovalReason.DISPELLED})
	_check((_property_usage(reaction, &"removal_reason") & PROPERTY_USAGE_EDITOR) == 0
			and not reaction.matches(expired) and reaction.matches(dispelled),
			"Only a dispel can identify a removal instigator, regardless of the stored removal filter")
	reaction.recipient = ReactionDefinition.Recipient.CREDITED_OWNER
	reaction.trigger = ReactionDefinition.Trigger.ON_HIT
	var saved := reaction.duplicate() as ReactionDefinition
	_check(saved.removal_reason == ReactionDefinition.RemovalFilter.EXPIRED
			and saved.get_validation_error().is_empty(),
			"A hidden removal reason is retained in storage and ignored by other triggers")
	reaction.recipient = ReactionDefinition.Recipient.LINKED_ACTOR
	reaction.link_slot = &"Test.Copy"
	_check((_property_usage(reaction, &"link_slot") & PROPERTY_USAGE_EDITOR) != 0
			and (_property_usage(reaction, &"link_range") & PROPERTY_USAGE_EDITOR) != 0
			and (_property_usage(reaction, &"link_exclude_trigger_target") & PROPERTY_USAGE_EDITOR) != 0
			and (_property_usage(reaction, &"nearby_targeting") & PROPERTY_USAGE_EDITOR) == 0,
			"Linked recipients expose only the link fields")
	reaction.trigger = ReactionDefinition.Trigger.ON_BATCH_COMPLETE
	_check((_property_usage(reaction, &"link_slot") & PROPERTY_USAGE_EDITOR) != 0
			and (_property_usage(reaction, &"link_exclude_trigger_target") & PROPERTY_USAGE_EDITOR) == 0,
			"Linked batch reactions hide the target exclusion toggle because a batch has no single target")
	reaction.trigger = ReactionDefinition.Trigger.ON_HIT
	reaction.recipient = ReactionDefinition.Recipient.NEARBY_TARGETS
	_check((_property_usage(reaction, &"link_slot") & PROPERTY_USAGE_EDITOR) == 0
			and (_property_usage(reaction, &"nearby_targeting") & PROPERTY_USAGE_EDITOR) != 0
			and refreshes[0] >= 4,
			"Nearby recipients expose the area query and selector changes notify the Inspector")
	reaction.required_provenance = CombatOutcomeContext.Provenance.ORIGINAL
	reaction.excluded_provenance = CombatOutcomeContext.Provenance.ORIGINAL
	var hit := CombatOutcome.new(context, {"type": &"hit_outcome", "outcome": &"hit"})
	_check(reaction.matches(hit)
			and _property_metadata(reaction, &"required_provenance").hint_string == "Copied:2,Reflected:4,Transferred:8,Retaliation:16,Pet:32",
			"The universal original-attribution bit stays stored and is unavailable as a provenance filter")
	reaction.recipient = ReactionDefinition.Recipient.CREDITED_OWNER
	reaction.once_policy = ReactionDefinition.OncePolicy.PER_EXECUTION
	reaction.fire_limit = 2
	_check((_property_usage(reaction, &"fire_limit") & PROPERTY_USAGE_EDITOR) == 0
			and reaction.claim(hit, "test", Callable()).is_empty()
			and reaction.claim(hit, "test", Callable()) == &"once_policy",
			"Once per execution hides and ignores the separate fire limit")

	var apply := ApplyEffectReactionAction.new()
	apply.effect = GameplayEffectDefinition.new()
	apply.amount = AmountDefinition.fixed(5.0)
	_check((_property_usage(apply, &"amount") & PROPERTY_USAGE_EDITOR) == 0
			and (_property_usage(apply, &"amount") & PROPERTY_USAGE_STORAGE) != 0
			and apply.get_validation_error(ReactionDefinition.Trigger.ON_HIT).is_empty(),
			"An inactive reaction amount remains stored but does not require a magnitude key")
	apply.magnitude_tag = &"Data.Test.Amount"
	_check((_property_usage(apply, &"amount") & PROPERTY_USAGE_EDITOR) != 0
			and apply.amount.fixed_amount == 5.0,
			"Entering a magnitude key restores the authored amount field")

	var observation := ObserveOutcomeEffectComponent.new()
	_check((_property_usage(observation, &"reset_attack_uses_on_reapply") & PROPERTY_USAGE_EDITOR) == 0,
			"Unlimited observers hide attack budget refill")
	observation.attack_uses = 2
	_check((_property_usage(observation, &"reset_attack_uses_on_reapply") & PROPERTY_USAGE_EDITOR) != 0,
			"Attack budgets expose refill policy")
	_check((_property_usage(CombatCopyPolicy.new(), &"critical_rule") & PROPERTY_USAGE_EDITOR) == 0
			and EchoDamageReactionAction.new().critical_rule == EchoDamageReactionAction.CriticalRule.REUSE,
			"Critical handling is a damage-copy choice and defaults to inheriting the original result")
	_check(_property_metadata(RestoreResourceReactionAction.new(), &"resource").hint_string == "Mana:1,Stamina:2",
			"Resource recovery offers only the two pools it can actually restore")


func _linked_observation(trigger: ReactionDefinition.Trigger, action: CombatReactionAction) -> ReactionDefinition:
	var reaction := ReactionDefinition.new()
	reaction.trigger = trigger
	reaction.recipient = ReactionDefinition.Recipient.LINKED_ACTOR
	reaction.link_slot = &"Test.Copy"
	reaction.link_exclude_trigger_target = false
	reaction.excluded_provenance = 0
	reaction.actions = [action]
	return reaction


func _install_observer(caster: AbilitySystem, secondary: AbilitySystem, reaction: ReactionDefinition) -> void:
	var mark := GameplayEffectDefinition.new()
	mark.effect_id = 253
	mark.timing = GameplayEffectDefinition.Timing.INFINITE
	mark.exclusive_owner_slot = reaction.link_slot
	var marked := secondary.apply_effect_spec_to_self(caster.make_outgoing_spec(mark))
	_check(marked > 0, "Copy recipient occupies the source's retained-effect slot")
	var behavior := ObserveOutcomeEffectComponent.new()
	behavior.reactions = [reaction]
	var observation := GameplayEffectDefinition.new()
	observation.effect_id = 254
	observation.timing = GameplayEffectDefinition.Timing.INFINITE
	observation.components = [behavior]
	var observed := caster.apply_effect_spec_to_self(caster.make_outgoing_spec(observation))
	_check(observed > 0, "Copy observation is owned by a retained effect")


func _combat_actor() -> AbilitySystem:
	var owner := Node3D.new()
	var attributes := _actor()
	var system := AbilitySystem.new()
	system.attributes = attributes
	owner.add_child(attributes)
	owner.add_child(system)
	root.add_child(owner)
	return system


func _mana_reaction() -> ReactionDefinition:
	var reaction := ReactionDefinition.new()
	reaction.once_policy = ReactionDefinition.OncePolicy.PER_EXECUTION_TARGET
	var action := RestoreResourceReactionAction.new()
	action.amount = AmountDefinition.new()
	action.amount.source = AmountDefinition.Source.RESOURCE_PERCENT
	action.amount.timing = AmountDefinition.Timing.SNAPSHOT
	action.amount.percentage = 1.0
	reaction.actions = [action]
	return reaction


func _hit(context: CombatOutcomeContext, target: ActorAttributes) -> CombatOutcome:
	return CombatOutcomeDispatcher.publish(context, {"type": &"hit_outcome",
			"outcome": &"hit", "target_id": target.get_instance_id()})


func _damage(
		context: CombatOutcomeContext, target: ActorAttributes, actual: float,
		reaction: ReactionDefinition
) -> CombatOutcome:
	return CombatOutcomeDispatcher.publish(context, {"type": &"damage", "target_id": target.get_instance_id(),
			"raw_magnitude": 100.0, "resolved_amount": 60.0, "health_damage": actual}, [reaction])


func _actor(max_mana: float = 100.0) -> ActorAttributes:
	var actor := ActorAttributes.new()
	actor.set_numeric_base_value(MAX_HEALTH, 100.0)
	actor.set_numeric_base_value(MAX_MANA, max_mana)
	actor.restore_resources()
	actor.set_base_value(MANA, 0.0)
	return actor


func _record(outcome: CombatOutcome) -> void:
	_observed.append(outcome)


func _find_child(parent: CombatOutcome) -> CombatOutcome:
	for outcome in _observed:
		if outcome.context.parent_event_id == parent.id:
			return outcome
	return null


func _find_kind_after(kind: CombatOutcome.Kind, start: int) -> CombatOutcome:
	for index in range(start, _observed.size()):
		if _observed[index].kind == kind:
			return _observed[index]
	return null


func _property_usage(resource: Resource, property_name: StringName) -> int:
	return _property_metadata(resource, property_name).get("usage", 0)


func _property_metadata(resource: Resource, property_name: StringName) -> Dictionary:
	for property in resource.get_property_list():
		if property.name == property_name:
			return property
	return {}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
