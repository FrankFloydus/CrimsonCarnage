extends RefCounted
## Samples finite dust paths for the two GPU emitters through a shared texture.

const PATH_COUNT := 512
const PATHS_PER_SECOND := 1000.0
const SPAWN_RADIUS := 20.0
const MAX_LIFETIME := 2.0
const SPAWN_HEIGHT := 6.0
const CEILING_DISTANCE := 80.0

var texture: ImageTexture
var path_count := 0

var _image: Image
var _rng := RandomNumberGenerator.new()
var _query := PhysicsRayQueryParameters3D.new()
var _next_path := 0
var _request_budget := 0.0


func _init() -> void:
	_image = Image.create_empty(PATH_COUNT, 2, false, Image.FORMAT_RGBAF)
	texture = ImageTexture.create_from_image(_image)
	_rng.randomize()


func reset() -> void:
	path_count = 0
	_next_path = 0
	_request_budget = 0.0
	_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	texture.update(_image)


func update(
	delta: float, space: PhysicsDirectSpaceState3D, origin: Vector3, forward: Vector3,
	general_velocity: Vector3, randomness: float, collision_mask: int, excluded: Array[RID]
) -> void:
	_request_budget += PATHS_PER_SECOND * delta
	var requests := mini(floori(_request_budget), PATH_COUNT)
	_request_budget = minf(_request_budget - requests, 1.0)
	if requests == 0:
		return
	_query.collision_mask = collision_mask
	_query.exclude = excluded
	for index in requests:
		var start := _spawn_position(origin, forward)
		var velocity := _specific_velocity(general_velocity, randomness)
		var end := start + velocity * MAX_LIFETIME
		var lifetime := MAX_LIFETIME
		var valid := true
		if collision_mask != 0 and space != null and velocity.length_squared() > 0.000001:
			_query.from = start - velocity.normalized() * CEILING_DISTANCE
			_query.to = end
			var hit := space.intersect_ray(_query)
			if not hit.is_empty():
				end = hit[&"position"]
				valid = (end - start).dot(velocity) > 0.0
				lifetime = start.distance_to(end) / velocity.length()
		_image.set_pixel(_next_path, 0, Color(start.x, start.y, start.z, lifetime))
		_image.set_pixel(_next_path, 1, Color(end.x, end.y, end.z, float(valid)))
		_next_path = (_next_path + 1) % PATH_COUNT
	path_count = mini(path_count + requests, PATH_COUNT)
	texture.update(_image)


func _spawn_position(origin: Vector3, forward: Vector3) -> Vector3:
	var horizontal := Vector2(forward.x, forward.z)
	var horizontal_length := horizontal.length()
	var direction := horizontal.normalized() if horizontal_length >= 0.02 else Vector2(0.0, -1.0)
	var narrow_angle := _rng.randf_range(-0.2, 0.2)
	var full_angle := _rng.randf_range(-0.5, 0.5)
	var angle := lerpf(narrow_angle, full_angle, pow(_rng.randf(), 0.9 * horizontal_length))
	angle = lerpf(angle, full_angle, pow(absf(forward.y), 3.0))
	direction = direction.rotated(angle * TAU)
	var radius := SPAWN_RADIUS * lerpf(0.1, 1.0, _rng.randf()) * sqrt(_rng.randf())
	var height := SPAWN_HEIGHT * (_rng.randf() - 0.25)
	return origin + Vector3(direction.x * radius, height, direction.y * radius)


func _specific_velocity(general_velocity: Vector3, randomness: float) -> Vector3:
	var scaled := general_velocity * _rng.randf_range(0.8, 1.4)
	var height := _rng.randf_range(-1.0, 1.0)
	var angle := _rng.randf() * TAU
	var horizontal := sqrt(maxf(0.0, 1.0 - height * height))
	var random_direction := Vector3(horizontal * cos(angle), height, horizontal * sin(angle))
	return scaled.lerp(random_direction * scaled.length(), randomness)
