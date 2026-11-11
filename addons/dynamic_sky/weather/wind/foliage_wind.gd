@tool
class_name DynamicSkyFoliageWind
extends Node3D
## Attach to geometry whose ShaderMaterial includes foliage_wind.gdshaderinc.

const WindSource = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")
const VELOCITY_PARAMETER := &"dynamic_sky_wind_velocity"
const SETTINGS_PARAMETER := &"dynamic_sky_foliage_settings"

## Optional source for local gusts. Empty uses the first DynamicSky in this World3D.
@export var sky_rig: DynamicSky

## Model-space Y at which roots are anchored. Vertices at or below it stay still.
@export_range(-20.0, 20.0, 0.01, "or_greater", "or_less", "suffix:m") var root_height: float = 0.0

## Model-space height above the root where bend reaches full strength.
@export_range(0.01, 30.0, 0.01, "or_greater", "suffix:m") var flexible_height: float = 2.0

## Full-height displacement in world meters for each meter per second of wind.
@export_range(0.0, 0.2, 0.001, "or_greater") var bend_per_wind_speed: float = 0.018

## Sideways flutter as a fraction of the wind bend. The shader masks it by vertex.
@export_range(0.0, 1.0, 0.01) var flutter: float = 0.25

var _sky: DynamicSky
var _applied_velocity: Vector3 = Vector3.ZERO
var _applied_settings: Vector4 = Vector4.ZERO


func _ready() -> void:
	set_process(not Engine.is_editor_hint())


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var geometry := get_parent() as GeometryInstance3D
	if geometry != null:
		geometry.set_instance_shader_parameter(VELOCITY_PARAMETER, null)
		geometry.set_instance_shader_parameter(SETTINGS_PARAMETER, null)
	_applied_velocity = Vector3.ZERO
	_applied_settings = Vector4.ZERO


func _get_configuration_warnings() -> PackedStringArray:
	if not get_parent() is GeometryInstance3D:
		return ["Place Foliage Wind directly under a MeshInstance3D or MultiMeshInstance3D."]
	return []


func _process(_delta: float) -> void:
	var geometry := get_parent() as GeometryInstance3D
	if geometry == null:
		return
	_sky = WindSource.resolve(self, sky_rig, _sky)
	var velocity := Vector3.ZERO if _sky == null else _sky.get_wind_at(global_position)
	var settings := Vector4(root_height, flexible_height, bend_per_wind_speed, flutter)
	if not settings.is_equal_approx(_applied_settings):
		geometry.set_instance_shader_parameter(SETTINGS_PARAMETER, settings)
		_applied_settings = settings
	if not velocity.is_equal_approx(_applied_velocity):
		geometry.set_instance_shader_parameter(VELOCITY_PARAMETER, velocity)
		_applied_velocity = velocity
