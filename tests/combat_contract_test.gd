extends SceneTree
## Combat 2.0 action ownership, explicit payload delivery and modifier-lifetime contracts.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

class WaitingExecution extends AbilityExecution:
	func begin(cast: AbilityCast) -> void:
		cast.data[&"began"] = true

	func handle_event(cast: AbilityCast, event_name: StringName) -> void:
		cast.data[&"last_event"] = event_name

	func input_released(cast: AbilityCast) -> void:
		cast.finish()

	func end(cast: AbilityCast, cancelled: bool) -> void:
		cast.data[&"cancelled"] = cancelled


class PlaybackExecution extends AbilityExecution:
	const REPLACEMENT_ID: int = 217

	func get_animation_name() -> StringName:
		return &"shared_playback"

	func begin(cast: AbilityCast) -> void:
		cast.get_system().play_cast_animation(cast, 1.0)

	func handle_event(cast: AbilityCast, event_name: StringName) -> void:
		if event_name == &"cancel_playback":
			var system := cast.get_system()
			cast.cancel()
			cast.data[&"replacement_failure"] = system.get_activation_failure(REPLACEMENT_ID)
		else:
			cast.data[&"unexpected_event"] = event_name

const COMMITMENT = preload("res://tests/ability_commit_fixture.gd")

var _checks: int = 0
var _failures: int = 0
var _fixtures: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_activation_cost_cooldown_and_tags()
	_test_spec_cost_magnitudes()
	_test_shared_cooldown_and_deferred_commit()
	_test_independent_grant_specs()
	_test_ability_asset_tag_conflicts()
	_test_independent_activation_lifetimes()
	_test_activation_conflicts_precede_callbacks()
	_test_cancelled_animation_frame_cannot_transfer_ownership()
	_test_reentrant_interruption()
	_test_explicit_connected_payload()
	_test_modifier_lifetime()
	_test_invalid_projectile_and_payload_reject_before_commit()
	for fixture in _fixtures:
		fixture.free()
	print("Combat 2.0 contract checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _fixture(with_startup_effects: bool = false) -> AbilitySystem:
	var holder := Node.new()
	holder.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := ActorAttributes.new() if with_startup_effects else ATTRIBUTE_FIXTURE.new_attributes()
	var system := AbilitySystem.new()
	system.attributes = attributes
	if with_startup_effects:
		ATTRIBUTE_FIXTURE.configure(system)
	holder.add_child(attributes)
	holder.add_child(system)
	root.add_child(holder)
	_fixtures.append(holder)
	return system


func _waiting_ability(id: int) -> AbilityDefinition:
	var ability := AbilityDefinition.new()
	ability.ability_id = id
	ability.execution = WaitingExecution.new()
	ability.resource_costs = [COMMITMENT.make_cost(AmountDefinition.Pool.MANA, 12.0)]
	ability.charge_pool = COMMITMENT.make_cooldown(2.0)
	ability.activation_tags = PackedStringArray(["State.ContractAction", "State.CombatAction"])
	ability.interruption_policy = AbilityInterruptionPolicy.new()
	ability.interruption_policy.activation_blockers = PackedStringArray(["State.CombatAction"])
	ability.interruption_policy.cancel_on_tags = PackedStringArray(["State.ContractInterrupt"])
	return ability


func _test_activation_cost_cooldown_and_tags() -> void:
	var system := _fixture(true)
	var ability := _waiting_ability(200)
	ability.required_tags = PackedStringArray(["Training.Contract"])
	_check(system.grant_ability(ability), "An unlocked ability is registered through the shared interface")
	_check(not system.try_activate(ability.ability_id), "Required tags gate activation before resources are spent")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 100.0, "Rejected activation does not spend Mana")
	system.tags.add_tag(&"Training.Contract")
	system.tags.add_tag(&"State.ContractAction")
	_check(system.try_activate(ability.ability_id), "A qualified actor starts its authored execution")
	var cast := system.get_active_cast(ability.ability_id)
	_check(cast != null and cast.data.get(&"began", false), "Execution receives per-cast runtime state")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 88.0, "Authored cost is committed once")
	_near(system.get_cooldown_remaining(ability.ability_id), 2.0, "Authored cooldown begins at activation")
	_check(system.tags.get_count(&"State.ContractAction") == 2, "Action tags retain independent ownership")
	_check(not system.try_activate(ability.ability_id), "A second request cannot overlap the current action")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 88.0, "Overlapping requests do not charge another cost")
	system.advance(0.5)
	_near(cast.elapsed, 0.5, "Execution advances on its ordinary action clock")
	_near(system.get_cooldown_remaining(ability.ability_id), 1.5, "Cooldown advances independently")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 90.5,
			"The periodic recovery effect ticks once per period during the active cast")
	system.tags.add_tag(&"State.ContractInterrupt")
	_check(system.get_active_cast(ability.ability_id) == null and cast.data.get(&"cancelled", false),
			"An authored interruption ends the action")
	_check(not system.tags.has_tag(&"State.CombatAction"), "Interruption removes the action's owned lock")
	_check(system.tags.get_count(&"State.ContractAction") == 1, "Interruption preserves an external grant of the same tag")
	system.tags.remove_tag(&"State.ContractInterrupt")
	_check(not system.try_activate(ability.ability_id), "Cancelling does not erase the committed cooldown")
	system.advance(2.0)
	_check(system.try_activate(ability.ability_id), "The action becomes available after its authored cooldown")
	system.revoke_ability(ability.ability_id)
	_check(system.get_active_cast(ability.ability_id) == null, "Revoking an active ability cleans up its cast")
	_check(system.get_activation_failure(ability.ability_id) == &"ability_not_granted", "Revocation removes future activation access")


func _test_spec_cost_magnitudes() -> void:
	var system := _fixture()
	var ability := _waiting_ability(201)
	var amount := ability.resource_costs[0].amount
	amount.source = AmountDefinition.Source.STAT_PERCENT
	amount.stat = CombatAttributes.Id.INTELLECT
	amount.percentage = 110.0
	var handle := system.grant_ability_spec(ability)
	system.attributes.set_base_value(CombatAttributes.Id.INTELLECT, 10.0)
	system.attributes.set_base_value(CombatAttributes.Id.MANA, 10.0)
	_check(system.get_activation_failure_for_spec(handle) == &"insufficient_resource",
			"Eligibility evaluates the authored percentage of the source stat")
	system.attributes.set_base_value(CombatAttributes.Id.MANA, 11.0)
	_check(system.try_activate_spec(handle), "The exact resolved dynamic cost can commit")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 0.0,
			"Commit applies the same dynamic magnitude as the affordability check")


func _test_shared_cooldown_and_deferred_commit() -> void:
	var system := _fixture()
	var deferred := _waiting_ability(202)
	var followup := _waiting_ability(203)
	deferred.interruption_policy.cost_timing = AbilityInterruptionPolicy.CommitTiming.ON_RELEASE
	deferred.interruption_policy.cooldown_timing = AbilityInterruptionPolicy.CommitTiming.ON_RELEASE
	deferred.charge_pool = COMMITMENT.make_cooldown(2.0, &"fixture_shared")
	followup.charge_pool = COMMITMENT.make_cooldown(2.0, &"fixture_shared")
	deferred.resource_costs.append(COMMITMENT.make_cost(AmountDefinition.Pool.STAMINA, 5.0))
	system.grant_ability(deferred)
	system.grant_ability(followup)
	_check(system.try_activate(deferred.ability_id), "An execution can defer commit until a later event")
	var cast := system.get_active_cast(deferred.ability_id)
	if cast == null:
		return
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 100.0, "Activation alone does not pay a deferred cost")
	cast.phase = AbilityCast.Phase.RELEASE
	system.attributes.set_base_value(CombatAttributes.Id.STAMINA, 4.0)
	_check(not cast.commit(), "Deferred commit rechecks all current pool costs")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 100.0, "A rejected multi-pool cost pays nothing")
	_near(system.get_cooldown_remaining(deferred.ability_id), 0.0, "A rejected commit grants no cooldown")
	system.attributes.set_base_value(CombatAttributes.Id.STAMINA, 5.0)
	_check(cast.commit() and cast.commit(), "Repeated commit calls cannot apply the same cast's effects twice")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 88.0, "A successful commit pays Mana once")
	_near(system.attributes.get_value(CombatAttributes.Id.STAMINA), 0.0, "The same commit pays the Stamina cost")
	cast.finish()
	_check(system.get_activation_failure(followup.ability_id) == &"no_charges",
			"Different ability definitions can reserve charges from one group")
	_near(system.get_cooldown_remaining(followup.ability_id), 2.0,
			"The cooldown query reads the shared pool's recharge clock")
	system.advance(2.01)
	_check(system.get_activation_failure(followup.ability_id).is_empty(), "Recharge restores the shared charge")
	var reentrant := _fixture()
	var interrupted := _waiting_ability(204)
	reentrant.tags.changed.connect(func(tag: StringName, present: bool) -> void:
		if tag == &"State.CombatAction" and present:
			reentrant.attributes.set_base_value(CombatAttributes.Id.MANA, 1.0))
	reentrant.grant_ability(interrupted)
	_check(not reentrant.try_activate(interrupted.ability_id),
			"Commit fails if a synchronous activation listener makes the cost unaffordable")
	_check(reentrant.get_available_charges(interrupted.ability_id) == 1
			and reentrant.get_active_cast(interrupted.ability_id) == null,
			"A failed commit releases its reserved charge and action ownership")
	_near(reentrant.attributes.get_value(CombatAttributes.Id.MANA), 1.0, "A failed commit never debits an unaffordable cost")


func _test_independent_grant_specs() -> void:
	var system := _fixture()
	var definition := AbilityDefinition.new()
	definition.ability_id = 205
	definition.execution = WaitingExecution.new()
	var first_source := Resource.new()
	var second_source := Resource.new()
	var first := system.grant_ability_spec(definition, 3, first_source)
	var second := system.grant_ability_spec(definition, 7, second_source)
	_check(first > 0 and second > 0 and first != second,
			"Two grants of one definition have distinct handles")
	_check(system.try_activate_spec(first) and system.try_activate_spec(second),
			"Each grant can own an independent activation")
	var first_cast := system.get_active_cast_for_spec(first)
	var second_cast := system.get_active_cast_for_spec(second)
	_check(first_cast != null and second_cast != null and first_cast != second_cast,
			"Active state is indexed by grant handle")
	if first_cast == null or second_cast == null:
		return
	_check(first_cast.grant_spec.source_object == first_source
			and second_cast.grant_spec.source_object == second_source,
			"Each activation can inspect its grant's source object")
	var effect := GameplayEffectDefinition.new()
	_check(first_cast.make_effect_spec(effect).level == 3 and second_cast.make_effect_spec(effect).level == 7,
			"Outgoing effect specs use the grant's level")
	_check(system.get_active_cast(definition.ability_id) == first_cast,
			"ID-based input resolves the first grant")
	system.revoke_ability_spec(first)
	_check(first_cast.finished and system.get_ability_spec(first) == null
			and system.get_active_cast(definition.ability_id) == second_cast,
			"Revoking one grant leaves the other activation intact")
	system.release_ability_spec(second)
	_check(second_cast.finished and system.get_active_cast_for_spec(second) == null,
			"Input release addresses only the chosen grant")


func _test_ability_asset_tag_conflicts() -> void:
	var system := _fixture()
	var attacker := AbilityDefinition.new()
	attacker.ability_id = 206
	attacker.ability_tags = PackedStringArray(["Ability.Test.Attack.Light"])
	attacker.execution = WaitingExecution.new()
	var interrupt := AbilityDefinition.new()
	interrupt.ability_id = 207
	interrupt.execution = WaitingExecution.new()
	interrupt.cancel_ability_tags = PackedStringArray(["Ability.Test.Attack"])
	interrupt.block_ability_tags = interrupt.cancel_ability_tags.duplicate()
	var attacker_handle := system.grant_ability_spec(attacker)
	var first_block := system.grant_ability_spec(interrupt)
	var second_block := system.grant_ability_spec(interrupt)
	_check(system.try_activate_spec(attacker_handle), "The tagged attack can start before the blocker")
	var attack := system.get_active_cast_for_spec(attacker_handle)
	_check(system.try_activate_spec(first_block) and attack != null and attack.finished
			and attack.data.get(&"cancelled", false),
			"Starting an ability can cancel matching descendant asset tags")
	_check(system.try_activate_spec(second_block)
			and system.get_activation_failure_for_spec(attacker_handle) == &"blocked_by_ability_tags",
			"Active abilities can block subsequent matching asset tags")
	system.cancel_ability_spec(first_block)
	_check(system.get_activation_failure_for_spec(attacker_handle) == &"blocked_by_ability_tags",
			"Removing one blocker preserves the independent second grant's block")
	system.cancel_ability_spec(second_block)
	_check(system.try_activate_spec(attacker_handle), "The last blocker releases the attack family")


func _test_independent_activation_lifetimes() -> void:
	var system := _fixture()
	var attack := _waiting_ability(208)
	var other_attack := _waiting_ability(209)
	var sprint := _waiting_ability(210)
	sprint.interruption_policy.activation_blockers = PackedStringArray(["State.Encumbered"])
	sprint.interruption_policy.cancel_on_tags = PackedStringArray(["State.Encumbered"])
	sprint.activation_tags = PackedStringArray(["State.Sprinting"])
	sprint.resource_costs.clear()
	sprint.charge_pool = null
	for definition: AbilityDefinition in [attack, other_attack, sprint]:
		system.grant_ability(definition)
	_check(system.try_activate(sprint.ability_id) and system.get_animation_cast() == null,
			"An animation-free activation leaves the playback slot available")
	var sprint_cast := system.get_active_cast(sprint.ability_id)
	_check(system.try_activate(attack.ability_id), "Combat can start alongside an independent action")
	var attack_cast := system.get_active_cast(attack.ability_id)
	_check(system.get_activation_failure(other_attack.ability_id) == &"blocked_by_tags",
			"Authored tags make these combat actions mutually exclusive")
	_check(system.get_activation_failure(sprint.ability_id) == &"action_in_progress",
			"An independent ability cannot overlap itself")
	system.advance(0.5)
	_near(sprint_cast.elapsed, 0.5, "Independent actions advance on the ability clock")
	_near(attack_cast.elapsed, 0.5, "Combat advances while an independent action is running")
	system.handle_animation_event(&"release")
	_check(not attack_cast.data.has(&"last_event") and not sprint_cast.data.has(&"last_event"),
			"A method event with no playback owner cannot reach either cast")
	system.tags.add_tag(&"State.Encumbered")
	_check(sprint_cast.finished and sprint_cast.data.get(&"cancelled", false),
			"An interruption tag cancels the matching independent cast")
	_check(system.get_active_cast(attack.ability_id) == attack_cast and not system.tags.has_tag(&"State.Sprinting"),
			"An interruption removes only its own activation and tags")
	_check(system.get_activation_failure(sprint.ability_id) == &"blocked_by_tags",
			"The same state can prevent a new activation")
	system.tags.remove_tag(&"State.Encumbered")
	_check(system.try_activate(sprint.ability_id), "An independent cast can start during combat")
	var replacement := system.get_active_cast(sprint.ability_id)
	sprint_cast.cancel()
	_check(system.get_active_cast(sprint.ability_id) == replacement,
			"Late cleanup from the prior instance cannot cancel its replacement")
	system.release_ability(sprint.ability_id)
	_check(replacement.finished and not replacement.data.get(&"cancelled", true)
			and system.get_active_cast(attack.ability_id) == attack_cast,
			"Release reaches only the named execution and can finish it normally")
	_check(system.try_activate(sprint.ability_id), "The held action can start again after release")
	system.cancel_ability(attack.ability_id)
	_check(system.get_active_cast(sprint.ability_id) != null and system.get_active_cast(attack.ability_id) == null,
			"Targeted cancellation leaves the unrelated action active")
	var check_cleanup := func(id: int, _cancelled: bool) -> void:
		_check(system.get_activation_failure(id) == &"activation_unavailable",
				"End callbacks cannot restart abilities during bulk cleanup")
	system.ability_ended.connect(check_cleanup)
	system.cancel_all_abilities()
	system.ability_ended.disconnect(check_cleanup)
	_check(system.get_active_cast(sprint.ability_id) == null and not system.tags.has_tag(&"State.Sprinting"),
			"Bulk cancellation ends the independent cast and releases its state")
	_check(system.try_activate(sprint.ability_id), "A new request can start after bulk cleanup ends")
	system.attributes.modify_current(CombatAttributes.Id.HEALTH, -1000.0)
	_check(system.get_active_cast(sprint.ability_id) == null and not system.tags.has_tag(&"State.Sprinting"),
			"Death cleans up independent casts even without a death interruption tag")


func _test_activation_conflicts_precede_callbacks() -> void:
	var system := _fixture()
	var first := _waiting_ability(211)
	var second := _waiting_ability(212)
	system.grant_ability(first)
	system.grant_ability(second)
	var failures: Array[StringName] = []
	system.tags.changed.connect(func(tag: StringName, present: bool) -> void:
		if tag == &"State.ContractAction" and present:
			failures.append(system.get_activation_failure(second.ability_id)))
	system.attributes.attribute_changed.connect(func(id: int, _old: float, _new: float) -> void:
		if id == CombatAttributes.Id.MANA:
			failures.append(system.get_activation_failure(second.ability_id)))
	_check(system.try_activate(first.ability_id), "The first action commits through the shared activation path")
	_check(failures == [&"blocked_by_tags", &"blocked_by_tags"],
			"The full activation lock is visible in both tag and cost callbacks")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 88.0, "Only one activation spends Mana")


func _test_cancelled_animation_frame_cannot_transfer_ownership() -> void:
	var system := _fixture()
	system.name = &"AbilitySystem"
	var player := AnimationPlayer.new()
	system.get_parent().add_child(player)
	system.animation_player = player
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("AbilitySystem"))
	animation.track_insert_key(track, 0.25,
			{"method": &"handle_animation_event", "args": [&"cancel_playback"]})
	animation.track_insert_key(track, 0.50,
			{"method": &"handle_animation_event", "args": [&"late_playback_event"]})
	var library := AnimationLibrary.new()
	library.add_animation(&"shared_playback", animation)
	player.add_animation_library(&"", library)
	var original := AbilityDefinition.new()
	original.ability_id = 216
	original.execution = PlaybackExecution.new()
	var replacement := AbilityDefinition.new()
	replacement.ability_id = PlaybackExecution.REPLACEMENT_ID
	replacement.execution = original.execution
	system.grant_ability(original)
	system.grant_ability(replacement)
	_check(system.try_activate(original.ability_id), "The first cast claims the shared animation player")
	var cast := system.get_active_cast(original.ability_id)
	system.advance_animation(0.75)
	_check(cast.finished and system.get_animation_cast() == null and not player.is_playing(),
			"A method event can cancel its own playback inside the animation frame")
	_check(cast.data.get(&"replacement_failure") == &"animation_in_use"
			and not cast.data.has(&"unexpected_event"),
			"Remaining callbacks from that frame cannot route to another activation")
	_check(system.try_activate(replacement.ability_id)
			and system.get_active_cast(replacement.ability_id) == system.get_animation_cast(),
			"A new cast can use the same clip after the cancelled frame returns")
	system.cancel_animation()


func _test_reentrant_interruption() -> void:
	var system := _fixture()
	var ability := _waiting_ability(213)
	ability.charge_pool = null
	var observed: Array[AbilityCast] = []
	system.ability_started.connect(func(id: int) -> void:
		observed.append(system.get_active_cast(id))
		system.cancel_ability(id))
	system.grant_ability(ability)
	_check(system.try_activate(ability.ability_id), "A start callback can synchronously cancel an accepted action")
	_check(observed.size() == 1 and not observed[0].data.get(&"began", false),
			"A cancelled start never enters execution afterward")
	_check(system.get_active_cast(ability.ability_id) == null and not system.tags.has_tag(&"State.CombatAction"),
			"Synchronous cancellation leaves no active cast or leaked action tag")
	var dying := _fixture()
	var sacrifice := _waiting_ability(214)
	sacrifice.resource_costs = [COMMITMENT.make_cost(
			AmountDefinition.Pool.HEALTH, dying.attributes.get_value(CombatAttributes.Id.HEALTH))]
	dying.grant_ability(sacrifice)
	_check(not dying.try_activate(sacrifice.ability_id), "A lethal resource cost prevents execution from starting")
	_check(dying.tags.has_tag(&"State.Dead") and dying.get_active_cast(sacrifice.ability_id) == null,
			"Lethal costs preserve ordinary death cleanup")
	_check(not dying.tags.has_tag(&"State.CombatAction"), "Cancellation during cost payment releases the action lock")
	sacrifice.interruption_policy.activation_blockers.clear()
	_check(dying.get_activation_failure(sacrifice.ability_id) == &"actor_dead",
			"A dead actor cannot bypass the lifecycle guard by removing optional blocked tags")
	var invalid := _fixture()
	var malformed := _waiting_ability(215)
	invalid.grant_ability(malformed)
	malformed.resource_costs[0].amount.fixed_amount = NAN
	_check(invalid.get_activation_failure(malformed.ability_id) == &"invalid_resource_cost",
			"Nonfinite authored costs are rejected before changing current resources")
	malformed.resource_costs.clear()
	malformed.charge_pool.recharge_seconds = INF
	_check(invalid.get_activation_failure(malformed.ability_id) == &"invalid_charge_pool",
			"Nonfinite authored cooldowns cannot corrupt the action clock")


func _test_explicit_connected_payload() -> void:
	var source := _fixture()
	var target := _fixture()
	source.attributes.level = 1
	target.attributes.level = 1
	source.attributes.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	target.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 10000.0)
	target.attributes.restore_resources()
	var weapon := WeaponDefinition.new()
	weapon.kind = WeaponDefinition.Kind.SWORD_ONE_HAND
	weapon.physical_damage_min = 30.0
	weapon.physical_damage_max = 30.0
	weapon.base_attack_cycle = 1.0
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.get_damage_execution().use_weapon_damage = true
	var context := source.create_effect_context(PackedStringArray(["Ability.Attack"]))
	context.bind_weapon(weapon)
	var all_hits := true
	for attempt in 32:
		var result := target.receive_hit(context, [effect])
		all_hits = all_hits and result.outcome == &"hit" and result.applied_effects == 1
	_check(all_hits, "A same-level Accuracy-capped source reliably delivers its connected weapon payload")
	_near(target.attributes.get_value(CombatAttributes.Id.HEALTH), 8400.0,
			"Physical damage uses weapon30 + Dexterity10*2 without level or defense multipliers")
	_check(target.effects.active_count() == 0, "Direct physical hits do not generate automatic ailments")
	var removed: Array[float] = []
	target.effects.damage_applied.connect(func(amount: float, _effect: GameplayEffectDefinition) -> void:
		removed.append(amount))
	target.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 20.0)
	target.attributes.restore_resources()
	target.receive_hit(context, [effect])
	_near(removed[0], 20.0, "A lethal hit reports actual Health removed instead of its overkill magnitude")
	_check(target.tags.has_tag(&"State.Dead"), "A delivered lethal hit grants the owned death state")
	_check(target.receive_hit(context, [effect]).outcome == &"invalid", "Dead targets reject further delivery")
	target.attributes.restore_resources()
	_check(not target.tags.has_tag(&"State.Dead"), "Explicit playground restoration clears the owned death state")
	var magic := GameplayEffectDefinition.new()
	magic.executions = [GameplayEffectDamageExecution.new()]
	magic.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	magic.get_damage_execution().amount = AmountDefinition.fixed(5.0)
	target.receive_hit(source.create_effect_context(PackedStringArray(["Ability.Spell"])), [magic])
	_check(target.effects.active_count() == 0, "Magic hits apply only their explicit payload and never create Burn")


func _test_modifier_lifetime() -> void:
	var system := _fixture()
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.MAGIC_POWER
	modifier.value = 10.0
	var increased := modifier.copy()
	increased.operation = AttributeModifier.Operation.ADD_PERCENT
	increased.value = 50.0
	var more := modifier.copy()
	more.operation = AttributeModifier.Operation.MORE_PERCENT
	more.value = 20.0
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 3.0
	effect.modifiers = [modifier, increased, more]
	effect.granted_tags = PackedStringArray(["Buff.Contract"])
	system.tags.add_tag(&"Buff.Contract")
	var handle := system.effects.apply_effect(effect, system.create_effect_context())
	_check(handle > 0 and system.effects.active_count() == 1, "An explicit buff receives one removable owned instance")
	_near(system.attributes.get_value(CombatAttributes.Id.MAGIC_POWER), 54.0,
			"Buff modifiers use flat foundation, combined increase, then independent more")
	_check(system.tags.get_count(&"Buff.Contract") == 2, "A buff owns its tag independently")
	system.advance(2.99)
	_near(system.attributes.get_value(CombatAttributes.Id.MAGIC_POWER), 54.0, "The buff lasts until its authored expiry")
	system.advance(0.01)
	_near(system.attributes.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Expiry removes every owned modifier")
	_check(system.effects.active_count() == 0 and system.tags.get_count(&"Buff.Contract") == 1,
			"Expiry preserves external tag ownership and leaves no active instance")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) < 0.00001,
			"%s (%.8f / %.8f)" % [label, actual, expected])


func _test_invalid_projectile_and_payload_reject_before_commit() -> void:
	var system := _fixture()
	var origin := Node3D.new()
	system.get_parent().add_child(origin)
	system.cast_origin = origin
	var animation_player := AnimationPlayer.new()
	animation_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var animation := Animation.new()
	animation.length = 1.0
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("."))
	animation.track_insert_key(track, 0.5, {"method": &"handle_animation_event", "args": [&"release"]})
	var library := AnimationLibrary.new()
	library.add_animation(&"cast_fireball", animation)
	animation_player.add_animation_library(&"", library)
	system.get_parent().add_child(animation_player)
	system.animation_player = animation_player
	var effect := GameplayEffectDefinition.new()
	var damage := GameplayEffectDamageExecution.new()
	damage.amount = AmountDefinition.fixed(10.0)
	effect.executions = [damage]
	var execution := PhasedAbilityExecution.new()
	execution.cast_mode = PhasedAbilityExecution.CastMode.ANIMATION
	execution.animation_name = &"cast_fireball"
	execution.release_event = &"release"
	execution.targeting = AbilityTargetingDefinition.new()
	execution.targeting.shape = AbilityTargetingDefinition.Shape.POINT
	execution.targeting.origin = AbilityTargetingDefinition.Origin.SOCKET
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.delivery.kind = AbilityDeliveryDefinition.Kind.PROJECTILE
	var action := AbilityApplyEffectsAction.new()
	action.effects = [effect]
	var impact := AbilityPhaseDefinition.new()
	impact.actions = [action]
	execution.phases = [impact]
	var valid_root := AbilityProjectile.new()
	execution.delivery.projectile_scene = PackedScene.new()
	_check(execution.delivery.projectile_scene.pack(valid_root) == OK, "A projectile root is a valid fixture")
	valid_root.free()
	var ability := AbilityDefinition.new()
	ability.ability_id = 218
	ability.ability_tags = PackedStringArray(["Ability.Spell"])
	ability.resource_costs = [COMMITMENT.make_cost(AmountDefinition.Pool.MANA, 17.0)]
	ability.charge_pool = COMMITMENT.make_cooldown(5.0)
	ability.execution = execution
	ability.activation_tags = PackedStringArray(["State.CombatAction"])
	system.grant_ability(ability)
	_check(system.get_activation_failure(ability.ability_id).is_empty(),
			"The projectile validation fixture has a valid origin, release animation and payload")
	for tag: String in ["Weapon.Brutality", "Ability.Spell"]:
		effect.damage_tags = PackedStringArray([tag])
		_check(not system.try_activate(ability.ability_id),
				"Reserved payload tags reject activation before committing an action")
		_near(system.attributes.get_value(CombatAttributes.Id.MANA), 100.0,
				"Rejected payload classification does not consume Mana")
		_near(system.get_cooldown_remaining(ability.ability_id), 0.0,
				"Rejected payload classification does not start a cooldown")
		_check(system.get_active_cast(ability.ability_id) == null and not system.tags.has_tag(&"State.CombatAction"),
				"Rejected payload classification grants no action state")
	effect.damage_tags = PackedStringArray()
	var wrong_root := Node3D.new()
	var invalid_scene := PackedScene.new()
	_check(invalid_scene.pack(wrong_root) == OK, "A non-projectile scene is a valid PackedScene fixture")
	wrong_root.free()
	execution.delivery.projectile_scene = invalid_scene
	var orphan_count := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_check(system.get_activation_failure(ability.ability_id) == &"invalid_projectile_root",
			"A PackedScene with the wrong root is rejected during preflight")
	_check(not system.try_activate(ability.ability_id), "A non-projectile root never commits its cast")
	_near(system.attributes.get_value(CombatAttributes.Id.MANA), 100.0,
			"Invalid projectile root does not consume Mana")
	_near(system.get_cooldown_remaining(ability.ability_id), 0.0,
			"Invalid projectile root does not start a cooldown")
	_near(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphan_count,
			"Preflight frees every invalid root probe instead of leaking orphan nodes")
	_check(system.get_active_cast(ability.ability_id) == null and not system.tags.has_tag(&"State.CombatAction"),
			"Invalid projectile preflight leaves no active cast or action tag")


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
