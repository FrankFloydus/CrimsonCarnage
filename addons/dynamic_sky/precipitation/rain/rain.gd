extends GPUParticles3D
## Drives independent near, middle, and distant world-space rain volumes.

var _intensity: float = -1.0
var _wind: Vector2
var _active: bool

@onready var _middle: GPUParticles3D = $MiddleRain
@onready var _distant: GPUParticles3D = $DistantRain
@onready var _spray: GPUParticles3D = $StormSpray


func _ready() -> void:
	_spray.set_instance_shader_parameter(&"impact_lifetime", _spray.lifetime)
	if _intensity >= 0.0:
		_update_layers()


## Applies normalized rain, horizontal wind in m/s, and availability of the viewing camera.
func apply_rain(intensity: float, wind: Vector2, active: bool) -> void:
	var next_intensity := clampf(intensity, 0.0, 1.0)
	if _intensity == next_intensity and _wind == wind and _active == active:
		return
	_intensity = next_intensity
	_wind = wind
	_active = active
	if is_node_ready():
		_update_layers()


func _update_layers() -> void:
	var storm := smoothstep(0.68, 1.0, _intensity) * smoothstep(7.0, 13.5, _wind.length())
	_apply_layer(self, storm)
	_apply_layer(_middle, storm)
	_apply_layer(_distant, storm)


func _apply_layer(layer: GPUParticles3D, storm: float) -> void:
	layer.amount_ratio = _intensity
	var material := layer.process_material as ShaderMaterial
	material.set_shader_parameter(&"wind", _wind)
	material.set_shader_parameter(&"storm", storm)
	layer.set_instance_shader_parameter(&"storm", storm)
	var should_emit := _active and _intensity > 0.0
	if layer.emitting != should_emit:
		layer.emitting = should_emit
