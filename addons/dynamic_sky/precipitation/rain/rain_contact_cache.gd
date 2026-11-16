extends RefCounted
## Publishes sampled opaque rain impacts as position/validity and normal rows for GPU splash births.

var texture: ImageTexture

var _settings: DynamicSkyRainSettings
var _image: Image
var _query := PhysicsRayQueryParameters3D.new()
var _random := RandomNumberGenerator.new()
var _next_path := 0
var _request_budget := 0.0
var _previous_position := Vector3.INF
var _previous_forward := Vector3.FORWARD


func configure(settings: DynamicSkyRainSettings) -> void:
	var count := clampi(settings.splash_cached_paths, 64, 16384)
	var same_resource := _settings == settings
	_settings = settings
	var collision_changed := _query.collision_mask != settings.splash_collision_mask
	_query.collision_mask = settings.splash_collision_mask
	if same_resource and _image != null and _image.get_width() == count:
		if collision_changed:
			clear()
		return
	_image = Image.create_empty(count, 2, false, Image.FORMAT_RGBAF)
	texture = ImageTexture.create_from_image(_image)
	_random.randomize()
	_reset_view()


func clear() -> void:
	_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	texture.update(_image)
	_reset_view()


func update(delta: float, world: World3D, view: Transform3D, wind: Vector2) -> void:
	var forward := -view.basis.z.normalized()
	var translation := view.origin - _previous_position
	var camera_velocity := Vector3.ZERO
	var forward_derivative := Vector3.ZERO
	if _previous_position.is_finite():
		if translation.length_squared() > 16.0 or forward.dot(_previous_forward) < 0.70:
			clear()
		else:
			camera_velocity = translation / maxf(delta, 0.000001)
			forward_derivative = (forward - _previous_forward) / maxf(delta, 0.000001)
	_previous_position = view.origin
	_previous_forward = forward
	# Rain's source camera speed factor uses 555 cm/s and a 3× cap for CPU path replacement.
	var replacement := minf(1.0 + minf(camera_velocity.length(), 20.0) / 5.55 + minf(forward_derivative.length() / 3.0, 3.0), 3.0)
	var count := _image.get_width()
	_request_budget += maxf(_settings.splash_paths_per_second, 1.0) * replacement * delta
	var requested := floori(_request_budget)
	_request_budget -= requested
	if requested == 0:
		return

	# Match the rig's Rain wind mapping, including the upwind offset of the source spawn origin.
	var wind_strength := clampf((wind.length() - 4.0) / 7.7047, 0.0, 1.0)
	var strong_wind := pow(clampf((wind_strength - 0.2) / 0.8, 0.0, 1.0), 2.5)
	var horizontal := wind.normalized() * (9.0 * strong_wind)
	var general_velocity := Vector3(horizontal.x, -7.5, horizontal.y)
	var randomness := lerpf(0.01, 0.228, wind_strength)
	var fall_speeds := _settings.near_layer.fall_speed_range if _settings.near_layer != null else Vector2(4.875, 9.0)
	var camera_lead := (camera_velocity * Vector3(0.2, 0.4, 0.2)).clamp(Vector3.ONE * -50.0, Vector3.ONE * 50.0)
	var spawn_origin := view.origin + forward * maxf(_settings.fall_volume_forward_offset, 0.0) + camera_lead
	spawn_origin -= general_velocity * Vector3(0.3, 0.0, 0.3)
	var space := world.direct_space_state
	var upstream := maxf(_settings.splash_ceiling_check, 0.0)
	var lifetime := maxf(_settings.fall_volume_lifetime, 0.05)
	var facing_normal := clampf(_settings.splash_minimum_facing_normal, 0.0, 1.0)
	var incoming := -general_velocity.normalized()
	for _sample in mini(requested, count):
		var start := _spawn_position(spawn_origin, forward)
		var velocity := _specific_velocity(general_velocity, randomness, fall_speeds / 7.5)
		_query.from = start - velocity.normalized() * upstream
		_query.to = start + velocity * lifetime
		var hit := space.intersect_ray(_query)
		var position: Vector3 = hit.get(&"position", Vector3.ZERO)
		var normal: Vector3 = hit.get(&"normal", Vector3.ZERO)
		var valid := not hit.is_empty() and _query.from.distance_to(position) > upstream and normal.dot(incoming) > facing_normal
		_image.set_pixel(_next_path, 0, Color(position.x, position.y, position.z, float(valid)))
		_image.set_pixel(_next_path, 1, Color(normal.x, normal.y, normal.z, 0.0))
		_next_path = (_next_path + 1) % count
	texture.update(_image)


func _reset_view() -> void:
	_next_path = 0
	_request_budget = 0.0
	_previous_position = Vector3.INF


func _spawn_position(origin: Vector3, forward: Vector3) -> Vector3:
	var horizontal := Vector2(forward.x, forward.z)
	var horizontal_length := horizontal.length()
	var direction := horizontal.normalized() if horizontal_length >= 0.02 else Vector2.RIGHT
	var wide := _random.randf_range(-0.5, 0.5)
	var narrow := _random.randf_range(-0.2, 0.2)
	var bias := pow(maxf(_random.randf(), 0.000001), maxf(_settings.fall_volume_forward_bias, 0.0) * horizontal_length)
	var angle := lerpf(lerpf(narrow, wide, bias), wide, pow(absf(forward.y), 3.0)) * TAU
	direction = direction.rotated(angle)
	var radial_weight := pow(_random.randf(), maxf(_settings.fall_volume_radial_distribution, 0.1))
	var radius := maxf(_settings.fall_volume_radius, 0.1) * lerpf(0.1, 1.0, radial_weight) * sqrt(_random.randf())
	var height := maxf(_settings.fall_volume_height, 0.1) * (_random.randf() - 0.25)
	return origin + Vector3(direction.x * radius, height, direction.y * radius)


func _specific_velocity(general: Vector3, randomness: float, scale_range: Vector2) -> Vector3:
	var scaled := general * _random.randf_range(scale_range.x, scale_range.y)
	var vertical := _random.randf_range(-1.0, 1.0)
	var angle := _random.randf() * TAU
	var horizontal := sqrt(maxf(1.0 - vertical * vertical, 0.0))
	var direction := Vector3(cos(angle) * horizontal, vertical, sin(angle) * horizontal)
	return scaled.lerp(direction * scaled.length(), randomness)
