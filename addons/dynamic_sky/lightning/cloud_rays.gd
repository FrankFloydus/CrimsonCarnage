extends MeshInstance3D
## Presents the cloud ray card for a full strike while its independent envelope runs.

const ENVELOPE := preload("res://addons/dynamic_sky/lightning/cloud_ray_envelope.tres")
const CARD_DROP_M := 80.0
const LIFETIME_SCALE := 0.75
const RADIANCE_SCALE := 0.035
const NOISE_AMOUNT := 0.15
const NOISE_SPEED := 5.0

var intensity: float = 1.0:
	set(value):
		intensity = maxf(value, 0.0)
		if intensity == 0.0 and is_node_ready():
			clear()

var envelope: Curve

var _supported: bool = false
var _age: float = 0.0
var _lifetime: float = 0.0
var _phase: float = 0.0
var _cloud_top_m: float = 1000000.0
var _wind: Vector2 = Vector2.ZERO
var _noise := FastNoiseLite.new()

@onready var _material := material_override as ShaderMaterial


func _ready() -> void:
	clear()
	_supported = _material != null and RenderingServer.get_current_rendering_method() == "forward_plus"
	if not _supported:
		return
	_noise.seed = 128021
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	var plane := mesh as PlaneMesh
	if plane != null:
		_material.set_shader_parameter(&"card_half_extent_m", plane.size * 0.5)


func begin(cloud_position: Vector3, strike_duration: float, noise_phase: float) -> void:
	clear()
	if not _supported or intensity <= 0.0 or strike_duration <= 0.0:
		return
	_age = 0.0
	_lifetime = strike_duration * LIFETIME_SCALE
	_phase = noise_phase
	global_position = cloud_position - Vector3.UP * CARD_DROP_M
	_material.set_shader_parameter(&"card_center", global_position)
	_material.set_shader_parameter(&"cloud_top_m", _cloud_top_m)
	_material.set_shader_parameter(&"wind_mps", _wind)
	set_process(true)


func set_environment(cloud_top_m: float, wind: Vector2) -> void:
	if not is_equal_approx(_cloud_top_m, cloud_top_m):
		_cloud_top_m = cloud_top_m
		if is_processing():
			_material.set_shader_parameter(&"cloud_top_m", _cloud_top_m)
	if not _wind.is_equal_approx(wind):
		_wind = wind
		if is_processing():
			_material.set_shader_parameter(&"wind_mps", _wind)


func clear() -> void:
	hide()
	set_process(false)


func _process(delta: float) -> void:
	_age += delta
	if _age >= _lifetime:
		clear()
		return
	var relative_age := _age / _lifetime
	var noise := _noise.get_noise_3d(_age * NOISE_SPEED + _phase, 0.17, 0.53)
	var flicker := 1.0 + clampf(noise * NOISE_AMOUNT, 0.0, 2.0)
	var pulse := ENVELOPE if envelope == null else envelope
	var radiance := pulse.sample(relative_age) * flicker * intensity * RADIANCE_SCALE
	visible = radiance > 0.00001
	if visible:
		_material.set_shader_parameter(&"particle_rgb", radiance)
		_material.set_shader_parameter(&"relative_age", relative_age)
