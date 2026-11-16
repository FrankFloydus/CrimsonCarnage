@tool
extends RefCounted
## Receives Viewer packs and appends their clips to one editor AnimationLibrary.

const DIALOG := preload("viewer_clip_import_dialog.tscn")
const ClipImport := preload("viewer_clip_import.gd")
const NEW_LIBRARY := 0
const EXISTING_LIBRARY := 1
const SOURCE_ID := &"native_animation_id"

var _button: Button
var _picker: EditorFileDialog
var _dialog: ConfirmationDialog
var _summary: Label
var _clips: Tree
var _mode: OptionButton
var _new_name: LineEdit
var _existing: OptionButton
var _feedback: Label
var _undo: EditorUndoRedoManager
var _get_context: Callable
var _target: AnimationPlayer
var _pack: Dictionary = {}


## Bind the controls and resolve the writable preview player at the point of import.
func setup(panel: Control, undo: EditorUndoRedoManager, get_context: Callable) -> void:
	_undo = undo
	_get_context = get_context
	_button = panel.get_node("%ImportClips")
	_button.pressed.connect(_open_picker)

	_picker = EditorFileDialog.new()
	_picker.name = "ViewerClipPackPicker"
	_picker.title = "Choose Viewer Clip Pack"
	_picker.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_picker.access = EditorFileDialog.ACCESS_FILESYSTEM
	_picker.add_filter("*.json", "Viewer clip packs")
	_picker.file_selected.connect(_read_pack)
	_picker.canceled.connect(_clear_target)
	panel.add_child(_picker)

	_dialog = DIALOG.instantiate()
	_summary = _dialog.get_node("%ImportSummary")
	_clips = _dialog.get_node("%ImportClipsList")
	_mode = _dialog.get_node("%LibraryMode")
	_new_name = _dialog.get_node("%NewLibraryName")
	_existing = _dialog.get_node("%ExistingLibrary")
	_feedback = _dialog.get_node("%ImportFeedback")
	_clips.set_column_title(0, "Weapon Set")
	_clips.set_column_title(1, "Clip")
	_clips.set_column_expand_ratio(0, 1)
	_clips.set_column_expand_ratio(1, 2)
	_mode.item_selected.connect(_validate_destination.unbind(1))
	_new_name.text_changed.connect(_validate_destination.unbind(1))
	_existing.item_selected.connect(_validate_destination.unbind(1))
	_dialog.register_text_enter(_new_name)
	_dialog.confirmed.connect(_import_clips)
	_dialog.canceled.connect(_clear_target)
	panel.add_child(_dialog)


func refresh_availability() -> void:
	_button.disabled = _get_context.call().is_empty()


func is_modal_active() -> bool:
	return _picker.visible or _dialog.visible


func _open_picker() -> void:
	var context: Dictionary = _get_context.call()
	if context.is_empty():
		return
	_target = context.player
	_picker.popup_file_dialog()


func _read_pack(path: String) -> void:
	if not is_instance_valid(_target) or _target != _get_context.call().get("player"):
		_notify("Open the preview player scene before importing clips.")
		_clear_target()
		return
	_pack = ClipImport.read_pack(path)
	var error: String = _pack.get("error", "")
	if not error.is_empty():
		_notify(error)
		_clear_target()
		return

	_clips.clear()
	var root := _clips.create_item()
	var sets: Dictionary[String, bool] = {}
	for clip: Dictionary in _pack.clips:
		var weapon_set: String = clip.get("weapon_set", "Unclassified")
		sets[weapon_set] = true
		var row := _clips.create_item(root)
		row.set_text(0, weapon_set)
		row.set_text(1, _clip_label(clip.name))
		row.set_tooltip_text(1, "%s\n%s" % [clip.name, clip.id])

	_summary.text = "%d clips · %d weapon sets · %s" % [_pack.clips.size(), sets.size(), _pack.rig.name]
	_existing.clear()
	for library in _target.get_animation_library_list():
		_existing.add_item("Global" if library.is_empty() else String(library))
		_existing.set_item_metadata(_existing.item_count - 1, library)
	if _existing.item_count > 0:
		_existing.select(0)
	_mode.set_item_disabled(_mode.get_item_index(EXISTING_LIBRARY), _existing.item_count == 0)
	_mode.select(_mode.get_item_index(NEW_LIBRARY))
	var suggested := "vermintide"
	if sets.size() == 1 and not sets.has("Unclassified"):
		var weapon_set: String = sets.keys()[0]
		suggested = _clean_name(weapon_set.to_snake_case())
	_new_name.text = _unique_library_name(suggested)
	_validate_destination()
	_dialog.popup_centered_clamped(Vector2i(600, 415), 0.85)
	_new_name.grab_focus()
	_new_name.select_all()


func _validate_destination() -> void:
	var create := _mode.get_selected_id() == NEW_LIBRARY
	_new_name.visible = create
	_existing.visible = not create
	var error := _destination_error()
	_dialog.get_ok_button().disabled = not error.is_empty()
	_show_feedback(error)


func _destination_key() -> StringName:
	if _mode.get_selected_id() == NEW_LIBRARY:
		return StringName(_new_name.text.strip_edges())
	if _existing.get_selected() >= 0:
		return _existing.get_selected_metadata()
	return &""


func _destination_error() -> String:
	if not is_instance_valid(_target) or _target != _get_context.call().get("player"):
		return "Select the original preview player before importing."
	var key := _destination_key()
	if _mode.get_selected_id() == NEW_LIBRARY:
		if key.is_empty():
			return "Enter a library name."
		if String(key) != _clean_name(String(key)):
			return "Library names cannot contain slash, colon, comma, or opening bracket."
		if _target.has_animation_library(key):
			return "That library already exists. Choose it under Existing library."
	elif _existing.get_selected() < 0 or not _target.has_animation_library(key):
		return "Choose an existing animation library."
	return ""


func _import_clips() -> void:
	var error := _destination_error()
	if not error.is_empty():
		_show_feedback(error)
		return
	var context: Dictionary = _get_context.call()
	var key := _destination_key()
	var previous := _target.get_animation_library(key) if _target.has_animation_library(key) else null
	var updated := previous.duplicate(false) as AnimationLibrary if previous != null else AnimationLibrary.new()
	var seen: Dictionary[String, bool] = {}
	for name in updated.get_animation_list():
		var saved := updated.get_animation(name)
		var id := String(saved.get_meta(SOURCE_ID, ""))
		if not id.is_empty():
			seen[id] = true

	var added := 0
	var skipped := 0
	var sockets_only := 0
	for clip: Dictionary in _pack.clips:
		if seen.has(clip.id):
			skipped += 1
			continue
		var result := ClipImport.build_animation(_pack, clip, context.sockets, context.camera, context.native)
		var animation := result.get("animation") as Animation
		if animation == null:
			var reason: String = result.get("error", "Could not prepare the clip.")
			_show_feedback("%s — %s" % [_clip_label(clip.name), reason])
			return
		var clip_name := _unique_clip_name(updated, _clean_name(_clip_label(clip.name)))
		if updated.add_animation(clip_name, animation) != OK:
			_show_feedback("Could not add %s to the animation library." % clip_name)
			return
		seen[clip.id] = true
		added += 1
		if not bool(result.get("pose_bound", false)):
			sockets_only += 1
	if added == 0:
		_show_feedback("All selected clips are already in this library.")
		return

	_undo.create_action("Import Viewer Animation Clips", UndoRedo.MERGE_DISABLE, _target)
	if previous == null:
		_undo.add_do_method(_target, &"add_animation_library", key, updated)
		_undo.add_undo_method(_target, &"remove_animation_library", key)
	else:
		var property := StringName("libraries/" + String(key))
		_undo.add_do_property(_target, property, updated)
		_undo.add_undo_property(_target, property, previous)
	_undo.commit_action()

	var destination := "Global" if key.is_empty() else String(key)
	var message := "Imported %d clips into %s." % [added, destination]
	if skipped > 0:
		message += " Skipped %d existing clips." % skipped
	if sockets_only > 0:
		message += " %d clips use socket preview." % sockets_only
	_notify(message)
	_dialog.hide()
	_clear_target()


func _unique_library_name(stem: String) -> String:
	var candidate := stem
	var suffix := 2
	while _target.has_animation_library(StringName(candidate)):
		candidate = "%s_%d" % [stem, suffix]
		suffix += 1
	return candidate


func _unique_clip_name(library: AnimationLibrary, stem: String) -> StringName:
	var candidate := stem
	var suffix := 2
	while library.has_animation(StringName(candidate)):
		candidate = "%s_%d" % [stem, suffix]
		suffix += 1
	return StringName(candidate)


func _clip_label(source_name: String) -> String:
	var label := source_name.replace("\\", "/").get_file().trim_suffix(".animation").strip_edges()
	return "Animation" if label.is_empty() else label


func _clean_name(name: String) -> String:
	return name.replace("/", "_").replace(":", "_").replace(",", "_").replace("[", "_")


func _show_feedback(message: String) -> void:
	_feedback.text = message
	_feedback.visible = not message.is_empty()


func _clear_target() -> void:
	_pack.clear()
	_target = null


func _notify(message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(message)
