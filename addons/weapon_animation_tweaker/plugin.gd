@tool
extends EditorPlugin

const PANEL := preload("tweaker_panel.tscn")
const FLOATING_WINDOW := preload("tweaker_window.tscn")
const TweakerPanel := preload("tweaker_panel.gd")
const REFERENCE_STAGE := preload("preview_reference.tscn")
const VARIANT_DIALOG := preload("save_variant_dialog.tscn")
const AnimationVariants := preload("animation_variants.gd")
const SwordGizmo := preload("sword_gizmo.gd")
const SocketKeys := preload("socket_keys.gd")
const PoseView := preload("pose_view.gd")
const NativePose := preload("native_pose.gd")
const OnionPreview := preload("onion_preview.gd")
const ViewerImportDialog := preload("viewer_clip_import_dialog.gd")
const VIEWER_POSE_META := &"viewer_pose_track"
const BONE_KEYFRAME := 2
const POSE_MODE := 1
const SOCKET_KEYFRAME := 1
const LAYOUT_SECTION := "weapon_animation_tweaker"
const AnimationTweaks := preload("animation_tweaks.gd")
const PreviewOverlays := preload("preview_overlays.gd")
const Timeline := preload("timeline.gd")
const ClipTracks := preload("clip_tracks.gd")
const TrackTimeline := preload("track_timeline.gd")
const ComboData := preload("weapon_animation_combo.gd")
const ComboPanel := preload("combo_panel.gd")
const COMBO_PANEL := preload("combo_panel.tscn")
const ComboPreview := preload("combo_preview.gd")
const DEFAULT_COMBO := "res://data/melee/kerillian_1h_sword_light_combo.tres"
const MOTION_FIELDS: Array[StringName] = [
	&"VerticalOffset", &"Width", &"Height", &"Depth", &"CameraOffset", &"Duration",
]
const SWORD_POSITION_FIELDS: Array[StringName] = [&"SwordPositionX", &"SwordPositionY", &"SwordPositionZ"]
const SWORD_ROTATION_FIELDS: Array[StringName] = [&"SwordRotationX", &"SwordRotationY", &"SwordRotationZ"]
const PREVIEW_CLIP := &"preview"
const CAMERA_MOTION_PROPERTY := &"attack_camera_motion"
const PREVIEW_CAMERA_TRACK := ^"PreviewCamera:transform"
const ONION_PAST_ID := 0
const ONION_FUTURE_ID := 1
const ONION_STEPS_ID := 10
const ONION_SPACING_ID := 20
const ONION_HIDE_UNCHANGED_ID := 30
const ONION_INTERVALS := [0.0, 1.0 / 60.0, 1.0 / 30.0, 1.0 / 15.0]
const ONION_PAST := Color("#ee7582")
const ONION_FUTURE := Color("#77d99a")
const COMPARISON_COLOR := Color("#caa6ed")
const COMPARISON_PAST := Color("#e9a783")
const COMPARISON_FUTURE := Color("#72d4e4")
const LOOP_ENDPOINT_STEP := 0.000001

## Playback behavior for the private preview player.
enum PlaybackMode {
	## Repeat the whole clip.
	LOOP_CLIP,
	## Repeat between the authored preview endpoints.
	LOOP_REGION,
	## Hold the last pose when the clip reaches its end.
	ONCE,
}

var _dock: EditorDock
var _panel: TweakerPanel
var _combo_ui: ComboPanel
var _combo := ComboData.new()
var _combo_preview := ComboPreview.new()
var _combo_path := ""
var _combo_open := false
var _combo_playing := false
var _combo_sequence := true
var _combo_join := -1
var _combo_clips: Dictionary[StringName, Animation] = {}
var _floating_window: Window
var _window_button: Button
var _moving_panel := false
var _clip_picker: OptionButton
var _sword_picker: OptionButton
var _edit_target: OptionButton
var _model_picker_label: Label
var _set_socket_key_button: Button
var _show_sockets: CheckBox
var _show_trails: CheckBox
var _inputs: Dictionary[StringName, SpinBox] = {}
var _sliders: Dictionary[StringName, HSlider] = {}
var _reset: Button
var _undo_button: Button
var _redo_button: Button
var _draft_history := UndoRedo.new()
var _draft_anchor: Dictionary = {}
var _draft_gesture: Dictionary = {}
var _restoring_draft := false
var _apply: Button
var _save_as: Button
var _split: HSplitContainer
var _sidebar_split: VSplitContainer
var _timeline_split: VSplitContainer
var _scene_picker: Button
var _play_scene: Button
var _scene_dialog: EditorFileDialog
var _play_scene_path := ""
var _mode_switch: OptionButton
var _preview_hint: Label
var _viewer_import := ViewerImportDialog.new()
var _pose_view: PoseView
var _pose_mode := false
var _editing_bone := false
var _native_pose := NativePose.new()
var _native_name := ""
var _native_paths: Array[NodePath] = []
var _native_source: Animation
var _orbit_camera: Camera3D
var _variant_dialog: ConfirmationDialog
var _variant_name: LineEdit
var _variant_feedback: Label
var _variant_source: Animation
var _gizmo: SwordGizmo
var _gizmo_mode: OptionButton
var _status: Label
var _viewport: SubViewport
var _crosshair: Control
var _play: Button
var _playback_mode_picker: OptionButton
var _playback_region: Control
var _loop_start_field: SpinBox
var _loop_end_field: SpinBox
var _playback_mode: int = PlaybackMode.LOOP_CLIP
var _loop_start_phase := 0.0
var _loop_end_phase := 1.0
var _syncing_loop_fields := false
var _time: Timeline
var _track_timeline: TrackTimeline
var _onion_preview: OnionPreview
var _onion_toggle: CheckBox
var _onion_options: MenuButton
var _comparison_toggle: Button
var _comparison_lane: Control
var _comparison_picker: OptionButton
var _comparison_time: Timeline
var _onion_past := true
var _onion_future := false
var _onion_steps := 1
var _onion_spacing := 0
var _onion_hide_unchanged := false
var _onion_refresh_queued := false
var _comparison_key: StringName
var _comparison_source: Animation
var _comparison_camera: Camera3D
var _comparison_clip: Animation
var _comparison_native_name := ""

var _player: AnimationPlayer
var _clip_name: StringName
var _source: Animation
var _source_tracks := ClipTracks.new()
var _draft_tracks := _source_tracks
var _tracks_changed := false
var _targets: Array[NodePath] = []
var _source_camera: Camera3D
var _candidate: Animation
var _motion_base: Animation
var _editing_socket := false
var _socket_path: NodePath
var _socket_keys: Dictionary[NodePath, Dictionary] = {}
var _socket_offset_position := Vector3.ZERO
var _socket_offset_rotation := Vector3.ZERO
var _socket_base_pose := Transform3D.IDENTITY
var _socket_pose_editable := false
var _socket_preview_queued := false
var _sword_models: Array[NodePath] = []
var _duration_at_reset: float
var _motion_changed := false
var _sword_path: NodePath
var _sword_positions: Dictionary[NodePath, Vector3] = {}
var _sword_rotations: Dictionary[NodePath, Vector3] = {}
var _drag_sword: NodePath
var _drag_position: Vector3
var _drag_rotation: Vector3
var _drag_base_rotation := Quaternion.IDENTITY
var _context_refresh_queued := false
var _preview_refresh_queued := false

var _preview_camera: Camera3D
var _preview_reference: Node3D
var _preview_player: AnimationPlayer
var _preview_library: AnimationLibrary
var _preview_clip: Animation
var _preview_has_camera_motion := false
var _preview_paths: Array[NodePath] = []
var _preview_time: float
var _overlays := PreviewOverlays.new()


func _enter_tree() -> void:
	_panel = PANEL.instantiate() as TweakerPanel
	_setup_combo_panel()
	_window_button = _panel.get_node("%OpenWindow")
	_window_button.pressed.connect(_toggle_window, CONNECT_DEFERRED)
	_panel.key_input.connect(_on_preview_key_input)
	_panel.minimum_size_changed.connect(_sync_floating_minimum_size, CONNECT_DEFERRED)
	_clip_picker = _panel.get_node("%Clip")
	_sword_picker = _panel.get_node("%Sword")
	_edit_target = _panel.get_node("%EditTarget")
	_model_picker_label = _panel.get_node("%ModelPickerLabel")
	_set_socket_key_button = _panel.get_node("%SetSocketKey")
	_show_sockets = _panel.get_node("%ShowSockets")
	_show_trails = _panel.get_node("%ShowTrails")
	_reset = _panel.get_node("%Reset")
	_undo_button = _panel.get_node("%UndoDraft")
	_redo_button = _panel.get_node("%RedoDraft")
	_apply = _panel.get_node("%Apply")
	_save_as = _panel.get_node("%SaveAs")
	_split = _panel.get_node("%Columns")
	_sidebar_split = _panel.get_node("%SidebarSplit")
	_timeline_split = _panel.get_node("%TimelineSplit")
	_scene_picker = _panel.get_node("%ScenePicker")
	_play_scene = _panel.get_node("%PlayScene")
	_mode_switch = _panel.get_node("%ModeSwitch")
	_preview_hint = _panel.get_node("%PreviewHint")
	_pose_view = PoseView.new()
	_pose_view.name = "PoseView"
	var frame := _panel.get_node("%PreviewViewport").get_parent() as SubViewportContainer
	_setup_onion_skin(frame)
	frame.add_child(_pose_view)
	_pose_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pose_view.set_active(false)
	_scene_dialog = EditorFileDialog.new()
	_scene_dialog.title = "Choose Scene to Play"
	_scene_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_scene_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_scene_dialog.add_filter("*.tscn, *.scn", "Godot scenes")
	_scene_dialog.file_selected.connect(_set_play_scene)
	_panel.add_child(_scene_dialog)
	var default_play_scene: String = ProjectSettings.get_setting(
		"crimson/weapon_animation/play_scene", ProjectSettings.get_setting("application/run/main_scene", "")
	)
	if ResourceLoader.exists(default_play_scene, "PackedScene"):
		_set_play_scene(default_play_scene)
	_gizmo = _panel.get_node("%SwordGizmo")
	# The gizmo handles its drags first. Unhandled input bubbles to PoseView.
	_gizmo.owner = null
	_gizmo.reparent(_pose_view, false)
	_gizmo.owner = _panel
	_gizmo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gizmo_mode = _panel.get_node("%GizmoMode")
	_variant_dialog = VARIANT_DIALOG.instantiate()
	_variant_name = _variant_dialog.get_node("%VariantName")
	_variant_feedback = _variant_dialog.get_node("%VariantFeedback")
	_panel.add_child(_variant_dialog)
	_status = _panel.get_node("%Status")
	_viewport = _panel.get_node("%PreviewViewport")
	_crosshair = _panel.get_node("%PreviewCrosshair")
	_play = _panel.get_node("%Play")
	_playback_mode_picker = _panel.get_node("%PlaybackMode")
	_playback_region = _panel.get_node("%PlaybackRegion")
	_loop_start_field = _panel.get_node("%LoopStart")
	_loop_end_field = _panel.get_node("%LoopEnd")
	_time = _panel.get_node("%Time")
	_track_timeline = _panel.get_node("%TrackTimeline")
	_track_timeline.bind_ruler(_time)
	_track_timeline.edit_requested.connect(_on_track_edit)
	_track_timeline.seek_requested.connect(_seek_track_time)
	_track_timeline.status_requested.connect(_show_status)
	_panel.get_node("%TimelineFit").pressed.connect(_track_timeline.fit_value_axes)
	_viewer_import.setup(_panel, get_undo_redo(), _viewer_import_context)

	_clip_picker.item_selected.connect(_on_clip_selected)
	_sword_picker.item_selected.connect(_on_edit_item_selected)
	_edit_target.add_item("Bone Keyframe", BONE_KEYFRAME)
	_edit_target.set_item_disabled(_edit_target.get_item_index(BONE_KEYFRAME), true)
	_edit_target.item_selected.connect(_on_edit_target_selected)
	_mode_switch.item_selected.connect(_on_mode_selected)
	_pose_view.bone_selected.connect(_on_pose_bone_selected)
	_set_socket_key_button.pressed.connect(_record_socket_key)
	_show_sockets.toggled.connect(_update_overlays.unbind(1))
	_show_trails.toggled.connect(_update_overlays.unbind(1))
	for key in MOTION_FIELDS + SWORD_POSITION_FIELDS + SWORD_ROTATION_FIELDS:
		var input: SpinBox = _panel.get_node("%" + String(key))
		var slider: HSlider = _panel.get_node("%" + String(key) + "Slider")
		_inputs[key] = input
		_sliders[key] = slider
		input.value_changed.connect(_on_numeric_changed.bind(key))
		slider.value_changed.connect(_on_slider_changed.bind(key))
		slider.drag_started.connect(_begin_draft_gesture)
		slider.drag_ended.connect(_end_slider_gesture)
	_reset.pressed.connect(_on_reset_pressed)
	_undo_button.pressed.connect(_step_draft_history.bind(false))
	_redo_button.pressed.connect(_step_draft_history.bind(true))
	_apply.pressed.connect(_apply_tweak)
	_save_as.pressed.connect(_open_save_as)
	_variant_dialog.register_text_enter(_variant_name)
	_variant_dialog.confirmed.connect(_save_variant)
	_variant_name.text_changed.connect(_validate_variant_name.unbind(1))
	for splitter: SplitContainer in [_split, _sidebar_split, _timeline_split]:
		splitter.dragged.connect(queue_save_layout.unbind(1))
	_scene_picker.pressed.connect(_open_scene_picker)
	_play_scene.pressed.connect(_run_selected_scene)
	_gizmo_mode.item_selected.connect(_on_gizmo_mode_selected)
	_gizmo.drag_started.connect(_on_gizmo_drag_started)
	_gizmo.drag_ended.connect(_on_gizmo_drag_ended)
	_gizmo.move_dragged.connect(_on_gizmo_move)
	_gizmo.rotate_dragged.connect(_on_gizmo_rotate)
	_on_gizmo_mode_selected(_gizmo_mode.selected)
	_play.toggled.connect(_on_play_toggled)
	_playback_mode_picker.add_item("Loop Clip", PlaybackMode.LOOP_CLIP)
	_playback_mode_picker.add_item("Loop Region", PlaybackMode.LOOP_REGION)
	_playback_mode_picker.add_item("Play Once", PlaybackMode.ONCE)
	_playback_mode_picker.select(0)
	_playback_mode_picker.item_selected.connect(_on_playback_mode_selected)
	_loop_start_field.value_changed.connect(_set_loop_endpoint.bind(true))
	_loop_end_field.value_changed.connect(_set_loop_endpoint.bind(false))
	_panel.get_node("%SetLoopStart").pressed.connect(_capture_loop_endpoint.bind(true))
	_panel.get_node("%SetLoopEnd").pressed.connect(_capture_loop_endpoint.bind(false))
	_update_playback_region()
	_time.value_changed.connect(_seek_preview)
	_panel.visibility_changed.connect(_on_preview_visibility_changed)

	_dock = EditorDock.new()
	_dock.name = "WeaponAnimationTweakerDock"
	_dock.title = "Weapon Animation Tweaker"
	_dock.layout_key = "weapon_animation_tweaker_main"
	_dock.default_slot = EditorDock.DOCK_SLOT_MAIN_SCREEN
	_dock.available_layouts = EditorDock.DOCK_LAYOUT_MAIN_SCREEN
	_dock.add_child(_panel)
	add_dock(_dock)

	EditorInterface.get_selection().selection_changed.connect(_queue_context_refresh)
	scene_changed.connect(_queue_context_refresh.unbind(1))
	get_undo_redo().version_changed.connect(_queue_context_refresh)
	get_undo_redo().history_changed.connect(_queue_context_refresh)
	set_process(false)
	_queue_context_refresh()


func _exit_tree() -> void:
	EditorInterface.get_selection().selection_changed.disconnect(_queue_context_refresh)
	scene_changed.disconnect(_queue_context_refresh.unbind(1))
	get_undo_redo().version_changed.disconnect(_queue_context_refresh)
	get_undo_redo().history_changed.disconnect(_queue_context_refresh)
	_bind_player(null)
	_set_comparison_source(&"", null)
	_load_source(&"")
	_clear_preview()
	remove_dock(_dock)
	_dock.queue_free()
	if is_instance_valid(_floating_window):
		_floating_window.hide()
		_floating_window.queue_free()
		_floating_window = null
	_dock = null
	_panel = null


func _get_window_layout(configuration: ConfigFile) -> void:
	if is_instance_valid(_split):
		configuration.set_value(LAYOUT_SECTION, "sidebar_splits", _split.split_offsets)
		configuration.set_value(LAYOUT_SECTION, "details_split", _sidebar_split.split_offsets)
		configuration.set_value(LAYOUT_SECTION, "timeline_split", _timeline_split.split_offsets)
	configuration.set_value(LAYOUT_SECTION, "play_scene", _play_scene_path)


func _set_window_layout(configuration: ConfigFile) -> void:
	if is_instance_valid(_split):
		var offsets: Variant = configuration.get_value(LAYOUT_SECTION, "sidebar_splits", _split.split_offsets)
		if offsets is PackedInt32Array and offsets.size() == 1:
			_split.split_offsets = offsets
		_restore_vertical_split(configuration, "details_split", _sidebar_split)
		_restore_vertical_split(configuration, "timeline_split", _timeline_split)
	if is_instance_valid(_scene_picker):
		_set_play_scene(String(configuration.get_value(LAYOUT_SECTION, "play_scene", _play_scene_path)))


func _restore_vertical_split(configuration: ConfigFile, key: String, splitter: VSplitContainer) -> void:
	var offsets: Variant = configuration.get_value(LAYOUT_SECTION, key, splitter.split_offsets)
	if offsets is PackedInt32Array and offsets.size() == 1:
		splitter.split_offsets = offsets


func _open_scene_picker() -> void:
	if not _play_scene_path.is_empty():
		_scene_dialog.current_path = _play_scene_path
	_scene_dialog.popup_file_dialog()


func _set_play_scene(path: String) -> void:
	if not path.begins_with("res://") or not ResourceLoader.exists(path, "PackedScene"):
		return
	_play_scene_path = path
	_scene_picker.text = path.get_file().get_basename().replace("_", " ").capitalize()
	_scene_picker.tooltip_text = path
	_play_scene.disabled = false
	if is_inside_tree():
		queue_save_layout()


func _run_selected_scene() -> void:
	if not ResourceLoader.exists(_play_scene_path, "PackedScene"):
		_play_scene.disabled = true
		return
	_set_preview_playing(false)
	EditorInterface.play_custom_scene(_play_scene_path)


func _toggle_window() -> void:
	if not is_instance_valid(_panel):
		return
	if is_instance_valid(_floating_window) and _panel.get_parent() == _floating_window:
		_dock_panel()
		return
	var create_window := not is_instance_valid(_floating_window)
	if create_window:
		var editor := EditorInterface.get_base_control()
		_floating_window = FLOATING_WINDOW.instantiate() as Window
		_floating_window.theme = EditorInterface.get_editor_theme()
		var background := _floating_window.get_node("Background") as ColorRect
		background.color = _floating_window.theme.get_color(&"background", &"Editor")
		_floating_window.min_size = Vector2i(_panel.get_combined_minimum_size().ceil())
		_floating_window.close_requested.connect(_dock_panel, CONNECT_DEFERRED)
		editor.add_child(_floating_window)
		var usable := DisplayServer.screen_get_usable_rect(editor.get_window().current_screen)
		_floating_window.size = Vector2i(Vector2(usable.size) * 0.86).max(Vector2i(800, 540))
		_floating_window.position = usable.get_center() - _floating_window.size / 2

	_moving_panel = true
	_floating_window.show()
	_panel.reparent(_floating_window, false)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The empty tab is closed for this session only.
	_dock.transient = true
	_dock.close()
	_window_button.text = "Dock Back"
	_window_button.tooltip_text = "Return the tweaker to its editor tab."
	_moving_panel = false
	_on_preview_visibility_changed()
	_floating_window.grab_focus()


func _sync_floating_minimum_size() -> void:
	if not is_instance_valid(_floating_window) or not is_instance_valid(_panel) or _panel.get_parent() != _floating_window:
		return
	var minimum := Vector2i(_panel.get_combined_minimum_size().ceil())
	if _floating_window.min_size != minimum:
		_floating_window.min_size = minimum


func _dock_panel() -> void:
	if not is_instance_valid(_panel) or _panel.get_parent() != _floating_window:
		return
	_moving_panel = true
	_dock.transient = false
	_dock.make_visible()
	_panel.reparent(_dock, false)
	_floating_window.hide()
	_window_button.text = "Open in Window"
	_window_button.tooltip_text = "Open the tweaker in a separate, resizable window."
	_moving_panel = false
	_on_preview_visibility_changed()


func _on_preview_key_input(event: InputEventKey) -> void:
	if not event.pressed or event.alt_pressed:
		return
	if _scene_dialog.visible or _variant_dialog.visible or _viewer_import.is_modal_active():
		return
	var active_viewport := _panel.get_viewport()
	var focused := active_viewport.gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	if _combo_open:
		if event.keycode == KEY_SPACE and not event.echo and not event.shift_pressed \
				and not event.is_command_or_control_pressed() and not _combo_ui.is_modal_active() \
				and (focused == null or focused == _panel or _panel.is_ancestor_of(focused)) \
				and not (focused is BaseButton or focused is ItemList or focused is SpinBox):
			_combo_ui.toggle_playback()
			active_viewport.set_input_as_handled()
		return
	if event.is_command_or_control_pressed():
		var redo: bool = event.keycode == KEY_Y or (event.keycode == KEY_Z and event.shift_pressed)
		if not event.echo and event.keycode in [KEY_Y, KEY_Z] and _step_draft_history(redo):
			active_viewport.set_input_as_handled()
	elif event.keycode == KEY_TAB and not event.echo and not event.shift_pressed and not _mode_switch.disabled:
		_on_mode_selected(0 if _pose_mode else POSE_MODE)
		active_viewport.set_input_as_handled()
	elif not event.shift_pressed and _handle_timeline_shortcut(event, focused):
		active_viewport.set_input_as_handled()


func _handle_timeline_shortcut(event: InputEventKey, focused: Control) -> bool:
	if event.keycode not in [KEY_SPACE, KEY_LEFT, KEY_RIGHT, KEY_M, KEY_DELETE] or not _can_preview():
		return false
	if focused != null and focused != _panel and not _panel.is_ancestor_of(focused):
		return false
	if event.keycode == KEY_DELETE:
		return _track_timeline.handle_delete_key(focused, event.echo)
	if (focused is Range and focused != _time) or (focused is BaseButton and focused != _play):
		return false
	if event.keycode == KEY_SPACE:
		if not event.echo:
			_on_play_toggled(not _play.button_pressed)
	elif event.keycode == KEY_M:
		if not event.echo:
			_track_timeline.add_marker_at_playhead()
	else:
		var direction := -1 if event.keycode == KEY_LEFT else 1
		_on_play_toggled(false)
		_time.step_keyframe(-direction if _time.is_layout_rtl() else direction)
	return true


func _on_mode_selected(index: int) -> void:
	var was_pose := _pose_mode
	_pose_mode = index == POSE_MODE and not _native_paths.is_empty()
	_mode_switch.select(POSE_MODE if _pose_mode else 0)
	_set_preview_playing(false)
	_apply_view_mode()
	_update_sword_models()
	_fill_transform_controls()
	if _pose_mode and not was_pose and is_instance_valid(_orbit_camera):
		_pose_view.frame_target()
		_pose_view.grab_focus()


func _apply_view_mode() -> void:
	var orbiting := _pose_mode and is_instance_valid(_orbit_camera)
	_pose_view.set_active(orbiting)
	_crosshair.visible = is_instance_valid(_preview_camera) and not orbiting
	_preview_hint.visible = orbiting or _editing_bone
	_preview_hint.text = (
		"Right drag + WASD/QE to fly · Middle drag to orbit · Shift + middle drag to pan · F to frame · Tab to edit"
		if orbiting else "Adjust the selected bone, then Set Key to record its pose."
	)
	if is_instance_valid(_preview_camera):
		(_orbit_camera if orbiting else _preview_camera).make_current()
	_set_socket_key_button.disabled = not _socket_pose_editable or _play.button_pressed


func _on_pose_bone_selected(index: int) -> void:
	if index < 0 or index >= _native_paths.size():
		return
	var path := _native_paths[index]
	var target_mode := BONE_KEYFRAME
	for left in [false, true]:
		if index == _native_pose.socket_index(left):
			for candidate in _targets:
				var is_left := String(candidate.get_name(candidate.get_name_count() - 1)).to_lower().contains("left")
				if is_left == left:
					path = candidate
					target_mode = SOCKET_KEYFRAME
					break
	var choice := _edit_target.get_item_index(target_mode)
	_edit_target.select(choice)
	_on_edit_target_selected(choice)
	for item in _sword_picker.item_count:
		if _sword_picker.get_item_metadata(item) == path:
			_sword_picker.select(item)
			_on_edit_item_selected(item)
			break
	_pose_view.set_selected(index)


func _setup_combo_panel() -> void:
	_combo_ui = COMBO_PANEL.instantiate() as ComboPanel
	_combo_ui.hide()
	_panel.get_node("%TimelineSplit").add_child(_combo_ui)
	_panel.get_node("%ComboMode").toggled.connect(_toggle_combo_workspace)
	_combo_ui.combo_changed.connect(_set_combo_draft)
	_combo_ui.join_selected.connect(_select_combo_join)
	_combo_ui.sequence_view_requested.connect(_show_combo_sequence)
	_combo_ui.play_join_requested.connect(_play_combo_join)
	_combo_ui.play_combo_requested.connect(_play_full_combo)
	_combo_ui.stop_requested.connect(_set_combo_playing.bind(false))
	_combo_ui.seek_requested.connect(_seek_combo)
	_combo_ui.save_requested.connect(_save_combo)
	_combo_ui.load_requested.connect(_load_combo)


func _toggle_combo_workspace(open: bool) -> void:
	_set_preview_playing(false)
	_set_combo_playing(false)
	_combo_open = open
	_panel.get_node("%SidebarBody").get_parent().visible = not open
	for path in ["%ViewportToolbar", "%Footer", "%ModeSwitch", "%Clip"]:
		_panel.get_node(path).visible = not open
	_panel.get_node("%ClipLabel").visible = not open
	_combo_ui.visible = open
	if open:
		_refresh_combo_context()
		_queue_onion_refresh()
	else:
		_combo_preview.clear()
		_combo_join = -1
		_combo_sequence = true
	if _candidate != null and is_instance_valid(_source_camera):
		_update_preview_stage()


func _refresh_combo_context() -> void:
	_combo_clips.clear()
	var entries: Array[Dictionary] = []
	if is_instance_valid(_player):
		for index in _clip_picker.item_count:
			var key := StringName(_clip_picker.get_item_text(index))
			var animation := _player.get_animation(key)
			entries.append({"key": key, "duration": animation.length, "markers": ClipTracks.read_from(animation).markers})
	_combo_ui.set_context(entries)
	if _combo.clip_keys.is_empty() and _combo_path.is_empty() and is_instance_valid(_player) \
			and ResourceLoader.exists(DEFAULT_COMBO):
		var preset := ComboData.from_resource(ResourceLoader.load(DEFAULT_COMBO))
		if preset != null and preset.validate(_player).is_empty():
			_apply_loaded_combo(preset, DEFAULT_COMBO)
			_combo_ui.select_join(1)


func _set_combo_draft(data: Dictionary) -> void:
	var selected_join := _combo_ui.get_selected_join()
	var clips: Array = data.get("clips", [])
	var same_order := _combo.clip_keys == clips
	var keep_time := selected_join == _combo_join and same_order
	var keep_looping := _combo_playing and not _combo_sequence and keep_time
	if not same_order:
		_combo_sequence = true
	_combo.display_name = data.get("display_name", _combo.display_name)
	_combo.clip_keys.assign(clips)
	_combo.joins.assign(data.get("joins", []))
	_combo.loop = data.get("loop", true)
	_combo_join = selected_join
	_refresh_combo_preview(keep_time)
	if keep_looping and _combo_preview.length > 0.0:
		_set_combo_playing(true)


func _apply_loaded_combo(resource: ComboData, path: String) -> void:
	_combo = resource.copy()
	_combo_path = path
	_combo_ui.set_combo({
		"display_name": _combo.display_name,
		"clips": _combo.clip_keys.duplicate(),
		"joins": _combo.joins.duplicate(true),
		"loop": _combo.loop,
	}, path)


func _load_combo(path: String) -> void:
	var resource := ComboData.from_resource(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE))
	if resource == null:
		_combo_ui.set_feedback("Choose a Weapon Animation Combo resource.")
		return
	_apply_loaded_combo(resource, path)
	_combo_sequence = true
	_refresh_combo_preview()


func _save_combo(path: String) -> void:
	if _combo.clip_keys.size() < 2:
		_combo_ui.set_feedback("Add at least two clips before saving a combo.")
		return
	var snapshot := _combo.copy()
	if snapshot.display_name.strip_edges().is_empty():
		snapshot.display_name = path.get_file().get_basename()
	var result := ResourceSaver.save(snapshot, path)
	if result != OK:
		_combo_ui.set_feedback("Could not save the combo (%s)." % error_string(result))
		return
	_combo_path = path
	_combo.display_name = snapshot.display_name
	_combo_ui.set_saved_path(path, snapshot.display_name)
	_combo_ui.set_feedback("Saved %s." % path.get_file())
	EditorInterface.get_resource_filesystem().update_file(path)


func _select_combo_join(index: int) -> void:
	_set_combo_playing(false)
	var changed := index != _combo_join
	_combo_join = index
	if _combo_sequence:
		_seek_combo_to_join()
	elif changed:
		_refresh_combo_preview()


func _seek_combo_to_join() -> void:
	var layout := _combo_preview.get_timeline_layout()
	for blend: Dictionary in layout.get("blends", []):
		if blend.index == _combo_join:
			_seek_combo(lerpf(blend.start, blend.end, 0.5))
			return


func _refresh_combo_preview(keep_time := false) -> void:
	_set_combo_playing(false)
	var previous_time := _combo_preview.time if keep_time else 0.0
	_combo_join = _combo_ui.get_selected_join()
	_combo_preview.clear()
	if is_instance_valid(_preview_player):
		_preview_player.stop(true)
	if _combo_open and _can_preview() and _combo.clip_keys.size() >= 2:
		var ready := _prepare_combo_sequence() if _combo_sequence else _prepare_combo_join(_combo_join)
		if ready:
			_combo_preview.seek(previous_time)
			_update_sword_models()
	else:
		_combo_ui.set_feedback("")
	_sync_combo_transport()
	_combo_ui.set_timeline_layout(_combo_preview.get_timeline_layout(), _combo_sequence)


func _prepare_combo_join(index: int) -> bool:
	var join := _combo.resolve_join(_player, index)
	if join.has("error"):
		_combo_ui.set_feedback(join.error)
		return false
	var outgoing := _combo_preview_clip(join.outgoing_key)
	var incoming := _combo_preview_clip(join.incoming_key)
	var incoming_index := (index + 1) % _combo.clip_keys.size()
	if not _combo_preview.setup(outgoing, incoming, join, _combo_camera_motion(join.outgoing_key),
			_combo_camera_motion(join.incoming_key), index, incoming_index):
		_combo_ui.set_feedback("The join needs two playable clips on the preview camera rig.")
		return false
	var effective := _combo_preview.effective_blend
	_combo_ui.set_feedback(
		"Blend limited to %.3f s by the clip bounds." % effective if effective < float(join.blend_duration) - 0.000001
		else ""
	)
	return true


func _combo_preview_clip(key: StringName) -> Animation:
	if _combo_clips.has(key):
		return _combo_clips[key]
	var animation := _player.get_animation(key)
	var targets := _find_targets(animation)
	if targets.is_empty():
		return null
	var rig := _player.get_node_or_null(_player.root_node)
	if rig.get_node(targets[0]).get_parent() != _source_camera:
		return null
	if not bool(animation.get_meta(VIEWER_POSE_META, false)):
		var native_name := _native_pose.clip_name(animation, key)
		var native_paths := _get_native_paths()
		if not native_name.is_empty() and not native_paths.is_empty():
			animation = _native_pose.with_tracks(animation, native_name, native_paths)
	var clip := _remap_preview_clip(animation)
	_combo_clips[key] = clip
	return clip


func _combo_camera_motion(key: StringName) -> Callable:
	var native_name := _native_pose.clip_name(_player.get_animation(key), key)
	return _combo_camera_at_phase.bind(native_name) if not native_name.is_empty() else Callable()


func _combo_camera_at_phase(phase: float, native_name: String) -> Transform3D:
	return _native_pose.camera_motion(native_name, phase)


func _play_combo_join(index: int) -> void:
	if not _combo_open or not _can_preview():
		return
	if _combo_sequence or index != _combo_join or _combo_preview.length <= 0.0:
		_combo_sequence = false
		_refresh_combo_preview()
	_set_combo_playing(_combo_preview.length > 0.0)


func _play_full_combo() -> void:
	if not _combo_open or not _can_preview():
		return
	if not _combo_sequence or _combo_preview.length <= 0.0:
		_combo_sequence = true
		_refresh_combo_preview()
	elif _combo_preview.time >= _combo_preview.length:
		_combo_preview.seek(0.0)
	_set_combo_playing(_combo_preview.length > 0.0)


func _show_combo_sequence() -> void:
	_combo_sequence = true
	_refresh_combo_preview()
	_seek_combo_to_join()


func _prepare_combo_sequence() -> bool:
	var problem := _combo.validate(_player)
	if not problem.is_empty():
		_combo_ui.set_feedback(problem)
		return false
	var clips: Array[Animation] = []
	var camera_fallbacks: Array[Callable] = []
	for key in _combo.clip_keys:
		clips.append(_combo_preview_clip(key))
		camera_fallbacks.append(_combo_camera_motion(key))
	var joins: Array[Dictionary] = []
	for index in _combo.get_join_count():
		joins.append(_combo.resolve_join(_player, index))
	if not _combo_preview.setup_sequence(clips, joins, _combo.loop, camera_fallbacks):
		_combo_ui.set_feedback("This sequence needs compatible clips and playable time between its entry and exit points.")
		return false
	_combo_ui.set_feedback("")
	return true


func _set_combo_playing(playing: bool) -> void:
	_combo_playing = playing
	set_process(playing or (is_instance_valid(_play) and _play.button_pressed and not _combo_open))
	_sync_combo_transport()


func _seek_combo(seconds: float) -> void:
	_combo_preview.seek(seconds)
	_set_combo_playing(false)


func _sync_combo_transport() -> void:
	if is_instance_valid(_combo_ui) and _combo_ui.is_node_ready():
		_combo_ui.set_transport(_combo_preview.time, _combo_preview.length, _combo_preview.blend_start,
			_combo_preview.blend_end, _combo_playing)


func _process(delta: float) -> void:
	if _combo_open:
		if not _combo_playing or not _can_preview():
			_set_combo_playing(false)
			return
		_combo_preview.advance(delta)
		if _combo_sequence and not _combo.loop and _combo_preview.time >= _combo_preview.length:
			_set_combo_playing(false)
		else:
			_sync_combo_transport()
		return
	if not _can_preview() or not _play.button_pressed:
		set_process(false)
		return
	var duration := _candidate.length
	match _playback_mode:
		PlaybackMode.ONCE:
			var next_time := _preview_time + delta
			_seek_preview(minf(next_time, duration))
			if next_time >= duration:
				_on_play_toggled(false)
		PlaybackMode.LOOP_REGION:
			var start := _loop_start_phase * duration
			var end := _loop_end_phase * duration
			var current := _preview_time if _preview_time >= start and _preview_time < end else start
			_seek_preview(start + fposmod(current - start + delta, end - start))
		_:
			_seek_preview(fposmod(_preview_time + delta, duration))


func _queue_context_refresh() -> void:
	if not _context_refresh_queued:
		_context_refresh_queued = true
		_refresh_context.call_deferred()


func _refresh_context() -> void:
	_context_refresh_queued = false
	if not is_instance_valid(_panel):
		return
	var scene := EditorInterface.get_edited_scene_root()
	_bind_player(_find_player(scene))
	_clip_picker.clear()
	var selected := -1
	if is_instance_valid(_player):
		for key in _player.get_animation_list():
			var animation := _player.get_animation(key)
			if _find_targets(animation).is_empty():
				continue
			_clip_picker.add_item(key)
			if key == _clip_name:
				selected = _clip_picker.item_count - 1
	_clip_picker.disabled = _clip_picker.item_count == 0
	_panel.get_node("%ComboMode").disabled = _clip_picker.disabled and not _combo_open
	if _combo_open:
		_refresh_combo_context()
	if _clip_picker.disabled:
		_clip_picker.tooltip_text = ""
		_load_source(&"")
		_refresh_comparison_picker()
		_viewer_import.refresh_availability()
		_refresh_sword_picker()
		_queue_preview_refresh()
		_show_status(
			"Select an AnimationPlayer in its own scene." if not is_instance_valid(_player)
			else "The AnimationPlayer has no camera-local position tracks."
		)
		return
	if selected < 0:
		selected = 0
	_clip_picker.select(selected)
	_on_clip_selected(selected)
	if _combo_open:
		_queue_preview_refresh()
	_update_sword_models()


func _find_player(scene: Node) -> AnimationPlayer:
	if scene == null:
		return null
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is AnimationPlayer and (node == scene or node.owner == scene):
			return node
	if is_instance_valid(_player) and (_player == scene or _player.owner == scene):
		return _player
	if scene is AnimationPlayer:
		return scene
	var found: AnimationPlayer
	for node in scene.find_children("*", "AnimationPlayer", true, true):
		if node.owner != scene:
			continue
		if found != null:
			return null
		found = node
	return found


func _bind_player(player: AnimationPlayer) -> void:
	if is_instance_valid(_player):
		if _player == player:
			return
		_player.animation_list_changed.disconnect(_queue_context_refresh)
		_player.animation_libraries_updated.disconnect(_queue_context_refresh)
	_player = player
	if is_instance_valid(_player):
		_player.animation_list_changed.connect(_queue_context_refresh)
		_player.animation_libraries_updated.connect(_queue_context_refresh)


func _on_clip_selected(index: int) -> void:
	var key := _clip_picker.get_item_text(index)
	_clip_picker.tooltip_text = key
	_load_source(StringName(key))
	_refresh_comparison_picker()
	_viewer_import.refresh_availability()


func _load_source(key: StringName) -> void:
	var animation: Animation
	if not key.is_empty() and is_instance_valid(_player) and _player.has_animation(key):
		animation = _player.get_animation(key)
	var targets := _find_targets(animation)
	var camera: Camera3D
	if not targets.is_empty():
		var rig := _player.get_node_or_null(_player.root_node)
		var socket := rig.get_node_or_null(targets[0]) as Node3D
		camera = socket.get_parent() as Camera3D
	if key == _clip_name and animation == _source and camera == _source_camera and targets == _targets:
		return
	if _source != null:
		_source.changed.disconnect(_on_source_changed)
	if key != _clip_name or animation == null:
		_loop_start_phase = 0.0
		_loop_end_phase = 1.0
	_clip_name = key
	_source = animation
	_reset_source_tracks()
	_track_timeline.set_clip(null, 0.0)
	_targets = targets
	_socket_keys.clear()
	_clear_socket_offsets()
	if _source_camera != camera:
		_sword_positions.clear()
		_sword_rotations.clear()
		_sword_path = NodePath()
	_source_camera = camera
	_bind_native_source()
	_refresh_sword_picker()
	if _source != null:
		_source.changed.connect(_on_source_changed)
	_set_preview_playing(false)
	_preview_time = 0.0
	_reset_motion_controls()
	_clear_draft_history()


func _on_source_changed() -> void:
	_reset_source_tracks()
	_bind_native_source()
	_socket_keys.clear()
	_clear_socket_offsets()
	_reset_motion_controls()
	_clear_draft_history()
	_queue_context_refresh()


func _reset_source_tracks() -> void:
	_source_tracks = ClipTracks.read_from(_source)
	_set_draft_tracks(_source_tracks)


func _set_draft_tracks(tracks: ClipTracks) -> void:
	_draft_tracks = tracks
	_tracks_changed = tracks != _source_tracks and not tracks.same_content(_source_tracks)


func _bind_native_source() -> void:
	_native_paths.clear()
	_native_source = null
	_native_name = _native_pose.clip_name(_source, _clip_name)
	var imported_pose := _source != null and bool(_source.get_meta(VIEWER_POSE_META, false))
	if imported_pose or not _native_name.is_empty():
		_native_paths = _get_native_paths()
		if not _native_paths.is_empty():
			_native_source = _source if imported_pose else _native_pose.with_tracks(_source, _native_name, _native_paths)
	_mode_switch.disabled = _native_source == null
	var option := _edit_target.get_item_index(BONE_KEYFRAME)
	_edit_target.set_item_disabled(option, _native_source == null)
	if _native_source == null:
		_pose_mode = false
		_mode_switch.select(0)
		if _editing_bone:
			_editing_bone = false
			_editing_socket = false
			_edit_target.select(0)


func _get_native_paths(camera: Camera3D = null) -> Array[NodePath]:
	var paths: Array[NodePath] = []
	if camera == null:
		camera = _source_camera
	if not is_instance_valid(camera) or not is_instance_valid(_player):
		return paths
	var rig := _player.get_node_or_null(_player.root_node)
	if rig == null:
		return paths
	var native := camera.get_node_or_null("NativePoseRig") as Node3D
	for bone in _native_pose.nodes(native):
		paths.append(rig.get_path_to(bone))
	return paths


func _viewer_import_context() -> Dictionary:
	var scene := EditorInterface.get_edited_scene_root()
	if not is_instance_valid(_player) or (_player != scene and _player.owner != scene):
		return {}
	var rig := _player.get_node_or_null(_player.root_node)
	if rig == null:
		return {}
	var camera := _source_camera if is_instance_valid(_source_camera) else rig.get_node_or_null(^"Look/Camera3D") as Camera3D
	if camera == null or not rig.is_ancestor_of(camera):
		return {}
	var sockets: Dictionary = {}
	for side: String in ["right", "left"]:
		var name := "WeaponControl" if side == "right" else "LeftWeaponControl"
		var target := camera.get_node_or_null(name) as Node3D
		if target != null:
			sockets[side] = rig.get_path_to(target)
	if sockets.is_empty():
		return {}
	var camera_path := NodePath()
	var look := camera.get_parent()
	if look.get(CAMERA_MOTION_PROPERTY) is Transform3D:
		camera_path = NodePath("%s:%s" % [rig.get_path_to(look), CAMERA_MOTION_PROPERTY])
	var native: Dictionary = {}
	for path in _get_native_paths(camera):
		native[String(path.get_name(path.get_name_count() - 1))] = path
	return {"player": _player, "sockets": sockets, "camera": camera_path, "native": native}


func _find_targets(animation: Animation) -> Array[NodePath]:
	var paths: Array[NodePath] = []
	if animation == null or not is_instance_valid(_player):
		return paths
	var rig := _player.get_node_or_null(_player.root_node)
	if rig == null:
		return paths
	var camera: Camera3D
	for track in animation.get_track_count():
		if not animation.track_is_enabled(track) or animation.track_get_key_count(track) == 0:
			continue
		var path := animation.track_get_path(track)
		var type := animation.track_get_type(track)
		if type != Animation.TYPE_POSITION_3D and (
				type != Animation.TYPE_VALUE or path.get_concatenated_subnames() != &"position"):
			continue
		var node_path := NodePath(String(path.get_concatenated_names()))
		var socket := rig.get_node_or_null(node_path) as Node3D
		if socket == null or not socket.get_parent() is Camera3D:
			continue
		if camera != null and socket.get_parent() != camera:
			return []
		camera = socket.get_parent()
		if not paths.has(node_path):
			paths.append(node_path)
	return paths


func _on_slider_changed(value: float, key: StringName) -> void:
	_inputs[key].value = value
	_sliders[key].set_value_no_signal(_inputs[key].value)


func _on_numeric_changed(value: float, key: StringName) -> void:
	_sliders[key].set_value_no_signal(value)
	if key in MOTION_FIELDS:
		_queue_preview_refresh()
	elif _editing_socket:
		_set_socket_axis(key, value)
	elif not _sword_path.is_empty():
		var axis := SWORD_POSITION_FIELDS.find(key)
		if axis >= 0:
			_set_sword_axis(_sword_positions, axis, value)
		else:
			_set_sword_axis(_sword_rotations, SWORD_ROTATION_FIELDS.find(key), value)
		_update_sword_models()
		_update_apply_buttons()
	if _draft_gesture.is_empty():
		_record_draft_change("Adjust Preview", _draft_anchor)


func _set_field(key: StringName, value: float) -> void:
	_inputs[key].set_value_no_signal(value)
	_sliders[key].set_value_no_signal(_inputs[key].value)


func _reset_motion_controls() -> void:
	if not is_instance_valid(_panel):
		return
	_set_field(&"VerticalOffset", 0.0)
	_set_field(&"Width", 1.0)
	_set_field(&"Height", 1.0)
	_set_field(&"Depth", 1.0)
	_set_field(&"CameraOffset", 0.0)
	var duration := _source.length if _source != null else _inputs[&"Duration"].min_value
	_sliders[&"Duration"].max_value = maxf(6.0, ceilf(duration * 2.0))
	_set_field(&"Duration", duration)
	_duration_at_reset = _inputs[&"Duration"].value
	_queue_preview_refresh()


func _capture_draft() -> Dictionary:
	var motion := PackedFloat64Array()
	for key in MOTION_FIELDS:
		motion.append(_inputs[key].value)
	return {
		"motion": motion,
		"tracks": _draft_tracks,
		"pose_keys": _socket_keys.duplicate(true),
		"mount_positions": _sword_positions.duplicate(),
		"mount_rotations": _sword_rotations.duplicate(),
		"position": _socket_offset_position,
		"rotation": _socket_offset_rotation,
		"target": _edit_target.get_selected_id(),
		"item": _socket_path if _editing_socket else _sword_path,
		"phase": _preview_time / _candidate.length if _candidate != null else 0.0,
	}


func _sync_draft_anchor() -> void:
	if not _restoring_draft and _draft_gesture.is_empty():
		_draft_anchor = _capture_draft()


func _record_draft_change(label: String, before: Dictionary) -> void:
	if _source == null or _restoring_draft:
		return
	var after := _capture_draft()
	_draft_anchor = after
	if before.is_empty() or before == after:
		return
	_draft_history.create_action(label)
	_draft_history.add_do_method(_restore_draft.bind(after))
	_draft_history.add_undo_method(_restore_draft.bind(before))
	_draft_history.commit_action(false)
	_update_draft_buttons()


func _restore_draft(state: Dictionary) -> void:
	_restoring_draft = true
	_set_preview_playing(false)
	for index in MOTION_FIELDS.size():
		_set_field(MOTION_FIELDS[index], state.motion[index])
	_set_draft_tracks(state.tracks)
	_socket_keys.assign(state.pose_keys.duplicate(true))
	_sword_positions.assign(state.mount_positions)
	_sword_rotations.assign(state.mount_rotations)
	var target := _edit_target.get_item_index(state.target)
	if target >= 0:
		_edit_target.select(target)
		_on_edit_target_selected(target)
	for item in _sword_picker.item_count:
		if _sword_picker.get_item_metadata(item) == state.item:
			_sword_picker.select(item)
			_on_edit_item_selected(item)
			break
	_clear_socket_offsets()
	_refresh_preview()
	if _candidate != null:
		_seek_preview(state.phase * _candidate.length)
	_socket_offset_position = state.position
	_socket_offset_rotation = state.rotation
	_fill_transform_controls()
	_update_socket_pose()
	_update_apply_buttons()
	_restoring_draft = false
	_sync_draft_anchor()


func _begin_draft_gesture() -> void:
	if _source != null and _draft_gesture.is_empty():
		_draft_gesture = _capture_draft()


func _end_slider_gesture(_changed: bool) -> void:
	_end_draft_gesture("Adjust Preview")


func _end_draft_gesture(label: String) -> void:
	var before := _draft_gesture
	_draft_gesture = {}
	if not before.is_empty():
		_record_draft_change(label, before)


func _step_draft_history(redo: bool) -> bool:
	var handled := _draft_history.redo() if redo else _draft_history.undo()
	_update_draft_buttons()
	return handled


func _update_draft_buttons() -> void:
	_undo_button.disabled = not _draft_history.has_undo()
	_redo_button.disabled = not _draft_history.has_redo()


func _clear_draft_history() -> void:
	_draft_history.clear_history()
	_draft_gesture = {}
	_sync_draft_anchor()
	_update_draft_buttons()


func _on_reset_pressed() -> void:
	var before := _capture_draft()
	_reset_draft()
	_record_draft_change("Reset Preview", before)


func _reset_draft() -> void:
	_set_draft_tracks(_source_tracks)
	_sword_positions.clear()
	_sword_rotations.clear()
	_socket_keys.clear()
	_clear_socket_offsets()
	_fill_transform_controls()
	_update_sword_models()
	_reset_motion_controls()


func _refresh_sword_picker() -> void:
	_sword_picker.clear()
	_sword_models.clear()
	_model_picker_label.text = "Bone" if _editing_bone else ("Socket" if _editing_socket else "Sword")
	_set_socket_key_button.visible = _editing_socket
	var model_name_counts: Dictionary[StringName, int] = {}
	if is_instance_valid(_source_camera):
		for socket in _source_camera.get_children():
			if not socket is Node3D:
				continue
			for sword in socket.get_children():
				if not sword is Node3D or sword is VisualInstance3D:
					continue
				if sword.find_children("*", "MeshInstance3D", true, false).is_empty():
					continue
				var path := _source_camera.get_path_to(sword)
				_sword_models.append(path)
				model_name_counts[sword.name] = model_name_counts.get(sword.name, 0) + 1
	if _editing_socket:
		for path in (_native_paths if _editing_bone else _targets):
			_add_edit_item(String(path.get_name(path.get_name_count() - 1)), path)
	else:
		for path in _sword_models:
			var model_name := path.get_name(path.get_name_count() - 1)
			var label := String(model_name).capitalize()
			if model_name_counts[model_name] > 1:
				label = "%s / %s" % [String(path.get_name(0)).capitalize(), label]
			_add_edit_item(label, path)

	_sword_picker.disabled = _sword_picker.item_count == 0
	if _sword_picker.disabled:
		_socket_path = NodePath()
		_socket_pose_editable = false
		_fill_transform_controls()
		return
	var selected := _socket_path if _editing_socket else _sword_path
	var index := 0
	for item in _sword_picker.item_count:
		if _sword_picker.get_item_metadata(item) == selected:
			index = item
			break
	_sword_picker.select(index)
	_on_edit_item_selected(index)


func _add_edit_item(label: String, path: NodePath) -> void:
	_sword_picker.add_item(label)
	_sword_picker.set_item_metadata(_sword_picker.item_count - 1, path)


func _on_edit_target_selected(index: int) -> void:
	_set_preview_playing(false)
	_clear_socket_offsets()
	var target := _edit_target.get_item_id(index)
	_editing_bone = target == BONE_KEYFRAME and not _native_paths.is_empty()
	_editing_socket = target == SOCKET_KEYFRAME or _editing_bone
	_refresh_sword_picker()
	_apply_view_mode()
	_seek_preview(_preview_time)
	_refresh_socket_trail()
	_update_apply_buttons()


func _on_edit_item_selected(index: int) -> void:
	var path: NodePath = _sword_picker.get_item_metadata(index)
	_sword_picker.tooltip_text = _sword_picker.get_item_text(index) if _editing_socket else String(path)
	if _editing_socket:
		_socket_path = path
		_clear_socket_offsets()
		_seek_preview(_preview_time)
		_refresh_socket_trail()
		_update_timeline_keys()
		_sync_pose_selection()
	else:
		_sword_path = path
		_update_sword_models()
	_fill_transform_controls()
	_sync_draft_anchor()


func _fill_transform_controls() -> void:
	var position: Vector3 = _sword_positions.get(_sword_path, Vector3.ZERO)
	var rotation: Vector3 = _sword_rotations.get(_sword_path, Vector3.ZERO)
	var editable := not _sword_path.is_empty() and is_instance_valid(_source_camera)
	if _editing_socket:
		position = _socket_offset_position
		rotation = _socket_offset_rotation
		editable = _socket_pose_editable
	for axis in 3:
		_set_field(SWORD_POSITION_FIELDS[axis], position[axis])
		_set_field(SWORD_ROTATION_FIELDS[axis], rotation[axis])
		_set_editable(SWORD_POSITION_FIELDS[axis], editable)
		_set_editable(SWORD_ROTATION_FIELDS[axis], editable)
	_set_socket_key_button.disabled = not _socket_pose_editable or _play.button_pressed


func _set_socket_axis(key: StringName, value: float) -> void:
	if not _socket_pose_editable:
		return
	_set_preview_playing(false)
	var axis := SWORD_POSITION_FIELDS.find(key)
	if axis >= 0:
		_socket_offset_position[axis] = value
	else:
		_socket_offset_rotation[SWORD_ROTATION_FIELDS.find(key)] = value
	_update_socket_pose()


func _clear_socket_offsets() -> void:
	_socket_offset_position = Vector3.ZERO
	_socket_offset_rotation = Vector3.ZERO


func _socket_offsets_pending() -> bool:
	return not _socket_offset_position.is_zero_approx() or not _socket_offset_rotation.is_zero_approx()


func _preview_socket_path() -> NodePath:
	if _socket_path.is_empty() or not is_instance_valid(_player) or not is_instance_valid(_source_camera):
		return NodePath()
	var rig := _player.get_node_or_null(_player.root_node)
	var socket := rig.get_node_or_null(_socket_path) if rig != null else null
	if socket == null or not _source_camera.is_ancestor_of(socket):
		return NodePath()
	return NodePath("PreviewCamera/" + String(_source_camera.get_path_to(socket)))


func _preview_socket() -> Node3D:
	var path := _preview_socket_path()
	if path.is_empty() or not is_instance_valid(_preview_player):
		return null
	return _viewport.get_node_or_null(path) as Node3D


func _update_socket_pose() -> void:
	var socket := _preview_socket()
	if socket == null or not _editing_socket or not _socket_pose_editable:
		return
	var pose := _socket_base_pose
	pose.origin += _socket_offset_position
	pose.basis = Basis.from_euler(_socket_offset_rotation * (PI / 180.0)) * pose.basis
	socket.transform = pose
	_update_apply_buttons()
	if not _socket_preview_queued:
		_socket_preview_queued = true
		_refresh_socket_trail.call_deferred()


func _refresh_socket_trail() -> void:
	_socket_preview_queued = false
	if not is_instance_valid(_preview_player) or _preview_clip == null:
		return
	var display := _preview_clip
	var socket := _preview_socket()
	if _editing_socket and not _editing_bone and _socket_offsets_pending() and socket != null:
		var draft := _preview_clip.duplicate() as Animation
		if SocketKeys.set_pose(draft, _preview_socket_path(), _preview_time, socket.transform):
			display = draft
	_overlays.configure(_preview_player, _preview_paths, display)


func _record_socket_key() -> void:
	if not _owns_source() or not _editing_socket or not _socket_pose_editable or _play.button_pressed:
		return
	var socket := _preview_socket()
	if socket == null or _motion_base == null:
		return
	var base: Variant = SocketKeys.sample_pose(_motion_base, _socket_path, _preview_time)
	if base == null:
		return
	var pose := socket.transform
	# Validate against the displayed draft before changing the list of recorded keys.
	var check := _candidate.duplicate() as Animation
	if not SocketKeys.set_pose(check, _socket_path, _preview_time, pose):
		_show_status("This pose could not be keyed at the current time.")
		return
	var before := _capture_draft()
	var base_pose: Transform3D = base
	var delta := Transform3D(
		Basis(pose.basis.get_rotation_quaternion() * base_pose.basis.get_rotation_quaternion().inverse()),
		pose.origin - base_pose.origin
	)
	var keys: Dictionary = _socket_keys.get(_socket_path, {})
	var phase := _preview_time / _motion_base.length
	for recorded in keys:
		if is_equal_approx(phase, float(recorded)):
			phase = float(recorded)
			break
	keys[phase] = delta
	_socket_keys[_socket_path] = keys
	_clear_socket_offsets()
	_fill_transform_controls()
	_refresh_preview()
	_record_draft_change("Set Pose Key", before)


func _apply_socket_keys(base: Animation) -> Animation:
	if base == null or _socket_keys.is_empty():
		return base
	var result := base.duplicate(true) as Animation
	for path in _socket_keys:
		var keys: Dictionary = _socket_keys[path]
		for phase in keys:
			var seconds := clampf(float(phase) * base.length, 0.0, base.length)
			var sampled: Variant = SocketKeys.sample_pose(base, path, seconds)
			if sampled == null:
				return null
			var pose: Transform3D = sampled
			var delta: Transform3D = keys[phase]
			pose.origin += delta.origin
			pose.basis = delta.basis * pose.basis
			if not SocketKeys.set_pose(result, path, seconds, pose):
				return null
	return result


func _set_sword_axis(drafts: Dictionary[NodePath, Vector3], axis: int, value: float) -> void:
	var offset: Vector3 = drafts.get(_sword_path, Vector3.ZERO)
	offset[axis] = value
	if offset.is_zero_approx():
		drafts.erase(_sword_path)
	else:
		drafts[_sword_path] = offset


func _sword_transform(sword: Node3D, path: NodePath) -> Transform3D:
	var position: Vector3 = _sword_positions.get(path, Vector3.ZERO)
	var rotation: Vector3 = _sword_rotations.get(path, Vector3.ZERO)
	var baseline := sword.transform
	baseline.origin += position
	if not rotation.is_zero_approx():
		baseline.basis = Basis.from_euler(rotation * (PI / 180.0)) * baseline.basis
	return baseline


func _update_sword_models() -> void:
	if not is_instance_valid(_preview_camera) or not is_instance_valid(_source_camera):
		return
	var selected := _source_camera.get_node_or_null(_sword_path) as Node3D
	var selected_copy: Node3D
	for path in _sword_models:
		var sword := _source_camera.get_node_or_null(path) as Node3D
		var copy := _preview_camera.get_node_or_null(path) as Node3D
		if copy == null or sword == null:
			continue
		copy.transform = _sword_transform(sword, path)
		var selected_mount := selected != null and sword.get_parent() == selected.get_parent()
		copy.visible = sword == selected if selected_mount else sword.visible
		if sword == selected:
			selected_copy = copy
	if _combo_open:
		_gizmo.configure(null, null, null)
		return
	if _editing_socket:
		_configure_socket_gizmo()
	else:
		_gizmo_mode.disabled = selected_copy == null
		var socket := selected_copy.get_parent_node_3d() if selected_copy != null else null
		_gizmo.configure(_viewport.get_camera_3d(), socket, selected_copy)
	_queue_onion_refresh()


func _configure_socket_gizmo() -> void:
	var socket := _preview_socket() if _socket_pose_editable else null
	_gizmo_mode.disabled = socket == null
	_gizmo.configure(_viewport.get_camera_3d(), socket.get_parent_node_3d() if socket != null else null, socket)


func _on_gizmo_mode_selected(index: int) -> void:
	_gizmo.set_mode(_gizmo_mode.get_item_id(index))


func _on_gizmo_drag_started() -> void:
	_set_preview_playing(false)
	_begin_draft_gesture()
	_drag_sword = _socket_path if _editing_socket else _sword_path
	if _editing_socket:
		_drag_position = _socket_offset_position
		_drag_rotation = _socket_offset_rotation
	else:
		_drag_position = _sword_positions.get(_sword_path, Vector3.ZERO)
		_drag_rotation = _sword_rotations.get(_sword_path, Vector3.ZERO)
	var node := _preview_socket() if _editing_socket else _preview_camera.get_node_or_null(_sword_path) as Node3D
	_drag_base_rotation = Quaternion.IDENTITY
	if node != null:
		var offset := Quaternion.from_euler(_drag_rotation * (PI / 180.0))
		_drag_base_rotation = (offset.inverse() * node.basis.get_rotation_quaternion()).normalized()


func _on_gizmo_drag_ended() -> void:
	_drag_sword = NodePath()
	_end_draft_gesture("Drag Transform")


func _on_gizmo_move(axis: int, amount: float) -> void:
	if not _drag_sword.is_empty() and _drag_sword == (_socket_path if _editing_socket else _sword_path):
		_inputs[SWORD_POSITION_FIELDS[axis]].value = _drag_position[axis] + amount


func _on_gizmo_rotate(axis: int, degrees: float) -> void:
	if _drag_sword.is_empty() or _drag_sword != (_socket_path if _editing_socket else _sword_path):
		return
	var direction := Vector3.ZERO
	direction[axis] = 1.0
	var start := Quaternion.from_euler(_drag_rotation * (PI / 180.0))
	var local_turn := Quaternion(direction, deg_to_rad(degrees))
	var rotated := (start * _drag_base_rotation * local_turn * _drag_base_rotation.inverse()).normalized()
	var angles := rotated.get_euler() * (180.0 / PI)
	for index in 3:
		var key := SWORD_ROTATION_FIELDS[index]
		_set_field(key, angles[index])
		if _editing_socket:
			_socket_offset_rotation[index] = _inputs[key].value
		else:
			_set_sword_axis(_sword_rotations, index, _inputs[key].value)
	if _editing_socket:
		_update_socket_pose()
	else:
		_update_sword_models()
		_update_apply_buttons()


func _set_editable(key: StringName, enabled: bool) -> void:
	_inputs[key].editable = enabled
	_sliders[key].editable = enabled


func _queue_preview_refresh() -> void:
	if not _preview_refresh_queued:
		_preview_refresh_queued = true
		_refresh_preview.call_deferred()


func _refresh_preview() -> void:
	_preview_refresh_queued = false
	if not is_instance_valid(_panel):
		return
	var editable := _source != null and not _targets.is_empty() and is_instance_valid(_source_camera)
	for key in MOTION_FIELDS:
		_set_editable(key, editable)
	_show_sockets.disabled = not editable
	_show_trails.disabled = not editable
	_edit_target.disabled = not editable
	if not editable:
		_candidate = null
		_update_playback_region()
		_motion_base = null
		_motion_changed = false
		_update_apply_buttons()
		_time.set_key_times(PackedFloat64Array())
		_refresh_track_timeline()
		_clear_preview()
		return

	var offset_y := _inputs[&"VerticalOffset"].value
	var width := _inputs[&"Width"].value
	var height := _inputs[&"Height"].value
	var depth := _inputs[&"Depth"].value
	var offset_z := _inputs[&"CameraOffset"].value
	var duration := _inputs[&"Duration"].value
	var duration_changed := not is_equal_approx(duration, _duration_at_reset)
	var global_changed := (
		duration_changed or not is_zero_approx(offset_y) or not is_equal_approx(width, 1.0)
		or not is_equal_approx(height, 1.0) or not is_equal_approx(depth, 1.0) or not is_zero_approx(offset_z)
	)
	var phase := _preview_time / _candidate.length if _candidate != null else 0.0
	_motion_changed = global_changed or not _socket_keys.is_empty()
	var editable_source := _native_source if _native_source != null else _source
	_motion_base = editable_source
	if global_changed:
		_motion_base = AnimationTweaks.apply(editable_source, _targets, offset_y, width, height, depth,
				offset_z, duration if duration_changed else _source.length)
	_candidate = _apply_socket_keys(_motion_base)
	_update_playback_region()
	_update_apply_buttons()
	if _candidate == null:
		_time.set_key_times(PackedFloat64Array())
		_refresh_track_timeline()
		_clear_preview()
		return

	_time.max_value = _candidate.length
	_update_timeline_keys()
	_preview_time = phase * _candidate.length
	_refresh_track_timeline()
	_update_preview_stage()


func _update_timeline_keys() -> void:
	if _candidate == null:
		return
	if _editing_bone and not _socket_path.is_empty():
		_time.set_key_times(_native_pose.key_times(_candidate, _socket_path))
	else:
		_time.set_key_times(PreviewOverlays.key_times(_candidate, _hand_paths(_targets)))


func _on_track_edit(operation: StringName, args: Dictionary) -> void:
	if _candidate == null or not _owns_source():
		return
	var edit := args
	# Keep draft notify times in source seconds so repeated duration edits do not
	# compound the time conversion. Curve keys already use a normalized phase.
	if operation in [&"add_notify", &"set_notify", &"add_marker", &"set_marker"] and _candidate.length != _source.length:
		edit = args.duplicate()
		if args.has("time"):
			edit.time = float(args.time) / _candidate.length * _source.length
		if float(args.get("end_time", -1.0)) >= 0.0:
			edit.end_time = float(args.end_time) / _candidate.length * _source.length
	var tracks := _draft_tracks.copy()
	var index := tracks.apply_edit(operation, edit, _source.length)
	if index < 0:
		return
	var before := _capture_draft()
	_set_draft_tracks(tracks)
	_refresh_track_timeline()
	match operation:
		&"add_marker", &"set_marker":
			_track_timeline.select_marker(index)
		&"remove_marker":
			_track_timeline.select_marker(-1)
		&"add_notify_track":
			_track_timeline.select_track(false, index)
		&"add_curve_track", &"add_curve_preset":
			_track_timeline.select_track(true, index)
		&"add_notify", &"set_notify":
			_track_timeline.select_track(false, int(args.track), index)
		&"add_curve_key", &"set_curve_key":
			_track_timeline.select_track(true, int(args.track), index)
	_update_apply_buttons()
	_record_draft_change("Edit Animation Tracks", before)


func _effective_tracks() -> ClipTracks:
	if _candidate == null:
		return null
	if _candidate.length == _source.length:
		return _draft_tracks
	var tracks := _draft_tracks.copy()
	return tracks if tracks.retime(_candidate.length / _source.length) else null


func _refresh_track_timeline() -> void:
	_track_timeline.set_clip(_effective_tracks(), _candidate.length if _candidate != null else 0.0)
	_track_timeline.set_playhead(_preview_time if _candidate != null else 0.0)


func _animation_to_save() -> Animation:
	var tracks := _effective_tracks()
	if tracks == null or not tracks.is_valid(_candidate.length):
		return null
	if not _tracks_changed and tracks.is_empty():
		return _candidate
	# Keep the authored data independent of preview, history and the source clip.
	var result := _candidate.duplicate() as Animation
	tracks.write_to(result)
	return result


func _update_apply_buttons() -> void:
	var changed := _motion_changed or _tracks_changed \
			or not _sword_positions.is_empty() or not _sword_rotations.is_empty()
	var pending := _editing_socket and _socket_offsets_pending()
	_reset.disabled = not changed and not pending
	_apply.disabled = not changed or _candidate == null or pending
	_save_as.disabled = _candidate == null or pending
	if pending:
		_show_status("Use Set Key to keep this pose.")
	elif _candidate != null:
		_show_status("Unsaved changes" if changed else "")
	elif _source != null:
		_show_status("Try a longer duration to preserve all keys.")


func _show_status(message: String) -> void:
	_status.text = message
	_status.visible = not message.is_empty()


func _hand_paths(paths: Array[NodePath]) -> Array[NodePath]:
	var hands: Array[NodePath] = [NodePath(), NodePath()]
	for path in paths:
		var last := String(path.get_name(path.get_name_count() - 1)).to_lower()
		if last.contains("left"):
			hands[1] = path
		elif hands[0].is_empty():
			hands[0] = path
		elif hands[1].is_empty():
			hands[1] = path
	return hands


func _update_overlays() -> void:
	_overlays.set_visible(_show_sockets.button_pressed, _show_trails.button_pressed)


func _setup_onion_skin(frame: Control) -> void:
	_onion_preview = OnionPreview.new()
	_onion_preview.name = "OnionPreview"
	frame.add_child(_onion_preview)
	_onion_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_onion_toggle = _panel.get_node("%OnionSkin")
	_onion_options = _panel.get_node("%OnionOptions")
	_comparison_toggle = _panel.get_node("%ShowComparison")
	_comparison_lane = _panel.get_node("%ComparisonLane")
	_comparison_picker = _panel.get_node("%ComparisonClip")
	_comparison_time = _panel.get_node("%ComparisonTime")
	_onion_toggle.toggled.connect(_queue_onion_refresh.unbind(1))
	_comparison_toggle.toggled.connect(_on_comparison_toggled)
	_comparison_picker.item_selected.connect(_on_comparison_clip_selected)
	_comparison_time.value_changed.connect(_queue_onion_refresh.unbind(1))

	var menu := _onion_options.get_popup()
	menu.hide_on_checkable_item_selection = false
	menu.add_separator("Directions")
	menu.add_check_item("Past", ONION_PAST_ID)
	menu.add_check_item("Future", ONION_FUTURE_ID)
	menu.add_separator("Depth")
	for step in range(1, 4):
		var label := "1 step" if step == 1 else "%d steps" % step
		menu.add_radio_check_item(label, ONION_STEPS_ID + step - 1)
	menu.add_separator("Spacing")
	var spacing_labels := ["Clip step", "1/60 s", "1/30 s", "1/15 s"]
	for spacing in spacing_labels.size():
		menu.add_radio_check_item(spacing_labels[spacing], ONION_SPACING_ID + spacing)
	menu.add_separator()
	menu.add_check_item("Hide Unchanged Elements", ONION_HIDE_UNCHANGED_ID)
	menu.id_pressed.connect(_on_onion_option_selected)
	_sync_onion_options()


func _on_onion_option_selected(id: int) -> void:
	if id == ONION_PAST_ID:
		_onion_past = not _onion_past
		if not _onion_past:
			_onion_future = true
	elif id == ONION_FUTURE_ID:
		_onion_future = not _onion_future
		if not _onion_future:
			_onion_past = true
	elif id == ONION_HIDE_UNCHANGED_ID:
		_onion_hide_unchanged = not _onion_hide_unchanged
	elif id >= ONION_SPACING_ID:
		_onion_spacing = id - ONION_SPACING_ID
	else:
		_onion_steps = id - ONION_STEPS_ID + 1
	_sync_onion_options()
	_queue_onion_refresh()


func _sync_onion_options() -> void:
	var menu := _onion_options.get_popup()
	menu.set_item_checked(menu.get_item_index(ONION_PAST_ID), _onion_past)
	menu.set_item_checked(menu.get_item_index(ONION_FUTURE_ID), _onion_future)
	menu.set_item_checked(menu.get_item_index(ONION_HIDE_UNCHANGED_ID), _onion_hide_unchanged)
	for step in range(1, 4):
		menu.set_item_checked(menu.get_item_index(ONION_STEPS_ID + step - 1), step == _onion_steps)
	for spacing in ONION_INTERVALS.size():
		menu.set_item_checked(menu.get_item_index(ONION_SPACING_ID + spacing), spacing == _onion_spacing)


func _on_comparison_toggled(enabled: bool) -> void:
	_comparison_lane.visible = enabled
	_queue_onion_refresh()


func _refresh_comparison_picker() -> void:
	_comparison_picker.clear()
	_comparison_picker.add_item("Select clip…")
	_comparison_picker.set_item_metadata(0, &"")
	var selected := 0
	if is_instance_valid(_source_camera) and is_instance_valid(_player):
		var rig := _player.get_node(_player.root_node)
		for key in _player.get_animation_list():
			if key == "RESET":
				continue
			var animation := _player.get_animation(key)
			var paths := _find_targets(animation)
			if paths.is_empty() or rig.get_node(paths[0]).get_parent() != _source_camera:
				continue
			_comparison_picker.add_item(key)
			var index := _comparison_picker.item_count - 1
			_comparison_picker.set_item_metadata(index, StringName(key))
			if key == _comparison_key:
				selected = index
	_comparison_picker.disabled = _comparison_picker.item_count <= 1
	_comparison_picker.select(selected)
	_on_comparison_clip_selected(selected)


func _on_comparison_clip_selected(index: int) -> void:
	var key: StringName = _comparison_picker.get_item_metadata(index)
	var animation: Animation
	if not key.is_empty() and is_instance_valid(_player) and _player.has_animation(key):
		animation = _player.get_animation(key)
	_comparison_picker.tooltip_text = String(key) if animation != null else "Select the clip shown in the preview."
	_set_comparison_source(key, animation)


func _set_comparison_source(key: StringName, animation: Animation) -> void:
	if key == _comparison_key and animation == _comparison_source and _comparison_camera == _source_camera:
		return
	if _comparison_source != null:
		_comparison_source.changed.disconnect(_rebuild_comparison)
	var new_clip := key != _comparison_key or _comparison_camera != _source_camera
	_comparison_key = key
	_comparison_source = animation
	_comparison_camera = _source_camera
	if _comparison_source != null:
		_comparison_source.changed.connect(_rebuild_comparison)
	if new_clip:
		_comparison_time.set_value_no_signal(0.0)
		_comparison_time.fit()
	_rebuild_comparison()


func _rebuild_comparison() -> void:
	_comparison_clip = null
	_comparison_native_name = ""
	var times := PackedFloat64Array()
	if _comparison_source != null and is_instance_valid(_source_camera) and is_instance_valid(_player):
		var source := _comparison_source
		_comparison_native_name = _native_pose.clip_name(source, _comparison_key)
		if not _comparison_native_name.is_empty():
			var paths := _get_native_paths()
			if paths.is_empty():
				_comparison_native_name = ""
			else:
				source = _native_pose.with_tracks(source, _comparison_native_name, paths)
		_comparison_clip = _remap_preview_clip(source)
		times = PreviewOverlays.key_times(source, _hand_paths(_find_targets(source)))
		_comparison_time.max_value = _comparison_clip.length
	_comparison_time.editable = _comparison_clip != null
	_comparison_time.set_key_times(times)
	_queue_onion_refresh()


func _configure_onion_preview(rig: Node) -> void:
	var bones: Array[NodePath] = []
	var parents := PackedInt32Array()
	if not _native_paths.is_empty():
		for path in _native_paths:
			bones.append(_source_camera.get_path_to(rig.get_node(path)))
		for left in [false, true]:
			var index := _native_pose.socket_index(left)
			var socket := _source_camera.get_node_or_null("LeftWeaponControl" if left else "WeaponControl")
			if socket != null and index >= 0 and index < bones.size():
				bones[index] = _source_camera.get_path_to(socket)
		parents = _native_pose.parents()
	_onion_preview.configure(_viewport, _source_camera, _preview_camera, _sword_models, bones, parents)


func _queue_onion_refresh() -> void:
	if _onion_refresh_queued or not is_instance_valid(_panel):
		return
	_onion_refresh_queued = true
	_refresh_onion.call_deferred()


func _refresh_onion() -> void:
	_onion_refresh_queued = false
	if not is_instance_valid(_panel):
		return
	var available := not _combo_open and _can_preview() and _preview_clip != null
	_onion_toggle.disabled = not available
	_onion_options.disabled = not available
	var layers: Array[Dictionary] = []
	var temporal := available and _onion_toggle.button_pressed
	if temporal and not _play.button_pressed:
		_append_onion_neighbors(layers, _preview_clip, _preview_time, _native_name, ONION_PAST, ONION_FUTURE)
	if available and _comparison_toggle.button_pressed and _comparison_clip != null:
		var time := _comparison_time.value
		if temporal:
			_append_onion_neighbors(layers, _comparison_clip, time, _comparison_native_name, COMPARISON_PAST, COMPARISON_FUTURE)
		_append_onion_layer(layers, _comparison_clip, time, _comparison_native_name, Color(COMPARISON_COLOR, 0.72))
	_onion_preview.set_layers(layers, _pose_mode, _onion_hide_unchanged)


func _append_onion_neighbors(layers: Array[Dictionary], clip: Animation, time: float, native_name: String,
		past_color: Color, future_color: Color) -> void:
	var interval: float = clip.step if _onion_spacing == 0 else ONION_INTERVALS[_onion_spacing]
	if interval <= 0.0:
		return
	var seen := PackedFloat64Array([time])
	for step in range(_onion_steps, 0, -1):
		var alpha := float(_onion_steps - step + 1) / float(_onion_steps + 1)
		for direction: int in [-1, 1]:
			if (direction < 0 and not _onion_past) or (direction > 0 and not _onion_future):
				continue
			var sample: float = time + direction * step * interval
			match clip.loop_mode:
				Animation.LOOP_LINEAR:
					sample = fposmod(sample, clip.length)
				Animation.LOOP_PINGPONG:
					sample = pingpong(sample, clip.length)
				_:
					if sample < -0.000001 or sample > clip.length + 0.000001:
						continue
					sample = clampf(sample, 0.0, clip.length)
			var repeated := false
			for already_seen in seen:
				if is_equal_approx(sample, already_seen):
					repeated = true
					break
			if repeated:
				continue
			seen.append(sample)
			_append_onion_layer(layers, clip, sample, native_name, Color(past_color if direction < 0 else future_color, alpha))


func _append_onion_layer(layers: Array[Dictionary], clip: Animation, time: float,
		native_name: String, color: Color) -> void:
	var camera_pose := Transform3D.IDENTITY
	if _pose_mode and not native_name.is_empty() and clip.find_track(PREVIEW_CAMERA_TRACK, Animation.TYPE_VALUE) < 0:
		camera_pose = _native_pose.camera_motion(native_name, time / clip.length)
	var has_bones := not native_name.is_empty() or bool(clip.get_meta(VIEWER_POSE_META, false))
	layers.append({"clip": clip, "time": time, "color": color, "camera_pose": camera_pose, "bones": has_bones})


func _remap_preview_clip(animation: Animation) -> Animation:
	var rig := _player.get_node(_player.root_node)
	var clip := animation.duplicate() as Animation
	for track in range(clip.get_track_count() - 1, -1, -1):
		var path := clip.track_get_path(track)
		var source_node := rig.get_node_or_null(NodePath(String(path.get_concatenated_names())))
		if source_node == _source_camera.get_parent() and path.get_subname_count() == 1 \
				and path.get_subname(0) == CAMERA_MOTION_PROPERTY and clip.track_get_type(track) == Animation.TYPE_VALUE:
			clip.track_set_path(track, PREVIEW_CAMERA_TRACK)
			continue
		if source_node == null or not _source_camera.is_ancestor_of(source_node):
			clip.remove_track(track)
			continue
		var mapped := "PreviewCamera/" + String(_source_camera.get_path_to(source_node))
		if path.get_subname_count() > 0:
			mapped += ":" + String(path.get_concatenated_subnames())
		clip.track_set_path(track, NodePath(mapped))
	return clip


func _update_preview_stage() -> void:
	if not _panel.is_visible_in_tree():
		return
	if _preview_camera != null and _preview_camera.get_meta(&"source_id") != _source_camera.get_instance_id():
		_clear_preview()
	if _preview_camera == null:
		_create_preview_stage()
	if _combo_open:
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		_update_sword_models()
		_gizmo.configure(null, null, null)
		_pose_view.set_active(false)
		_preview_camera.make_current()
		_crosshair.show()
		_overlays.set_visible(false, false)
		_refresh_combo_preview()
		return

	var rig := _player.get_node(_player.root_node)
	var clip := _remap_preview_clip(_candidate)
	if _playback_mode == PlaybackMode.ONCE:
		clip.loop_mode = Animation.LOOP_NONE
	_preview_has_camera_motion = clip.find_track(PREVIEW_CAMERA_TRACK, Animation.TYPE_VALUE) >= 0
	_preview_player.stop()
	_preview_camera.transform = Transform3D.IDENTITY
	if _preview_library.has_animation(PREVIEW_CLIP):
		_preview_library.remove_animation(PREVIEW_CLIP)
	_preview_library.add_animation(PREVIEW_CLIP, clip)
	var preview_paths: Array[NodePath] = []
	for target in _targets:
		var socket := rig.get_node(target)
		preview_paths.append(NodePath("PreviewCamera/" + String(_source_camera.get_path_to(socket))))
	_preview_clip = clip
	_preview_paths = _hand_paths(preview_paths)
	_overlays.configure(_preview_player, _preview_paths, clip)
	_update_overlays()
	_update_sword_models()
	_preview_player.play(PREVIEW_CLIP)
	_preview_player.advance(0.0)
	_seek_preview(_preview_time)
	_bind_pose_view()
	_apply_view_mode()
	_configure_onion_preview(rig)
	_update_sword_models()
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_play.disabled = false
	_time.editable = true


func _create_preview_stage() -> void:
	_preview_camera = _source_camera.duplicate(0) as Camera3D
	_preview_camera.name = "PreviewCamera"
	_preview_camera.transform = Transform3D.IDENTITY
	_preview_camera.set_meta(&"source_id", _source_camera.get_instance_id())
	_preview_reference = REFERENCE_STAGE.instantiate()
	_viewport.add_child(_preview_reference)
	var environment: WorldEnvironment = _preview_reference.get_node("WorldEnvironment")
	_preview_camera.environment = environment.environment
	for marker in _preview_camera.find_children("*SocketMarker", "MeshInstance3D", true, false):
		marker.hide()
	_viewport.add_child(_preview_camera)
	_preview_camera.make_current()
	_preview_player = AnimationPlayer.new()
	_preview_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_preview_library = AnimationLibrary.new()
	_preview_player.add_animation_library(&"", _preview_library)
	_viewport.add_child(_preview_player)
	_combo_preview.configure(_preview_player, _preview_camera)


func _bind_pose_view() -> void:
	if not is_instance_valid(_preview_camera) or _native_paths.is_empty():
		_pose_view.set_active(false)
		return
	if not is_instance_valid(_orbit_camera):
		_orbit_camera = Camera3D.new()
		_orbit_camera.name = "PoseCamera"
		_orbit_camera.near = 0.025
		_orbit_camera.far = _preview_camera.far
		_orbit_camera.environment = _preview_camera.environment
		_viewport.add_child(_orbit_camera)
		_orbit_camera.position = Vector3(1.6, 0.5, -0.15)
	var rig := _preview_camera.get_node_or_null("NativePoseRig") as Node3D
	var display_bones := _native_pose.nodes(rig)
	for left in [false, true]:
		var index := _native_pose.socket_index(left)
		var socket := _preview_camera.get_node_or_null("LeftWeaponControl" if left else "WeaponControl") as Node3D
		if socket != null and index >= 0 and index < display_bones.size():
			display_bones[index] = socket
	var first_bind := not _pose_view.is_processing()
	_pose_view.configure(_orbit_camera, display_bones, _native_pose.parents())
	_sync_pose_selection()
	if first_bind and _pose_mode:
		_pose_view.frame_target()


func _sync_pose_selection() -> void:
	var selected := _native_paths.find(_socket_path)
	if selected < 0 and _socket_path in _targets:
		var name := String(_socket_path.get_name(_socket_path.get_name_count() - 1)).to_lower()
		selected = _native_pose.socket_index(name.contains("left"))
	_pose_view.set_selected(selected)


func _clear_preview() -> void:
	_set_combo_playing(false)
	_combo_preview.clear()
	_combo_clips.clear()
	if _combo_open:
		_sync_combo_transport()
		_combo_ui.set_timeline_layout({}, _combo_sequence)
	_set_preview_playing(false)
	_onion_preview.clear()
	_overlays.clear()
	_pose_view.set_active(false)
	_pose_view.configure(null, [], PackedInt32Array())
	_gizmo.configure(null, null, null)
	_gizmo_mode.disabled = true
	_crosshair.hide()
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ONCE if _panel.is_visible_in_tree() else SubViewport.UPDATE_DISABLED
		)
	if is_instance_valid(_preview_player):
		_viewport.remove_child(_preview_player)
		_preview_player.queue_free()
	if is_instance_valid(_preview_camera):
		_viewport.remove_child(_preview_camera)
		_preview_camera.queue_free()
	if is_instance_valid(_preview_reference):
		_viewport.remove_child(_preview_reference)
		_preview_reference.queue_free()
	if is_instance_valid(_orbit_camera):
		_viewport.remove_child(_orbit_camera)
		_orbit_camera.queue_free()
	_orbit_camera = null
	_preview_player = null
	_preview_camera = null
	_preview_reference = null
	_preview_library = null
	_preview_clip = null
	_preview_paths.clear()
	_socket_pose_editable = false
	_fill_transform_controls()
	if is_instance_valid(_play):
		_play.disabled = true
		_time.editable = false
	_queue_onion_refresh()


func _on_preview_visibility_changed() -> void:
	if _moving_panel or not is_instance_valid(_panel):
		return
	if not _panel.is_visible_in_tree():
		_set_combo_playing(false)
		_set_preview_playing(false)
		_pose_view.set_active(false)
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_queue_onion_refresh()
	elif _candidate != null and is_instance_valid(_source_camera):
		_queue_preview_refresh()


func _can_preview() -> bool:
	return _candidate != null and is_instance_valid(_preview_player) and _panel.is_visible_in_tree()


func _on_play_toggled(playing: bool) -> void:
	playing = playing and _can_preview()
	if playing:
		_seek_playback_start_if_needed()
	_set_preview_playing(playing)
	if _editing_socket:
		_set_socket_key_button.disabled = not _socket_pose_editable or _play.button_pressed


func _on_playback_mode_selected(index: int) -> void:
	_playback_mode = _playback_mode_picker.get_item_id(index)
	_update_playback_region()
	if _can_preview():
		# A looping source wraps an exact end seek to zero. Play Once samples the actual last pose.
		_preview_clip.loop_mode = Animation.LOOP_NONE if _playback_mode == PlaybackMode.ONCE else _candidate.loop_mode
		if _play.button_pressed:
			_seek_playback_start_if_needed()
		_seek_preview(_preview_time)
		_time.grab_focus()


func _seek_playback_start_if_needed() -> void:
	var duration := _candidate.length
	if _playback_mode == PlaybackMode.ONCE and _preview_time >= duration:
		_seek_preview(0.0)
	elif _playback_mode == PlaybackMode.LOOP_REGION:
		var start := _loop_start_phase * duration
		var end := _loop_end_phase * duration
		if _preview_time < start or _preview_time >= end:
			_seek_preview(start)


func _update_playback_region() -> void:
	_playback_mode_picker.disabled = _candidate == null
	_playback_region.visible = _candidate != null and _playback_mode == PlaybackMode.LOOP_REGION
	if not _playback_region.visible:
		_time.clear_loop_region()
		return
	var duration := _candidate.length
	var start := _loop_start_phase * duration
	var end := _loop_end_phase * duration
	_syncing_loop_fields = true
	_loop_start_field.max_value = maxf(0.0, end - LOOP_ENDPOINT_STEP)
	_loop_end_field.max_value = duration
	_loop_end_field.min_value = minf(duration, start + LOOP_ENDPOINT_STEP)
	_loop_start_field.set_value_no_signal(start)
	_loop_end_field.set_value_no_signal(end)
	_syncing_loop_fields = false
	_time.set_loop_region(start, end)


func _capture_loop_endpoint(is_start: bool) -> void:
	_set_loop_endpoint(_preview_time, is_start)
	if _can_preview():
		_time.grab_focus()


func _set_loop_endpoint(seconds: float, is_start: bool) -> void:
	if _candidate == null or _syncing_loop_fields:
		return
	var duration := _candidate.length
	var phase := clampf(seconds, 0.0, duration) / duration
	if (is_start and phase >= _loop_end_phase) or (not is_start and phase <= _loop_start_phase):
		_show_status("Loop In must be before Loop Out.")
		return
	if is_start:
		_loop_start_phase = phase
	else:
		_loop_end_phase = phase
	_update_playback_region()
	_update_apply_buttons()
	if _play.button_pressed:
		_seek_playback_start_if_needed()


func _set_preview_playing(playing: bool) -> void:
	set_process(playing or _combo_playing)
	if is_instance_valid(_play):
		var stopped := not playing and _play.button_pressed
		_play.set_pressed_no_signal(playing)
		_play.text = "Pause Clip" if playing else "Play Clip"
		if stopped:
			_sync_draft_anchor()
	_queue_onion_refresh()


func _seek_track_time(time: float) -> void:
	_set_preview_playing(false)
	_seek_preview(time)


func _seek_preview(seconds: float) -> void:
	if not is_instance_valid(_preview_player) or _candidate == null:
		return
	var time := clampf(seconds, 0.0, _candidate.length)
	var time_changed := not is_equal_approx(time, _preview_time)
	if time_changed and _socket_offsets_pending():
		_clear_socket_offsets()
		_refresh_socket_trail()
	_preview_time = time
	_time.set_value_no_signal(time)
	var at_loop_end := time == _candidate.length and _preview_clip.loop_mode == Animation.LOOP_LINEAR
	if at_loop_end:
		_preview_clip.loop_mode = Animation.LOOP_NONE
	_preview_player.seek(time, true, true)
	if at_loop_end:
		_preview_clip.loop_mode = Animation.LOOP_LINEAR
	# Older clips can still preview the recovered motion before it is authored into the scene.
	if not _preview_has_camera_motion:
		_preview_camera.transform = _native_pose.camera_motion(_native_name, time / _candidate.length)
	_track_timeline.set_playhead(time)
	var socket := _preview_socket() if _editing_socket else null
	_socket_pose_editable = socket != null and SocketKeys.sample_pose(_candidate, _socket_path, time) != null
	if _editing_socket:
		if socket != null:
			_socket_base_pose = socket.transform
		_fill_transform_controls()
		_configure_socket_gizmo()
		if _socket_offsets_pending():
			_update_socket_pose()
		else:
			_update_apply_buttons()
	if time_changed and not _play.button_pressed:
		_sync_draft_anchor()
	_queue_onion_refresh()


func _owns_source() -> bool:
	var scene := EditorInterface.get_edited_scene_root()
	return (
		is_instance_valid(_player) and (_player == scene or _player.owner == scene)
		and _player.has_animation(_clip_name) and _player.get_animation(_clip_name) == _source
	)


func _clip_library() -> StringName:
	var parts := String(_clip_name).split("/", false, 1)
	return StringName(parts[0]) if parts.size() == 2 else &""


func _open_save_as() -> void:
	if not _owns_source():
		return
	_refresh_preview()
	if _save_as.disabled:
		return
	_set_preview_playing(false)
	_variant_source = _source
	var library := _player.get_animation_library(_clip_library())
	var base_name := String(_clip_name).get_file()
	var number := 2
	while library.has_animation(StringName("%s_v%d" % [base_name, number])):
		number += 1
	_variant_name.text = "%s_v%d" % [base_name, number]
	_validate_variant_name()
	_variant_dialog.popup_centered(Vector2i(410, 0))
	_variant_name.grab_focus()
	_variant_name.select_all()


func _validate_variant_name() -> String:
	var error := "Select the animation again before saving."
	if _owns_source() and _variant_source == _source:
		var library := _player.get_animation_library(_clip_library())
		error = AnimationVariants.name_error(library, _variant_name.text.strip_edges())
	_variant_dialog.get_ok_button().disabled = not error.is_empty()
	if error.is_empty() and (not _sword_positions.is_empty() or not _sword_rotations.is_empty()):
		_variant_feedback.text = "Sword mount offsets are still in the preview. Use Apply to save them."
	else:
		_variant_feedback.text = error
	_variant_feedback.visible = not _variant_feedback.text.is_empty()
	return error


func _save_variant() -> void:
	if not _validate_variant_name().is_empty():
		return
	_refresh_preview()
	var animation := _animation_to_save()
	if animation == null:
		_variant_feedback.text = "Adjust the draft so all animation keys can be saved."
		_variant_feedback.show()
		return
	var name := StringName(_variant_name.text.strip_edges())
	var library_key := _clip_library()
	var previous := _player.get_animation_library(library_key)
	var updated := AnimationVariants.make_library(previous, name, animation)
	if updated == null:
		_variant_feedback.text = "The animation copy could not be saved."
		_variant_feedback.show()
		return
	var property := StringName("libraries/" + String(library_key))
	var undo := get_undo_redo()
	undo.create_action("Save Weapon Animation As", UndoRedo.MERGE_DISABLE, _player)
	undo.add_do_property(_player, property, updated)
	undo.add_undo_property(_player, property, previous)
	undo.commit_action()
	_variant_dialog.hide()
	_variant_source = null
	var key := name if library_key.is_empty() else StringName("%s/%s" % [library_key, name])
	_load_source(key)
	_refresh_context()


func _apply_tweak() -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if not _owns_source():
		_queue_context_refresh()
		return
	_refresh_preview()
	if _apply.disabled:
		return
	var sword_paths := _sword_positions.keys()
	for path in _sword_rotations:
		if not sword_paths.has(path):
			sword_paths.append(path)
	for path in sword_paths:
		var sword := _source_camera.get_node_or_null(path) as Node3D
		if sword == null or sword.owner != scene:
			_show_status("Open the scene that owns the selected sword mount to apply its transform.")
			return

	var undo := get_undo_redo()
	var replace_clip := _motion_changed or _tracks_changed
	var animation := _animation_to_save() if replace_clip else null
	if replace_clip and animation == null:
		_show_status("The animation tracks could not be saved.")
		return
	undo.create_action("Tweak Weapon Animation", UndoRedo.MERGE_DISABLE, _player)
	if replace_clip:
		var library_name := _clip_library()
		var clip_name := StringName(String(_clip_name).get_file())
		var previous := _player.get_animation_library(library_name)
		var updated := previous.duplicate() as AnimationLibrary
		updated.remove_animation(clip_name)
		updated.add_animation(clip_name, animation)
		var property := StringName("libraries/" + String(library_name))
		undo.add_do_property(_player, property, updated)
		undo.add_undo_property(_player, property, previous)
	for path in sword_paths:
		var sword := _source_camera.get_node(path) as Node3D
		undo.add_do_property(sword, &"transform", _sword_transform(sword, path))
		undo.add_undo_property(sword, &"transform", sword.transform)
	undo.commit_action()
	_reset_draft()
	_clear_draft_history()
	_refresh_context()

