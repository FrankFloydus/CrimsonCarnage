class_name LiveAttributeEditor
extends VBoxContainer
## Live test controls. Owned modifiers never overwrite the actor's authored profile.

## Emitted after values are refreshed for the editor and its computed sheet.
signal values_refreshed

enum UtilityAction { RESET_EDITS, CLEAR_EFFECTS, RESTORE_RESOURCES }

## Saved row layout instantiated once for each active code-defined combat attribute.
@export var row_scene: PackedScene
## Include resource restoration in this actor's utility menu.
@export var allow_restore_resources: bool = true
## Playground slider ranges by attribute ID. X is the minimum and Y is the maximum.
## Resource tracks follow their pool capacity. The weight track includes at least three times Carry Capacity.
## Other omitted ranges use 0 to 100.
@export var slider_ranges: Dictionary[int, Vector2] = {}

var actor: AbilitySystem
var rows: Dictionary[int, LiveAttributeEditorRow] = {}
var override_values: Dictionary[int, float] = {}
var context_tags := PackedStringArray()
var context_name: String = "Selected action"
var _original_level: int = 1
var _modifier_owner: StringName = StringName("combat_test_editor_%d" % get_instance_id())
var _dirty_ids: Dictionary[int, bool] = {}
var _refresh_queued: bool = false
var _context_refresh_elapsed: float = 0.0

@onready var _level_input: HSlider = $ActorControls/Level
@onready var _level_value: Label = $ActorControls/LevelValue
@onready var _search: LineEdit = $Search
@onready var _utilities: MenuButton = $ActorControls/Utilities
@onready var _scroll: ScrollContainer = $Scroll
@onready var _row_list: VBoxContainer = $Scroll/Rows
@onready var _empty_state: Label = $Scroll/Rows/EmptyState


func _ready() -> void:
	_level_input.value_changed.connect(_on_level_changed)
	var popup := _utilities.get_popup()
	if not allow_restore_resources:
		var restore_index := popup.get_item_index(UtilityAction.RESTORE_RESOURCES)
		if restore_index >= 0:
			popup.remove_item(restore_index)
	popup.id_pressed.connect(_on_utility_selected)
	_search.text_changed.connect(_filter_rows)
	for id: int in CombatAttributes.all_ids():
		var row := row_scene.instantiate() as LiveAttributeEditorRow
		_row_list.add_child(row)
		row.configure(id, slider_ranges.get(id, Vector2(0.0, 100.0)))
		row.override_changed.connect(set_attribute_override)
		rows[id] = row
	_refresh_all()
	_refresh_all.call_deferred()


func _exit_tree() -> void:
	_disconnect_actor()
	if is_instance_valid(actor) and is_instance_valid(actor.attributes):
		actor.attributes.remove_modifiers(_modifier_owner)


func bind_actor(system: AbilitySystem) -> void:
	_disconnect_actor()
	if is_instance_valid(actor) and is_instance_valid(actor.attributes):
		actor.attributes.remove_modifiers(_modifier_owner)
	actor = system
	override_values.clear()
	if is_instance_valid(actor) and is_instance_valid(actor.attributes):
		_original_level = actor.attributes.level
		actor.attributes.attribute_changed.connect(_on_attribute_changed)
		actor.tags.changed.connect(_on_tags_changed)
	if is_node_ready():
		_refresh_all()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or not _has_actor():
		return
	_context_refresh_elapsed += delta
	if _context_refresh_elapsed < 0.15:
		return
	_context_refresh_elapsed = 0.0
	# Scoped modifiers may change selected-action values without changing unscoped totals.
	_refresh_all()


func set_context_tags(tags: PackedStringArray, action_name: String = "Selected action") -> void:
	context_tags = tags.duplicate()
	context_name = action_name
	_refresh_all()


func set_actor_level(value: int) -> void:
	if not _has_actor():
		return
	actor.attributes.level = value
	_refresh_all()


func set_attribute_override(id: int, value: float, enabled: bool = true) -> void:
	if not _has_actor() or id not in CombatAttributes.all_ids() or not is_finite(value):
		return
	if CombatAttributes.is_current_resource(id):
		set_current_value(id, value)
		return
	if enabled:
		override_values[id] = roundf(value) if LiveAttributeEditorRow.step_for_attribute(id) == 1.0 else value
	else:
		override_values.erase(id)
	_apply_overrides()
	_refresh_all()


func set_current_value(id: int, value: float) -> void:
	if not _has_actor() or not CombatAttributes.is_current_resource(id) or not is_finite(value):
		return
	actor.attributes.modify_current(id, value - actor.attributes.get_value(id))
	_queue_refresh(id)


func clear_overrides() -> void:
	override_values.clear()
	if _has_actor():
		actor.attributes.remove_modifiers(_modifier_owner)
	_refresh_all()


func reset_test_edits() -> void:
	clear_overrides()
	set_actor_level(_original_level)


func restore_actor() -> void:
	if not _has_actor():
		return
	actor.cancel_all_abilities()
	_clear_effects()
	actor.attributes.restore_resources()
	_refresh_all()


func _apply_overrides() -> void:
	var modifiers: Array[AttributeModifier] = []
	for id: int in override_values:
		var modifier := AttributeModifier.new()
		modifier.attribute = id as CombatAttributes.Id
		modifier.operation = AttributeModifier.Operation.SET_BASE
		modifier.value = override_values[id]
		modifiers.append(modifier)
	actor.attributes.set_modifiers(_modifier_owner, modifiers)


func _clear_effects() -> void:
	if _has_actor() and actor.effects != null:
		actor.clear_transient_effects()
	_refresh_all()


func _has_actor() -> bool:
	return is_instance_valid(actor) and is_instance_valid(actor.attributes)


func _disconnect_actor() -> void:
	if not _has_actor():
		return
	if actor.attributes.attribute_changed.is_connected(_on_attribute_changed):
		actor.attributes.attribute_changed.disconnect(_on_attribute_changed)
	if actor.tags.changed.is_connected(_on_tags_changed):
		actor.tags.changed.disconnect(_on_tags_changed)


func _on_level_changed(value: float) -> void:
	set_actor_level(int(value))


func _on_utility_selected(id: int) -> void:
	match id:
		UtilityAction.RESET_EDITS:
			reset_test_edits()
		UtilityAction.CLEAR_EFFECTS:
			_clear_effects()
		UtilityAction.RESTORE_RESOURCES:
			if allow_restore_resources:
				restore_actor()


func _on_attribute_changed(id: int, _previous: float, _value: float) -> void:
	for resource_id in CombatAttributes.current_ids():
		if CombatAttributes.maximum_for(resource_id) == id:
			_dirty_ids[resource_id] = true
	if id == CombatAttributes.Id.CARRY_CAPACITY:
		_dirty_ids[CombatAttributes.Id.CARRIED_WEIGHT] = true
	_queue_refresh(id)


func _on_tags_changed(_tag: StringName, _present: bool) -> void:
	_queue_refresh()


func _queue_refresh(id: int = CombatAttributes.Id.NONE) -> void:
	if id != CombatAttributes.Id.NONE:
		_dirty_ids[id] = true
	if _refresh_queued or not is_node_ready():
		return
	_refresh_queued = true
	_refresh_dirty.call_deferred()


func _refresh_dirty() -> void:
	_refresh_queued = false
	if not _has_actor():
		_refresh_all()
		return
	for id: int in _dirty_ids:
		_refresh_row(id)
	_dirty_ids.clear()
	_refresh_level()
	values_refreshed.emit()


func _refresh_all() -> void:
	if not is_node_ready():
		return
	var has_actor := _has_actor()
	_level_input.editable = has_actor
	_search.editable = has_actor
	_utilities.disabled = not has_actor
	_row_list.visible = has_actor
	if has_actor:
		for id: int in rows:
			_refresh_row(id)
		_refresh_level()
	_dirty_ids.clear()
	values_refreshed.emit()


func _refresh_row(id: int) -> void:
	if not rows.has(id):
		return
	var track_maximum := 0.0
	if CombatAttributes.is_current_resource(id):
		track_maximum = actor.attributes.get_value(CombatAttributes.maximum_for(id))
	elif id == CombatAttributes.Id.CARRIED_WEIGHT:
		var overload_limit := actor.attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY) * 3.0
		if is_finite(overload_limit):
			track_maximum = ceilf(overload_limit)
	rows[id].refresh(actor.attributes.get_base_value(id, context_tags),
			override_values.has(id), override_values.get(id, 0.0), track_maximum)


func _refresh_level() -> void:
	_level_input.set_value_no_signal(actor.attributes.level)
	_level_value.text = str(actor.attributes.level)


func _filter_rows(query: String) -> void:
	var search := query.strip_edges().to_lower()
	var has_match := false
	for id: int in rows:
		var matches := search.is_empty() or rows[id].name_label.text.to_lower().contains(search)
		rows[id].visible = matches
		has_match = has_match or matches
	_empty_state.visible = not has_match
	_scroll.scroll_vertical = 0
