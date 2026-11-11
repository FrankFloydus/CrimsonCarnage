extends Node3D

## Real seconds per solar day when the demo clock is running.
@export_range(1.0, 3600.0, 1.0, "suffix:s") var preview_day_length_seconds: float = 90.0

## Real seconds to blend to the weather selected from the demo controls.
@export_range(0.0, 30.0, 0.1, "suffix:s") var weather_transition_seconds: float = 2.0

## Fly camera speed in meters per second while holding the right mouse button.
@export_range(1.0, 30.0, 0.1, "suffix:m/s") var camera_speed: float = 6.0

## Camera turn in degrees per pixel of mouse travel.
@export_range(0.01, 0.5, 0.01) var look_sensitivity: float = 0.14

## Multisampling for the demo viewport. Four samples keep thin spruce needles readable in motion.
@export var scene_msaa: Viewport.MSAA = Viewport.MSAA_4X

var _looking: bool = false
var _previous_msaa: Viewport.MSAA

@onready var _sky: DynamicSky = $DynamicSky
@onready var _camera: Camera3D = $Lookout/Camera3D
@onready var _viewpoints: Array[Camera3D] = [
	$Lookout/RidgeView, $Lookout/ShelterView, $Lookout/LakeshoreView, $Lookout/SkySurveyView,
	$Lookout/WeatherApronView,
	$Lookout/RidgeTrailView,
]
@onready var _time_slider: HSlider = %TimeSlider
@onready var _time_readout: Label = %TimeReadout
@onready var _cloud_mode_selector: OptionButton = %CloudModeSelector
@onready var _color_mode_selector: OptionButton = %ColorModeSelector
@onready var _settings_panel: PanelContainer = $Controls/Panel
@onready var _settings_rows: VBoxContainer = $Controls/Panel/Rows
@onready var _panel_toggle: Button = $Controls/Panel/Rows/Title
@onready var _weather_menu: OptionButton = $Controls/Panel/Rows/Weather/WeatherPreset


func _ready() -> void:
	_previous_msaa = get_viewport().msaa_3d
	if DisplayServer.get_name() != "headless":
		get_viewport().msaa_3d = scene_msaa
	_show_time()
	_on_view_selected(0)
	_on_cloud_mode_selected(_cloud_mode_selector.selected)
	_on_color_mode_selected(_color_mode_selector.selected)
	_populate_weather_menu()
	_on_panel_toggled(_panel_toggle.button_pressed)


func _process(delta: float) -> void:
	if _sky.day_length_seconds > 0.0:
		_show_time()
	if not _looking:
		return
	var movement := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	)
	var flight_direction := (
		_camera.basis.x * movement.x + Vector3.UP * movement.y + _camera.basis.z * movement.z
	)
	_camera.position += flight_direction.normalized() * camera_speed * delta


func _exit_tree() -> void:
	if _looking:
		_release_look()
	if DisplayServer.get_name() != "headless":
		get_viewport().msaa_3d = _previous_msaa


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _looking:
		_release_look()


func _input(event: InputEvent) -> void:
	if not _looking:
		return
	if event is InputEventMouseMotion:
		var angles := _camera.rotation_degrees
		angles.y -= event.screen_relative.x * look_sensitivity
		angles.x = clampf(angles.x - event.screen_relative.y * look_sensitivity, -85.0, 85.0)
		_camera.rotation_degrees = angles
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_cancel") or (
		event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed
	):
		_release_look()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_looking = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _release_look() -> void:
	_looking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _show_time() -> void:
	var time := _sky.time_of_day
	var minutes := floori(time * 60.0)
	_time_slider.set_value_no_signal(time)
	_time_readout.text = "%02d:%02d" % [floori(time), minutes % 60]


func _on_time_changed(value: float) -> void:
	_sky.time_of_day = value
	_show_time()


func _on_run_clock_toggled(enabled: bool) -> void:
	_sky.day_length_seconds = preview_day_length_seconds if enabled else 0.0


func _on_weather_selected(index: int) -> void:
	if index < 0 or index >= _weather_menu.item_count:
		return
	var preset_index := _weather_menu.get_item_id(index)
	if preset_index >= 0 and preset_index < _sky.weather_presets.size():
		_sky.set_weather(_sky.weather_presets[preset_index], weather_transition_seconds)


func _populate_weather_menu() -> void:
	_weather_menu.clear()
	for index in _sky.weather_presets.size():
		var preset := _sky.weather_presets[index]
		if preset == null:
			continue
		_weather_menu.add_item(preset.resource_name, index)
		if preset == _sky.start_weather:
			_weather_menu.select(_weather_menu.item_count - 1)


func _on_cloud_mode_selected(index: int) -> void:
	_sky.set_cloud_mode(_cloud_mode_selector.get_item_id(index))


func _on_color_mode_selected(index: int) -> void:
	_sky.set_color_mode(_color_mode_selector.get_item_id(index))


func _on_view_selected(index: int) -> void:
	if index < 0 or index >= _viewpoints.size():
		return
	var viewpoint := _viewpoints[index]
	_camera.global_transform = viewpoint.global_transform
	_camera.fov = viewpoint.fov
	_camera.reset_physics_interpolation()


func _on_lightning_pressed() -> void:
	_sky.trigger_lightning()


func _on_panel_toggled(expanded: bool) -> void:
	for row: Control in _settings_rows.get_children():
		if row != _panel_toggle:
			row.visible = expanded
	_panel_toggle.text = "▾ Dynamic Sky" if expanded else "▸ Dynamic Sky"
	_panel_toggle.tooltip_text = "Collapse sky settings" if expanded else "Expand sky settings"
	_settings_panel.reset_size()
