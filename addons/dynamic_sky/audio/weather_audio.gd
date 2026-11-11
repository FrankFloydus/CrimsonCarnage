extends Node3D
## Mixes spatial weather beds and propagating thunder for the local listener.

const THUNDER_VOICE := preload("res://addons/dynamic_sky/audio/thunder_voice.tscn")
const SILENT_GAIN := 0.0001
const AUDIBLE_INTENSITY := 0.001
const RAY_SAMPLES: Array[float] = [0.0, -1.0, 1.0]

## Overrides where weather audio is sampled. Empty uses the viewport's audio listener or camera.
@export var listener_override: Node3D

## Physics layers that block the path from outdoor sound to the listener. Zero ignores shelter.
@export_flags_3d_physics var occlusion_mask: int = 1

## How far roof and upwind rays search for shelter, in meters.
@export_range(1.0, 100.0, 0.5, "suffix:m") var cover_probe_distance: float = 24.0

## Spacing of neighboring cover rays, in meters. Larger values soften the transition at edges.
@export_range(0.1, 3.0, 0.05, "suffix:m") var cover_probe_spread: float = 0.55

## Real seconds between cover samples.
@export_range(0.05, 1.0, 0.01, "suffix:s") var cover_sample_interval: float = 0.12

## Real seconds for weather and shelter changes to settle in the mix.
@export_range(0.05, 2.0, 0.01, "suffix:s") var mix_response_seconds: float = 0.32

## Wind speed in meters per second at which the wind layer reaches its authored volume.
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var full_wind_speed: float = 12.0

## Sound propagation speed in meters per second. Used to delay thunder after a strike.
@export_range(200.0, 450.0, 1.0, "suffix:m/s") var speed_of_sound: float = 343.0

## Maximum distance from which thunder can be heard, in meters.
@export_range(50.0, 10000.0, 10.0, "or_greater", "suffix:m") var thunder_range: float = 6400.0

var _wind: Vector2 = Vector2.ZERO
var _intensity: Vector4 = Vector4.ZERO
var _mixed_intensity: Vector4 = Vector4.ZERO
var _cover: Vector2 = Vector2.ZERO
var _target_cover: Vector2 = Vector2.ZERO
var _probe_remaining: float = 0.0
var _listener_id: int = 0
var _tree_generation: int = 0
var _underwater: bool = false
var _open_players: Array[AudioStreamPlayer3D] = []
var _sheltered_players: Array[AudioStreamPlayer3D] = []
var _open_gain: Array[float] = []
var _sheltered_gain: Array[float] = []
var _upwind_offset: Array[Vector3] = []
var _rng := RandomNumberGenerator.new()

@onready var _ambience: Node3D = $Ambience
@onready var _emitters: Array[Node3D] = [$Ambience/Rain, $Ambience/Snow, $Ambience/Wind, $Ambience/Dust]


func _ready() -> void:
	for emitter in _emitters:
		var open := emitter.get_node(^"Open") as AudioStreamPlayer3D
		var sheltered := emitter.get_node(^"Sheltered") as AudioStreamPlayer3D
		_open_players.append(open)
		_sheltered_players.append(sheltered)
		_open_gain.append(open.volume_linear)
		_sheltered_gain.append(sheltered.volume_linear)
		_upwind_offset.append(emitter.position)


func _exit_tree() -> void:
	_tree_generation += 1
	_listener_id = 0
	_mixed_intensity = Vector4.ZERO
	for index in _open_players.size():
		_open_players[index].stop()
		_sheltered_players[index].stop()
	for voice in get_children():
		if voice.scene_file_path != THUNDER_VOICE.resource_path:
			continue
		(voice.get_node(^"Open") as AudioStreamPlayer3D).stop()
		(voice.get_node(^"Sheltered") as AudioStreamPlayer3D).stop()
		voice.queue_free()


func _physics_process(delta: float) -> void:
	var listener := _get_listener()
	if listener == null:
		_listener_id = 0
		_mixed_intensity = Vector4.ZERO
		_update_beds()
		return

	var upwind := Vector3(-_wind.x, 0.0, -_wind.y).normalized()
	_ambience.global_position = listener.global_position
	_emitters[2].position = _directional_position(_upwind_offset[2], upwind)
	_emitters[3].position = _directional_position(_upwind_offset[3], upwind)

	var new_listener := listener.get_instance_id() != _listener_id
	if _underwater:
		_target_cover = Vector2.ONE
	elif _intensity != Vector4.ZERO or _mixed_intensity.length_squared() > AUDIBLE_INTENSITY:
		_probe_remaining -= delta
		if _probe_remaining <= 0.0 or new_listener:
			_target_cover = _sample_cover(listener, upwind)
			if new_listener or _mixed_intensity.is_zero_approx():
				_cover = _target_cover
			_probe_remaining = cover_sample_interval
	else:
		_probe_remaining = 0.0
	_listener_id = listener.get_instance_id()

	var blend := minf(delta / maxf(mix_response_seconds, 0.001), 1.0)
	_cover = _cover.move_toward(_target_cover, blend)
	_mixed_intensity = _mixed_intensity.lerp(_intensity, blend)
	_update_beds()


## Sets rain, snow and dust intensity from zero to one, and horizontal wind velocity in m/s.
func apply_weather(rain: float, snow: float, dust: float, wind: Vector2) -> void:
	_wind = wind
	_intensity = Vector4(
		clampf(rain, 0.0, 1.0),
		clampf(snow, 0.0, 1.0),
		clampf(wind.length() / maxf(full_wind_speed, 0.001), 0.0, 1.0),
		clampf(dust, 0.0, 1.0),
	)


## Forces the sheltered mix underwater without changing authored ray masks or mix settings.
## Delayed thunder uses the listener's underwater state when the sound arrives.
func set_underwater(underwater: bool) -> void:
	if _underwater == underwater:
		return
	_underwater = underwater
	_probe_remaining = 0.0
	if underwater:
		_target_cover = Vector2.ONE
		_cover = Vector2.ONE
	elif is_inside_tree():
		# Re-sample the current observer immediately on the next physics update.
		_listener_id = 0
	if is_node_ready():
		_update_beds()


## Schedules a spatial thunder roll from a strike. Intensity is normalized from zero to one.
func play_thunder(world_position: Vector3, intensity: float = 1.0) -> void:
	if not is_inside_tree() or intensity <= 0.0:
		return
	var listener := _get_listener()
	if listener == null:
		return
	var distance := listener.global_position.distance_to(world_position)
	if distance >= thunder_range:
		return
	var delay := distance / maxf(speed_of_sound, 1.0)
	var arrival := get_tree().create_timer(delay, false, true)
	arrival.timeout.connect(_play_arrived_thunder.bind(world_position, intensity, _tree_generation), CONNECT_ONE_SHOT)


func _get_listener() -> Node3D:
	if is_instance_valid(listener_override) and listener_override.is_inside_tree():
		if listener_override.get_world_3d() == get_world_3d():
			return listener_override
	var viewport := get_viewport()
	var listener := viewport.get_audio_listener_3d()
	if listener != null:
		return listener
	return viewport.get_camera_3d()


func _directional_position(authored_offset: Vector3, upwind: Vector3) -> Vector3:
	var horizontal_distance := Vector2(authored_offset.x, authored_offset.z).length()
	return upwind * horizontal_distance + Vector3.UP * authored_offset.y


func _sample_cover(listener: Node3D, upwind: Vector3) -> Vector2:
	if occlusion_mask == 0:
		return Vector2.ZERO
	var origin := listener.global_position
	var exclude := _listener_colliders(listener)
	var roof := _blocked_fraction(origin, origin + Vector3.UP * cover_probe_distance, exclude)
	var wind_cover := roof * 0.5
	if not upwind.is_zero_approx():
		var end := origin + upwind * cover_probe_distance + Vector3.UP
		wind_cover = maxf(wind_cover, _blocked_fraction(origin, end, exclude))
	return Vector2(roof, wind_cover)


func _blocked_fraction(from: Vector3, to: Vector3, exclude: Array[RID]) -> float:
	var direction := to - from
	if occlusion_mask == 0 or direction.length_squared() < 0.01:
		return 0.0
	var across := direction.cross(Vector3.UP).normalized()
	if across.is_zero_approx():
		across = Vector3.RIGHT
	var state := get_world_3d().direct_space_state
	var blocked := 0.0
	for sample in RAY_SAMPLES:
		var offset := across * (sample * cover_probe_spread)
		var query := PhysicsRayQueryParameters3D.create(from + offset, to + offset, occlusion_mask, exclude)
		query.hit_from_inside = true
		if not state.intersect_ray(query).is_empty():
			blocked += 1.0
	return blocked / RAY_SAMPLES.size()


func _listener_colliders(listener: Node3D) -> Array[RID]:
	var exclude: Array[RID] = []
	var ancestor: Node = listener
	while ancestor != null:
		if ancestor is CollisionObject3D:
			exclude.append(ancestor.get_rid())
		ancestor = ancestor.get_parent()
	return exclude


func _update_beds() -> void:
	for index in _emitters.size():
		var intensity := _mixed_intensity[index]
		var shelter := _cover.x if index < 2 else _cover.y
		var open := _open_players[index]
		var sheltered := _sheltered_players[index]
		if _listener_id == 0 or (intensity <= AUDIBLE_INTENSITY and _intensity[index] <= AUDIBLE_INTENSITY):
			if open.playing:
				open.stop()
				sheltered.stop()
			continue
		open.volume_linear = maxf(intensity * (1.0 - shelter) * _open_gain[index], SILENT_GAIN)
		sheltered.volume_linear = maxf(intensity * shelter * _sheltered_gain[index], SILENT_GAIN)
		if not open.playing and intensity > AUDIBLE_INTENSITY:
			open.play()
			sheltered.play()


func _play_arrived_thunder(world_position: Vector3, intensity: float, generation: int) -> void:
	if not is_inside_tree() or generation != _tree_generation:
		return
	var listener := _get_listener()
	if listener == null or listener.global_position.distance_to(world_position) >= thunder_range:
		return
	# Raise the emitter and ray endpoint away from the struck ground surface.
	var source_position := world_position + Vector3.UP * 2.0
	var origin := listener.global_position
	var cover := 1.0 if _underwater else _blocked_fraction(origin, source_position, _listener_colliders(listener))
	var source := THUNDER_VOICE.instantiate() as Node3D
	add_child(source)
	source.global_position = source_position
	var open := source.get_node(^"Open") as AudioStreamPlayer3D
	var sheltered := source.get_node(^"Sheltered") as AudioStreamPlayer3D
	var level := clampf(intensity, 0.0, 1.0)
	var pitch := _rng.randf_range(0.89, 1.10)
	open.max_distance = thunder_range
	sheltered.max_distance = thunder_range
	open.pitch_scale = pitch
	sheltered.pitch_scale = pitch
	open.volume_linear = maxf(open.volume_linear * level * (1.0 - cover), SILENT_GAIN)
	sheltered.volume_linear = maxf(sheltered.volume_linear * level * cover, SILENT_GAIN)
	open.finished.connect(source.queue_free, CONNECT_ONE_SHOT)
	open.play()
	sheltered.play()
