extends SceneTree
## Actor-driven gait speeds and grounded sprint upkeep through saved first-person assets.

const CONTROLLER = preload("res://player/first_person_controller.tscn")
const CASTER = preload("res://examples/fireball/caster.tscn")
const EDITOR = preload("res://levels/playground/testing/attribute_editor.tscn")
const SPRINT_EXECUTION = preload("res://player/abilities/sprint_execution.gd")
const SPRINT_FIXTURE = preload("res://tests/sprint_fixture.gd")
const UPKEEP_ID: StringName = &"Effect.Sprint.StaminaUpkeep"
const REGENERATION_PERIOD: float = 0.1

var _world: Node3D
var _player: FirstPersonController
var _movement: FirstPersonMovement
var _has_authored_movement_settings := false
var _upkeep_calculation: SprintStaminaUpkeepCalculation
var _attributes: ActorAttributes
var _gait: FirstPersonGait
var _checks: int = 0
var _failures: int = 0
var _delta: float = 1.0 / 60.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	Engine.physics_ticks_per_second = 60
	await _test_saved_wiring_and_live_modifiers()
	await _test_engine_speed_tuning_guard()
	await _test_live_editor_affects_motion()
	await _test_encumbrance_speed_and_capacity()
	await _test_encumbrance_jump_physics()
	await _test_encumbrance_blocks_sprint()
	await _test_sprint_upkeep()
	await _test_exhaustion_and_retry()
	await _test_final_charge_uses_remainder()
	await _test_zero_cost_and_invalid_inputs()
	await _test_non_sprinting_movement_is_free()
	await _test_wall_and_airborne_costs()
	await _test_missing_attributes_zero_speed_and_death()
	await _test_reentrant_movement_callbacks()
	await _test_time_partitioned_costs()
	print("Movement attribute checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_saved_wiring_and_live_modifiers() -> void:
	await _start_fixture()
	_check(_has_authored_movement_settings and _movement.attributes == _attributes,
			"Saved Movement references its settings and the actor's attribute component")
	_check(not "sprint_stamina_drain" in _movement.settings,
			"Movement settings have no duplicate Sprint cost")
	_check(CombatAttributes.Id.MOVEMENT_SPEED == 54, "Movement Speed bonus has its own stable identity")
	_check(not CombatAttributes.is_active(27), "Legacy percentage movement data remains inactive")
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 0.0,
			"The fixture starts with a zero-percent bonus above normal movement")
	var defaults := [4.0, 2.0, 6.0, 2.4, 1.2]
	for gait: int in range(5):
		_near(_movement.get_speed_for_gait(gait), defaults[gait],
				"Fixture gait ratios scale the normal movement baseline")
	for property: Dictionary in _movement.settings.get_property_list():
		_check(property.name not in ["run_speed", "walk_speed", "sprint_speed", "crouch_speed", "crouch_walk_speed"],
				"Movement settings do not retain duplicate absolute gait speeds")
	_attributes.set_modifiers(&"speed", [_modifier(1.0)])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 1.0, "One flat Movement Speed adds one bonus percentage point")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.04,
			"One bonus percentage point produces the intended small physical increase")
	_attributes.set_modifiers(&"speed", [_modifier(20.0, AttributeModifier.Operation.ADD_PERCENT)])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 0.0, "Increased alone leaves a zero bonus unchanged")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.0,
			"A zero bonus preserves normal physical speed")
	_attributes.set_modifiers(&"speed", [_modifier(20.0)])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 20.0, "Add20 grants a twenty-percent speed bonus")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.8, "Twenty bonus points produce 4.8 meters per second")
	_attributes.set_modifiers(&"speed", [_modifier(20.0), _modifier(20.0, AttributeModifier.Operation.ADD_PERCENT)])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 24.0, "Increased20 scales an accumulated twenty-point bonus to24")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.96, "The generic modified bonus is applied to physical speed once")
	_attributes.set_modifiers(&"speed", [
		_modifier(10.0),
		_modifier(50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	var expected := [4.72, 2.36, 7.08, 2.832, 1.416]
	for gait: int in range(5):
		_near(_movement.get_speed_for_gait(gait), expected[gait],
				"Each gait uses final flat/increased/More Movement Speed exactly once")
	_attributes.set_modifiers(&"speed", [
		_modifier(100.0),
		_modifier(50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 25.0,
			"The final twenty-five-percent cap follows flat, increased and More modifiers")
	var capped := [5.0, 2.5, 7.5, 3.0, 1.5]
	for gait: int in range(5):
		_near(_movement.get_speed_for_gait(gait), capped[gait],
				"Every gait uses the same capped final Movement Speed bonus")
	_attributes.remove_modifiers(&"speed")
	_attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 10.0)
	var changed := [4.4, 2.2, 6.6, 2.64, 1.32]
	for gait: int in range(5):
		_near(_movement.get_speed_for_gait(gait), changed[gait], "Live base changes immediately affect every gait")
	var caster := CASTER.instantiate() as FirstPersonController
	var caster_system := caster.get_node("AbilitySystem") as AbilitySystem
	# Reproduce an editor resave dropping the inherited exported Node reference.
	caster_system.attributes = null
	_world.add_child(caster)
	_disable_processing(caster)
	var caster_movement := caster.get_node("Movement") as FirstPersonMovement
	_check(caster_movement.attributes == caster_system.attributes
			and caster.get_node("Attributes") == caster_system.attributes,
			"A missing serialized reference resolves the same inherited actor attributes")
	_check(caster_system.effects != null,
			"The missing-reference recovery completes ability initialization for the saved caster")
	for ability_id: StringName in [&"sprint", &"jump", &"crouch", &"encumbered", &"stamina_exhaustion", &"fireball"]:
		var definition := caster_system.get_ability_definition(ability_id)
		_check(definition != null and caster_system.granted_abilities.has(definition),
				"The saved caster registers %s from Granted Abilities" % ability_id)
	var saved_sprint := caster_system.get_ability_definition(&"sprint").execution as SPRINT_EXECUTION
	var upkeep := saved_sprint.upkeep_effect
	_check(upkeep != null and upkeep.effect_id == UPKEEP_ID
			and upkeep.timing == GameplayEffectDefinition.Timing.INFINITE and upkeep.period > 0.0
			and upkeep.ongoing_required_target_tags.has("State.Movement.SprintUpkeepDue")
			and upkeep.period_inhibition_policy == GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD,
			"The saved Sprint grant references an Infinite, due-gated periodic upkeep effect")
	var attribute_nodes := 0
	for child in caster.get_children():
		if child is ActorAttributes:
			attribute_nodes += 1
	_check(attribute_nodes == 1, "Moving Attributes into the reusable controller creates no duplicate actor state")
	await _end_fixture()


func _test_live_editor_affects_motion() -> void:
	await _start_fixture()
	var system := AbilitySystem.new()
	system.attributes = _attributes
	_player.add_child(system)
	system.set_process(false)
	var editor := EDITOR.instantiate() as LiveAttributeEditor
	_world.add_child(editor)
	editor.bind_actor(system)
	var row: LiveAttributeEditorRow = editor.rows[CombatAttributes.Id.MOVEMENT_SPEED]
	row.override_toggle.button_pressed = true
	row.base_slider.value = 100.0
	for tick in 35:
		await _step(Vector2.RIGHT)
	_near(_horizontal_speed(), 5.0, "The actual saved F3 row applies the final speed cap without a restart")
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 25.0,
			"An oversized F3 base override cannot bypass the twenty-five-percent cap")
	row.base_slider.value = -25.0
	for tick in 20:
		await _step(Vector2.RIGHT)
	_near(_horizontal_speed(), 3.0, "A later F3 edit changes existing movement through normal acceleration")
	editor.clear_overrides()
	for tick in 20:
		await _step(Vector2.RIGHT)
	_near(_horizontal_speed(), 4.0, "Removing the editor override restores the actor's authored Movement Speed")
	_near(_movement.settings.walk_speed_multiplier, 0.5, "Live attribute edits do not mutate shared gait tuning")
	await _end_fixture()


func _test_engine_speed_tuning_guard() -> void:
	await _start_fixture()
	var previous := _movement.settings.normal_run_speed
	var drain := _upkeep_calculation.stamina_per_interval
	var stamina := _attributes.get_value(CombatAttributes.Id.STAMINA)
	_movement.settings.normal_run_speed = 6.0
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 6.0,
			"Changing the authored normal speed changes the zero-bonus baseline")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.SPRINT), 9.0,
			"Sprint remains one authored ratio above the configurable baseline")
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 0.0,
			"Changing normal speed does not manufacture a Movement Speed bonus")
	for tick in 30:
		await _step(Vector2.RIGHT)
	_near(_horizontal_speed(), 6.0, "Live baseline edits affect physical movement without changing actor data")
	_attributes.set_modifiers(&"baseline_bonus", [_modifier(20.0)])
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 20.0, "The actor owns its independent twenty-percent bonus")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 7.2,
			"Twenty-percent bonus scales a six-meter authored baseline to7.2")
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.SPRINT), 10.8,
			"Sprint multiplies the modified configurable normal speed once")
	_movement.settings.normal_run_speed = 3.0
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 3.6,
			"A later baseline change preserves the existing percentage modifier")
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 20.0,
			"Baseline tuning leaves an existing actor bonus unchanged")
	_near(_upkeep_calculation.stamina_per_interval, drain,
			"Normal speed tuning does not alter fixed sprint cost")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), stamina,
			"Baseline tuning and speed inspection do not spend Stamina")
	_attributes.remove_modifiers(&"baseline_bonus")
	for normal_speed: float in [-1.0, 0.0, INF, NAN]:
		_movement.settings.normal_run_speed = normal_speed
		_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 0.0,
				"Invalid or disabled normal speed cannot grant backward or nonfinite movement")
		_check(not _movement.can_move_in_sprint(), "Invalid or disabled normal speed cannot authorize sprint")
	_movement.settings.normal_run_speed = previous
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.0,
			"Restoring authored normal speed preserves the zero-bonus baseline")
	await _end_fixture()


func _test_sprint_upkeep() -> void:
	await _start_fixture()
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 80.0)
	_attributes.set_base_value(CombatAttributes.Id.HEALTH, 50.0)
	_attributes.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 5.0)
	_attributes.set_base_value(CombatAttributes.Id.MANA, 50.0)
	for tick in 60:
		await _step(Vector2.ZERO, true, false, true)
	_check(system.tags.has_tag(&"State.Movement.Sprinting"), "Idle Sprint owns its lifetime tag")
	var idle_handle := _upkeep_handle(system)
	_check(idle_handle > 0 and system.effects.active_count(UPKEEP_ID) == 1
			and system.effects.is_effect_inhibited(idle_handle),
			"Idle Sprint owns one inhibited upkeep effect")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 80.0, "Idle Sprint suppresses recovery without charging travel")
	_near(_attributes.get_value(CombatAttributes.Id.HEALTH), 55.0, "Health still regenerates during Sprint")
	_near(_attributes.get_value(CombatAttributes.Id.MANA), 55.0, "Mana still regenerates during Sprint")
	for tick in 3:
		await _step(Vector2.RIGHT, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 80.0, "Half an interval has no charge yet")
	await _step(Vector2.ZERO)
	_check(_upkeep_handle(system) == 0, "Release removes the ability's upkeep effect")
	for tick in 3:
		await _step(Vector2.RIGHT, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 78.0, "Short taps retain travel and pay one full charge")
	var sustained_handle := _upkeep_handle(system)
	for tick in 60:
		await _step(Vector2.RIGHT, true, false, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 58.0, "One second costs ten charges despite positive regeneration")
	_check(_upkeep_handle(system) == sustained_handle and sustained_handle > 0
			and system.effects.active_count(UPKEEP_ID) == 1
			and system.effects.is_effect_inhibited(sustained_handle),
			"Periodic charges reuse the same active effect handle")
	_upkeep_calculation.stamina_per_interval = 4.0
	for tick in 6:
		await _step(Vector2.RIGHT, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 56.0,
			"An active upkeep spec keeps its copied calculation data")
	await _step()
	for tick in 6:
		await _step(Vector2.RIGHT, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 52.0,
			"A new application uses the changed authored charge cost")
	await _step()
	system.advance(REGENERATION_PERIOD)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 53.0,
			"Ordinary release allows regeneration without a delay")
	await _step(Vector2.RIGHT, true)
	_check(system.effects.remove_effect(_upkeep_handle(system)), "The active upkeep is removable by its handle")
	await _step(Vector2.RIGHT, true)
	_check(system.get_active_cast(&"sprint") == null
			and _movement.effective_gait == FirstPersonGait.Gait.RUN,
			"Losing upkeep cancels Sprint before more grounded travel")
	await _end_fixture()


func _test_encumbrance_speed_and_capacity() -> void:
	await _start_fixture()
	_near(_attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY), 100.0,
			"The movement fixture has the agreed starting carry capacity")
	for load: Vector3 in [Vector3(0.0, 1.0, 1.0), Vector3(100.0, 1.0, 1.0),
			Vector3(125.0, 0.7109375, 0.75), Vector3(150.0, 0.5625, 0.5),
			Vector3(175.0, 0.5078125, 0.25),
			Vector3(200.0, 0.5, 0.0), Vector3(250.0, 0.5, 0.0)]:
		_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, load.x)
		var factors := _movement.get_encumbrance_factors()
		_near(factors.x, load.y, "Speed factor at carried weight %.0f" % load.x)
		_near(factors.y, load.z, "Jump-height factor at carried weight %.0f" % load.x)
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 125.0)
	_attributes.set_modifiers(&"speed", [_modifier(20.0)])
	var expected := [3.4125, 1.70625, 5.11875, 2.0475, 1.02375]
	for gait: int in range(5):
		_near(_movement.get_speed_for_gait(gait), expected[gait],
				"Encumbrance multiplies the already modified speed for each gait")
	for tick in 30:
		await _step(Vector2.RIGHT)
	_near(_horizontal_speed(), 3.4125, "Actual horizontal movement follows the combined gear and load factors")
	_near(_attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 20.0,
			"Encumbrance applies to locomotion without changing the actor's Movement Speed bonus")
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 250.0)
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 2.4,
			"Fully encumbered movement retains half of its modified normal speed")
	_attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, 200.0)
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 3.4125,
			"Increasing capacity immediately restores some speed at the same carried weight")
	_near(_movement.get_encumbrance_factors().y, 0.75,
			"Increasing capacity also restores jump height at the same load")
	_movement.settings.full_penalty_ratio = 1.25
	_movement.settings.min_speed_multiplier = 0.3
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 1.44,
			"Authored full-load ratio and minimum speed govern the capped penalty")
	_near(_movement.get_encumbrance_factors().y, 0.0,
			"The authored full-load ratio disables jumping at the exact threshold")
	await _end_fixture()


func _test_encumbrance_jump_physics() -> void:
	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 150.0)
	_check(_movement.is_grounded(), "Loaded standing jump starts on a floor")
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, true)
	var gravity := _movement.settings.gravity
	var half_height := _movement.settings.jump_height * 0.5
	_near(_player.velocity.y, sqrt(2.0 * gravity * half_height),
			"A half-height penalty is applied before the standing launch square root")
	var launch_velocity := _player.velocity.y
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 250.0)
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO)
	_near(_player.velocity.y, launch_velocity - gravity * _delta,
			"Changing carried weight in flight does not rescale an existing jump")
	await _end_fixture()

	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 150.0)
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, false, true, true)
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, true)
	_near(_player.velocity.y, sqrt(2.0 * _movement.settings.gravity * _movement.settings.crouch_jump_height * 0.5),
			"Crouched launch uses its own authored height with the same encumbrance factor")
	await _end_fixture()

	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 200.0)
	_check(_movement.is_grounded(), "Full-load jump attempt has valid floor support")
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, true)
	_check(_player.velocity.y <= 0.0 and _movement.is_grounded(),
			"At full encumbrance, a supported jump request never launches")
	await _end_fixture()

	await _start_fixture(Vector3(0.0, 8.0, 0.0), false)
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 250.0)
	_player.velocity.y = -3.0
	_movement._coyote_time_remaining = 0.1
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, true)
	_near(_player.velocity.y, -3.0 - _movement.settings.gravity * _delta,
			"A rejected fully encumbered coyote jump preserves falling velocity")
	_near(_movement._coyote_time_remaining, 0.1 - _delta,
			"A zero-height request does not consume the remaining coyote window")
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 100.0)
	await physics_frame
	_player.advance_locomotion(_delta, Vector2.ZERO, true)
	_near(_player.velocity.y, sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height),
			"Removing excess weight permits launch within the retained coyote window")
	await _end_fixture()


func _test_encumbrance_blocks_sprint() -> void:
	await _start_fixture()
	var weight_id := CombatAttributes.Id.CARRIED_WEIGHT
	_attributes.set_base_value(weight_id, 100.0)
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.SPRINT,
			"An actor carrying exactly its capacity can sprint")
	var stamina := _attributes.get_value(CombatAttributes.Id.STAMINA)
	_attributes.set_base_value(weight_id, 100.01)
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.RUN,
			"Crossing capacity cancels held sprint on the next movement step")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), stamina,
			"Encumbered movement spends no sprint Stamina")
	_upkeep_calculation.stamina_per_interval = 0.0
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	_check(system.get_activation_failure(&"sprint") == &"blocked_by_tags",
			"Even a free sprint is blocked by the authored tag over capacity")
	await physics_frame
	_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT)
	_check(_movement.effective_gait == FirstPersonGait.Gait.RUN,
			"Direct sprint requests cannot bypass the encumbrance restriction")
	_attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, 101.0)
	_check(system.get_activation_failure(&"sprint").is_empty(),
			"Increasing capacity restores sprint eligibility")
	await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.SPRINT,
			"A fresh Shift press sprints once weight is within capacity again")
	await _end_fixture()


func _test_exhaustion_and_retry() -> void:
	await _start_fixture()
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	system.set_process(false)
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 2.0)
	for tick in 6:
		await _step(Vector2.RIGHT, true, false, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 0.0, "The final affordable charge empties Stamina")
	_check(system.get_active_cast(&"sprint") == null and system.tags.has_tag(&"State.Stamina.Exhausted"),
			"Depletion cancels Sprint and starts the granted Exhaustion response")
	_check(system.effects.active_count(&"Effect.Stamina.Exhausted") == 1,
			"Depletion applies one timed authored effect")
	system.advance(SPRINT_FIXTURE.EXHAUSTION_DURATION - 0.2)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 0.0, "Exhaustion suppresses Stamina until its duration expires")
	system.advance(0.6)
	_check(_attributes.get_value(CombatAttributes.Id.STAMINA) >= SPRINT_FIXTURE.STAMINA_PER_CHARGE,
			"Recovery resumes after the Exhaustion effect expires")
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.RUN, "Holding Shift after depletion does not restart Sprint")
	await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.SPRINT, "A fresh funded Shift press restarts Sprint")
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 1.0)
	await _step(Vector2.RIGHT, true)
	_check(system.get_active_cast(&"sprint") == null and not system.tags.has_tag(&"State.Stamina.Exhausted"),
			"An external reduction below the next charge cancels Sprint without triggering Exhaustion")
	system.advance(REGENERATION_PERIOD)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 2.0,
			"Recovery starts immediately after external underfunding")
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 1.0)
	await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(_movement.effective_gait == FirstPersonGait.Gait.RUN, "One Stamina cannot start a two-Stamina Sprint")
	_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT)
	_check(_movement.effective_gait == FirstPersonGait.Gait.RUN, "Direct movement cannot bypass Sprint affordability")
	await _end_fixture()


func _test_final_charge_uses_remainder() -> void:
	for starting_stamina: float in [3.0, 5.25]:
		await _start_fixture()
		var system := _player.get_node("AbilitySystem") as AbilitySystem
		system.set_process(false)
		_attributes.set_base_value(CombatAttributes.Id.STAMINA, starting_stamina)
		_attributes.set_base_value(CombatAttributes.Id.HEALTH, 50.0)
		_attributes.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 5.0)
		_attributes.set_base_value(CombatAttributes.Id.MANA, 50.0)
		var debits: Array[Vector2] = []
		_attributes.attribute_changed.connect(func(id: int, previous: float, value: float) -> void:
			if id == CombatAttributes.Id.STAMINA and value < previous:
				debits.append(Vector2(previous, value)))
		var charges := floori(starting_stamina / 2.0)
		for tick in (charges - 1) * 6:
			await _step(Vector2.RIGHT, true)
		var final_payment := starting_stamina - 2.0 * (charges - 1)
		_near(_attributes.get_value(CombatAttributes.Id.STAMINA), final_payment,
				"Full charges preserve a remainder that can fund one more interval")
		for tick in 6:
			await _step(Vector2.RIGHT, true)
		_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 0.0,
				"The final charge consumes a positive underfunded remainder")
		_check(debits.size() == charges and debits.back().is_equal_approx(Vector2(final_payment, 0.0)),
				"The last charge spends all remaining Stamina in one debit")
		_check(system.get_active_cast(&"sprint") == null
				and system.effects.active_count(&"Effect.Stamina.Exhausted") == 1,
				"The zero crossing ends Sprint and grants one exhaustion effect")
		system.advance(SPRINT_FIXTURE.EXHAUSTION_DURATION / 2.0)
		_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 0.0,
				"A final charge with a remainder triggers the full recovery delay")
		_near(_attributes.get_value(CombatAttributes.Id.HEALTH), 52.5,
				"Health recovery continues during the Stamina delay")
		_near(_attributes.get_value(CombatAttributes.Id.MANA), 52.5,
				"Mana recovery continues during the Stamina delay")
		system.advance(SPRINT_FIXTURE.EXHAUSTION_DURATION / 2.0 + REGENERATION_PERIOD)
		_check(_attributes.get_value(CombatAttributes.Id.STAMINA) > 0.0,
				"Stamina recovers on a periodic tick after exhaustion expires")
		await _end_fixture()

	await _start_fixture()
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 3.0)
	for tick in 3:
		await _step(Vector2.RIGHT, true)
	await _step()
	system.advance(REGENERATION_PERIOD)
	_check(not system.tags.has_tag(&"State.Stamina.Exhausted"),
			"Releasing before the final due charge avoids exhaustion")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 4.0,
			"Releasing before the final due charge allows immediate recovery")
	await _end_fixture()


func _test_zero_cost_and_invalid_inputs() -> void:
	await _start_fixture()
	_upkeep_calculation.stamina_per_interval = 0.0
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 0.0)
	await _step(Vector2.RIGHT, true)
	_check(_gait.current_gait == FirstPersonGait.Gait.SPRINT and _movement.can_continue_sprint(_delta),
			"A designer-authored zero cost permits sprint with an empty Stamina pool")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 0.0, "Free sprint creates no implicit Stamina spending")
	for delta: float in [0.0, -1.0, INF, NAN]:
		_check(not _movement.can_continue_sprint(delta), "Invalid elapsed time cannot authorize a sprint")
		var position := _player.position
		_movement.move(delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT)
		_check(_player.position == position, "Invalid time steps cannot move or spend resources")
	await _step()
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	for invalid_cost: float in [-1.0, INF, NAN]:
		_upkeep_calculation.stamina_per_interval = invalid_cost
		_check(not system.get_activation_failure(&"sprint").is_empty(),
				"Invalid authored drain cannot start a new Sprint")
	_upkeep_calculation.stamina_per_interval = SPRINT_FIXTURE.STAMINA_PER_CHARGE
	_attributes.set_base_value(CombatAttributes.Id.STAMINA, 100.0)
	var stamina := _attributes.get_value(CombatAttributes.Id.STAMINA)
	for query in 10:
		_movement.can_continue_sprint(_delta)
		_movement.get_speed_for_gait(FirstPersonGait.Gait.SPRINT)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), stamina, "Speed and affordability inspection spend no Stamina")
	await _end_fixture()


func _test_non_sprinting_movement_is_free() -> void:
	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	await _step(Vector2.ZERO, true)
	for tick in 10:
		await _step(Vector2.ZERO, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Holding Shift while idle costs no Stamina")
	for tick in 20:
		await _step(Vector2.RIGHT, true, true)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Walking while sprint is selected costs no Stamina")
	for tick in 20:
		await physics_frame
		_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.CROUCH)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Crouched movement costs no sprint Stamina")
	for tick in 20:
		await physics_frame
		_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.CROUCH_WALK)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Crouch walking costs no sprint Stamina")
	for tick in 20:
		await physics_frame
		_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.RUN)
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Ordinary running costs no sprint Stamina")
	await _end_fixture()


func _test_wall_and_airborne_costs() -> void:
	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	_add_box(Vector3(2.0, 1.5, 0.0), Vector3(1.0, 3.0, 20.0))
	for tick in 40:
		await _step(Vector2.RIGHT, true)
	var stopped_position := _player.position.x
	var stopped_stamina := _attributes.get_value(CombatAttributes.Id.STAMINA)
	for tick in 30:
		await _step(Vector2.RIGHT, true)
	_near(_player.position.x, stopped_position, "A solid wall stops requested sprint travel")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), stopped_stamina,
			"Blocked sprint input without horizontal travel costs no Stamina")
	await _end_fixture()
	await _start_fixture(Vector3(0.0, 8.0, 0.0), false)
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	for tick in 15:
		await _step(Vector2.RIGHT, true)
	_check(not _movement.is_grounded(), "Airborne Sprint fixture remains above the floor")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Airborne input accrues no Sprint charge")
	_check(_horizontal_speed() <= _movement.get_speed_for_gait(FirstPersonGait.Gait.RUN) + 0.0001,
			"Airborne Sprint input cannot accelerate beyond ordinary air movement")
	await _end_fixture()


func _test_missing_attributes_zero_speed_and_death() -> void:
	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	_attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, -100.0)
	await _step(Vector2.RIGHT, true)
	_near(_horizontal_speed(), 0.0, "Minus one hundred percent Movement Speed prevents requested horizontal movement")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Zero-speed sprint attempts spend no Stamina")
	_check(not _movement.can_move_in_sprint(), "Minus one hundred percent Movement Speed makes sprint unavailable")
	_attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 0.0)
	_movement.attributes = null
	_near(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 0.0, "A missing attribute reference has no hidden speed fallback")
	_check(not _movement.can_move_in_sprint(), "A missing attribute reference cannot authorize sprint")
	_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT)
	_near(_horizontal_speed(), 0.0, "Missing attributes leave gravity available without granting horizontal speed")
	_movement.attributes = _attributes
	_attributes.apply_damage(100000.0)
	_check(not _movement.can_move_in_sprint(), "A dead actor cannot sprint")
	_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT)
	_near(_horizontal_speed(), 0.0, "A dead actor receives no requested horizontal speed")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 100.0, "Dead actors cannot spend sprint Stamina")
	await _end_fixture()


func _test_time_partitioned_costs() -> void:
	var previous_ticks := Engine.physics_ticks_per_second
	for ticks: int in [30, 60, 120]:
		Engine.physics_ticks_per_second = ticks
		_delta = 1.0 / ticks
		await _start_fixture()
		for tick in ticks:
			await _step(Vector2.RIGHT, true, false, true)
		_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 80.0,
				"One second of grounded Sprint has the same cost at different physics rates")
		await _end_fixture()
	Engine.physics_ticks_per_second = previous_ticks
	_delta = 1.0 / previous_ticks


func _test_reentrant_movement_callbacks() -> void:
	await _start_fixture()
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 0.0)
	var calls := {"reset": 0, "stamina": 0, "advanced": 0}
	_movement.terrain_reset.connect(func() -> void:
		calls.reset += 1
		if calls.reset == 1:
			_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT))
	_attributes.attribute_changed.connect(func(id: int, previous: float, value: float) -> void:
		if id == CombatAttributes.Id.STAMINA and value < previous:
			calls.stamina += 1
			if calls.stamina == 1:
				_upkeep_calculation.stamina_per_interval = NAN
				_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT))
	_movement.terrain_advanced.connect(func(_time: float, _height: float) -> void:
		calls.advanced += 1
		if calls.advanced == 1:
			_movement.move(_delta, Vector2.RIGHT, FirstPersonGait.Gait.SPRINT))
	_player.position.x += 10.0
	await _step(Vector2.RIGHT, true)
	_check(calls.advanced == 1, "A terrain-advanced listener cannot move the body a second time")
	for tick in 8:
		await _step(Vector2.RIGHT, true)
	_check(calls.reset == 1, "A terrain-reset listener cannot recursively move the body")
	_check(calls.stamina == 1, "A Stamina-change listener cannot apply a second movement cost")
	_near(_attributes.get_value(CombatAttributes.Id.STAMINA), 98.0,
			"The interval uses its checked cost despite callbacks changing tuning")
	await _end_fixture()


func _start_fixture(position: Vector3 = Vector3(0.0, 0.03, 0.0), settle: bool = true) -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(400.0, 1.0, 400.0))
	_player = CONTROLLER.instantiate() as FirstPersonController
	_player.position = position
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	preload("res://tests/attribute_fixture.gd").configure(system, REGENERATION_PERIOD)
	SPRINT_FIXTURE.configure(system)
	_attributes = _player.get_node("Attributes") as ActorAttributes
	_attributes.initial_modifiers = []
	_world.add_child(_player)
	var sprint := system.get_ability_definition(&"sprint").execution as SPRINT_EXECUTION
	_upkeep_calculation = sprint.upkeep_effect.executions[0] as SprintStaminaUpkeepCalculation
	_disable_processing(_player)
	_movement = _player.get_node("Movement") as FirstPersonMovement
	_has_authored_movement_settings = _movement.settings != null
	_movement.settings = FirstPersonMovementSettings.new()
	_movement.settings.normal_run_speed = 4.0
	_movement.settings.walk_speed_multiplier = 0.5
	_movement.settings.sprint_speed_multiplier = 1.5
	_movement.settings.crouch_speed_multiplier = 0.6
	_movement.settings.full_penalty_ratio = 2.0
	_movement.settings.min_speed_multiplier = 0.5
	var crouch := _player.get_node("Crouch") as FirstPersonCrouch
	crouch.settings = FirstPersonCrouchSettings.new()
	_attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 100.0)
	_attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 100.0)
	_attributes.set_base_value(CombatAttributes.Id.MAX_STAMINA, 100.0)
	_attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 10.0)
	_attributes.set_base_value(CombatAttributes.Id.MANA_REGEN, 5.0)
	_attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, 100.0)
	_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 0.0)
	_attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 0.0)
	_attributes.restore_resources()
	_gait = _player._gait
	if settle:
		for tick in 10:
			await _step()


func _disable_processing(player: FirstPersonController) -> void:
	player.set_physics_process(false)
	player.get_node("AbilitySystem").set_process(false)
	player.get_node("Crouch").set_process(false)
	player.get_node("Look").set_process(false)
	player.get_node("Look").set_process_unhandled_input(false)


func _end_fixture() -> void:
	_world.queue_free()
	await process_frame
	_world = null
	_player = null


func _step(input: Vector2 = Vector2.ZERO, sprint_held: bool = false,
		walk_held: bool = false, regenerate: bool = false) -> void:
	await physics_frame
	_player.advance_locomotion(_delta, input, false, false, false, sprint_held, walk_held)
	if regenerate:
		var system := _player.get_node("AbilitySystem") as AbilitySystem
		system.advance(_delta)


func _upkeep_handle(system: AbilitySystem) -> int:
	for effect: Dictionary in system.effects.get_active_effects():
		if effect["effect_id"] == UPKEEP_ID:
			return int(effect["handle"])
	return 0


func _add_box(position: Vector3, size: Vector3) -> void:
	var obstacle := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	obstacle.position = position
	obstacle.add_child(collision)
	_world.add_child(obstacle)


func _modifier(value: float, operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.MOVEMENT_SPEED
	modifier.value = value
	modifier.operation = operation
	return modifier


func _horizontal_speed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _near(actual: float, expected: float, label: String) -> void:
	_check(absf(actual - expected) < 0.0001, "%s: %.8f expected %.8f" % [label, actual, expected])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
