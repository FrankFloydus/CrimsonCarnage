extends Node3D
## Drives the two emitters in the saved stylized weather scene.

@onready var _rain: GPUParticles3D = $Rain
@onready var _snow: GPUParticles3D = $Snow


func apply_weather(
	active: bool, camera: Camera3D, rain: float, snow: float, wind: Vector2, exposure: float, solar_elevation: float,
	look: Vector2,
) -> void:
	var show_particles := active and camera != null and exposure > 0.001
	visible = show_particles
	if not show_particles:
		_update_emitter(_rain, 0.0, wind, 0.0, look)
		_update_emitter(_snow, 0.0, wind, 0.0, look)
		return
	global_position = camera.get_camera_transform().origin
	var daylight := smoothstep(-0.18, 0.22, solar_elevation)
	_update_emitter(_rain, rain * exposure, wind, daylight, look)
	_update_emitter(_snow, snow * exposure, wind, daylight, look)


func _update_emitter(emitter: GPUParticles3D, amount: float, wind: Vector2, daylight: float, look: Vector2) -> void:
	var active := amount > 0.002
	if active:
		emitter.amount_ratio = clampf(amount, 0.0, 1.0)
		var process := emitter.process_material as ShaderMaterial
		var draw := emitter.material_override as ShaderMaterial
		process.set_shader_parameter(&"wind", wind)
		draw.set_shader_parameter(&"daylight", daylight)
		draw.set_shader_parameter(&"style_scale_opacity", look)
		if emitter == _snow:
			draw.set_shader_parameter(&"flurry_strength", smoothstep(5.0, 12.0, wind.length()))
	if emitter.emitting != active:
		if active:
			emitter.restart()
		emitter.emitting = active
