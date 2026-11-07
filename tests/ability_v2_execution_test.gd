extends SceneTree
## Exercises reserved and paid costs through the same cast path used by authored abilities.

const MANA := CombatAttributes.Id.MANA
const FIRE := &"School.Fire"
const COLD := &"School.Cold"
const SILENCE := &"State.Control.Silenced"

class DelayedExecution extends AbilityExecution:
	func begin(cast: AbilityCast) -> void:
		var delay := AbilityTaskWaitDelay.new(1.5)
		delay.finished.connect(func() -> void:
			cast.phase = AbilityCast.Phase.RELEASE
			if cast.commit() and not cast.finished:
				cast.released = true
				cast.finish()
			else:
				cast.cancel()
		)
		cast.start_task(delay)


class ChannelExecution extends AbilityExecution:
	func begin(cast: AbilityCast) -> void:
		cast.phase = AbilityCast.Phase.CHANNEL
		cast.data[&"pulses"] = 0

	func advance(cast: AbilityCast, _delta: float) -> void:
		cast.data[&"pulses"] += 1


var _system: AbilitySystem
var _holder: Node
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_holder = Node.new()
	_holder.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := preload("res://tests/attribute_fixture.gd").new_attributes()
	_holder.add_child(attributes)
	_system = AbilitySystem.new()
	_system.attributes = attributes
	_holder.add_child(_system)
	root.add_child(_holder)
	_test_delayed_commit()
	_test_lockout_and_channels()
	_test_pool_save_and_recharge()
	_holder.free()
	print("Ability v2 execution checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(1 if _failures > 0 else 0)


func _test_delayed_commit() -> void:
	var spell := _spell(&"delayed", FIRE)
	var timing := AbilityInterruptionPolicy.CommitTiming.ON_RELEASE
	spell.interruption_policy.cost_timing = timing
	spell.interruption_policy.cooldown_timing = timing
	spell.resource_costs[0].spend_up_to_maximum = true
	spell.resource_costs[0].maximum = 45.0
	spell.charge_pool = _charges(1, &"")
	_system.grant_ability(spell)
	_set_mana(40.0)
	_check(_system.try_activate(&"delayed"), "The release-based cast starts")
	var cast := _system.get_active_cast(&"delayed")
	if cast == null:
		return
	_check(_mana() == 40.0 and cast.spend_receipt == null and not cast.committed,
			"Reserving the cast never debits Mana")
	_check(_system.get_available_charges(&"delayed") == 0
			and not _system.can_spend_current(MANA, 1.0), "Other actions respect reservations")
	_system.advance(0.7)
	_system.tags.add_tag(SILENCE)
	_system.advance(1.0)
	_check(cast.finished and not cast.released and _mana() == 40.0,
			"Silence at 0.7 seconds stops release without a debit")
	_check(_system.get_available_charges(&"delayed") == 1
			and _system.get_cooldown_remaining(&"delayed") == 0.0,
			"A pre-release interruption starts no recharge")
	_system.tags.remove_tag(SILENCE)

	_check(_system.try_activate(&"delayed"), "Released reservations allow retry")
	cast = _system.get_active_cast(&"delayed")
	_set_mana(60.0)
	_system.advance(1.5)
	_check(cast.released and _mana() == 20.0 and cast.spend_receipt.get_spent(MANA) == 40.0,
			"Release spends the amount reserved at start, with an actual debit receipt")
	_check(cast.spend_receipt.get_amounts().is_read_only(), "Spend receipts are immutable")
	_check(_system.get_available_charges(&"delayed") == 0,
			"Release consumes the reserved charge once")

	var upfront := _spell(&"upfront", FIRE)
	_system.grant_ability(upfront)
	_set_mana(60.0)
	_check(_system.try_activate(&"upfront") and _mana() == 40.0, "The start-based cost pays at start")
	_system.tags.add_tag(SILENCE)
	_check(_mana() == 40.0, "The default interruption policy retains an upfront debit")
	_system.tags.remove_tag(SILENCE)

	var refundable := _spell(&"refundable", FIRE)
	refundable.interruption_policy.refund_cost_on_cancel = true
	refundable.interruption_policy.refund_cooldown_on_cancel = true
	refundable.charge_pool = _charges(1, &"")
	_system.grant_ability(refundable)
	_check(_system.try_activate(&"refundable") and _mana() == 20.0, "A refundable cost still pays first")
	_system.cancel_ability(&"refundable")
	_check(_mana() == 40.0 and _system.get_available_charges(&"refundable") == 1,
			"Cancellation returns the paid resources and the particular spent charge")


func _test_lockout_and_channels() -> void:
	var fire := _spell(&"fire_channel", FIRE)
	fire.execution = ChannelExecution.new()
	fire.interruption_policy.occupied_channels = PackedStringArray(["offense"])
	var cold := _spell(&"cold_cast", COLD)
	cold.interruption_policy.occupied_channels = PackedStringArray(["offense"])
	cold.interruption_policy.windup_movement = AbilityInterruptionPolicy.MovementRule.CANCEL_ON_REQUEST
	var defense := _spell(&"defense", &"")
	defense.interruption_policy.occupied_channels = PackedStringArray(["defense"])
	defense.interruption_policy.activation_exceptions = PackedStringArray([SILENCE])
	defense.activation_tags = PackedStringArray(["State.Defending"])
	for definition in [fire, cold, defense]:
		definition.resource_costs.clear()
		_system.grant_ability(definition)
	_check(not _system.interrupt_cast(2.0).is_success() and not _system.is_school_locked(FIRE),
			"Interrupting an idle actor applies no lockout")
	_check(_system.try_activate(&"fire_channel"), "The fire channel starts")
	var channel := _system.get_active_cast(&"fire_channel")
	_system.advance(0.1)
	_check(_system.get_activation_failure(&"cold_cast") == &"execution_channel_occupied",
			"Two exclusive occupants of the same channel cannot overlap")
	_check(_system.try_activate(&"defense"), "An independent defensive channel can overlap")
	_system.cancel_ability(&"defense")
	var result := _system.interrupt_cast(2.0)
	_check(result.interrupted_schools == [FIRE] and channel.finished,
			"Interrupt reports the school of the execution it actually stopped")
	_check(_system.get_activation_failure(&"fire_channel") == &"school_locked"
			and _system.get_activation_failure(&"cold_cast").is_empty(),
			"Only the interrupted school is locked")
	_system.advance(1.0)
	_check(channel.data[&"pulses"] == 1, "The interrupted channel emits no further pulses")
	_system.advance(1.0)
	_check(not _system.is_school_locked(FIRE), "The school unlocks at its own expiry")
	_check(_system.try_activate(&"cold_cast"), "Cold can cast independently of a stopped fire channel")
	_system.tags.add_tag(&"State.Control.Rooted")
	_check(_system.get_active_cast(&"cold_cast") != null,
			"Root alone does not cancel a stationary spell")
	_system.tags.remove_tag(&"State.Control.Rooted")
	_check(not _system.handle_movement_intent(false) and _system.get_active_cast(&"cold_cast") != null,
			"Standing still keeps a movement-sensitive cast active")
	_system.handle_movement_intent(true)
	_check(_system.get_active_cast(&"cold_cast") == null,
			"Movement intent interrupts an opted-in windup")
	_system.tags.add_tag(SILENCE)
	_check(_system.try_activate(&"defense"), "An authored exception bypasses that blocker")
	_check(_system.get_activation_failure(&"cold_cast") == &"blocked_by_tags",
			"The exception does not bypass the same blocker for other abilities")
	_system.cancel_ability(&"defense")
	_system.tags.remove_tag(SILENCE)


func _test_pool_save_and_recharge() -> void:
	var first := _spell(&"charge_one", FIRE)
	var second := _spell(&"charge_two", COLD)
	first.charge_pool = _charges(2, &"shared_test")
	second.charge_pool = _charges(2, &"shared_test")
	for definition in [first, second]:
		definition.resource_costs.clear()
		definition.execution = AbilityExecution.new()
		_system.grant_ability(definition)
	_check(_system.try_activate(&"charge_one") and _system.try_activate(&"charge_two"),
			"Two actions can spend the same group's two charges")
	_check(_system.get_activation_failure(&"charge_one") == &"no_charges",
			"Both actions see an empty shared pool")
	_system.advance(1.25)
	var saved := _system.capture_charge_recharge(&"charge_one")
	_check(saved == [0.75, 2.0], "Sequential recharge advances only its front clock")
	_system.advance(4.0)
	_check(_system.get_available_charges(&"charge_two") == 2
			and _system.restore_charge_recharge(&"charge_two", saved),
			"An idle actor can restore the group's remaining recharge")
	_system.advance(0.75)
	_check(_system.get_available_charges(&"charge_one") == 1
			and _system.capture_charge_recharge(&"charge_two") == [2.0],
			"Restored sequential recharge releases just the first charge")
	var parallel := _charges(2, &"")
	parallel.parallel_recharge = true
	var pool := AbilityChargePool.new(parallel)
	_check(pool.reserve(1) and pool.spend(1) != 0, "Parallel pool spends first charge")
	pool.advance(1.0)
	_check(pool.reserve(2) and pool.spend(2) != 0, "Parallel pool spends second charge")
	pool.advance(1.0)
	_check(pool.available() == 1 and pool.capture_recharge() == [1.0],
			"Parallel clocks advance independently")


func _spell(id: StringName, school: StringName) -> AbilityDefinition:
	var ability := AbilityDefinition.new()
	ability.ability_id = id
	ability.execution = DelayedExecution.new()
	ability.interruption_policy = AbilityInterruptionPolicy.new()
	ability.interruption_policy.school = school
	ability.interruption_policy.activation_blockers = PackedStringArray([SILENCE])
	ability.interruption_policy.cancel_on_tags = PackedStringArray([SILENCE])
	var cost := AbilityResourceCost.new()
	cost.pool = AmountDefinition.Pool.MANA
	cost.amount = AmountDefinition.fixed(20.0)
	ability.resource_costs = [cost]
	return ability


func _charges(capacity: int, group: StringName) -> AbilityChargeDefinition:
	var profile := AbilityChargeDefinition.new()
	profile.capacity = capacity
	profile.shared_group = group
	profile.recharge_seconds = 2.0
	return profile


func _set_mana(value: float) -> void:
	_system.attributes.set_base_value(MANA, value)


func _mana() -> float:
	return _system.attributes.get_value(MANA)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)
