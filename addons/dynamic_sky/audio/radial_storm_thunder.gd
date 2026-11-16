extends Node3D
## Plays the distant thunder bed for its parent Radial Storm.

const SkyLookup = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")
const LEGACY_VOICE_GAIN := 0.7071067812
const PAN_ANGLE := deg_to_rad(40.0)

var _sky: DynamicSky
var _authored_stream: AudioStream
var _paired_recording: bool = false
var _voice_gains: Vector2 = Vector2.ONE * LEGACY_VOICE_GAIN
var _rng := RandomNumberGenerator.new()

@onready var _storm := get_parent() as DynamicSkyRadialStorm
@onready var _voices: Array[AudioStreamPlayer3D] = [$Left, $Right]


func _process(_delta: float) -> void:
	if _storm == null:
		return
	if _authored_stream != _storm.thunder_stream:
		_set_stream(_storm.thunder_stream)
	var strength := _storm.get_thunder_strength()
	if not _storm.enabled or not _storm.thunder_enabled or _voices[0].stream == null or strength <= 0.0:
		_stop()
		return

	_sky = SkyLookup.resolve(self, null, _sky)
	if (
		_sky == null or _sky.weather_style != DynamicSky.WeatherStyle.REALISTIC
		or not _sky.accepts_weather_profile(_storm.weather)
	):
		_stop()
		return
	var listener := _get_listener()
	if listener == null or not listener.get_viewport().is_audio_listener_3d():
		_stop()
		return
	var center := _storm.global_position
	center.y = _sky.global_position.y + 1000.0 * _sky._get_cloud_layer_value(&"cloud_base_km", 0.60)
	var eye := listener.global_position
	var offset := center - eye
	var falloff := clampf(1.0 - offset.length() / maxf(_storm.thunder_range, 1.0), 0.0, 1.0)
	var gain := _storm.thunder_gain * _storm.get_effective_alpha() * strength * falloff * falloff
	for index in _voices.size():
		var voice := _voices[index]
		var angle := -PAN_ANGLE if index == 0 else PAN_ANGLE
		voice.global_position = eye + offset.rotated(Vector3.UP, angle)
		voice.volume_linear = gain * _voice_gains[index]
	_start_voices()


func _start_voices() -> void:
	if not _paired_recording:
		for voice in _voices:
			if not voice.playing:
				voice.play(_random_phase(voice.stream))
		return

	var left := _voices[0]
	var right := _voices[1]
	if left.playing and right.playing:
		return
	var phase: float
	if left.playing:
		phase = left.get_playback_position()
	elif right.playing:
		phase = right.get_playback_position()
	else:
		phase = _random_phase(left.stream)
	for voice in _voices:
		if not voice.playing:
			voice.play(phase)


func _random_phase(stream: AudioStream) -> float:
	var duration := stream.get_length()
	return fposmod(_rng.randf_range(0.0, 90.0), duration) if duration > 0.0 else 0.0


func _get_listener() -> Node3D:
	if _sky == null:
		return null
	var explicit := _sky.audio_listener
	if is_instance_valid(explicit) and explicit.is_inside_tree() and explicit.get_world_3d() == get_world_3d():
		return explicit
	var viewport := _sky.get_viewport()
	var listener := viewport.get_audio_listener_3d()
	return listener if listener != null else viewport.get_camera_3d()


func _set_stream(stream: AudioStream) -> void:
	_stop()
	_authored_stream = stream
	_paired_recording = false
	_voice_gains = Vector2.ONE * LEGACY_VOICE_GAIN
	var pair := stream as AudioStreamSynchronized
	if pair != null:
		_set_paired_recording(pair)
		return
	var wave := stream as AudioStreamWAV
	if stream != null and wave == null:
		push_warning("Radial Storm thunder requires a WAV or a synchronized pair of mono WAVs.")
	var loop := _looped_wave(wave)
	_voices[0].stream = loop
	_voices[1].stream = loop


func _set_paired_recording(pair: AudioStreamSynchronized) -> void:
	_voices[0].stream = null
	_voices[1].stream = null
	if pair.stream_count == 2:
		var left := _looped_wave(pair.get_sync_stream(0) as AudioStreamWAV)
		var right := _looped_wave(pair.get_sync_stream(1) as AudioStreamWAV)
		if _match_recording_channels(left, right):
			_voices[0].stream = left
			_voices[1].stream = right
			_paired_recording = true
			_voice_gains = Vector2(db_to_linear(pair.get_sync_stream_volume(0)), db_to_linear(pair.get_sync_stream_volume(1)))
			return
	push_warning("Radial Storm thunder requires two mono WAVs with matching duration and forward loops.")


func _match_recording_channels(left: AudioStreamWAV, right: AudioStreamWAV) -> bool:
	if left == null or right == null or left.stereo or right.stereo or left.mix_rate != right.mix_rate:
		return false
	var samples := roundi(left.get_length() * left.mix_rate)
	return (
		samples > 0 and samples == roundi(right.get_length() * right.mix_rate)
		and left.loop_mode == AudioStreamWAV.LOOP_FORWARD and right.loop_mode == AudioStreamWAV.LOOP_FORWARD
		and left.loop_begin == right.loop_begin and left.loop_end == right.loop_end
		and left.loop_begin >= 0 and left.loop_end > left.loop_begin and left.loop_end <= samples
	)


func _looped_wave(stream: AudioStreamWAV) -> AudioStreamWAV:
	if stream == null or stream.loop_mode != AudioStreamWAV.LOOP_DISABLED:
		return stream
	var loop := stream.duplicate() as AudioStreamWAV
	loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end = roundi(loop.get_length() * loop.mix_rate)
	return loop


func _stop() -> void:
	for voice in _voices:
		if voice.playing:
			voice.stop()
