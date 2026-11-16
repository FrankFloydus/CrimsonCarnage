class_name DynamicSkyScreenWeather
extends CanvasLayer
## Resolves local exposure and updates a passive weather lens behind the interface.

const PROBE_INTERVAL := 0.15
const PROBE_OFFSETS: Array[Vector2] = [
	Vector2.ZERO, Vector2(-0.38, -0.22), Vector2(0.38, -0.22),
	Vector2(-0.38, 0.22), Vector2(0.38, 0.22),
]

## Sole authoring resource for droplets, frost, heat, and shelter response.
@export var settings: DynamicSkyScreenSettings
## Camera whose lens and shelter are sampled. Empty follows this viewport's current camera.
@export var camera_override: Camera3D

var _camera: Camera3D
var _wetness: float = 0.0
var _frost: float = 0.0
var _heat: float = 0.0
var _exposure: float = 1.0
var _exposure_target: float = 1.0
var _probe_elapsed: float = 0.0
var _travel := Vector2.ZERO

@onready var _copy: BackBufferCopy = $BackBufferCopy
@onready var _effect: ColorRect = $Lens
@onready var _material: ShaderMaterial = _effect.material as ShaderMaterial


func _ready() -> void:
	_effect.hide()
	_copy.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	set_physics_process(false)


## Advances local lens weather after the rig resolves its camera weather.
## Inactive suspends and clears the lens, including frost, for backgrounds such as Space.
func apply_weather(
	rain: float, snow: float, dust: float, wind: Vector2, temperature: float, delta: float,
	active: bool = true, night_grade: Vector2 = Vector2.ZERO,
) -> void:
	if not is_node_ready():
		return
	if not active:
		reset()
		return
	var camera := camera_override
	if not is_instance_valid(camera) or not camera.is_inside_tree():
		camera = get_viewport().get_camera_3d()
	if camera == null:
		reset()
		return
	if settings == null or not settings.enabled:
		reset()
		if night_grade.x > 0.001:
			_effect.show()
			_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
			_material.set_shader_parameter(&"wetness", 0.0)
			_material.set_shader_parameter(&"frost", 0.0)
			_material.set_shader_parameter(&"heat", 0.0)
			_write_night_grade(night_grade)
		return
	if camera != _camera:
		_camera = camera
		_probe_elapsed = PROBE_INTERVAL
		_exposure = 1.0
		_exposure_target = 1.0
	set_physics_process(true)

	var step := maxf(delta, 0.0) if is_finite(delta) else 0.0
	rain = clampf(rain, 0.0, 1.0) if is_finite(rain) else 0.0
	snow = clampf(snow, 0.0, 1.0) if is_finite(snow) else 0.0
	dust = clampf(dust, 0.0, 1.0) if is_finite(dust) else 0.0
	temperature = temperature if is_finite(temperature) else 18.0
	wind = wind if wind.is_finite() else Vector2.ZERO
	_exposure = lerpf(_exposure, _exposure_target, 1.0 - exp(-step * 8.0))
	var upward_view := maxf(-camera.global_basis.z.y, 0.0)
	var lens_rain := rain * _exposure * clampf(0.72 + upward_view * 0.45 + wind.length() * 0.012, 0.0, 1.0)
	var cold := clampf(
		(settings.frost_start_temperature - temperature)
		/ maxf(settings.frost_start_temperature - settings.frost_full_temperature, 0.1),
		0.0, 1.0,
	)
	var wet_target := lens_rain * clampf(settings.maximum_wetness, 0.0, 1.0)
	if settings.droplets_enabled:
		var wetting := lens_rain / maxf(settings.wetting_seconds, 0.1)
		var drying := lerpf(0.24, 2.0, smoothstep(-8.0, 40.0, temperature))
		drying /= maxf(settings.drying_seconds, 0.1)
		_wetness = move_toward(_wetness, wet_target, step * (wetting if wet_target > _wetness else drying))
	else:
		_wetness = 0.0

	if settings.frost_enabled:
		var moisture := maxf(snow * _exposure, maxf(_wetness, lens_rain * 0.6))
		var frost_target := cold * maxf(moisture, _exposure * 0.16)
		if frost_target > _frost:
			_frost = move_toward(_frost, frost_target, cold * step / maxf(settings.freezing_seconds, 0.1))
		elif temperature > settings.frost_start_temperature:
			var thaw := clampf((temperature - settings.frost_start_temperature) / 12.0, 0.08, 2.5)
			_frost = move_toward(_frost, 0.0, thaw * step / maxf(settings.thawing_seconds, 0.1))
		_wetness = maxf(_wetness - cold * _wetness * step * 0.035, 0.0)
	else:
		_frost = 0.0

	var hot := clampf(
		(temperature - settings.heat_start_temperature)
		/ maxf(settings.heat_full_temperature - settings.heat_start_temperature, 0.1),
		0.0, 1.0,
	)
	var heat_target := hot * (1.0 - maxf(rain, snow)) * (1.0 - dust * 0.75) * _exposure
	_heat = move_toward(_heat, heat_target if settings.heat_enabled else 0.0, step * 1.5)
	_advance_lens(camera, wind, step)
	_write_material(camera, night_grade)


## Clears accumulated lens water and ice and suspends the screen copy.
func reset() -> void:
	_wetness = 0.0
	_frost = 0.0
	_heat = 0.0
	_camera = null
	_exposure = 1.0
	_exposure_target = 1.0
	_probe_elapsed = 0.0
	_travel = Vector2.ZERO
	set_physics_process(false)
	if is_node_ready():
		_effect.hide()
		_copy.copy_mode = BackBufferCopy.COPY_MODE_DISABLED


## Wets the exposed lens after leaving water. Call before the normal apply_weather update.
func wet_on_emerge() -> void:
	if settings != null and settings.enabled and settings.droplets_enabled:
		_wetness = clampf(settings.maximum_wetness, 0.0, 1.0)


## Returns wetness, frost, heat, and exposure for gameplay diagnostics.
func get_lens_state() -> Vector4:
	return Vector4(_wetness, _frost, _heat, _exposure)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree() or settings == null:
		return
	_probe_elapsed += delta
	if _probe_elapsed < PROBE_INTERVAL:
		return
	_probe_elapsed = 0.0
	_exposure_target = 1.0
	if settings.shelter_mask == 0 or settings.roof_probe_height <= 0.0:
		return

	var excluded: Array[RID] = []
	var parent: Node = _camera
	while parent != null:
		if parent is CollisionObject3D:
			excluded.append(parent.get_rid())
		parent = parent.get_parent()
	var blocked := 0
	var space := _camera.get_world_3d().direct_space_state
	for offset in PROBE_OFFSETS:
		var origin := _camera.global_position + Vector3(offset.x, 0.0, offset.y)
		var query := PhysicsRayQueryParameters3D.create(
			origin, origin + Vector3.UP * settings.roof_probe_height, settings.shelter_mask, excluded
		)
		if not space.intersect_ray(query).is_empty():
			blocked += 1
	_exposure_target = 1.0 - float(blocked) / float(PROBE_OFFSETS.size())


func _advance_lens(camera: Camera3D, wind: Vector2, delta: float) -> void:
	var gravity := Vector2(Vector3.DOWN.dot(camera.global_basis.x), -Vector3.DOWN.dot(camera.global_basis.y))
	var wind_world := Vector3(wind.x, 0.0, wind.y)
	var film_wind := Vector2(wind_world.dot(camera.global_basis.x), -wind_world.dot(camera.global_basis.y))
	_travel = (_travel + (gravity * 0.038 + film_wind * 0.0007) * delta).posmod(64.0)


func _write_material(camera: Camera3D, night_grade: Vector2) -> void:
	var active := maxf(night_grade.x, maxf(_wetness, maxf(_frost, _heat))) > 0.001
	_effect.visible = active
	_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if active else BackBufferCopy.COPY_MODE_DISABLED
	if not active:
		return
	_write_night_grade(night_grade)
	var size := get_viewport().get_visible_rect().size
	var horizon := -2.0
	var forward := -camera.global_basis.z
	var horizontal := Vector3(forward.x, 0.0, forward.z)
	if camera.projection == Camera3D.PROJECTION_PERSPECTIVE and horizontal.length_squared() > 0.001:
		var point := camera.global_position + horizontal.normalized() * 100.0
		horizon = camera.unproject_position(point).y / maxf(size.y, 1.0)
	var parameters: Dictionary[StringName, Variant] = {
		&"wetness": _wetness,
		&"frost": _frost,
		&"heat": _heat,
		&"droplet_travel": _travel,
		&"horizon": horizon,
		&"droplet_scale": clampf(settings.droplet_scale, 0.25, 3.0),
		&"droplet_refraction": maxf(settings.droplet_refraction_pixels, 0.0) / 1080.0,
		&"frost_opacity": clampf(settings.frost_opacity, 0.0, 1.0),
		&"frost_scale": clampf(settings.frost_scale, 0.25, 4.0),
		&"frost_refraction": maxf(settings.frost_refraction_pixels, 0.0) / 1080.0,
		&"frost_tint": settings.frost_tint,
		&"frost_texture": settings.frost_texture,
		&"heat_refraction": maxf(settings.heat_refraction_pixels, 0.0) / 1080.0,
		&"heat_horizon_width": clampf(settings.heat_horizon_width, 0.04, 0.5),
	}
	for parameter in parameters:
		if _material.get_shader_parameter(parameter) != parameters[parameter]:
			_material.set_shader_parameter(parameter, parameters[parameter])


func _write_night_grade(grade: Vector2) -> void:
	if _material.get_shader_parameter(&"night_grade") != grade:
		_material.set_shader_parameter(&"night_grade", grade)
	var linear_buffer := get_viewport().use_hdr_2d
	if _material.get_shader_parameter(&"night_grade_linear_buffer") != linear_buffer:
		_material.set_shader_parameter(&"night_grade_linear_buffer", linear_buffer)
