class_name CombatTestTools
extends CanvasLayer
## Scene-local controls for inspecting and tuning the two playground actors at runtime.

const COMBAT_DEFINITION_JSON = preload("res://combat/abilities/combat_definition_json.gd")

## Player whose attributes, granted abilities, and combat events are inspected.
@export var player_system: AbilitySystem
## Saved target restored by the reset action and edited in the Dummy tab.
@export var dummy: DamageDummy
## Mouse-look input receiver suspended while a test menu owns the pointer.
@export var player_look: Node
## Player action router whose primary combat slot can be reassigned for testing.
@export var action_router: PlayerActionRouter

var recorder := CombatTestRecorder.new()
var selected_ability_id: int = 0
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _look_input_was_enabled: bool = false
var _ability_process_was_enabled: bool = false
var _last_attribute_tab: int = 0

@onready var player_editor: LiveAttributeEditor = $Screen/Menu/Margin/Content/Workspace/Inputs/Margin/Content/Editors/Player
@onready var dummy_editor: LiveAttributeEditor = $Screen/Menu/Margin/Content/Workspace/Inputs/Margin/Content/Editors/Dummy
@onready var character_sheet: Control = $Screen/Menu/Margin/Content/Workspace/CharacterSheet
@onready var statistics_panel: Control = $Screen/Menu/Margin/Content/Statistics
@onready var combat_log: Control = $Screen/CombatLog
@onready var combat_hud: Control = $Screen/HUD
@onready var _menu: PanelContainer = $Screen/Menu
@onready var _backdrop: ColorRect = $Screen/Backdrop
@onready var _tabs: TabBar = $Screen/Menu/Margin/Content/Header/Tabs
@onready var _workspace: HBoxContainer = $Screen/Menu/Margin/Content/Workspace
@onready var _ability_selector: OptionButton = $Screen/Menu/Margin/Content/Workspace/Inputs/Margin/Content/Ability/Select
@onready var _sprint_id := COMBAT_DEFINITION_JSON.load_ability_id("res://player/abilities/sprint.ability.json")


func _ready() -> void:
	combat_hud.bind_attributes(player_system.attributes, player_system.effects, player_system)
	player_editor.bind_actor(player_system)
	dummy_editor.bind_actor(dummy.ability_system)
	statistics_panel.bind_recorder(recorder)
	combat_log.bind_recorder(recorder)
	player_system.combat_event.connect(recorder.record_event)
	dummy.ability_system.combat_event.connect(recorder.record_event)
	_ability_selector.item_selected.connect(_on_ability_selected)
	player_editor.values_refreshed.connect(_refresh_visible_sheet)
	dummy_editor.values_refreshed.connect(_refresh_visible_sheet)
	_tabs.tab_changed.connect(_on_tab_changed)
	var configured_ability_id := action_router.get_slot_ability(PlayerActionRouter.PRIMARY_SLOT)
	for definition in player_system.get_granted_ability_definitions():
		if definition.ability_id != configured_ability_id \
				and not AttributeModifier._has_match(definition.ability_tags, "Ability.Attack") \
				and not GameplayEffectContext.is_spell_delivery(definition.ability_tags):
			continue
		_ability_selector.add_item(definition.display_name)
		_ability_selector.set_item_metadata(_ability_selector.item_count - 1, definition.ability_id)
	if not select_ability(configured_ability_id, false) and _ability_selector.item_count > 0:
		select_ability(int(_ability_selector.get_item_metadata(0)), false)
	_menu.hide()
	_backdrop.hide()
	_on_tab_changed(_tabs.current_tab)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.echo:
		return
	if event.is_action_pressed(&"combat_statistics"):
		if is_menu_open() and _tabs.current_tab == 2:
			close_menu()
		else:
			show_statistics()
	elif event.is_action_pressed(&"combat_log"):
		toggle_log()
	elif event.is_action_pressed(&"combat_attributes"):
		if is_menu_open() and _tabs.current_tab != 2:
			close_menu()
		else:
			show_attributes(_last_attribute_tab)
	elif is_menu_open() and event.is_action_pressed(&"release_mouse"):
		close_menu()
	else:
		return
	get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"reset_target") and not is_menu_open():
		reset_dummy()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if is_instance_valid(_menu) and _menu.visible:
		close_menu()


func select_ability(ability_id: int, assign_primary_slot: bool = true) -> bool:
	var definition := player_system.get_ability_definition(ability_id)
	if definition == null:
		return false
	for index in _ability_selector.item_count:
		if int(_ability_selector.get_item_metadata(index)) == ability_id:
			if assign_primary_slot and not action_router.set_slot_ability(PlayerActionRouter.PRIMARY_SLOT, ability_id):
				return false
			selected_ability_id = ability_id
			_ability_selector.select(index)
			var context := player_system.create_ability_context(ability_id)
			var tags := context.ability_tags if context != null else definition.ability_tags
			player_editor.set_context_tags(tags, definition.display_name)
			dummy_editor.set_context_tags(tags, definition.display_name)
			refresh_matchup()
			return true
	return false


func show_attributes(target_index: int = 0) -> void:
	_open_menu(clampi(target_index, 0, 1))


func show_statistics() -> void:
	_open_menu(2)


func is_menu_open() -> bool:
	return is_instance_valid(_menu) and _menu.visible


func close_menu() -> void:
	if not is_menu_open():
		return
	_menu.hide()
	_backdrop.hide()
	if is_instance_valid(player_look):
		player_look.set_process_unhandled_input(_look_input_was_enabled)
	if is_instance_valid(action_router):
		action_router.set_process_unhandled_input(_ability_process_was_enabled)
	Input.mouse_mode = _previous_mouse_mode


func toggle_log() -> void:
	combat_log.visible = not combat_log.visible


func reset_dummy() -> void:
	dummy.reset_actor()


func refresh_matchup() -> void:
	var editor := dummy_editor if _last_attribute_tab == 1 else player_editor
	var actor_name := "Dummy" if _last_attribute_tab == 1 else "Player"
	var source := player_system.attributes if is_instance_valid(player_system) else null
	var target := dummy.attributes if is_instance_valid(dummy) else null
	var matchup: Dictionary = {}
	if is_instance_valid(source) and is_instance_valid(target):
		var definition := player_system.get_ability_definition(selected_ability_id)
		var context := player_system.create_ability_context(selected_ability_id)
		if definition != null and context != null:
			var tags := context.ability_tags
			var rating := source.get_value(CombatAttributes.Id.ACCURACY_RATING, tags)
			matchup = CombatMath.get_hit_chance_details(source.level, target.level, rating)
			matchup["accuracy_rating"] = rating
			matchup["spell"] = GameplayEffectContext.is_spell_delivery(tags)
			matchup["ability_name"] = definition.display_name
			matchup["source_level"] = source.level
			matchup["target_level"] = target.level
			_add_hit_preview(matchup, definition.execution, context, target)
	var movement: FirstPersonMovement
	if _last_attribute_tab == 0 and is_instance_valid(player_system) \
			and is_instance_valid(player_system.actor_body):
		movement = player_system.actor_body.get_node_or_null("Movement") as FirstPersonMovement
	character_sheet.refresh(editor.actor, editor.context_tags, actor_name, matchup, movement)


func _add_hit_preview(
		matchup: Dictionary, execution: AbilityExecution,
		context: GameplayEffectContext, target: ActorAttributes
) -> void:
	var target_system := dummy.ability_system
	if execution == null or not is_instance_valid(target_system) or target_system.effects == null:
		return
	var damage_effects: Array[GameplayEffectDefinition] = []
	for effect in execution.get_effect_payload():
		if effect != null and effect.is_damage_effect() \
				and target_system.effects.can_apply_effect(effect):
			damage_effects.append(effect)
	if damage_effects.is_empty():
		return

	# Explicit endpoint rolls keep the preview deterministic and leave combat RNG untouched.
	var low_context := context.duplicate_for_hit(0.0)
	var high_context := context.duplicate_for_hit(1.0)
	var minimum := 0.0
	var maximum := 0.0
	var power_details := PackedStringArray()
	for effect in damage_effects:
		minimum += CombatMath.resolve_effect(effect, low_context, target)
		maximum += CombatMath.resolve_effect(effect, high_context, target)
		var power := CombatMath.get_source_power(effect, context, effect.get_context_tags(context.ability_tags))
		var power_name := "Physical Power" if effect.damage_type == GameplayEffectDefinition.DamageType.PHYSICAL \
				else "Magic Power"
		var detail := "%s %s" % [power_name, LiveAttributeEditorRow.format_value(power).trim_suffix(".0")]
		if not power_details.has(detail):
			power_details.append(detail)
	if is_finite(minimum) and is_finite(maximum):
		matchup["hit_damage_min"] = minimum
		matchup["hit_damage_max"] = maximum
		matchup["hit_damage_power_details"] = "\n".join(power_details)


func _refresh_visible_sheet() -> void:
	if is_menu_open() and _workspace.visible:
		refresh_matchup()


func _open_menu(tab: int) -> void:
	if not is_menu_open():
		_previous_mouse_mode = Input.mouse_mode
		if is_instance_valid(player_look):
			_look_input_was_enabled = player_look.is_processing_unhandled_input()
			player_look.set_process_unhandled_input(false)
		if is_instance_valid(action_router):
			_ability_process_was_enabled = action_router.is_processing_unhandled_input()
			action_router.set_process_unhandled_input(false)
			action_router.cancel_pending_input()
		player_system.cancel_animation()
		player_system.release_ability(_sprint_id)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_backdrop.show()
		_menu.show()
	if _tabs.current_tab == tab:
		_refresh_visible_sheet()
	else:
		_tabs.current_tab = tab


func _on_tab_changed(tab: int) -> void:
	var show_editors := tab < 2
	_workspace.visible = show_editors
	statistics_panel.visible = not show_editors
	if show_editors:
		_last_attribute_tab = tab
		player_editor.visible = tab == 0
		dummy_editor.visible = tab == 1
		refresh_matchup()


func _on_ability_selected(index: int) -> void:
	select_ability(int(_ability_selector.get_item_metadata(index)))
