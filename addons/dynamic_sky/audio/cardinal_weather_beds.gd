extends Node3D
## Mixes the saved Rain and Wind pairs in four fixed world directions.

const SILENT_GAIN := 0.0001
const AUDIBLE_INTENSITY := 0.001
const CLOSE_RAIN_FULL_GAIN := 0.09
const CLOSE_RAIN_SATURATION := 0.4
const SOURCE_WIND_LEAN_DIVISOR := 25.0
const WHISTLE_START_STRENGTH := 6.0
const WHISTLE_FULL_STRENGTH := 10.0
const WHISTLE_MAX_SOURCE_GAIN := 0.7
const WHISTLE_PITCH_OFFSET := -2.0
const SEMITONES_PER_OCTAVE := 12.0
const DIRECTIONS: Array[String] = ["East", "West", "South", "North"]

## Start phases of the east, west, south, and north Rain loops, as fractions of clip duration.
@export var rain_start_phases := Vector4(0.0, 0.25, 0.5, 0.75)

## Start phases of the east, west, south, and north Wind loops, as fractions of clip duration.
@export var wind_start_phases := Vector4(0.0, 0.25, 0.5, 0.75)


class Pair:
	var open
	var sheltered
	var gains: Vector2
	var phase: float

	func _init(emitter: Node, start_phase: float) -> void:
		open = emitter.get_node(^"Open")
		sheltered = emitter.get_node(^"Sheltered")
		gains = Vector2(open.volume_linear, sheltered.volume_linear)
		phase = clampf(start_phase, 0.0, 0.99)

	func update(level: float, cover: float, threshold: float = AUDIBLE_INTENSITY, gain_floor: float = SILENT_GAIN) -> void:
		if level <= threshold:
			stop()
			return
		open.volume_linear = maxf(level * (1.0 - cover) * gains.x, gain_floor)
		sheltered.volume_linear = maxf(level * cover * gains.y, gain_floor)
		if not open.playing and open.stream != null:
			open.play(phase * open.stream.get_length())
		if not sheltered.playing and sheltered.stream != null:
			sheltered.play(phase * sheltered.stream.get_length())

	func stop() -> void:
		if open.playing:
			open.stop()
		if sheltered.playing:
			sheltered.stop()


var _rain: Array[Pair] = []
var _wind: Array[Pair] = []
var _close_rain: Pair
var _whistle: Pair
var _whistle_random := RandomNumberGenerator.new()


func _ready() -> void:
	_close_rain = Pair.new($CloseRain, 0.0)
	_whistle = Pair.new($WindWhistle, 0.0)
	for index in DIRECTIONS.size():
		var direction := DIRECTIONS[index]
		_rain.append(Pair.new(get_node("Rain" + direction), rain_start_phases[index]))
		_wind.append(Pair.new(get_node("Wind" + direction), wind_start_phases[index]))


func apply_mix(
	rain: float,
	wind: float,
	rain_cover: Vector4,
	wind_cover: Vector4,
	close_rain_cover: float,
	wind_velocity: Vector2,
	global_audio_enabled: bool,
	source_wind_strength: float,
	gust: float,
) -> void:
	var close_rain := CLOSE_RAIN_FULL_GAIN * minf(rain / CLOSE_RAIN_SATURATION, 1.0)
	_close_rain.update(close_rain if global_audio_enabled else 0.0, close_rain_cover)
	_update_whistle(source_wind_strength, gust, close_rain_cover, global_audio_enabled)
	var directional_rain := sqrt(maxf(rain * rain - close_rain * close_rain, 0.0))
	_mix_layer(_rain, directional_rain, rain_cover, Vector4.ONE * 0.5)
	# Normalize the four source-shaped directional gains to keep total power stable.
	var lean := -wind_velocity.normalized() * (source_wind_strength / SOURCE_WIND_LEAN_DIVISOR)
	var weights := (Vector4.ONE + Vector4(lean.x, -lean.x, lean.y, -lean.y)).normalized()
	_mix_layer(_wind, wind, wind_cover, weights)


func _update_whistle(source_wind_strength: float, gust: float, cover: float, enabled: bool) -> void:
	var strength := clampf(inverse_lerp(WHISTLE_START_STRENGTH, WHISTLE_FULL_STRENGTH, source_wind_strength), 0.0, 1.0)
	var level := WHISTLE_MAX_SOURCE_GAIN * strength * strength * gust
	if not enabled or level <= 0.0 or is_equal_approx(source_wind_strength, WHISTLE_START_STRENGTH):
		_whistle.stop()
		return
	if not _whistle.open.playing and not _whistle.sheltered.playing and _whistle.open.stream != null:
		var duration: float = _whistle.open.stream.get_length()
		if duration > 0.0:
			_whistle.phase = _whistle_random.randf_range(0.0, minf(15.0, duration * 0.99)) / duration
	var pitch := pow(2.0, gust - 1.0 + WHISTLE_PITCH_OFFSET / SEMITONES_PER_OCTAVE)
	_whistle.open.pitch_scale = pitch
	_whistle.sheltered.pitch_scale = pitch
	_whistle.update(level, cover, 0.0, 0.0000001)


func stop_beds() -> void:
	_close_rain.stop()
	_whistle.stop()
	for index in DIRECTIONS.size():
		_rain[index].stop()
		_wind[index].stop()


func _mix_layer(pairs: Array[Pair], intensity: float, cover: Vector4, weights: Vector4) -> void:
	for index in DIRECTIONS.size():
		pairs[index].update(intensity * weights[index], cover[index])
