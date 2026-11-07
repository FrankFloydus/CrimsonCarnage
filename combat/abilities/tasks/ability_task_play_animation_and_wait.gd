class_name AbilityTaskPlayAnimationAndWait
extends AbilityTask
## Plays an animation through the ASC and observes completion or interruption.

signal completed
signal interrupted
signal cancelled

var _animation_name: StringName
var _playback_rate: float
var _reset_on_end: bool
var _started: bool = false


func _init(animation_name: StringName, playback_rate: float = 1.0,
		reset_on_end: bool = false) -> void:
	_animation_name = animation_name
	_playback_rate = playback_rate
	_reset_on_end = reset_on_end


func _start() -> void:
	var cast := get_cast()
	var system := cast.get_system()
	if system == null or not system.play_cast_animation(
			cast, _playback_rate, _reset_on_end, _animation_name):
		_finish_playback(true)
		return
	_started = true


func _finish_playback(was_interrupted: bool) -> void:
	_started = false
	end_task()
	if was_interrupted:
		interrupted.emit()
	else:
		completed.emit()


func _cleanup() -> void:
	if _started:
		_started = false
		var cast := get_cast()
		if cast != null and cast.get_system() != null:
			cast.get_system().stop_cast_animation(cast)


func _end_from_cast(was_cancelled: bool) -> void:
	end_task()
	if was_cancelled:
		cancelled.emit()
