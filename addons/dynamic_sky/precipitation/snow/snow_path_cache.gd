extends RefCounted
## Maintains the source CPU trajectory fallback in a texture sampled once by each GPU snow birth.

const Settings = preload("res://addons/dynamic_sky/precipitation/snow/snow_settings.gd")

var texture: ImageTexture

var _settings: Settings
var _image: Image
var _random := RandomNumberGenerator.new()
var _next_path := 0
var _request_budget := 0.0
var _pending: Array[Dictionary] = []


func initialize(settings: Settings) -> void:
	_settings = settings
	_image = Image.create_empty(settings.cached_path_count, 3, false, Image.FORMAT_RGBAF)
	texture = ImageTexture.create_from_image(_image)
	_random.randomize()
	_next_path = 0
	_request_budget = 0.0
	_pending.clear()


func update(
	delta: float,
	world: World3D,
	origin: Vector3,
	forward: Vector3,
	general_velocity: Vector3,
	randomness: float,
	collision_enabled: bool,
	motion_multiplier: float = 1.0,
) -> void:
	# Source asynchronous queries publish the preceding frame's batch.
	if not _pending.is_empty():
		for path in _pending:
			var index: int = path[&"index"]
			var start: Vector3 = path[&"start"]
			var end: Vector3 = path[&"end"]
			var normal: Vector3 = path[&"normal"]
			_image.set_pixel(index, 0, Color(start.x, start.y, start.z, path[&"lifetime"]))
			_image.set_pixel(index, 1, Color(end.x, end.y, end.z, float(path[&"valid"])))
			_image.set_pixel(index, 2, Color(normal.x, normal.y, normal.z, float(path[&"hit"])))
		texture.update(_image)
		_pending.clear()

	_request_budget += _settings.cached_paths_per_second * clampf(motion_multiplier, 1.0, 3.0) * delta
	var requests := mini(floori(_request_budget), _settings.cached_path_count)
	_request_budget -= requests
	var space := world.direct_space_state
	for request in requests:
		var start := _spawn_position(origin, forward)
		var velocity := _specific_velocity(general_velocity, randomness)
		_pending.append(_trace_path(space, start, velocity, collision_enabled, _next_path))
		_next_path = (_next_path + 1) % _settings.cached_path_count


func _spawn_position(origin: Vector3, forward: Vector3) -> Vector3:
	var horizontal := Vector2(forward.x, forward.z)
	var horizontal_length := horizontal.length()
	var direction := horizontal.normalized() if horizontal_length >= 0.02 else Vector2(0.0, -1.0)
	var full_angle := _random.randf_range(-0.5, 0.5)
	var narrow_angle := _random.randf_range(-0.2, 0.2)
	var bias_weight := pow(_random.randf(), _settings.forward_bias * horizontal_length)
	var angle := lerpf(narrow_angle, full_angle, bias_weight)
	angle = lerpf(angle, full_angle, pow(absf(forward.y), 3.0))
	direction = direction.rotated(angle * TAU)
	var radius := _settings.spawn_radius_meters * lerpf(
		0.1, 1.0, pow(_random.randf(), _settings.spawn_distribution),
	) * sqrt(_random.randf())
	var height := _settings.spawn_height_meters * (_random.randf() - 0.25)
	return origin + Vector3(direction.x * radius, height, direction.y * radius)


func _specific_velocity(general_velocity: Vector3, randomness: float) -> Vector3:
	var scaled_velocity := general_velocity * _random.randf_range(0.65, 1.2)
	var vertical := _random.randf_range(-1.0, 1.0)
	var angle := _random.randf() * TAU
	var horizontal := sqrt(maxf(0.0, 1.0 - vertical * vertical))
	var random_direction := Vector3(horizontal * cos(angle), vertical, horizontal * sin(angle))
	return scaled_velocity.lerp(random_direction * scaled_velocity.length(), clampf(randomness, 0.0, 1.0))


func _trace_path(
	space: PhysicsDirectSpaceState3D,
	start: Vector3,
	velocity: Vector3,
	collision_enabled: bool,
	index: int,
) -> Dictionary:
	var speed := velocity.length()
	var direction := velocity / maxf(speed, 0.000001)
	var trace_start := start - direction * _settings.ceiling_check_meters
	var trace_end := start + velocity * _settings.maximum_lifetime_seconds
	var hit: Dictionary = {}
	if collision_enabled:
		var query := PhysicsRayQueryParameters3D.create(trace_start, trace_end, _settings.collision_mask)
		hit = space.intersect_ray(query)
	var end: Vector3 = hit.get(&"position", trace_end)
	var valid := hit.is_empty() or trace_start.distance_to(end) > _settings.ceiling_check_meters
	return {
		&"index": index,
		&"start": start,
		&"end": end,
		&"normal": hit.get(&"normal", Vector3.ZERO),
		&"lifetime": start.distance_to(end) / maxf(speed, 0.000001),
		&"valid": valid,
		&"hit": not hit.is_empty(),
	}
