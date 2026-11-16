@tool
extends EditorPlugin

const POST_PROCESSING := preload("res://scenes/effects/post_processing.tscn")
const PREVIEW_ITEM := 0
const EDIT_MATERIAL_ITEM := 1
const VIEWPORT_COUNT := 4

var _menu: MenuButton
var _preview_enabled := false
var _source_pass: ColorRect
var _preview_layers: Array[CanvasLayer] = []
var _preview_passes: Array[ColorRect] = []
var _refresh_queued := false


func _enter_tree() -> void:
	_menu = MenuButton.new()
	_menu.text = "Post Processing"
	var popup := _menu.get_popup()
	popup.add_check_item("Preview in 3D", PREVIEW_ITEM)
	popup.add_item("Edit Material", EDIT_MATERIAL_ITEM)
	popup.id_pressed.connect(_on_menu_item_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
	scene_changed.connect(_queue_refresh.unbind(1))
	get_tree().tree_changed.connect(_queue_refresh)
	_refresh_source.call_deferred()
	set_process(false)


func _exit_tree() -> void:
	scene_changed.disconnect(_queue_refresh.unbind(1))
	get_tree().tree_changed.disconnect(_queue_refresh)
	_clear_previews()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
	_menu.queue_free()
	_menu = null


func _process(_delta: float) -> void:
	if not is_instance_valid(_source_pass):
		return
	var material := _source_pass.material
	var show_preview := material != null and _source_pass.is_visible_in_tree()
	for preview_pass in _preview_passes:
		if preview_pass.material != material:
			preview_pass.material = material
	for layer in _preview_layers:
		layer.visible = show_preview


func _on_menu_item_pressed(id: int) -> void:
	match id:
		PREVIEW_ITEM:
			_preview_enabled = not _preview_enabled
			var popup := _menu.get_popup()
			popup.set_item_checked(popup.get_item_index(PREVIEW_ITEM), _preview_enabled)
			_update_previews()
		EDIT_MATERIAL_ITEM:
			if is_instance_valid(_source_pass) and _source_pass.material != null:
				EditorInterface.inspect_object(_source_pass.material)


func _queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		_refresh_source.call_deferred()


func _refresh_source() -> void:
	_refresh_queued = false
	if not is_instance_valid(_menu):
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var source_pass := _find_source_pass(scene_root)
	_menu.visible = source_pass != null
	if is_instance_valid(_source_pass) and _source_pass == source_pass:
		return
	_source_pass = source_pass
	_update_previews()


func _find_source_pass(scene_root: Node) -> ColorRect:
	if scene_root == null:
		return null
	if scene_root.scene_file_path == POST_PROCESSING.resource_path:
		return scene_root.get_node_or_null(^"Pass") as ColorRect
	for candidate in scene_root.find_children("*", "Control", true, false):
		if candidate.scene_file_path == POST_PROCESSING.resource_path:
			return candidate.get_node_or_null(^"Pass") as ColorRect
	return null


func _update_previews() -> void:
	_clear_previews()
	if not _preview_enabled or not is_instance_valid(_source_pass):
		return
	for index in VIEWPORT_COUNT:
		var viewport := EditorInterface.get_editor_viewport_3d(index)
		var layer := CanvasLayer.new()
		layer.name = &"PostProcessingPreview"
		layer.visible = false
		var preview := POST_PROCESSING.instantiate()
		var preview_pass := preview.get_node(^"Pass") as ColorRect
		preview_pass.material = _source_pass.material
		layer.add_child(preview)
		viewport.add_child(layer)
		_preview_layers.append(layer)
		_preview_passes.append(preview_pass)
	set_process(true)
	_process(0.0)


func _clear_previews() -> void:
	set_process(false)
	for layer in _preview_layers:
		if is_instance_valid(layer):
			layer.free()
	_preview_layers.clear()
	_preview_passes.clear()
