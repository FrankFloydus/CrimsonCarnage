extends SceneTree
## Verifies damage feedback, the combat HUD, expiry and matchup inspection inside the menu.
## Run headless with --fixed-fps 60 --script res://tests/damage_numbers_test.gd.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

const DUMMY_SCENE = preload("res://examples/fireball/dummy_actor.tscn")
const FIREBALL = preload("res://examples/fireball/fireball.tres")
const ARENA = preload("res://levels/playground/playground.tscn")
const ENCUMBERED = preload("res://player/encumbered_effect.tres")
const NUMBER_LIFETIME: float = 0.2

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_feedback_inspector()
	var dummy := DUMMY_SCENE.instantiate() as DamageDummy
	(dummy.get_node("Attributes") as ActorAttributes).initial_modifiers = []
	ATTRIBUTE_FIXTURE.configure(dummy.get_node("AbilitySystem") as AbilitySystem)
	root.add_child(dummy)
	dummy.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 200.0)
	dummy.attributes.restore_resources()
	dummy.ability_system.set_process(false)
	var source := ATTRIBUTE_FIXTURE.new_attributes()
	root.add_child(source)
	source.set_base_value(CombatAttributes.Id.INTELLECT, 20.0)
	var context := GameplayEffectContext.capture(source, GameplayTagSet.new(),
			FIREBALL.get_context_tags())
	var execution := FIREBALL.execution as PhasedAbilityExecution
	var saved_impact := execution.get_effect_payload()[0]
	var impact := GameplayEffectDefinition.new()
	impact.executions = [GameplayEffectDamageExecution.new()]
	impact.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	impact.magic_school = GameplayEffectDefinition.MagicSchool.FIRE
	impact.get_damage_execution().power_coefficient = 1.0
	var numbers := dummy.get_node("DamageNumbers")
	_check(dummy.ability_system.effects.apply_effect(impact, context),
			"The isolated Fireball feedback fixture applies")
	_check(numbers.get_child_count() == 1, "Actual damage creates one saved number instance")
	var number := numbers.get_child(0) as FloatingDamageNumber
	number.lifetime = NUMBER_LIFETIME
	_check(number.text == "40", "The number shows the actual 40 Health removed")
	_near(dummy.attributes.get_value(CombatAttributes.Id.HEALTH), 160.0,
			"Magic Power from Intellect supplies the direct damage")
	var bar := dummy.get_node("HealthBar")
	_near(float(bar.fill_ratio), 0.8, "The text-free Health bar follows the actual Health fraction")
	_check(execution.get_effect_payload().size() == 1
			and saved_impact.executions.size() == 1
			and saved_impact.executions[0] is GameplayEffectDamageExecution
			and saved_impact.timing == GameplayEffectDefinition.Timing.INSTANT
			and saved_impact.granted_tags.is_empty() and not dummy.has_node("BurnVisual"),
			"The saved Fireball remains direct instant damage without an automatic ailment or Burn visual")
	dummy.ability_system.effects.advance(10.0)
	_near(dummy.attributes.get_value(CombatAttributes.Id.HEALTH), 160.0,
			"Fireball does not generate automatic damage over time")
	_check(numbers.get_child_count() == 1, "Advancing effect time creates no extra damage numbers")
	dummy.ability_system.combat_event.emit({"type": &"damage", "amount": 0.0})
	_check(numbers.get_child_count() == 1, "Zero damage creates no number")
	dummy.ability_system.combat_event.emit({"type": &"hit_outcome", "outcome": &"hit"})
	_check(numbers.get_child_count() == 1,
			"A successful outcome does not duplicate the following damage feedback")
	for outcome: StringName in [&"miss", &"resist"]:
		dummy.ability_system.combat_event.emit({"type": &"hit_outcome", "outcome": outcome})
		var feedback := numbers.get_child(numbers.get_child_count() - 1) as FloatingDamageNumber
		feedback.lifetime = NUMBER_LIFETIME
		_check(feedback.text == str(outcome).to_upper(),
				"Failed Accuracy outcomes create readable text using the saved number scene")
	_check(numbers.get_child_count() == 3, "One feedback instance is created for each failed outcome")
	dummy.ability_system.combat_event.emit({"type": &"hit_outcome", "outcome": &"invalid"})
	_check(numbers.get_child_count() == 3, "An invalid delivery does not create misleading feedback")
	await create_timer(NUMBER_LIFETIME + 0.1).timeout
	await process_frame
	_check(numbers.get_child_count() == 0, "Numbers expire and remove their runtime nodes")
	await _test_critical_damage_feedback(dummy, source, impact)
	dummy.attributes.modify_current(CombatAttributes.Id.HEALTH,
			5.0 - dummy.attributes.get_value(CombatAttributes.Id.HEALTH))
	dummy.ability_system.effects.apply_effect(impact, context)
	_check(numbers.get_child_count() == 1, "A defeating hit creates one number")
	_check((numbers.get_child(0) as FloatingDamageNumber).text == "5",
			"Overkill displays only the Health actually removed")
	_near(float(bar.fill_ratio), 0.0, "The Health bar reaches zero on defeat")
	dummy.reset_actor()
	await process_frame
	_check(numbers.get_child_count() == 0, "Reset clears remaining floating feedback")
	_near(dummy.attributes.get_value(CombatAttributes.Id.HEALTH), 200.0,
			"Reset restores the configured dummy capacity")
	_near(float(bar.fill_ratio), 1.0, "Reset refills the Health bar")
	dummy.queue_free()
	source.queue_free()
	await process_frame
	await _test_combat_hud()
	print("Damage number checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_feedback_inspector() -> void:
	var dummy := DamageDummy.new()
	dummy.damage_number_spacing = 0.7
	_check(_property_usage(dummy, &"damage_number_spacing") & PROPERTY_USAGE_EDITOR == 0,
			"Without a damage number scene, lane spacing is hidden")
	_check(_property_usage(dummy, &"damage_number_spacing") & PROPERTY_USAGE_STORAGE != 0,
			"Hidden lane spacing remains serializable")
	dummy.damage_number_scene = PackedScene.new()
	_check(_property_usage(dummy, &"damage_number_spacing") & PROPERTY_USAGE_EDITOR != 0,
			"Selecting a damage number scene reveals lane spacing")
	_near(dummy.damage_number_spacing, 0.7, "Changing the scene preserves lane spacing")
	dummy.free()

	var number := FloatingDamageNumber.new()
	number.critical_pop_peak = 1.6
	number.critical_pop_duration = 0.0
	_check(_property_usage(number, &"critical_pop_peak") & PROPERTY_USAGE_EDITOR == 0,
			"Zero critical pop duration hides the critical pop peak")
	_check(_property_usage(number, &"critical_pop_peak") & PROPERTY_USAGE_STORAGE != 0,
			"Hidden critical pop peak remains serializable")
	number.critical_pop_duration = 0.25
	_check(_property_usage(number, &"critical_pop_peak") & PROPERTY_USAGE_EDITOR != 0,
			"Positive critical pop duration reveals the critical pop peak")
	_near(number.critical_pop_peak, 1.6, "Changing the duration preserves the critical pop peak")
	number.free()


func _property_usage(object: Object, name: StringName) -> int:
	for property: Dictionary in object.get_property_list():
		if property.name == name:
			return int(property.usage)
	return 0


func _test_critical_damage_feedback(
		dummy: DamageDummy, source: ActorAttributes, impact: GameplayEffectDefinition
) -> void:
	dummy.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 1000.0)
	dummy.attributes.restore_resources()
	source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	source.set_base_value(CombatAttributes.Id.CRITICAL_DAMAGE, 0.0)
	var context := GameplayEffectContext.capture(source, GameplayTagSet.new(), FIREBALL.get_context_tags())
	var payload: Array[GameplayEffectDefinition] = [impact]
	var numbers := dummy.get_node("DamageNumbers")
	var result := dummy.ability_system.receive_hit(context, payload)
	_check(bool(result.get("is_critical", false)), "One hundred percent Critical Chance produces critical delivery")
	_check(numbers.get_child_count() == 1, "One critical damage event creates one saved feedback instance")
	var critical := numbers.get_child(0) as FloatingDamageNumber
	critical.lifetime = NUMBER_LIFETIME
	_check(critical.is_critical and critical.text == "60",
			"Critical feedback receives the critical flag and actual one-hundred-fifty-percent damage")
	_near(dummy.attributes.get_value(CombatAttributes.Id.HEALTH), 940.0,
			"The critical number matches actual Health removed")
	await create_timer(NUMBER_LIFETIME + 0.1).timeout
	await process_frame
	_check(numbers.get_child_count() == 0, "Critical feedback completes its motion and expires normally")
	dummy.attributes.modify_current(CombatAttributes.Id.HEALTH,
			5.0 - dummy.attributes.get_value(CombatAttributes.Id.HEALTH))
	dummy.ability_system.receive_hit(context, payload)
	critical = numbers.get_child(0) as FloatingDamageNumber
	_check(critical.is_critical and critical.text == "5",
			"Critical overkill retains its flag while showing only actual Health removed")
	dummy.reset_actor()
	await process_frame
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 0.0)
	dummy.ability_system.receive_hit(context, payload)
	var ordinary := numbers.get_child(0) as FloatingDamageNumber
	_check(not ordinary.is_critical and ordinary.text == "40",
			"A following ordinary hit does not inherit critical presentation")
	ordinary.show_damage(60.0, true)
	ordinary.show_outcome(&"miss")
	_check(not ordinary.is_critical and ordinary.text == "MISS",
			"Reusing feedback for a failed outcome clears its critical state")
	dummy.reset_actor()
	await process_frame
	dummy.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 200.0)
	dummy.attributes.restore_resources()
	source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 20.0)


func _test_combat_hud() -> void:
	var arena := ARENA.instantiate()
	for path in ["Player/AbilitySystem", "Dummy/AbilitySystem"]:
		ATTRIBUTE_FIXTURE.configure(arena.get_node(path) as AbilitySystem)
	var source := arena.get_node("Player/Attributes") as ActorAttributes
	var target := arena.get_node("Dummy/Attributes") as ActorAttributes
	source.initial_modifiers = []
	target.initial_modifiers = []
	for attributes: ActorAttributes in [source, target]:
		attributes.level = 1
		attributes.allocated_strength = 0
		attributes.allocated_dexterity = 0
		attributes.allocated_intellect = 0
		attributes.allocated_vitality = 0
	root.add_child(arena)
	arena.get_node("Player").set_physics_process(false)
	arena.get_node("Player/AbilityInput").set_process(false)
	var tools := arena.get_node("CombatTestTools") as CombatTestTools
	tools.player_system.set_process(false)
	tools.dummy.ability_system.set_process(false)
	var hud := tools.get_node("Screen/HUD") as Control
	var health := hud.get_node("Health") as ProgressBar
	var mana := hud.get_node("Mana") as ProgressBar
	var stamina := hud.get_node("Stamina") as ProgressBar
	await _test_hud_layout(hud)
	_check(hud.has_node("EffectStrips") and not hud.has_node("Controls")
			and not hud.has_node("Resources") and not hud.has_node("MatchupStatus"),
			"The combat HUD contains the saved resource bars and effect strips")
	for bar in [health, mana, stamina]:
		_check(not bar.show_percentage and not bar.tooltip_text.is_empty(),
				"Resource bars have descriptions without numeric overlays")
	_check_bar(health, 200.0, 200.0, "Initial Health")
	_check_bar(mana, 100.0, 100.0, "Initial Mana")
	_check_bar(stamina, 100.0, 100.0, "Initial Stamina")
	await _test_effect_hud(hud, tools.player_system, tools.dummy.ability_system)
	source.apply_damage(25.0)
	source.modify_current(CombatAttributes.Id.MANA, -25.0)
	source.modify_current(CombatAttributes.Id.STAMINA, -30.0)
	_check_bar(health, 175.0, 200.0, "Health after damage")
	_check_bar(mana, 75.0, 100.0, "Mana after spending")
	_check_bar(stamina, 70.0, 100.0, "Stamina after spending")
	tools.player_system.advance(2.0)
	_check_bar(mana, 85.0, 100.0, "Mana after periodic regeneration")
	_check_bar(stamina, 90.0, 100.0, "Stamina after periodic regeneration")
	source.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 5.0)
	tools.player_system.advance(2.0)
	_check_bar(health, 185.0, 200.0, "Health after acquired regeneration")
	source.set_base_value(CombatAttributes.Id.MAX_HEALTH, 400.0)
	source.set_base_value(CombatAttributes.Id.MAX_MANA, 200.0)
	_check_bar(health, 185.0, 400.0, "Increasing Health capacity does not refill the bar")
	_check_bar(mana, 95.0, 200.0, "Increasing Mana capacity does not refill the bar")
	source.set_base_value(CombatAttributes.Id.MAX_STAMINA, 60.0)
	_check_bar(stamina, 60.0, 60.0, "Reducing Stamina capacity updates and clamps the bar")
	source.apply_damage(10000.0)
	tools.player_system.advance(10.0)
	_check_bar(health, 0.0, 400.0, "Death empties Health and regeneration cannot restore it")
	_check_bar(mana, 95.0, 200.0, "Mana stops recovering while the actor is dead")
	source.restore_resources()
	_check_bar(health, 400.0, 400.0, "Explicit restoration updates Health")
	_check_bar(mana, 200.0, 200.0, "Explicit restoration updates Mana")
	_check_bar(stamina, 60.0, 60.0, "Explicit restoration updates Stamina")
	var replacement := ATTRIBUTE_FIXTURE.new_attributes()
	root.add_child(replacement)
	replacement.modify_current(CombatAttributes.Id.HEALTH, -100.0)
	hud.bind_attributes(replacement)
	source.modify_current(CombatAttributes.Id.HEALTH, -10.0)
	_check_bar(health, 100.0, 200.0, "Rebinding disconnects the previous actor's signals")
	replacement.free()
	_check_bar(health, 0.0, 1.0, "A freed actor safely clears its HUD binding")
	hud.bind_attributes(source)
	_check_bar(health, 390.0, 400.0, "The HUD can bind back to the player after actor removal")
	tools.show_attributes(0)
	var sheet := tools.character_sheet
	var success_label := sheet.get_node("%SuccessLabel") as Label
	var success_value := sheet.get_node("%SuccessValue") as Label
	var failure_label := sheet.get_node("%FailureLabel") as Label
	var failure_value := sheet.get_node("%FailureValue") as Label
	var computed_health := sheet.get_value_label(CombatAttributes.Id.HEALTH) as Label
	var displayed_pool := computed_health.text.split("/")
	_check(displayed_pool.size() == 2 and float(displayed_pool[0]) == 390.0
			and float(displayed_pool[1]) == 400.0, "The sheet displays current and maximum Health")
	source.modify_current(CombatAttributes.Id.HEALTH, -10.0)
	await process_frame
	await process_frame
	displayed_pool = computed_health.text.split("/")
	_check(displayed_pool.size() == 2 and float(displayed_pool[0]) == 380.0
			and float(displayed_pool[1]) == 400.0,
			"The open sheet follows resource changes from outside its editor")
	_check(success_label.text == "Hit chance" and failure_label.text == "Resist",
			"The spell matchup shows Hit chance and Resist")
	_check(success_value.tooltip_text.contains("Accuracy rating 10"),
			"The selected spell's Accuracy remains available in the Hit chance tooltip")
	_near(float(success_value.text.trim_suffix("%")), 80.0, "The spell preview shows actual success chance")
	_near(float(failure_value.text.trim_suffix("%")), 20.0, "The spell preview shows actual resistance chance")
	target.level = 11
	tools.select_ability(&"fireball")
	tools.show_attributes(1)
	var actor_level := sheet.get_node("%ActorLevel") as Label
	_check(actor_level.text == "Lv. 11", "The sheet reports the edited dummy level")
	tools.show_attributes(0)
	_near(float(success_value.text.trim_suffix("%")), 8.0, "The spell preview follows the ten-level disadvantage")
	_near(float(failure_value.text.trim_suffix("%")), 92.0, "The spell preview shows the corresponding Resist chance")
	_check(success_value.tooltip_text.contains("Level ceiling 10"),
			"The Hit chance tooltip shows the level-specific ceiling")
	source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 10000.0)
	tools.refresh_matchup()
	_near(float(success_value.text.trim_suffix("%")), 10.0,
			"The menu respects the level-specific success ceiling despite huge rating")
	source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 10.0)
	target.level = 60
	tools.refresh_matchup()
	_check(float(success_value.text.trim_suffix("%").trim_prefix("<")) > 0.0,
			"The extended level curve's positive chance is not rounded to a misleading zero")
	arena.queue_free()
	await process_frame


func _test_effect_hud(hud: Control, system: AbilitySystem, dummy: AbilitySystem) -> void:
	var strips := hud.get_node("EffectStrips") as MarginContainer
	var buffs := strips.get_node("Rows/Buffs") as HFlowContainer
	var debuffs := strips.get_node("Rows/Debuffs") as HFlowContainer
	var health := hud.get_node("Health") as ProgressBar
	var health_top := health.get_global_rect().position.y
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	var buff := GameplayEffectDefinition.new()
	buff.display_name = "Test Buff"
	buff.timing = GameplayEffectDefinition.Timing.DURATION
	buff.duration = 1.0
	buff.icon = texture
	buff.hud_category = GameplayEffectDefinition.HudCategory.BUFF
	var debuff := buff.duplicate() as GameplayEffectDefinition
	debuff.display_name = "Test Debuff"
	debuff.hud_category = GameplayEffectDefinition.HudCategory.DEBUFF
	debuff.duration = 0.0
	var hidden := buff.duplicate() as GameplayEffectDefinition
	hidden.hud_category = GameplayEffectDefinition.HudCategory.NONE
	var iconless := buff.duplicate() as GameplayEffectDefinition
	iconless.icon = null
	var instant := GameplayEffectDefinition.new()
	instant.icon = texture
	instant.hud_category = GameplayEffectDefinition.HudCategory.BUFF
	var context := system.create_effect_context()
	var was_processing := system.is_processing()
	system.set_process(false)
	system.effects.apply_effect(hidden, context)
	system.effects.apply_effect(iconless, context)
	system.effects.apply_effect(instant, context)
	dummy.effects.apply_effect(buff, context)
	_check(not strips.visible and buffs.get_child_count() == 0 and debuffs.get_child_count() == 0,
			"Hidden, iconless, instant and other actors' effects leave the player's strips empty")

	var first_buff := system.effects.apply_effect(buff, context)
	for _index in range(5):
		system.effects.apply_effect(buff, context)
	system.effects.apply_effect(debuff, context)
	system.effects.apply_effect(debuff, context)
	_check(strips.visible and buffs.get_child_count() == 6 and debuffs.get_child_count() == 2,
			"Each retained instance gets its own icon in its authored strip")
	var second_buff := buffs.get_child(1) as Control
	var first_buff_icon := buffs.get_child(0) as Control
	var last_buff_icon := buffs.get_child(5) as Control
	var first_debuff_icon := debuffs.get_child(0) as Control
	var second_debuff_icon := debuffs.get_child(1) as Control
	_check(first_buff_icon.tooltip_text == buff.display_name
			and (first_buff_icon.get_node("Texture") as TextureRect).texture == texture,
			"An icon uses the effect's authored texture and display name")
	await process_frame
	await process_frame
	_check(first_buff_icon.global_position.x < second_buff.global_position.x
			and first_debuff_icon.global_position.x > second_debuff_icon.global_position.x,
			"Buffs flow from the left and debuffs flow from the right")
	_near(first_buff_icon.get_global_rect().position.x, health.get_global_rect().position.x,
			"The first buff starts at the left edge of the resource bars")
	_near(first_debuff_icon.get_global_rect().end.x, health.get_global_rect().end.x,
			"The first debuff starts at the right edge of the resource bars")
	_check(last_buff_icon.global_position.y > first_buff_icon.global_position.y
			and last_buff_icon.get_global_rect().end.x <= debuffs.get_global_rect().position.x
			and strips.get_global_rect().end.y <= health.get_global_rect().position.y,
			"Overflow wraps above the bars without running into the other strip")
	_near(health.get_global_rect().position.y, health_top,
			"Wrapping icons keeps the resource bars in place")

	system.effects.remove_effect(first_buff)
	_check(buffs.get_child_count() == 5 and buffs.get_child(0) == second_buff,
			"Removing one handle preserves the other instances of the same effect")
	hud.bind_attributes(system.attributes)
	_check(not strips.visible, "Rebinding without an effect runtime clears the old icons")
	hud.bind_attributes(system.attributes, system.effects)
	_check(buffs.get_child_count() == 5 and debuffs.get_child_count() == 2,
			"Rebinding populates the HUD from already-active effects")
	system.effects.advance(1.0)
	_check(buffs.get_child_count() == 0 and debuffs.get_child_count() == 2,
			"Expiry removes timed icons and preserves indefinite ones")
	system.clear_transient_effects()
	_check(not strips.visible and debuffs.get_child_count() == 0,
			"Clearing effects removes retained icons and collapses the empty strips")
	dummy.clear_transient_effects()
	system.set_process(was_processing)

	var attributes := system.attributes
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity + 50.0)
	var encumbered_icon := debuffs.get_child(0) as Control if debuffs.get_child_count() == 1 else null
	_check(encumbered_icon != null and encumbered_icon.tooltip_text == ENCUMBERED.display_name
			and (encumbered_icon.get_node("Texture") as TextureRect).texture == ENCUMBERED.icon,
			"Crossing carry capacity displays the saved Encumbered debuff icon")
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity)
	_check(not strips.visible, "Returning to carry capacity removes the Encumbered icon")


func _check_bar(bar: ProgressBar, current: float, maximum: float, message: String) -> void:
	_near(bar.value, current, message + ": current amount")
	_near(bar.max_value, maximum, message + ": maximum capacity")


func _test_hud_layout(hud: Control) -> void:
	var screen := hud.get_parent() as Control
	var bottom_inset := -hud.offset_bottom
	screen.set_anchors_preset(Control.PRESET_TOP_LEFT)
	for dimensions: Vector2 in [Vector2(1280.0, 720.0), Vector2(1920.0, 1080.0)]:
		screen.size = dimensions
		await process_frame
		_near(hud.position.x + hud.size.x * 0.5, dimensions.x * 0.5,
				"The saved playground HUD remains horizontally centered when its screen resizes")
		_near(dimensions.y - hud.position.y - hud.size.y, bottom_inset,
				"The saved playground HUD preserves its bottom inset when its screen resizes")


func _near(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.00001, "%s (%f / %f)" % [message, actual, expected])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
