extends SceneTree
## Verifies live 2.0 attribute editing, governing contexts, menus and damage telemetry.
## Run headless with --fixed-fps 60 --script res://tests/playground_tools_test.gd.

const PLAYGROUND = preload("res://levels/playground/playground.tscn")
const FIREBALL_FIXTURE = preload("res://tests/fireball_fixture.gd")
const SPRINT: int = 1
const FIREBALL: int = FIREBALL_FIXTURE.FIREBALL
const MOVEMENT_EXAMPLES: Array[int] = [SPRINT, 2, 3]
const ENCUMBERED_ACTION: int = 4
const EXHAUSTION_ACTION: int = 5
const ENCUMBERED_EFFECT_ID: int = 9
const DERIVATIONS_EFFECT_ID: int = 12
const REGENERATION_EFFECT_ID: int = 13

var _checks: int = 0
var _failures: int = 0
var _arena: Node3D
var _tools: CombatTestTools
var _source: ActorAttributes
var _target: ActorAttributes


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_arena = PLAYGROUND.instantiate()
	for path in ["Player/AbilitySystem", "Dummy/AbilitySystem"]:
		preload("res://tests/attribute_fixture.gd").configure(_arena.get_node(path) as AbilitySystem)
	for path in ["Player/Attributes", "Dummy/Attributes"]:
		var profile := _arena.get_node(path) as ActorAttributes
		profile.initial_modifiers = []
		profile.level = 1
		profile.allocated_strength = 0
		profile.allocated_dexterity = 0
		profile.allocated_intellect = 0
		profile.allocated_vitality = 0
	_prepare_test_tuning()
	root.add_child(_arena)
	current_scene = _arena
	_tools = _arena.get_node("CombatTestTools") as CombatTestTools
	_source = _tools.player_system.attributes
	_target = _tools.dummy.attributes
	_arena.get_node("Player").set_physics_process(false)
	_tools.ability_input.set_process(false)
	_tools.player_system.set_process(false)
	_tools.dummy.ability_system.set_process(false)
	_check_saved_grants()
	if not FIREBALL_FIXTURE.install(_tools.player_system):
		_check(false, "The saved Fireball is wired to a valid animation and impact")
		quit(1)
		return
	var fireball := _tools.player_system.get_ability_definition(FIREBALL)
	var impact := fireball.execution.get_effect_payload()[0]
	impact.get_damage_execution().amount = AmountDefinition.fixed(5.0)
	impact.get_damage_execution().power_coefficient = 1.0
	_tools.show_attributes(0)
	await _test_attribute_editors()
	_test_attribute_filter()
	_test_matchup_with_unavailable_attributes()
	_test_live_resistance_edits()
	_test_live_armor_edits()
	_test_live_armor_penetration_edits()
	_test_live_critical_edits()
	_test_live_movement_speed_edits()
	_test_live_action_speed_edits()
	await _test_live_carry_load_edits()
	await _test_clearing_capacity_effect_restores_encumbrance()
	_test_damage_preview()
	_tools.close_menu()
	_test_menu_and_input_ownership()
	await _test_split_layout()
	_test_real_damage_statistics()
	_test_failed_outcome_statistics()
	_test_critical_statistics()
	_test_recorder_reset_and_log_bound()
	await _test_fireball_cast_bar()
	_arena.queue_free()
	await process_frame
	print("Playground tools checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _prepare_test_tuning() -> void:
	var editors := _arena.get_node(
			"CombatTestTools/Screen/Menu/Margin/Content/Workspace/Inputs/Margin/Content/Editors")
	for editor: LiveAttributeEditor in [editors.get_node("Player"), editors.get_node("Dummy")]:
		var slider_ranges: Dictionary[int, Vector2] = {}
		for id: int in CombatAttributes.all_ids():
			slider_ranges[id] = Vector2(-300.0, 3000.0)
		slider_ranges[CombatAttributes.Id.CARRIED_WEIGHT] = Vector2(0.0, 400.0)
		slider_ranges[CombatAttributes.Id.ATTACK_SPEED] = Vector2(0.0, 100.0)
		slider_ranges[CombatAttributes.Id.CAST_SPEED] = Vector2(0.0, 100.0)
		editor.slider_ranges = slider_ranges
		var level := editor.get_node("ActorControls/Level") as HSlider
		level.min_value = 1.0
		level.max_value = 60.0

	var movement := _arena.get_node("Player/Movement") as FirstPersonMovement
	movement.settings = FirstPersonMovementSettings.new()
	movement.settings.normal_run_speed = 4.0
	movement.settings.sprint_speed_multiplier = 1.5
	movement.settings.crouch_speed_multiplier = 0.6
	movement.settings.walk_speed_multiplier = 0.5
	movement.settings.full_penalty_ratio = 2.0
	movement.settings.min_speed_multiplier = 0.5

	var player := _arena.get_node("Player/AbilitySystem") as AbilitySystem
	preload("res://tests/sprint_fixture.gd").configure(player)


func _test_attribute_editors() -> void:
	var editor := _tools.player_editor
	_check(editor.actor == _tools.player_system
			and _tools.dummy_editor.actor == _tools.dummy.ability_system,
			"The saved editors bind independently to player and dummy")
	_check(editor.rows.size() == CombatAttributes.all_ids().size()
			and editor.rows.has(CombatAttributes.Id.SPELL_PENETRATION),
			"The editor includes all active attributes, including Spell Penetration")
	_check(_sheet_value(CombatAttributes.Id.PHYSICAL_POWER) == null
			and _sheet_value(CombatAttributes.Id.MAGIC_POWER) == null
			and _sheet_value(CombatAttributes.Id.ACCURACY_RATING) == null,
			"The character sheet omits raw combat calculation inputs")
	for id: int in CombatAttributes.all_ids():
		_check(editor.rows.has(id), "%s has an editable row" % CombatAttributes.display_name(id))
		editor.set_attribute_override(id, 42.0)
		_check(CombatAttributes.is_current_resource(id) or editor.override_values.has(id),
				"Every non-current foundation attribute accepts a test override")
	editor.clear_overrides()
	for setting in [[CombatAttributes.Id.HEALTH_REGEN, 3.0],
			[CombatAttributes.Id.MANA_REGEN, 7.0], [CombatAttributes.Id.STAMINA_REGEN, 15.0]]:
		editor.set_attribute_override(setting[0], setting[1])
		_near(_source.get_value(setting[0]), setting[1],
				"Each regeneration rate can be changed live through the shared editor")
	editor.clear_overrides()
	_near(_source.get_value(CombatAttributes.Id.HEALTH_REGEN), 0.0,
			"Clearing regeneration overrides restores zero starting Health recovery")
	_near(_source.get_value(CombatAttributes.Id.MANA_REGEN), 5.0,
			"Clearing regeneration overrides restores base Mana recovery")
	_near(_source.get_value(CombatAttributes.Id.STAMINA_REGEN), 10.0,
			"Clearing regeneration overrides restores base Stamina recovery")
	var equipment := AttributeModifier.new()
	equipment.attribute = CombatAttributes.Id.MAX_HEALTH
	equipment.value = 7.0
	_source.set_modifiers(&"test_equipment", [equipment])
	editor.set_attribute_override(CombatAttributes.Id.MAX_HEALTH, 500.0)
	_near(_source.get_value(CombatAttributes.Id.MAX_HEALTH), 507.0,
			"A test base preserves another owner's flat contribution")
	editor.clear_overrides()
	_near(_source.get_value(CombatAttributes.Id.MAX_HEALTH), 207.0,
			"Removing the test override restores the primary-derived base")
	_source.remove_modifiers(&"test_equipment")
	var level := editor.get_node("ActorControls/Level") as HSlider
	level.value = 59.75
	_check(_source.level == 60 and _target.level == 1,
			"The Level slider snaps to whole levels and affects only the selected actor")
	_check(level.editable and level.step == 1.0, "The Level slider advances one level at a time")
	level.value = 99.0
	_check(_source.level == 60, "The level control obeys the level-60 limit")
	for id: int in [CombatAttributes.Id.STRENGTH, CombatAttributes.Id.DEXTERITY,
			CombatAttributes.Id.INTELLECT, CombatAttributes.Id.VITALITY]:
		var primary: LiveAttributeEditorRow = editor.rows[id]
		primary.override_toggle.button_pressed = true
		primary.base_slider.value = 12.75
		_check(primary.base_slider.editable and primary.base_slider.step == 1.0
				and _source.get_value(id) == 13.0 and primary.value_label.text == "13",
				"The %s slider snaps to whole points" % CombatAttributes.display_name(id))
	editor.reset_test_edits()
	_check(_source.level == 1 and editor.override_values.is_empty(),
			"Reset removes session overrides and restores the initial level")
	editor.set_attribute_override(CombatAttributes.Id.MAX_HEALTH, 1000.0)
	var health: LiveAttributeEditorRow = editor.rows[CombatAttributes.Id.HEALTH]
	_check(health.base_slider.editable and is_equal_approx(health.base_slider.step, 0.01),
			"The current pool slider accepts direct edits in hundredths")
	_near(health.base_slider.max_value, 1000.0, "The Health slider follows its edited capacity")
	health.base_slider.value = 500.37
	_near(_source.get_value(CombatAttributes.Id.HEALTH), 500.37,
			"The Health slider edits the current resource to hundredths")
	await process_frame
	var displayed_pool := _sheet_value(CombatAttributes.Id.HEALTH).text.split("/")
	_check(displayed_pool.size() == 2 and is_equal_approx(float(displayed_pool[0]), 500.37)
			and is_equal_approx(float(displayed_pool[1]), 1000.0),
			"The sheet follows the live slider amount and its current capacity")
	editor.set_attribute_override(CombatAttributes.Id.MAX_HEALTH, 450.0)
	_check(health.base_slider.max_value == 450.0 and health.base_slider.value == 450.0,
			"Reducing maximum Health updates the current slider's cap and value")
	editor.set_attribute_override(CombatAttributes.Id.MAX_HEALTH, 1000.0)
	editor.restore_actor()
	_near(_source.get_value(CombatAttributes.Id.HEALTH), 1000.0,
			"Restore fills the configured test capacity")
	_check(editor.override_values.has(CombatAttributes.Id.MAX_HEALTH),
			"Restore preserves deliberate test settings")
	editor.clear_overrides()
	_tools.dummy_editor.set_attribute_override(CombatAttributes.Id.STRENGTH, 30.0)
	_near(_target.get_value(CombatAttributes.Id.STRENGTH), 30.0,
			"Dummy attributes can be edited independently")
	_near(_source.get_value(CombatAttributes.Id.STRENGTH), 10.0,
			"Dummy changes do not leak into the player")
	_tools.dummy_editor.clear_overrides()


func _test_attribute_filter() -> void:
	var editor := _tools.player_editor
	var search := editor.find_child("Search", true, false) as LineEdit
	_check(search != null, "The saved editor has an attribute search field")
	if search == null:
		return
	search.text = "fIrE"
	search.text_changed.emit(search.text)
	_check(editor.rows[CombatAttributes.Id.FIRE_RESISTANCE].visible
			and not editor.rows[CombatAttributes.Id.ARMOR].visible,
			"Searching matches attribute names without requiring their exact case")
	search.text = ""
	search.text_changed.emit(search.text)
	_check(editor.rows[CombatAttributes.Id.ARMOR].visible,
			"Clearing the search restores filtered attributes")


func _test_matchup_with_unavailable_attributes() -> void:
	var sheet := _tools.character_sheet
	var preview := sheet.get_node("%Matchup") as Control
	var unavailable := sheet.get_node("%Unavailable") as Label
	var success := sheet.get_node("%SuccessValue") as Label
	_tools.refresh_matchup()
	var valid_success := success.text
	_check(preview.is_visible_in_tree() and not unavailable.is_visible_in_tree()
			and not valid_success.is_empty(),
			"Valid saved bindings produce the selected action's matchup information")
	_tools.player_system.attributes = null
	_tools.refresh_matchup()
	_check(unavailable.is_visible_in_tree() and not preview.is_visible_in_tree(),
			"Losing the player attribute binding after readiness produces a diagnostic instead of a nil call")
	_tools.player_system.attributes = _source
	_tools.refresh_matchup()
	_check(preview.is_visible_in_tree() and success.text == valid_success,
			"Restoring the player attribute binding restores matchup calculation")
	_tools.dummy.attributes = null
	_tools.refresh_matchup()
	_check(not preview.is_visible_in_tree() and not unavailable.is_visible_in_tree()
			and is_equal_approx(float(_sheet_value(CombatAttributes.Id.STRENGTH).text), 10.0),
			"The player sheet stays available when the matchup target loses its attributes")
	_tools.dummy.attributes = _target
	_tools.refresh_matchup()
	_check(preview.is_visible_in_tree() and success.text == valid_success,
			"Restoring the dummy attribute reference restores matchup calculation")


func _test_live_resistance_edits() -> void:
	var editor := _tools.player_editor
	for id: int in CombatAttributes.resistance_ids():
		var row: LiveAttributeEditorRow = editor.rows[id]
		row.override_toggle.button_pressed = true
		row.base_slider.value = -35.57
		_near(_source.get_value(id), -35.57, "A negative Resistance slider value preserves hundredths")
		_check(row.value_label.text.ends_with("%") and _sheet_value(id).text == "-35.57%",
				"Raw and effective Resistance show percentage units")
		row.base_slider.value = 140.0
		_near(editor.override_values[id], 140.0, "The live editor preserves its raw over-cap Resistance override")
		_near(_source.get_value(id), 80.0, "The live editor shows the final positive resistance cap")
		_near(row.base_slider.value, 140.0, "The input does not overwrite the authored over-cap value with its cap")
		row.base_slider.value = -250.0
		_near(_source.get_value(id), -100.0, "The live editor preserves negative input while limiting effective vulnerability")
		editor.clear_overrides()
		_near(_source.get_value(id), 0.0, "Removing a Resistance override restores neutral resistance")
		_tools.dummy_editor.set_attribute_override(id, -50.0)
		_near(_target.get_value(id), -50.0, "Dummy Resistance can be edited independently")
		_near(_source.get_value(id), 0.0, "Dummy Resistance changes do not modify the player")
		_tools.dummy_editor.clear_overrides()


func _test_live_armor_edits() -> void:
	_tools.show_attributes(1)
	var editor := _tools.dummy_editor
	var id := CombatAttributes.Id.ARMOR
	var row: LiveAttributeEditorRow = editor.rows[id]
	row.override_toggle.button_pressed = true
	row.base_slider.value = 2500.0
	_near(_target.get_value(id), 2500.0, "The saved Armor input accepts uncapped rating values")
	_near(row.base_slider.value, 2500.0, "The Armor input preserves rating above the reduction threshold")
	_check(not row.value_label.text.ends_with("%") and _sheet_value(id).text.ends_with("%"),
			"The Armor slider shows rating and the character sheet shows reduction")
	_near(float(_sheet_value(id).text.trim_suffix("%")), 75.0,
			"The sheet shows the capped Physical damage reduction")
	var debuff := AttributeModifier.new()
	debuff.attribute = id
	debuff.value = -2000.0
	_target.set_modifiers(&"test_armor_debuff", [debuff])
	_near(_target.get_value(id), 500.0, "Over-cap Armor absorbs part of a later debuff without discarding its rating")
	_near(_source.get_value(id), 0.0, "Changing dummy Armor does not modify the player")
	_target.remove_modifiers(&"test_armor_debuff")
	_near(_target.get_value(id), 2500.0, "Removing the debuff restores the full Armor rating")
	row.base_slider.value = -100.0
	_near(_target.get_value(id), 0.0, "The Armor slider floors the rating at zero")
	editor.clear_overrides()
	_near(_target.get_value(id), 0.0, "Clearing the Armor override restores the authored zero base")
	_tools.show_attributes(0)
	_near(float(_sheet_value(id).text.trim_suffix("%")), 0.0,
			"Switching back shows the player's independent Physical damage reduction")


func _test_live_armor_penetration_edits() -> void:
	var id := CombatAttributes.Id.ARMOR_PENETRATION
	var player_editor := _tools.player_editor
	var row: LiveAttributeEditorRow = player_editor.rows[id]
	row.override_toggle.button_pressed = true
	row.base_slider.value = 45.5
	_near(_source.get_value(id), 45.5, "The saved Penetration slider applies fractional percentage points live")
	_check(row.value_label.text.ends_with("%") and _sheet_value(id).text == "45.5%",
			"Penetration input and effective value communicate percentage units")
	row.base_slider.value = 175.0
	_near(_source.get_value(id), 100.0, "The live Penetration edit applies the final percentage cap")
	_near(player_editor.override_values[id], 175.0, "The live editor retains raw over-cap penetration")
	_near(row.base_slider.value, 175.0, "The input remains the raw authored percentage rather than replacing it with the cap")
	row.base_slider.value = -50.0
	_near(_source.get_value(id), 0.0, "Negative test penetration has a zero effective minimum")
	player_editor.clear_overrides()
	_tools.dummy_editor.set_attribute_override(id, 65.0)
	_near(_target.get_value(id), 65.0, "Dummy outgoing Penetration can be authored independently")
	_near(_source.get_value(id), 0.0, "Dummy Penetration edits do not alter player outgoing Penetration")
	_tools.dummy_editor.clear_overrides()
	_near(_target.get_value(id), 0.0, "Clearing dummy Penetration restores its neutral base")


func _test_live_critical_edits() -> void:
	var editor := _tools.player_editor
	var chance: LiveAttributeEditorRow = editor.rows[CombatAttributes.Id.CRITICAL_CHANCE]
	chance.override_toggle.button_pressed = true
	chance.base_slider.value = 150.0
	_near(_source.get_value(CombatAttributes.Id.CRITICAL_CHANCE), 100.0,
			"A live Critical Chance override reaches but cannot exceed one hundred percent")
	editor.clear_overrides()
	var damage: LiveAttributeEditorRow = editor.rows[CombatAttributes.Id.CRITICAL_DAMAGE]
	damage.override_toggle.button_pressed = true
	damage.base_slider.value = 2500.0
	_near(_source.get_value(CombatAttributes.Id.CRITICAL_DAMAGE), 2500.0,
			"Critical Damage accepts uncapped bonus percentages in the live editor")
	_near(float(_sheet_value(CombatAttributes.Id.CRITICAL_DAMAGE).text.trim_suffix("%")), 2650.0,
			"The sheet shows total Critical damage including its 150% baseline")
	editor.clear_overrides()
	_near(_source.get_value(CombatAttributes.Id.CRITICAL_CHANCE), 0.0,
			"Clearing Critical Chance restores the zero starting chance")
	_near(_source.get_value(CombatAttributes.Id.CRITICAL_DAMAGE), 0.0,
			"Clearing Critical Damage restores the zero bonus above base critical damage")
	_tools.dummy_editor.set_attribute_override(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	_near(_target.get_value(CombatAttributes.Id.CRITICAL_CHANCE), 100.0,
			"The dummy has independently editable outgoing Critical Chance")
	_near(_source.get_value(CombatAttributes.Id.CRITICAL_CHANCE), 0.0,
			"Dummy critical settings do not alter player critical chance")
	_tools.dummy_editor.clear_overrides()


func _test_live_movement_speed_edits() -> void:
	var id := CombatAttributes.Id.MOVEMENT_SPEED
	var editor := _tools.player_editor
	var row: LiveAttributeEditorRow = editor.rows[id]
	var player := _arena.get_node("Player")
	var movement := player.get_node("Movement") as FirstPersonMovement
	var attribute_components := 0
	for child in player.get_children():
		if child is ActorAttributes:
			attribute_components += 1
	_check(attribute_components == 1 and player.get_node("Attributes") == _source,
			"The saved caster inherits one player attribute component used by F3")
	_check(movement != null and movement.attributes == _source,
			"The saved movement component reads the same ActorAttributes that F3 edits")
	if movement == null:
		return
	var sprint_multiplier := movement.settings.sprint_speed_multiplier
	var crouch_walk_multiplier := movement.settings.crouch_speed_multiplier \
			* movement.settings.walk_speed_multiplier
	_near(row.base_slider.value, 0.0, "The saved Movement Speed control starts at zero bonus")
	_near(float(_sheet_value(id).text.trim_suffix("%")), 0.0, "The effective Movement Speed display starts at zero bonus")
	row.value_label.text = "0.0 m/s"
	row.refresh(0.0, false, 0.0)
	_check(row.value_label.text.ends_with("%") and _sheet_value(id).text.ends_with("%"),
			"Refreshing an existing Movement Speed row removes obsolete physical-speed units")
	row.override_toggle.button_pressed = true
	row.base_slider.value = 100.0
	_near(row.base_slider.value, 100.0, "F3 preserves an editable raw movement override above the effective cap")
	_near(editor.override_values[id], 100.0, "The editor retains the raw over-cap F3 Set Base modifier")
	_near(_source.get_value(id), 25.0, "The saved Movement Speed control applies the effective twenty-five-percent cap")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 5.0,
			"An over-cap F3 movement override reaches normal Run as a twenty-five-percent bonus")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.SPRINT), 5.0 * sprint_multiplier,
			"An over-cap F3 movement bonus respects the cap before the authored Sprint proportion")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH_WALK), 5.0 * crouch_walk_multiplier,
			"An over-cap F3 movement bonus respects the cap before the combined Crouch Walk proportion")
	_check(row.value_label.text.ends_with("%") and _sheet_value(id).text.ends_with("%"),
			"Movement Speed input and effective value communicate the percentage bonus")
	_near(float(_sheet_value(id).text.trim_suffix("%")), 25.0,
			"The displayed movement value is the effective capped bonus rather than the raw override")
	var slow := AttributeModifier.new()
	slow.attribute = id
	slow.value = -90.0
	_source.set_modifiers(&"test_movement_cap_debuff", [slow])
	_near(_source.get_value(id), 10.0, "A later debuff uses the raw over-cap F3 modifier before final clamping")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.4,
			"Movement immediately reads the debuffed result of the full raw F3 override")
	_source.remove_modifiers(&"test_movement_cap_debuff")
	_near(_source.get_value(id), 25.0, "Removing the debuff restores the capped F3 movement bonus")
	row.base_slider.value = 20.0
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.8,
			"A twenty-percent F3 movement bonus increases normal Run speed by twenty percent")
	row.base_slider.value = -100.0
	_near(_source.get_value(id), -100.0, "The live editor supports a negative one-hundred-percent movement bonus")
	for gait: FirstPersonGait.Gait in [FirstPersonGait.Gait.RUN, FirstPersonGait.Gait.SPRINT,
			FirstPersonGait.Gait.CROUCH_WALK]:
		_near(movement.get_speed_for_gait(gait), 0.0, "A minus-one-hundred-percent F3 bonus stops every inspected gait")
	editor.clear_overrides()
	_near(_source.get_value(id), 0.0, "Removing the movement override restores the authored zero bonus")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), 4.0,
			"Clearing F3 overrides restores actual normal-run speed")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.SPRINT), 4.0 * sprint_multiplier,
			"Clearing F3 overrides restores actual Sprint speed")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH_WALK), 4.0 * crouch_walk_multiplier,
			"Clearing F3 overrides restores actual Crouch Walk speed")
	_tools.dummy_editor.set_attribute_override(id, -12.5)
	_near(_target.get_value(id), -12.5, "Dummy Movement Speed bonus remains signed and independently editable")
	_near(_source.get_value(id), 0.0, "Dummy movement data does not alter the player's speed attribute")
	_tools.dummy_editor.clear_overrides()
	_near(_target.get_value(id), 0.0, "Clearing dummy Movement Speed restores its authored zero bonus")


func _test_live_action_speed_edits() -> void:
	var editor := _tools.player_editor
	for id: int in [CombatAttributes.Id.ATTACK_SPEED, CombatAttributes.Id.CAST_SPEED]:
		var row: LiveAttributeEditorRow = editor.rows[id]
		row.override_toggle.button_pressed = true
		_near(row.base_slider.max_value, 100.0, "Action speed starts with a 100% test range")
		row.base_slider.value = 50.0
		_check(row.value_label.text == "50%" and _sheet_value(id).text == "50%",
				"The action speed slider and sheet show the actual percentage")
		row.base_slider.value = 100.0
		row.base_slider.drag_ended.emit(true)
		_near(row.base_slider.max_value, 200.0, "Releasing at the upper edge expands the test range")
		_near(row.base_slider.value, 100.0, "Expanding the test range preserves the selected value")
		row.base_slider.value = 160.0
		_check(row.value_label.text == "160%" and _sheet_value(id).text == "100%",
				"The raw override can exceed the cap while the sheet shows the effective bonus")
		editor.clear_overrides()


func _test_live_carry_load_edits() -> void:
	var editor := _tools.player_editor
	var system := _tools.player_system
	var weight_id := CombatAttributes.Id.CARRIED_WEIGHT
	var capacity_id := CombatAttributes.Id.CARRY_CAPACITY
	var weight: LiveAttributeEditorRow = editor.rows[weight_id]
	var capacity: LiveAttributeEditorRow = editor.rows[capacity_id]
	var load_value := _sheet_value(weight_id)
	var badge := _tools.character_sheet.get_node("%Encumbered") as Control
	var speed_penalty := _tools.character_sheet.get_node("%MovementSpeedPenaltyValue") as Label
	var jump_penalty := _tools.character_sheet.get_node("%JumpHeightPenaltyValue") as Label
	var movement := _arena.get_node("Player/Movement") as FirstPersonMovement
	var debuffs := _tools.get_node("Screen/HUD/EffectStrips/Rows/Debuffs") as HFlowContainer
	_check(load_value == _sheet_value(capacity_id),
			"The sheet combines weight and capacity into one Carry load readout")
	_check(weight.base_slider.min_value == 0.0 and weight.base_slider.max_value >= 400.0
			and is_equal_approx(weight.base_slider.step, 0.01),
			"The weight slider has a fractional track that reaches beyond starting capacity")
	editor.set_attribute_override(CombatAttributes.Id.MOVEMENT_SPEED, 20.0)
	var unburdened_speed := movement.settings.normal_run_speed * 1.2
	for example in [[0.0, 1.0, 0.0], [100.0, 1.0, 0.0], [200.0, 0.5, -100.0], [150.0, 0.5625, -50.0]]:
		var carried: float = example[0]
		var speed_factor: float = example[1]
		var expected_jump_penalty: float = example[2]
		if carried > 0.0:
			weight.override_toggle.button_pressed = true
			weight.base_slider.value = carried
		var load_parts := load_value.text.split("/")
		_check(load_parts.size() == 2 and float(load_parts[0]) == carried and float(load_parts[1]) == 100.0,
				"The sheet displays %.0f carried weight against 100 capacity" % carried)
		_check(badge.is_visible_in_tree() == (carried > 100.0),
				"The encumbrance badge reflects the load at %.0f weight" % carried)
		_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), unburdened_speed * speed_factor,
				"F3 carried weight updates actual Run speed at %.0f weight" % carried)
		var shown_speed := speed_penalty.text.trim_suffix("%").replace("−", "-")
		var shown_jump := jump_penalty.text.trim_suffix("%").replace("−", "-")
		_check(speed_penalty.is_visible_in_tree() and speed_penalty.text.ends_with("%")
				and shown_speed.is_valid_float() and is_equal_approx(shown_speed.to_float(), (speed_factor - 1.0) * 100.0),
				"The sheet displays the live speed penalty at %.0f weight" % carried)
		_check(jump_penalty.is_visible_in_tree() and jump_penalty.text.ends_with("%")
				and shown_jump.is_valid_float() and is_equal_approx(shown_jump.to_float(), expected_jump_penalty),
				"The sheet displays the live jump height penalty at %.0f weight" % carried)
	_near(_source.get_value(weight_id), 150.0, "The weight slider accepts a load above capacity")
	_near(_source.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 20.0,
			"Encumbrance applies after the character's Movement Speed bonus")
	var previous_effects := system.effects.get_retained_effects()
	_check(system.get_active_cast(ENCUMBERED_ACTION) != null and debuffs.get_child_count() == 1,
			"Overloading through F3 starts the granted action and shows one HUD debuff")
	var utilities := editor.get_node("ActorControls/Utilities") as MenuButton
	utilities.get_popup().id_pressed.emit(LiveAttributeEditor.UtilityAction.CLEAR_EFFECTS)
	await process_frame
	var effects := system.effects.get_retained_effects()
	_check(system.effects.active_count(ENCUMBERED_EFFECT_ID) == 1
			and effects.keys() != previous_effects.keys()
			and system.effects.active_count(DERIVATIONS_EFFECT_ID) == 1
			and system.effects.active_count(REGENERATION_EFFECT_ID) == 1
			and system.get_active_cast(ENCUMBERED_ACTION) != null
			and system.tags.get_count(&"State.Encumbered") == 1 and debuffs.get_child_count() == 1,
			"Clearing effects restores the action-owned effect and preserves both startup effects")
	_check(badge.is_visible_in_tree() and load_value.text == "150 / 100"
			and speed_penalty.text.trim_suffix("%").replace("−", "-").to_float() == -43.75
			and jump_penalty.text.trim_suffix("%").replace("−", "-").to_float() == -50.0,
			"Clearing effects preserves the live carry load and penalty readouts")
	capacity.override_toggle.button_pressed = true
	capacity.base_slider.value = 200.0
	var expanded_load := load_value.text.split("/")
	_check(expanded_load.size() == 2 and float(expanded_load[0]) == 150.0 and float(expanded_load[1]) == 200.0
			and not badge.is_visible_in_tree(), "Raising capacity updates the load and clears the badge")
	_check(weight.base_slider.max_value >= 600.0 and weight.base_slider.value == 150.0,
			"Raising capacity expands the weight track and preserves the current load")
	_near(movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), unburdened_speed,
			"Raising capacity removes the physical movement penalty")
	_check(speed_penalty.text.trim_suffix("%").to_float() == 0.0
			and jump_penalty.text.trim_suffix("%").to_float() == 0.0,
			"Raising capacity clears both displayed penalties at the same weight")
	_check(system.get_active_cast(ENCUMBERED_ACTION) == null
			and system.tags.get_count(&"State.Encumbered") == 0
			and system.effects.active_count(ENCUMBERED_EFFECT_ID) == 0 and debuffs.get_child_count() == 0,
			"Raising capacity ends the action and removes its gameplay effect, tag and HUD icon")
	_tools.show_attributes(1)
	_check(not speed_penalty.is_visible_in_tree() and not jump_penalty.is_visible_in_tree(),
			"The stationary dummy does not show the player's movement penalties")
	_tools.show_attributes(0)
	editor.clear_overrides()


func _test_clearing_capacity_effect_restores_encumbrance() -> void:
	var editor := _tools.player_editor
	var system := _tools.player_system
	var badge := _tools.character_sheet.get_node("%Encumbered") as Control
	var weight_id := CombatAttributes.Id.CARRIED_WEIGHT
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.CARRY_CAPACITY
	modifier.value = 100.0
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = 221
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.modifiers = [modifier]
	var handle := system.effects.apply_effect(effect, system.create_effect_context())
	editor.set_attribute_override(weight_id, 150.0)
	_check(system.effects.has_retained_effect(handle) and not badge.is_visible_in_tree()
			and _sheet_value(weight_id).text == "150 / 200",
			"A retained capacity bonus keeps the F3 test weight below capacity")
	var utilities := editor.get_node("ActorControls/Utilities") as MenuButton
	utilities.get_popup().id_pressed.emit(LiveAttributeEditor.UtilityAction.CLEAR_EFFECTS)
	await process_frame
	_check(not system.effects.has_retained_effect(handle) and badge.is_visible_in_tree()
			and _sheet_value(weight_id).text == "150 / 100"
			and system.tags.get_count(&"State.Encumbered") == 1
			and system.effects.active_count(ENCUMBERED_EFFECT_ID) == 1
			and system.get_active_cast(ENCUMBERED_ACTION) != null,
			"Clearing a capacity bonus activates Encumbered and updates the sheet at the same weight")
	editor.clear_overrides()


func _check_saved_grants() -> void:
	var system := _tools.player_system
	var ability_ids := MOVEMENT_EXAMPLES + [FIREBALL, ENCUMBERED_ACTION, EXHAUSTION_ACTION]
	_check(system.granted_abilities.size() == ability_ids.size(),
			"The saved playground grants Fireball and its movement and status actions")
	for ability_id in ability_ids:
		var definition := system.get_ability_definition(ability_id)
		_check(definition != null and system.granted_abilities.has(definition)
				and system.get_ability_weapon_source(ability_id) == null
				and system.create_ability_context(ability_id) != null,
				"The playground grants %s directly with a usable context and no weapon source" % ability_id)


func _test_damage_preview() -> void:
	var editor := _tools.player_editor
	var target_editor := _tools.dummy_editor
	var system := _tools.player_system
	editor.set_attribute_override(CombatAttributes.Id.MAGIC_POWER, 35.0)
	editor.set_attribute_override(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	target_editor.set_attribute_override(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	var previous_health := _target.get_value(CombatAttributes.Id.HEALTH)
	target_editor.set_current_value(CombatAttributes.Id.HEALTH, 1.0)
	var weapon_rng := system.get("_weapon_random") as RandomNumberGenerator
	var weapon_state := weapon_rng.state
	var event_count := _tools.recorder.get_log().size()
	var mana := _source.get_value(CombatAttributes.Id.MANA)
	var stamina := _source.get_value(CombatAttributes.Id.STAMINA)
	var damage := _tools.character_sheet.get_node("%HitDamageValue") as Label
	_check(_tools.select_ability(FIREBALL), "The player can select Fireball")
	_check(damage.text.is_valid_float() and is_equal_approx(float(damage.text), 20.0),
			"Fireball shows one normal-hit value after matching Fire Resistance")
	target_editor.set_attribute_override(CombatAttributes.Id.FIRE_RESISTANCE, 75.0)
	_near(float(damage.text), 10.0, "Editing target Resistance updates the live hit preview")
	var penetration_id := CombatAttributes.Id.SPELL_PENETRATION
	var row: LiveAttributeEditorRow = editor.rows[penetration_id]
	row.override_toggle.button_pressed = true
	row.base_slider.value = 20.0
	_check(row.value_label.text == "20%" and _sheet_value(penetration_id).text == "20%",
			"The editor and character sheet show Spell Penetration as a percentage")
	_near(float(damage.text), 18.0, "Spell Penetration updates the normal-hit preview against high resistance")
	target_editor.set_attribute_override(CombatAttributes.Id.FIRE_RESISTANCE, 0.0)
	_near(float(damage.text), 48.0, "Spell Penetration takes the live preview below zero resistance")
	_tools.show_attributes(1)
	_near(float(damage.text), 48.0, "The Dummy sheet retains the player-to-dummy hit preview")
	_tools.show_attributes(0)
	_check(weapon_rng.state == weapon_state and _tools.recorder.get_log().size() == event_count
			and _target.get_value(CombatAttributes.Id.HEALTH) == 1.0
			and _source.get_value(CombatAttributes.Id.MANA) == mana
			and _source.get_value(CombatAttributes.Id.STAMINA) == stamina,
			"Inspecting normal hit damage leaves weapon randomness, resources and telemetry untouched")
	editor.clear_overrides()
	target_editor.clear_overrides()
	target_editor.set_current_value(CombatAttributes.Id.HEALTH, previous_health)


func _test_menu_and_input_ownership() -> void:
	_check(not _tools.select_ability(222)
			and _tools.selected_ability_id == FIREBALL,
			"An unknown selection cannot replace a valid ability")
	var selector := _tools.get_node(
			"Screen/Menu/Margin/Content/Workspace/Inputs/Margin/Content/Ability/Select"
	) as OptionButton
	var ability_ids: Array[int] = []
	for index in selector.item_count:
		ability_ids.append(selector.get_item_metadata(index))
	_check(ability_ids == [FIREBALL], "The combat selector offers Fireball")
	for locomotion_id in MOVEMENT_EXAMPLES:
		_check(not ability_ids.has(locomotion_id) and not _tools.select_ability(locomotion_id),
				"The combat selector excludes the %s movement ability" % locomotion_id)
	for status_id: int in [ENCUMBERED_ACTION, EXHAUSTION_ACTION]:
		_check(not ability_ids.has(status_id) and not _tools.select_ability(status_id),
				"The combat selector excludes the granted %s status action" % status_id)
	var look_enabled := _tools.player_look.is_processing_unhandled_input()
	var ability_enabled := _tools.ability_input.is_processing()
	_tools.show_attributes(1)
	_check(_tools.is_menu_open(), "F3's actor menu can be opened")
	var actor_title := _tools.character_sheet.get_node("%ActorTitle") as Label
	_check(_tools.dummy_editor.is_visible_in_tree() and not _tools.player_editor.is_visible_in_tree()
			and actor_title.text == "Dummy", "The selected actor controls both sides of the split view")
	_check(not _tools.player_look.is_processing_unhandled_input()
			and not _tools.ability_input.is_processing(),
			"An open menu suspends aiming and ability input")
	_tools.show_statistics()
	_check(_tools.statistics_panel.is_visible_in_tree()
			and not _tools.character_sheet.is_visible_in_tree(),
			"F1 shows statistics in place of the split attribute view")
	_tools.ability_input.set("_controls_were_active", true)
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	_tools._input(escape)
	_check(not _tools.is_menu_open()
			and _tools.player_look.is_processing_unhandled_input() == look_enabled
			and _tools.ability_input.is_processing() == ability_enabled,
			"Escape closes the panel and restores the input receivers' original state")
	_check(not bool(_tools.ability_input.get("_controls_were_active")),
			"Closing the panel clears the ability input latch")
	var visible_before := _tools.combat_log.visible
	_tools.toggle_log()
	_check(_tools.combat_log.visible != visible_before, "F2 toggles the log independently")
	_tools.toggle_log()
	for action_and_key in [[&"combat_statistics", KEY_F1], [&"combat_log", KEY_F2],
			[&"combat_attributes", KEY_F3]]:
		var found := false
		for event in InputMap.action_get_events(action_and_key[0]):
			if event is InputEventKey and event.physical_keycode == action_and_key[1]:
				found = true
		_check(found, "%s retains its function-key binding" % action_and_key[0])


func _test_split_layout() -> void:
	var screen := _tools.get_node("Screen") as Control
	var menu := screen.get_node("Menu") as Control
	var workspace := menu.get_node("Margin/Content/Workspace") as HBoxContainer
	var tabs := menu.get_node("Margin/Content/Header/Tabs") as TabBar
	var inputs := workspace.get_node("Inputs") as Control
	var ability := inputs.get_node("Margin/Content/Ability/Select") as OptionButton
	var scroll := _tools.character_sheet.get_node("Layout/Scroll") as ScrollContainer
	var scrollbar := scroll.get_v_scroll_bar()
	var capacity := CombatAttributes.Id.CARRY_CAPACITY
	var capacity_value := _sheet_value(capacity)
	var tab_titles := ["Player", "Dummy", "Statistics"]
	_tools.show_attributes(0)
	_tools.player_editor.set_attribute_override(capacity, 1.25e20)
	_check(ability.is_visible_in_tree() and _tools.player_editor.is_visible_in_tree()
			and _tools.character_sheet.is_visible_in_tree(),
			"The ability selector and actor editor share the left pane beside the computed sheet")
	_check(menu.find_child("Close", true, false) == null
			and menu.find_child("RestoreDummy", true, false) == null
			and menu.find_child("Footer", true, false) == null
			and _tools.player_editor.find_child("Help", true, false) == null,
			"The menu omits the removed buttons and instruction blocks")
	screen.set_anchors_preset(Control.PRESET_TOP_LEFT)
	for dimensions: Vector2 in [Vector2(960, 640), Vector2(1280, 720)]:
		screen.size = dimensions
		await process_frame
		await process_frame
		var left_rect := inputs.get_global_rect()
		var right_rect := _tools.character_sheet.get_global_rect()
		_check(left_rect.size.x > 0.0 and right_rect.size.x > 0.0
				and left_rect.end.x <= right_rect.position.x
				and menu.get_global_rect().encloses(left_rect)
				and menu.get_global_rect().encloses(right_rect)
				and screen.get_global_rect().encloses(menu.get_global_rect()),
				"The two panes fit side by side at %s" % dimensions)
		var tabs_fit := tabs.tab_count == tab_titles.size()
		var previous_right := 0.0
		if tabs_fit:
			for index in tabs.tab_count:
				var tab_rect := tabs.get_tab_rect(index)
				tabs_fit = tabs_fit and tabs.get_tab_title(index) == tab_titles[index] \
						and not tabs.is_tab_hidden(index) and tab_rect.size.x > 0.0 \
						and tab_rect.position.x >= previous_right \
						and Rect2(Vector2.ZERO, tabs.size).encloses(tab_rect)
				previous_right = tab_rect.end.x
		_check(tabs_fit, "All three tabs fit in the header without overlap at %s" % dimensions)
		scroll.scroll_vertical = ceili(scrollbar.max_value)
		await process_frame
		var value_rect := capacity_value.get_global_rect()
		var scroll_rect := scroll.get_global_rect()
		var gutter := scrollbar.get_global_rect().position.x - value_rect.end.x
		_check(scrollbar.is_visible_in_tree() and scroll.scroll_vertical > 0
				and value_rect.position.y >= scroll_rect.position.y
				and value_rect.end.y <= scroll_rect.end.y + 1.0 and gutter > 0.0,
				"The last sheet value fits beside the visible scrollbar at %s (gutter %.1f)"
				% [dimensions, gutter])
	_tools.player_editor.set_attribute_override(capacity, 0.0, false)
	scroll.scroll_vertical = 0
	_tools.close_menu()


func _test_real_damage_statistics() -> void:
	_tools.recorder.reset()
	_tools.recorder.clear_log()
	_source.set_base_value(CombatAttributes.Id.INTELLECT, 25.0)
	_source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	_target.set_base_value(CombatAttributes.Id.MAX_HEALTH, 500.0)
	_target.restore_resources()
	var system := _tools.player_system
	var definition := system.get_ability_definition(FIREBALL)
	var context := system.create_ability_context(FIREBALL)
	_check(definition != null and context != null, "The saved Fireball grant provides a spell context")
	if definition == null or context == null:
		return
	var payload: Array[GameplayEffectDefinition] = definition.execution.get_effect_payload()
	var numeric_effect := payload[0].duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as GameplayEffectDefinition
	numeric_effect.get_damage_execution().amount = null
	numeric_effect.get_damage_execution().power_coefficient = 1.0
	payload = [numeric_effect]
	var result := _tools.dummy.ability_system.receive_hit(context, payload)
	_check(result.outcome == &"hit", "An actual delivery succeeds through the shared runtime")
	_near(_target.get_value(CombatAttributes.Id.HEALTH), 450.0,
			"The private Fireball telemetry fixture applies 50 Magic Power as actual damage")
	var rows := _tools.recorder.get_rows(_source.get_instance_id())
	_check(rows.size() == 1, "Actual damage is grouped under its source and ability")
	if not rows.is_empty():
		var row: Dictionary = rows[0]
		_check(row.attempts == 1 and row.hits == 1 and row.damage_events == 1,
				"One contact records one delivery, hit and damage application")
		_near(row.damage, 50.0, "Statistics use actual Health removed")
	_check(system.try_activate(FIREBALL), "A real ability request is accepted")
	_check(not system.try_activate(FIREBALL),
			"An overlapping request is rejected")
	_check(system.try_activate(SPRINT) and not system.try_activate(SPRINT),
			"Sprint can start during Fireball and rejects a duplicate request")
	_source.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT,
			_source.get_value(CombatAttributes.Id.CARRY_CAPACITY) + 1.0)
	_check(system.get_active_cast(ENCUMBERED_ACTION) != null,
			"The granted status action starts during the combat telemetry fixture")
	_source.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 0.0)
	system.release_ability(SPRINT)
	system.cancel_ability(FIREBALL)
	var totals := _tools.recorder.get_totals()
	_check(totals.casts == 1 and totals.failed_casts == 1,
			"F1 counts accepted and rejected Fireball requests while excluding Sprint and Encumbered")
	var table := _tools.statistics_panel.get_node("TableScroll/Table") as Tree
	var table_row := table.get_root().get_first_child()
	_check(table_row != null and table_row.get_text(0).ends_with(definition.display_name)
			and table_row.get_next() == null,
			"The combat statistics table shows Fireball and excludes Sprint and Encumbered")
	_source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 10.0)


func _test_failed_outcome_statistics() -> void:
	_tools.recorder.reset()
	_tools.recorder.clear_log()
	_target.restore_resources()
	var system := _tools.player_system
	var definition := system.get_ability_definition(FIREBALL)
	var payload: Array[GameplayEffectDefinition] = definition.execution.get_effect_payload()
	var context := system.create_ability_context(FIREBALL)
	var before := _target.get_value(CombatAttributes.Id.HEALTH)
	var result := _tools.dummy.ability_system.receive_hit(context, payload, 1.0)
	_check(result.outcome == &"resist", "A failed spell delivery reports a Resist outcome")
	_near(_target.get_value(CombatAttributes.Id.HEALTH), before,
			"A resisted spell removes no Health")
	context.ability_tags = PackedStringArray(["Ability.Attack", "Weapon.Finesse"])
	result = _tools.dummy.ability_system.receive_hit(context, payload, 1.0)
	_check(result.outcome == &"miss", "A failed attack delivery reports a Miss outcome")
	var totals := _tools.recorder.get_totals(_source.get_instance_id())
	_check(totals.attempts == 2 and totals.hits == 0
			and totals.misses == 1 and totals.resists == 1 and totals.damage_events == 0,
			"The recorder counts one outcome per failed contact without inventing damage")
	_near(totals.damage, 0.0, "Failed outcomes do not add damage to statistics")
	var failures := 0
	for event: Dictionary in _tools.recorder.get_log():
		if StringName(event.get("type", &"")) != &"hit_outcome":
			continue
		var line := CombatLogPanel.format_event(event)
		_check(line.contains(definition.display_name)
				and line.contains(str(event.outcome).to_upper()),
				"Combat history names the ability and its failed Accuracy outcome")
		failures += 1
	_check(failures == 2, "Only one target event is recorded for each failed delivery")
	var table := _tools.statistics_panel.get_node("TableScroll/Table") as Tree
	var item := table.get_root().get_first_child()
	_check(item != null, "The statistics table includes the failed ability's row")
	if item != null:
		for column in CombatStatisticsPanel.COLUMNS.size():
			if CombatStatisticsPanel.COLUMNS[column][1] in ["misses", "resists"]:
				_check(item.get_text(column) == "1", "The statistics table displays the failed outcome count")


func _test_critical_statistics() -> void:
	_tools.recorder.reset()
	_tools.recorder.clear_log()
	_target.restore_resources()
	_source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	_source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	_source.set_base_value(CombatAttributes.Id.CRITICAL_DAMAGE, 0.0)
	var system := _tools.player_system
	var definition := system.get_ability_definition(FIREBALL)
	var context := system.create_ability_context(FIREBALL)
	var payload: Array[GameplayEffectDefinition] = definition.execution.get_effect_payload()
	var numeric_effect := payload[0].duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as GameplayEffectDefinition
	numeric_effect.get_damage_execution().amount = null
	numeric_effect.get_damage_execution().power_coefficient = 1.0
	payload = [numeric_effect]
	var components: Array[GameplayEffectDefinition] = [payload[0], payload[0]]
	var result := _tools.dummy.ability_system.receive_hit(context, components)
	_check(result.outcome == &"hit" and bool(result.get("is_critical", false)),
			"A successful critical payload reports one shared critical outcome")
	var totals := _tools.recorder.get_totals(_source.get_instance_id())
	_check(totals.attempts == 1 and totals.hits == 1 and totals.critical_hits == 1
			and totals.damage_events == 2,
			"Critical hits count once per payload rather than once per damage component")
	_near(totals.damage, 150.0, "Both components contribute their actual critical damage")
	var critical_lines := 0
	for event: Dictionary in _tools.recorder.get_log():
		if StringName(event.get("type", &"")) == &"damage":
			var line := CombatLogPanel.format_event(event)
			_check(line.contains("CRITICAL") and line.contains("75.0"),
					"The combat log marks critical damage while retaining the actual amount")
			critical_lines += 1
	_check(critical_lines == 2, "Each critical component is logged without duplicating damage events")
	_source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 0.0)
	result = _tools.dummy.ability_system.receive_hit(context, payload)
	_check(not bool(result.get("is_critical", true)), "Zero chance produces ordinary damage feedback")
	totals = _tools.recorder.get_totals(_source.get_instance_id())
	_check(totals.hits == 2 and totals.critical_hits == 1 and totals.damage_events == 3,
			"Ordinary hits increase hit counts without increasing Critical Hits")
	var table := _tools.statistics_panel.get_node("TableScroll/Table") as Tree
	var item := table.get_root().get_first_child()
	_check(item != null, "Critical telemetry appears in the per-ability statistics table")
	if item != null:
		for column in CombatStatisticsPanel.COLUMNS.size():
			if CombatStatisticsPanel.COLUMNS[column][1] == "critical_hits":
				_check(item.get_text(column) == "1", "The Critical Hits column displays contact count")
	_source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 10.0)


func _test_recorder_reset_and_log_bound() -> void:
	var recorder := _tools.recorder
	var old_count := recorder.get_log().size()
	recorder.reset()
	_check(recorder.get_rows().is_empty() and recorder.elapsed_seconds() == 0.0,
			"Reset clears measurements and restarts the measurement clock")
	_check(recorder.get_log().size() == old_count, "Statistics reset preserves log history")
	recorder.max_log_entries = 3
	for index in 10:
		recorder.record_event({"type": &"damage", "source_id": 5, "ability_id": 223,
				"source_name": "Test", "ability_name": "Bounded", "amount": 1.0,
				"resolved_amount": 100.0, "sequence": index})
	var log := recorder.get_log()
	_check(log.size() == 3 and log[0].sequence == 7 and log[2].sequence == 9,
			"Bounded history retains only the most recent events")
	_near(recorder.get_totals().damage, 10.0, "Discarding log lines does not discard statistics")
	log[0]["amount"] = 999.0
	_check(recorder.get_log()[0].amount == 1.0, "Returned log data cannot mutate history")
	recorder.clear_log()
	_check(recorder.get_log().is_empty() and recorder.get_totals().damage == 10.0,
			"Clearing history preserves accumulated measurements")


func _test_fireball_cast_bar() -> void:
	var system := _tools.player_system
	var bar := _tools.combat_hud.get_node("CastBarSlot/CastBar") as ProgressBar
	_check(not bar.is_visible_in_tree(), "The saved cast bar is hidden before Fireball starts")
	system.set_physics_process(false)
	system.advance(system.get_cooldown_remaining(FIREBALL) + 0.001)
	_source.restore_resources()
	_tools.player_editor.set_attribute_override(CombatAttributes.Id.CAST_SPEED, 50.0)
	if not system.try_activate(FIREBALL):
		_check(false, "Fireball begins for the cast bar test")
		return
	var cast := system.get_active_cast(FIREBALL)
	var release_time: float = FIREBALL_FIXTURE.RELEASE_TIME
	system.advance_animation(release_time / 3.0)
	await process_frame
	await process_frame
	_check(bar.is_visible_in_tree(), "The cast bar appears during Fireball windup")
	_near(bar.value, 0.5, "The cast bar follows actual animation position at 150% playback")
	system.advance_animation(release_time / 3.0 + 0.001)
	await process_frame
	await process_frame
	_check(cast.released and not cast.finished and not bar.is_visible_in_tree(),
			"The cast bar hides at the release key during recovery")
	system.cancel_ability(FIREBALL)
	system.advance(system.get_cooldown_remaining(FIREBALL) + 0.001)
	if not system.try_activate(FIREBALL):
		_check(false, "Fireball begins for the cancellation test")
		return
	system.advance_animation(release_time / 3.0)
	await process_frame
	await process_frame
	_check(bar.is_visible_in_tree(), "A new cast shows the cast bar")
	system.cancel_ability(FIREBALL)
	await process_frame
	await process_frame
	_check(not bar.is_visible_in_tree(), "Cancelling before release hides the cast bar")
	_tools.player_editor.clear_overrides()


func _sheet_value(attribute: int) -> Label:
	return _tools.character_sheet.get_value_label(attribute)


func _near(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.00001, "%s (%f / %f)" % [message, actual, expected])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
