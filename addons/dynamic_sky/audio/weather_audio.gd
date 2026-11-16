extends Node3D
## Mixes spatial weather beds and propagating thunder for the local listener.

const THUNDER_VOICE := preload("res://addons/dynamic_sky/audio/thunder_voice.tscn")
const CARDINAL_WEATHER_BEDS := preload("res://addons/dynamic_sky/audio/cardinal_weather_beds.tscn")
const WeatherAudioPortal := preload("res://addons/dynamic_sky/audio/weather_audio_portal.gd")
const WeatherState := preload("res://addons/dynamic_sky/weather/weather_state.gd")
const CardinalOcclusion := preload("res://addons/dynamic_sky/audio/cardinal_occlusion.gd")
const CardinalWeatherBeds := preload("res://addons/dynamic_sky/audio/cardinal_weather_beds.gd")
const SILENT_GAIN := 0.0001
const AUDIBLE_INTENSITY := 0.001
const RAY_SAMPLES: Array[float] = [0.0, -1.0, 1.0]

## Overrides where weather audio is sampled. Empty uses the viewport's audio listener or camera.
@export var listener_override: Node3D

## Physics layers that block the path from outdoor sound to the listener. Zero ignores shelter.
@export_flags_3d_physics var occlusion_mask: int = 1

## Enables directional Rain and Wind beds and a 48-ray shelter sample every 0.55 seconds.
@export var use_cardinal_occlusion: bool = false:
	set(value):
		if use_cardinal_occlusion == value:
			return
		use_cardinal_occlusion = value
		_probe_remaining = 0.0
		_cardinal_mix_initialized = false

## How far the default roof and upwind rays search for shelter, in meters.
@export_range(1.0, 100.0, 0.5, "suffix:m") var cover_probe_distance: float = 24.0

## Spacing of neighboring cover rays, in meters. Larger values soften the transition at edges.
@export_range(0.1, 3.0, 0.05, "suffix:m") var cover_probe_spread: float = 0.55

## Real seconds between samples in the default roof and upwind mode.
@export_range(0.05, 1.0, 0.01, "suffix:s") var cover_sample_interval: float = 0.12

## Real seconds for weather and shelter changes to settle in the mix.
@export_range(0.05, 2.0, 0.01, "suffix:s") var mix_response_seconds: float = 0.32

## Wind speed in meters per second at which the wind layer reaches its authored volume.
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var full_wind_speed: float = 12.0

## Sound propagation speed in meters per second. Used to delay thunder after a strike.
@export_range(200.0, 450.0, 1.0, "suffix:m/s") var speed_of_sound: float = 343.0

## Maximum distance from which thunder can be heard, in meters.
@export_range(50.0, 10000.0, 10.0, "or_greater", "suffix:m") var thunder_range: float = 6400.0


class PortalOpenings:
	var legacy: Vector2 = Vector2.ZERO
	var cardinal: Vector4 = Vector4.ZERO


var _wind: Vector2 = Vector2.ZERO
var _source_wind_strength: float = 0.0
var _wind_gust: float = 1.0
var _intensity: Vector4 = Vector4.ZERO
var _mixed_intensity: Vector4 = Vector4.ZERO
var _cover: Vector2 = Vector2.ZERO
var _target_cover: Vector2 = Vector2.ZERO
var _cardinal_cover: Vector4 = Vector4.ZERO
var _target_cardinal_cover: Vector4 = Vector4.ZERO
var _rain_portal_openness: float = 0.0
var _target_rain_portal_openness: float = 0.0
var _close_rain_cover: float = 0.0
var _target_close_rain_cover: float = 0.0
var _cardinal_mix_initialized: bool = false
var _probe_remaining: float = 0.0
var _listener_id: int = 0
var _tree_generation: int = 0
var _underwater: bool = false
var _cardinal_sampler: CardinalOcclusion
var _cardinal_beds: CardinalWeatherBeds
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
	if is_instance_valid(_cardinal_beds):
		_cardinal_beds.stop_beds()
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
		_cardinal_mix_initialized = false
		_update_beds()
		return

	var upwind := Vector3(-_wind.x, 0.0, -_wind.y).normalized()
	_ambience.global_position = listener.global_position
	_emitters[2].position = _directional_position(_upwind_offset[2], upwind)
	_emitters[3].position = _directional_position(_upwind_offset[3], upwind)

	var new_listener := listener.get_instance_id() != _listener_id
	if _underwater:
		_target_cover = Vector2.ONE
		_target_cardinal_cover = Vector4.ONE
		_target_rain_portal_openness = 0.0
		_target_close_rain_cover = 1.0
	elif _intensity != Vector4.ZERO or _mixed_intensity.length_squared() > AUDIBLE_INTENSITY:
		_probe_remaining -= delta
		if _probe_remaining <= 0.0 or new_listener:
			_target_cover = _sample_cover(listener, upwind)
			var snap := new_listener or _mixed_intensity.is_zero_approx()
			if snap:
				_cover = _target_cover
			if use_cardinal_occlusion and (snap or not _cardinal_mix_initialized):
				_cardinal_cover = _target_cardinal_cover
				_rain_portal_openness = _target_rain_portal_openness
				_close_rain_cover = _target_close_rain_cover
				_cardinal_mix_initialized = true
			_probe_remaining = CardinalOcclusion.UPDATE_PERIOD if use_cardinal_occlusion else cover_sample_interval
	else:
		_probe_remaining = 0.0
	_listener_id = listener.get_instance_id()

	var blend := minf(delta / maxf(mix_response_seconds, 0.001), 1.0)
	_cover = _cover.move_toward(_target_cover, blend)
	_mixed_intensity = _mixed_intensity.lerp(_intensity, blend)
	if use_cardinal_occlusion:
		_cardinal_cover = _cardinal_cover.lerp(_target_cardinal_cover, blend)
		_rain_portal_openness = lerpf(_rain_portal_openness, _target_rain_portal_openness, blend)
		_close_rain_cover = lerpf(_close_rain_cover, _target_close_rain_cover, blend)
	_update_beds(listener.get_viewport().is_audio_listener_3d())


## Sets rain, snow and dust intensity from zero to one, and horizontal wind velocity in m/s.
## Optional source strength (0–10) and longitudinal gust keep global wind cues independent of turbulence.
func apply_weather(
	rain: float, snow: float, dust: float, wind: Vector2, source_strength: float = -1.0, gust: float = 1.0,
) -> void:
	_wind = wind
	_source_wind_strength = clampf(source_strength, 0.0, 10.0) if source_strength >= 0.0 else WeatherState.source_wind_strength(wind)
	_wind_gust = maxf(gust, 0.0)
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
		_target_cardinal_cover = Vector4.ONE
		_cardinal_cover = Vector4.ONE
		_target_rain_portal_openness = 0.0
		_rain_portal_openness = 0.0
		_target_close_rain_cover = 1.0
		_close_rain_cover = 1.0
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
		_target_cardinal_cover = Vector4.ZERO
		_target_rain_portal_openness = 0.0
		_target_close_rain_cover = 0.0
		return Vector2.ZERO
	var origin := listener.global_position
	var exclude := _listener_colliders(listener)
	if use_cardinal_occlusion:
		if _cardinal_sampler == null:
			_cardinal_sampler = CardinalOcclusion.new()
		var openness := _cardinal_sampler.sample(get_world_3d().direct_space_state, origin, occlusion_mask, exclude)
		var cover := Vector2(1.0 - openness.upward, 1.0 - openness.in_direction(upwind))
		var openings := _sample_portal_openings(origin, upwind, exclude)
		_target_cardinal_cover = (Vector4.ONE - openness.cardinal - openings.cardinal).clamp(Vector4.ZERO, Vector4.ONE)
		_target_rain_portal_openness = minf(openings.legacy.x, 1.0)
		var global_openness := maxf(openness.global_open + openings.legacy.x, minf(openness.upward, 0.7))
		_target_close_rain_cover = 1.0 - minf(global_openness, 1.0)
		return (cover - openings.legacy).clamp(Vector2.ZERO, Vector2.ONE)
	var roof := _blocked_fraction(origin, origin + Vector3.UP * cover_probe_distance, exclude)
	var wind_cover := roof * 0.5
	if not upwind.is_zero_approx():
		var end := origin + upwind * cover_probe_distance + Vector3.UP
		wind_cover = maxf(wind_cover, _blocked_fraction(origin, end, exclude))
	var cover := Vector2(roof, wind_cover)
	if not cover.is_zero_approx():
		cover -= _sample_portal_openings(origin, upwind, exclude).legacy
	return cover.clamp(Vector2.ZERO, Vector2.ONE)


func _sample_portal_openings(origin: Vector3, upwind: Vector3, exclude: Array[RID]) -> PortalOpenings:
	var openings := PortalOpenings.new()
	var world := get_world_3d()
	for node in get_tree().get_nodes_in_group(WeatherAudioPortal.GROUP):
		var portal := node as WeatherAudioPortal
		if portal == null or portal.get_world_3d() != world:
			continue
		var offset := portal.global_position - origin
		var openness := portal.openness_at(offset.length())
		if openness.is_zero_approx():
			continue
		var heading := Vector3(offset.x, 0.0, offset.z).normalized()
		var upwind_openness := openness.y * maxf(upwind.dot(heading), 0.0)
		if not use_cardinal_occlusion and is_zero_approx(openness.x) and is_zero_approx(upwind_openness):
			continue
		if not offset.is_zero_approx():
			var query := PhysicsRayQueryParameters3D.create(portal.global_position, origin, occlusion_mask, exclude)
			query.hit_from_inside = true
			if not world.direct_space_state.intersect_ray(query).is_empty():
				continue
		openings.legacy += Vector2(openness.x, upwind_openness)
		if use_cardinal_occlusion:
			var projection := Vector4(heading.x, -heading.x, heading.z, -heading.z)
			openings.cardinal += openness.y * projection.max(Vector4.ZERO)
	return openings


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


func _update_beds(close_rain_enabled: bool = false) -> void:
	for index in _emitters.size():
		var intensity := _mixed_intensity[index]
		var shelter := _cover.x if index < 2 else _cover.y
		var open := _open_players[index]
		var sheltered := _sheltered_players[index]
		var replaced_by_cardinal := use_cardinal_occlusion and (index == 0 or index == 2)
		var dry := intensity <= AUDIBLE_INTENSITY and _intensity[index] <= AUDIBLE_INTENSITY
		if _listener_id == 0 or replaced_by_cardinal or dry:
			if open.playing:
				open.stop()
				sheltered.stop()
			continue
		open.volume_linear = maxf(intensity * (1.0 - shelter) * _open_gain[index], SILENT_GAIN)
		sheltered.volume_linear = maxf(intensity * shelter * _sheltered_gain[index], SILENT_GAIN)
		if not open.playing and intensity > AUDIBLE_INTENSITY:
			open.play()
			sheltered.play()
	_update_cardinal_beds(close_rain_enabled)


func _update_cardinal_beds(close_rain_enabled: bool) -> void:
	if not use_cardinal_occlusion or _listener_id == 0:
		if is_instance_valid(_cardinal_beds):
			_cardinal_beds.stop_beds()
		return
	if not is_instance_valid(_cardinal_beds):
		if maxf(_mixed_intensity.x, _mixed_intensity.z) <= AUDIBLE_INTENSITY:
			return
		_cardinal_beds = CARDINAL_WEATHER_BEDS.instantiate() as CardinalWeatherBeds
		add_child(_cardinal_beds)
		_cardinal_beds.global_basis = Basis.IDENTITY
	_cardinal_beds.global_position = _ambience.global_position
	var rain_cover := (_cardinal_cover - Vector4.ONE * _rain_portal_openness).max(Vector4.ZERO)
	_cardinal_beds.apply_mix(
		_mixed_intensity.x, _mixed_intensity.z, rain_cover, _cardinal_cover, _close_rain_cover, _wind,
		close_rain_enabled, _source_wind_strength, _wind_gust,
	)


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
