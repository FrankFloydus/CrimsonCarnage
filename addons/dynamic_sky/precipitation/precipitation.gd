extends Node3D
## Places weather emitters around the local camera. Emitted particles move in world space.

const COLLISION_GRID_STEP_METERS: float = 3.0
const Rain = preload("res://addons/dynamic_sky/precipitation/rain/rain.gd")
const Snowfall = preload("res://addons/dynamic_sky/precipitation/snow/snowfall.gd")

## Camera used to place the weather emitters. Leave empty to follow the viewport's active camera.
@export var camera_override: Camera3D

## Uses nearby opaque meshes from the CollisionField visual mask for shelter and rain impacts.
@export var surface_collision_enabled: bool = true

## Leaves a sparse layer of short-lived flakes at snow impacts when surface collision is active.
@export var enable_snow_contact: bool = false:
	set(value):
		enable_snow_contact = value
		if is_node_ready():
			_follow_camera()

var _rain_intensity: float = 0.0
var _snow_intensity: float = 0.0
var _dust_intensity: float = 0.0
var _wind: Vector2 = Vector2.ZERO
var _observer_active: bool = true
var _visibility_before_suppression: bool = true

@onready var _rain: Rain = $Rain
@onready var _snow: Snowfall = $Snowfall
@onready var _collision_field: GPUParticlesCollisionHeightField3D = $CollisionField


func _ready() -> void:
	_update_particles()


func _process(_delta: float) -> void:
	_follow_camera()


## Hides precipitation immediately for a submerged or suspended observer and restores visibility on exit.
func set_observer_active(active: bool) -> void:
	if _observer_active == active:
		return
	_observer_active = active
	if active:
		visible = _visibility_before_suppression
	else:
		_visibility_before_suppression = visible
		visible = false
	if is_node_ready():
		_update_particles()


## Sets rain and snow emissions and keeps the collision field available for airborne dust.
## Wind is horizontal world-space velocity in meters per second.
func apply_weather(rain: float, snow: float, wind: Vector2, dust: float = 0.0) -> void:
	var next_rain: float = clampf(rain, 0.0, 1.0)
	var next_snow: float = clampf(snow, 0.0, 1.0)
	var next_dust: float = clampf(dust, 0.0, 1.0)
	if (
		_rain_intensity == next_rain
		and _snow_intensity == next_snow
		and _dust_intensity == next_dust
		and _wind == wind
	):
		return
	_rain_intensity = next_rain
	_snow_intensity = next_snow
	_dust_intensity = next_dust
	_wind = wind
	if is_node_ready():
		_update_particles()


func _update_particles() -> void:
	_follow_camera()
	set_process(_has_precipitation())


func _follow_camera() -> void:
	var camera := get_effect_camera()
	if camera != null:
		global_position = camera.get_camera_transform().origin
	var has_camera: bool = camera != null and _observer_active
	_rain.apply_rain(_rain_intensity, _wind, has_camera)
	_snow.apply_snow(
		_snow_intensity, _wind, has_camera, enable_snow_contact and surface_collision_enabled,
		surface_collision_enabled, camera,
	)
	_update_collision_field(has_camera and _has_precipitation() and surface_collision_enabled)


## Returns the camera shared by falling precipitation and the airborne weather field.
func get_effect_camera() -> Camera3D:
	if is_instance_valid(camera_override) and camera_override.is_inside_tree():
		return camera_override
	return get_viewport().get_camera_3d()


func _has_precipitation() -> bool:
	return _rain_intensity > 0.0 or _snow_intensity > 0.0 or _dust_intensity > 0.0


func _update_collision_field(enabled: bool) -> void:
	if _collision_field.visible != enabled:
		_collision_field.visible = enabled
	if enabled:
		# Regenerate the small heightfield when crossing the grid, avoiding per-frame scene capture.
		var field_position: Vector3 = global_position.snappedf(COLLISION_GRID_STEP_METERS)
		if _collision_field.global_position != field_position:
			_collision_field.global_position = field_position
