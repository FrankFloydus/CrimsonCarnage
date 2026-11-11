extends MeshInstance3D
## Sends the local weather wind to the lake material.

const WindSource = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")

## Sky rig supplying wind. Empty uses the active rig in this World3D.
@export var sky_rig: DynamicSky

var _sky: DynamicSky
var _wind := Vector2(2.5, 0.8)


func _process(delta: float) -> void:
	if not is_instance_valid(_sky):
		_sky = null
	var explicit_sky: DynamicSky = sky_rig if is_instance_valid(sky_rig) else null
	_sky = WindSource.resolve(self, explicit_sky, _sky)
	if _sky == null:
		return
	var velocity := _sky.get_wind_at(global_position)
	var target := Vector2(velocity.x, velocity.z)
	_wind = _wind.lerp(target, 1.0 - exp(-delta * 1.6))
	set_instance_shader_parameter(&"lake_wind", _wind)
