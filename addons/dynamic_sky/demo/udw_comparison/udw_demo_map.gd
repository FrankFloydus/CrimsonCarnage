extends Node3D
## Runtime inspection controls for the fixed-camera UDW comparison map.

const ComparisonSurface := preload("res://addons/dynamic_sky/demo/udw_comparison/comparison_surface.gd")
const SOURCE_MATERIAL_STATE := &"source_material_state"
const SOURCE_FULL_WIND_METERS_PER_SECOND := 15.0

## Multisampling used while running this comparison scene. Disabled keeps the viewport's existing setting.
@export var comparison_msaa: Viewport.MSAA = Viewport.MSAA_DISABLED

## Real seconds for a full day while the comparison clock is running.
@export_range(1.0, 3600.0, 1.0, "suffix:s") var preview_day_length_seconds: float = 90.0

## Real seconds used to blend between presets selected from the comparison controls.
@export_range(0.0, 30.0, 0.1, "suffix:s") var weather_transition_seconds: float = 2.0

## Free camera movement speed in meters per second.
@export_range(1.0, 30.0, 0.1, "suffix:m/s") var camera_speed: float = 6.0

## Free camera turn in degrees per pixel of mouse movement.
@export_range(0.01, 0.5, 0.01) var look_sensitivity: float = 0.14

@export_group("Source Snow and Wetness")
## Simulates source snow accumulation and wetness during timed preview weather changes.
## A zero-second call to set_comparison_weather() always applies the settled reference state.
@export var simulate_source_material_timing: bool = true

## Real seconds for full-strength snowfall to cover a dry surface.
@export_range(0.1, 600.0, 0.1, "or_greater", "suffix:s") var source_snow_build_seconds: float = 60.0

## Real seconds for a full snow layer to melt when snowfall stops.
@export_range(0.1, 1200.0, 0.1, "or_greater", "suffix:s") var source_snow_melt_seconds: float = 90.0

## Real seconds for full-strength rainfall to saturate a dry surface.
@export_range(0.1, 600.0, 0.1, "or_greater", "suffix:s") var source_wetting_seconds: float = 20.0

## Real seconds for a wet surface to dry in clear daylight.
@export_range(0.1, 1200.0, 0.1, "or_greater", "suffix:s") var source_drying_seconds: float = 90.0

## Meltwater contribution to wetness. The source doubles this ratio in its active melt rate.
@export_range(0.0, 1.0, 0.01) var source_snow_melt_wetness: float = 0.75

@export_group("Source Orbit")
## Runs the source level script's small-sphere orbit during playback. Disable to inspect the saved actor pose.
@export var animate_small_sphere: bool = true

## Radius of the small sphere's world-space path, in meters.
@export_range(0.1, 10.0, 0.01, "suffix:m") var sphere_orbit_radius: float = 2.0

## Angular speed of the small sphere, in degrees per game second.
@export_range(1.0, 360.0, 1.0, "suffix:°/s") var sphere_orbit_speed: float = 85.0

var _looking := false
var _sphere_orbit_time: float = 0.0
var _material_blend_from := Vector3.ZERO
var _material_blend_to := Vector3.ZERO
var _material_blend_elapsed: float = 0.0
var _material_blend_seconds: float = 0.0
var _source_timing_active := false
var _source_timed_transition: DynamicSkyWeather
var _source_wet_snow := Vector2.ZERO
var _pool_wind := 0.0
var _previous_viewport_msaa := Viewport.MSAA_DISABLED
var _applied_viewport_msaa := Viewport.MSAA_DISABLED

@onready var _sky: DynamicSky = $DynamicSky
@onready var _camera: Camera3D = $Camera3D
@onready var _reference_views: Node3D = $ReferenceViews
@onready var _landscape: MeshInstance3D = $Terrain/Landscape
@onready var _small_sphere: MeshInstance3D = $Props/Sphere2
@onready var _controls: CanvasLayer = $Controls
@onready var _weather_menu: OptionButton = %WeatherPreset
@onready var _view_menu: OptionButton = %ReferenceView
@onready var _time_slider: HSlider = %TimeSlider
@onready var _time_readout: Label = %TimeReadout
@onready var _comparison_surfaces: Array[ComparisonSurface] = [
	$Terrain/Landscape/WeatherResponse,
	$Props/Sphere/WeatherResponse,
]


func _ready() -> void:
	if comparison_msaa != Viewport.MSAA_DISABLED:
		var viewport := get_viewport()
		_previous_viewport_msaa = viewport.msaa_3d
		_applied_viewport_msaa = comparison_msaa
		viewport.msaa_3d = _applied_viewport_msaa
	_sky.weather_transition_finished.connect(_apply_profile_material)
	_apply_profile_material(_sky.start_weather)
	for index: int in _sky.weather_presets.size():
		var preset := _sky.weather_presets[index]
		if preset == null:
			continue
		_weather_menu.add_item(preset.resource_name, index)
		if preset == _sky.start_weather:
			_weather_menu.select(_weather_menu.item_count - 1)
	for index: int in _reference_views.get_child_count():
		var view := _reference_views.get_child(index) as Camera3D
		if view != null:
			_view_menu.add_item(String(view.name).to_snake_case().capitalize(), index)
	_update_clock()


func _process(delta: float) -> void:
	if _source_timing_active:
		_advance_source_wet_snow(_sky.get_weather_state(), _sky.get_sun_direction().y > 0.0, delta)
	if _material_blend_seconds > 0.0:
		_material_blend_elapsed += delta
		var weight := smoothstep(0.0, _material_blend_seconds, _material_blend_elapsed)
		_set_source_material_state(_material_blend_from.lerp(_material_blend_to, weight))
	elif _source_timing_active:
		_set_source_material_state(_material_blend_to)
	if _controls.visible and _sky.day_length_seconds > 0.0:
		_update_clock()
	if not _looking:
		return
	var movement := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	)
	var direction := _camera.basis.x * movement.x + Vector3.UP * movement.y + _camera.basis.z * movement.z
	_camera.position += direction.normalized() * camera_speed * delta


func _physics_process(delta: float) -> void:
	if animate_small_sphere:
		_sphere_orbit_time += delta
		_apply_sphere_orbit()
	if _comparison_surfaces[0].get_accumulation().x > 0.0:
		_update_pool_wind()


func _update_pool_wind() -> void:
	# The comparison presets map normalized source wind quadratically to Godot meters per second.
	var speed := _sky.get_wind_at(_landscape.global_position).length()
	var source_wind := sqrt(clampf(speed / SOURCE_FULL_WIND_METERS_PER_SECOND, 0.0, 1.0))
	if not is_equal_approx(source_wind, _pool_wind):
		_pool_wind = source_wind
		_landscape.set_instance_shader_parameter(&"comparison_pool_wind", source_wind)


func _exit_tree() -> void:
	if _looking:
		_release_look()
	if _applied_viewport_msaa != Viewport.MSAA_DISABLED:
		var viewport := get_viewport()
		if viewport != null and viewport.msaa_3d == _applied_viewport_msaa:
			viewport.msaa_3d = _previous_viewport_msaa


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _looking:
		_release_look()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.physical_keycode == KEY_TAB and event.pressed and not event.echo:
		_controls.visible = not _controls.visible
		get_viewport().set_input_as_handled()
		return
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



## Copies a saved ReferenceViews camera pose and lens into the active camera.
func select_view(path: NodePath) -> bool:
	var reference := get_node_or_null(path) as Camera3D
	if reference == null or reference.get_parent() != _reference_views:
		return false
	_camera.global_transform = reference.global_transform
	_camera.keep_aspect = reference.keep_aspect
	_camera.fov = reference.fov
	_camera.near = reference.near
	_camera.far = reference.far
	_camera.reset_physics_interpolation()
	return true


## Moves the small sphere to the source orbit pose at the specified game time.
func set_small_sphere_orbit_time(seconds: float) -> void:
	_sphere_orbit_time = maxf(seconds, 0.0)
	_apply_sphere_orbit()
	_small_sphere.reset_physics_interpolation()


## Applies a comparison profile. Zero seconds selects its settled state for a reference capture.
## During a timed change, the source simulation can evolve wetness and snow from the current surface.
func set_comparison_weather(profile: DynamicSkyWeather, seconds: float = 0.0) -> void:
	if profile == null:
		return
	var state: Variant = profile.get_meta(SOURCE_MATERIAL_STATE, Vector3.INF)
	_material_blend_seconds = 0.0
	_source_timing_active = false
	_source_timed_transition = null
	if seconds > 0.0 and state is Vector3 and state.is_finite():
		_material_blend_from = _comparison_surfaces[0].get_accumulation()
		_material_blend_to = state.clamp(Vector3.ZERO, Vector3.ONE)
		_material_blend_elapsed = 0.0
		_material_blend_seconds = seconds
		if simulate_source_material_timing:
			_source_timing_active = true
			_source_timed_transition = profile
			_source_wet_snow = Vector2(_material_blend_from.x, _material_blend_from.y)
	elif seconds > 0.0:
		_apply_profile_material(profile)
	_sky.set_weather(profile, seconds)


func _apply_profile_material(profile: DynamicSkyWeather) -> void:
	_material_blend_seconds = 0.0
	if _source_timed_transition == null or profile != _source_timed_transition:
		_source_timing_active = false
	_source_timed_transition = null
	var state: Variant = profile.get_meta(SOURCE_MATERIAL_STATE, Vector3.INF) if profile != null else Vector3.INF
	if state is Vector3 and state.is_finite():
		_material_blend_to = state.clamp(Vector3.ZERO, Vector3.ONE)
		_set_source_material_state(_material_blend_to)
	else:
		for surface in _comparison_surfaces:
			surface.clear_source_state()


func _advance_source_wet_snow(weather: Dictionary[StringName, Variant], sun_up: bool, delta: float) -> void:
	var rain := clampf(float(weather[&"rain"]), 0.0, 1.0)
	var snow := clampf(float(weather[&"snow"]), 0.0, 1.0)
	var previous_snow := _source_wet_snow.y
	var melting_seconds := 0.0
	if snow > 0.0:
		_source_wet_snow.y = minf(1.0, previous_snow + snow * delta / maxf(source_snow_build_seconds, 0.001))
	else:
		var melt_duration := maxf(source_snow_melt_seconds, 0.001)
		melting_seconds = minf(delta, previous_snow * melt_duration)
		_source_wet_snow.y = maxf(0.0, previous_snow - melting_seconds / melt_duration)
	if rain > 0.0:
		_source_wet_snow.x = minf(1.0, _source_wet_snow.x + rain * delta / maxf(source_wetting_seconds, 0.001))
		return
	if source_snow_melt_wetness > 0.0:
		var melted := previous_snow - _source_wet_snow.y
		_source_wet_snow.x = minf(1.0, _source_wet_snow.x + maxf(melted, 0.0) * 2.0 * source_snow_melt_wetness)
	else:
		melting_seconds = 0.0
	var sunlight := 1.0 - clampf(inverse_lerp(0.3, 0.7, float(weather[&"cloud_coverage"])), 0.0, 1.0) if sun_up else 0.0
	var drying_rate := lerpf(0.3, 1.0, sunlight) / maxf(source_drying_seconds, 0.001)
	_source_wet_snow.x = maxf(0.0, _source_wet_snow.x - (delta - melting_seconds) * drying_rate)


func _set_source_material_state(state: Vector3) -> void:
	if _source_timing_active:
		state.x = _source_wet_snow.x
		state.y = _source_wet_snow.y
	for surface in _comparison_surfaces:
		surface.set_source_state(state)


func _apply_sphere_orbit() -> void:
	var phase := deg_to_rad(fposmod(_sphere_orbit_time * sphere_orbit_speed, 360.0))
	_small_sphere.position = Vector3(
		sin(phase) * sphere_orbit_radius,
		0.16,
		-cos(phase) * sphere_orbit_radius,
	)


func _release_look() -> void:
	_looking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _update_clock() -> void:
	var minutes := floori(_sky.time_of_day * 60.0)
	_time_slider.set_value_no_signal(_sky.time_of_day)
	_time_readout.text = "%02d:%02d" % [floori(_sky.time_of_day), minutes % 60]


func _on_reference_selected(index: int) -> void:
	var reference := _reference_views.get_child(_view_menu.get_item_id(index))
	select_view(get_path_to(reference))


func _on_weather_selected(index: int) -> void:
	set_comparison_weather(_sky.weather_presets[_weather_menu.get_item_id(index)], weather_transition_seconds)


func _on_time_changed(value: float) -> void:
	_sky.time_of_day = value
	_update_clock()


func _on_run_clock_toggled(enabled: bool) -> void:
	_sky.day_length_seconds = preview_day_length_seconds if enabled else 0.0
