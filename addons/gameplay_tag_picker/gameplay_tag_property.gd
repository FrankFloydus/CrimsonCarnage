@tool
extends EditorProperty
## Edits a tag or tag array through the project registry while preserving legacy values.

var _multiple: bool
var _allow_implied: bool
var _read_only: bool
var _choices := PackedStringArray()
var _unregistered := PackedStringArray()
var _draft := PackedStringArray()

@onready var _button: Button = %ChooseTags
@onready var _picker: ConfirmationDialog = %Picker
@onready var _search: LineEdit = %Search
@onready var _tree: Tree = %TagList
@onready var _message: Label = %RegistryMessage


func configure(multiple: bool, allow_implied: bool) -> void:
	_multiple = multiple
	_allow_implied = allow_implied


func _ready() -> void:
	add_focusable(_button)
	_button.disabled = _read_only
	_button.pressed.connect(_open_picker)
	_search.text_changed.connect(_rebuild_choices)
	_tree.item_edited.connect(_on_checkbox_changed)
	_tree.item_selected.connect(_on_item_selected)
	_picker.confirmed.connect(_apply_tags)
	_update_property()


func _set_read_only(read_only: bool) -> void:
	_read_only = read_only
	if is_node_ready():
		_button.disabled = read_only


func _update_property() -> void:
	if not is_node_ready() or not is_instance_valid(get_edited_object()):
		return
	var tags := _read_tags()
	if tags.is_empty():
		_button.text = "Choose Tags…" if _multiple else "Choose Tag…"
	elif tags.size() == 1:
		_button.text = tags[0]
	else:
		_button.text = "%d Tags" % tags.size()
	_button.tooltip_text = "\n".join(tags)


func _read_tags() -> PackedStringArray:
	var value: Variant = get_edited_object().get(get_edited_property())
	if _multiple:
		return value as PackedStringArray
	return PackedStringArray([String(value)]) if value != &"" else PackedStringArray()


func _open_picker() -> void:
	if _read_only or not is_instance_valid(get_edited_object()):
		return
	GameplayTagRegistry.refresh()
	_choices = GameplayTagRegistry.get_choices(_allow_implied)
	if get_edited_object() is AbilityPhaseDefinition and get_edited_property() == &"event_key":
		for event: StringName in AbilityPhaseDefinition.LIFECYCLE_EVENTS:
			var event_name := String(event)
			if not _choices.has(event_name):
				_choices.append(event_name)
		_choices.sort()
	_draft = _read_tags().duplicate()
	_unregistered.clear()
	for tag: String in _draft:
		if not _choices.has(tag) and not _unregistered.has(tag):
			_unregistered.append(tag)
	var error := GameplayTagRegistry.get_load_error()
	_message.text = error
	_message.visible = not error.is_empty()
	_picker.get_ok_button().disabled = not error.is_empty()
	_search.clear()
	_rebuild_choices("")
	_picker.popup_centered(_picker.size)
	_search.grab_focus()


func _rebuild_choices(query: String) -> void:
	_tree.clear()
	var root := _tree.create_item()
	if not _multiple:
		_add_choice(root, "", "(None)")
	var filter := query.strip_edges()
	for tag: String in _unregistered:
		if filter.is_empty() or tag.findn(filter) >= 0:
			_add_choice(root, tag, "%s (Unregistered)" % tag)
	for tag: String in _choices:
		if filter.is_empty() or tag.findn(filter) >= 0:
			_add_choice(root, tag, tag)


func _add_choice(root: TreeItem, tag: String, label: String) -> void:
	var item := _tree.create_item(root)
	item.set_metadata(0, tag)
	if _multiple:
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_checked(0, _draft.has(tag))
		item.set_editable(0, true)
	item.set_text(0, label)
	if tag == label:
		item.set_tooltip_text(0, GameplayTagRegistry.get_description(StringName(tag)))
	if not _multiple and (_draft.has(tag) or (tag.is_empty() and _draft.is_empty())):
		item.select(0)


func _on_checkbox_changed() -> void:
	var item := _tree.get_edited()
	var tag := item.get_metadata(0) as String
	if item.is_checked(0):
		if not _draft.has(tag):
			_draft.append(tag)
	else:
		while _draft.has(tag):
			_draft.remove_at(_draft.find(tag))


func _on_item_selected() -> void:
	if _multiple:
		return
	var tag := _tree.get_selected().get_metadata(0) as String
	_draft = PackedStringArray([tag]) if not tag.is_empty() else PackedStringArray()


func _apply_tags() -> void:
	if _read_only or not is_instance_valid(get_edited_object()) or _draft == _read_tags():
		return
	if _multiple:
		emit_changed(get_edited_property(), _draft.duplicate())
	else:
		var value := StringName(_draft[0]) if not _draft.is_empty() else &""
		emit_changed(get_edited_property(), value)
