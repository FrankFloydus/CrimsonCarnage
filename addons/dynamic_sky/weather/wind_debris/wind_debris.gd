class_name DynamicSkyWindDebris
extends Node3D
## Spawns optional world-space leaf, needle, and twig fragments in strong wind.

const COLLISION_GRID_METERS := 3.0
const MIN_EMISSION := 0.001
const PROBE_OFFSETS: Array[float] = [0.0, -0.42, 0.42]

## Enables loose vegetation debris. Dust particles and airborne mist have separate controls.
@export var enabled: bool = false:
	set(value):
		enabled = value
		if is_node_ready():
			if enabled and _strength > MIN_EMISSION:
				set_physics_process(true)
			elif not enabled:
				_hide_debris()

## Uses this camera to place debris. Empty follows the viewport's active camera.
@export var camera_override: Camera3D

## Wind speed below which debris does not spawn, in meters per second.
@export_range(0.0, 40.0, 0.1, "suffix:m/s") var start_wind_speed: float = 7.5

## Wind speed for full authored emission, in meters per second.
@export_range(1.0, 60.0, 0.1, "suffix:m/s") var full_wind_speed: float = 16.5

## Physics layers that shelter the observer from nearby wind debris. Zero skips the ray tests.
@export_flags_3d_physics var shelter_mask: int = 1

## Vertical reach of the roof exposure probes, in meters.
@export_range(0.5, 25.0, 0.1, "suffix:m") var roof_probe_distance: float = 9.0

## Horizontal reach of the probes looking into the wind, in meters.
@export_range(0.5, 25.0, 0.1, "suffix:m") var upwind_probe_distance: float = 6.0

## Real seconds between sets of shelter probes.
@export_range(0.05, 1.0, 0.01, "suffix:s") var shelter_sample_interval: float = 0.13

## Uses the saved GPU heightfield to reject sheltered spawns and settle debris on surfaces.
@export var surface_collision_enabled: bool = true

var _wind: Vector2 = Vector2.ZERO
var _gustiness: float = 0.0
var _strength: float = 0.0
var _openness: float = 1.0
var _target_openness: float = 1.0
var _probe_remaining: float = 0.0
var _camera_id: int = 0
var _linger: float = 0.0
var _max_lifetime: float = 0.0

@onready var _field: GPUParticlesCollisionHeightField3D = $CollisionField
@onready var _layers: Array[GPUParticles3D] = [$Leaves, $Needles, $Twigs]


func _ready() -> void:
	for layer in _layers:
		_max_lifetime = maxf(_max_lifetime, layer.lifetime)
	set_physics_process(enabled and _strength > MIN_EMISSION)


func _physics_process(delta: float) -> void:
	var camera := _get_camera()
	if camera == null:
		_hide_debris()
		set_physics_process(enabled and _strength > MIN_EMISSION)
		return

	global_position = camera.get_camera_transform().origin
	_probe_remaining -= delta
	var changed_camera := camera.get_instance_id() != _camera_id
	if changed_camera or _probe_remaining <= 0.0:
		_target_openness = _sample_exposure(camera)
		_probe_remaining = shelter_sample_interval
		_camera_id = camera.get_instance_id()
		if changed_camera:
			_openness = _target_openness
	_openness = move_toward(_openness, _target_openness, delta * 4.0)

	var amount := _strength * _openness
	var spawning := amount > MIN_EMISSION
	_linger = _max_lifetime if spawning else maxf(_linger - delta, 0.0)
	var visible_debris := spawning or _linger > 0.0
	_update_collision_field(visible_debris and surface_collision_enabled)
	for layer in _layers:
		var process_material := layer.process_material as ShaderMaterial
		var draw_material := layer.material_override as ShaderMaterial
		_write_parameter(process_material, &"wind", _wind)
		_write_parameter(process_material, &"gustiness", _gustiness)
		_write_parameter(draw_material, &"openness", _openness)
		layer.visible = visible_debris
		layer.amount_ratio = amount
		if layer.emitting != spawning:
			layer.emitting = spawning
	if _strength <= MIN_EMISSION and not visible_debris:
		_hide_debris()


## Applies horizontal wind in m/s and local gustiness. Exposure hides local effects without changing wind.
func apply_weather(wind: Vector2, gustiness: float, _delta: float, exposure: float = 1.0) -> void:
	_wind = wind
	_gustiness = clampf(gustiness, 0.0, 1.0)
	var ramp := clampf((wind.length() - start_wind_speed) / maxf(full_wind_speed - start_wind_speed, 0.01), 0.0, 1.0)
	_strength = ramp * ramp * clampf(exposure, 0.0, 1.0)
	if is_node_ready() and exposure <= 0.0:
		_hide_debris()
		return
	if is_node_ready() and enabled and _strength > MIN_EMISSION and not is_physics_processing():
		set_physics_process(true)


func _get_camera() -> Camera3D:
	if is_instance_valid(camera_override) and camera_override.is_inside_tree():
		if camera_override.get_world_3d() == get_world_3d():
			return camera_override
	return get_viewport().get_camera_3d()


func _sample_exposure(camera: Camera3D) -> float:
	if shelter_mask == 0:
		return 1.0
	var excluded: Array[RID] = []
	var ancestor: Node = camera
	while ancestor != null:
		if ancestor is CollisionObject3D:
			excluded.append(ancestor.get_rid())
		ancestor = ancestor.get_parent()
	var origin := camera.get_camera_transform().origin
	var upwind := Vector3(-_wind.x, 0.0, -_wind.y).normalized()
	var roof := _blocked_fraction(origin, Vector3.UP * roof_probe_distance, Vector3.RIGHT, excluded)
	if upwind.is_zero_approx():
		return 1.0 - roof
	var incoming := upwind * upwind_probe_distance + Vector3.UP * 0.45
	var windward := _blocked_fraction(origin, incoming, upwind.cross(Vector3.UP), excluded)
	return (1.0 - roof) * (1.0 - windward)


func _blocked_fraction(origin: Vector3, direction: Vector3, across: Vector3, excluded: Array[RID]) -> float:
	var space := get_world_3d().direct_space_state
	var count := 0.0
	for distance in PROBE_OFFSETS:
		var from := origin + across * distance
		var query := PhysicsRayQueryParameters3D.create(from, from + direction, shelter_mask, excluded)
		query.hit_from_inside = true
		if not space.intersect_ray(query).is_empty():
			count += 1.0
	return count / PROBE_OFFSETS.size()


func _update_collision_field(active: bool) -> void:
	if active:
		var target := global_position.snappedf(COLLISION_GRID_METERS)
		if _field.global_position != target:
			_field.global_position = target
	if _field.visible != active:
		_field.visible = active
		if active and RenderingServer.get_rendering_device() != null:
			RenderingServer.particles_collision_height_field_update(_field.get_base())


func _hide_debris() -> void:
	for layer in _layers:
		layer.emitting = false
		layer.visible = false
		layer.amount_ratio = 0.0
	_field.visible = false
	_linger = 0.0
	_camera_id = 0
	set_physics_process(false)


func _write_parameter(material: ShaderMaterial, parameter: StringName, value: Variant) -> void:
	if material.get_shader_parameter(parameter) != value:
		material.set_shader_parameter(parameter, value)
