@tool
class_name WeaponAnimationCombo
extends Resource
## An ordered list of AnimationPlayer clips and the transitions between them.

const ClipData := preload("weapon_animation_clip.gd")
const CLIP_BOUNDARY := -1.0
const DEFAULT_BLEND := 0.08

## Name shown in the Tweaker when the combo is loaded.
@export var display_name := ""
## AnimationPlayer keys in playback order, including their library names.
@export var clip_keys: Array[StringName] = []
## Per-step transitions. The final transition joins the last clip to the first.
@export var joins: Array[Dictionary] = []
## Include the final transition when playing the full combo.
@export var loop := true


## Read either the scripted combo or a saved native Crimson Framework combo.
static func from_resource(resource: Resource) -> WeaponAnimationCombo:
	if resource is WeaponAnimationCombo:
		return resource
	if resource == null or resource.get_class() != &"CrimsonWeaponAnimationCombo":
		return null
	var converted := WeaponAnimationCombo.new()
	converted.display_name = resource.get(&"display_name")
	converted.clip_keys.assign(resource.get(&"clip_keys"))
	converted.joins.assign(resource.get(&"joins"))
	converted.loop = resource.get(&"loop")
	return converted


## Create an independent draft with a separate copy of all join settings.
func copy() -> WeaponAnimationCombo:
	return duplicate(true) as WeaponAnimationCombo


## Set the playback order, retaining transitions whose clip pairs still exist.
func set_clips(keys: Array[StringName]) -> void:
	var updated: Array[Dictionary] = []
	var matched := {}
	for index in keys.size():
		var next_index := (index + 1) % keys.size()
		var join := _default_join()
		for old_index in clip_keys.size():
			var old_next := (old_index + 1) % clip_keys.size()
			if matched.has(old_index):
				continue
			if clip_keys[old_index] == keys[index] and clip_keys[old_next] == keys[next_index]:
				join = get_join(old_index)
				matched[old_index] = true
				break
		updated.append(join)
	clip_keys = keys.duplicate()
	joins = updated
	emit_changed()


## Count the active transitions in the current playback order.
func get_join_count() -> int:
	if clip_keys.size() < 2:
		return 0
	return clip_keys.size() if loop else clip_keys.size() - 1


## Read independent join settings or the default settings for a missing join.
func get_join(index: int) -> Dictionary:
	var join := _default_join()
	if index >= 0 and index < joins.size():
		join.merge(joins[index], true)
	return join


## Update one transition. A named marker takes precedence over its optional time.
## A time of -1 uses the end of the outgoing clip or the start of the incoming clip.
func set_join(
	index: int,
	exit_marker: StringName,
	entry_marker: StringName,
	blend_duration: float,
	exit_time: float = CLIP_BOUNDARY,
	entry_time: float = CLIP_BOUNDARY,
) -> void:
	if index < 0 or index >= clip_keys.size():
		return
	while joins.size() <= index:
		joins.append(_default_join())
	joins[index] = {
		"exit_marker": exit_marker,
		"entry_marker": entry_marker,
		"exit_time": exit_time,
		"entry_time": entry_time,
		"blend_duration": blend_duration,
	}
	emit_changed()


## Resolve an active join against the current AnimationPlayer library and clip markers.
## Returns an "error" message if it cannot be previewed.
func resolve_join(player: AnimationPlayer, index: int) -> Dictionary:
	if index < 0 or index >= get_join_count():
		return {"error": "Choose a transition in the combo."}
	var outgoing := clip_keys[index]
	var incoming := clip_keys[(index + 1) % clip_keys.size()]
	var from_animation := _animation(player, outgoing)
	var to_animation := _animation(player, incoming)
	if from_animation == null:
		return {"error": _clip_error(outgoing)}
	if to_animation == null:
		return {"error": _clip_error(incoming)}

	var join := get_join(index)
	var exit_marker := StringName(join.exit_marker)
	var entry_marker := StringName(join.entry_marker)
	var exit_time := _resolve_time(from_animation, exit_marker, join.exit_time, from_animation.length)
	var entry_time := _resolve_time(to_animation, entry_marker, join.entry_time, 0.0)
	if not _is_clip_time(exit_time, from_animation.length):
		return {"error": _time_error(outgoing, exit_marker, "exit")}
	if not _is_clip_time(entry_time, to_animation.length):
		return {"error": _time_error(incoming, entry_marker, "entry")}
	var blend := float(join.blend_duration)
	if not is_finite(blend) or blend < 0.0:
		return {"error": "Blend duration must be a finite, non-negative number of seconds."}
	return {
		"outgoing_key": outgoing,
		"incoming_key": incoming,
		"outgoing_length": from_animation.length,
		"incoming_length": to_animation.length,
		"exit_marker": exit_marker,
		"entry_marker": entry_marker,
		"exit_time": minf(exit_time, from_animation.length),
		"entry_time": minf(entry_time, to_animation.length),
		"blend_duration": blend,
	}


## Return the first playback problem, or an empty string for a valid combo.
func validate(player: AnimationPlayer) -> String:
	if clip_keys.size() < 2:
		return "Add at least two clips to preview a combo."
	var resolved: Array[Dictionary] = []
	for index in get_join_count():
		var join := resolve_join(player, index)
		if join.has("error"):
			return join.error
		resolved.append(join)
	for index in range(0 if loop else 1, resolved.size()):
		var previous := posmod(index - 1, resolved.size())
		var entry: float = resolved[previous].entry_time
		var exit: float = resolved[index].exit_time
		if entry > exit and not is_equal_approx(entry, exit):
			return 'The entry point for clip %d "%s" follows its exit point.' % [index + 1, clip_keys[index]]
	return ""


static func _default_join() -> Dictionary:
	return {
		"exit_marker": &"",
		"entry_marker": &"",
		"exit_time": CLIP_BOUNDARY,
		"entry_time": CLIP_BOUNDARY,
		"blend_duration": DEFAULT_BLEND,
	}


static func _animation(player: AnimationPlayer, key: StringName) -> Animation:
	if player == null or not player.has_animation(key):
		return null
	var animation := player.get_animation(key)
	if animation == null or not is_finite(animation.length) or animation.length <= 0.0:
		return null
	return animation


static func _resolve_time(animation: Animation, marker: StringName, seconds: float, boundary: float) -> float:
	if marker != &"":
		var data := ClipData.from_animation(animation)
		return data.get_marker_time(marker) if data != null else -1.0
	return boundary if seconds == CLIP_BOUNDARY else seconds


static func _is_clip_time(seconds: float, length: float) -> bool:
	return is_finite(seconds) and seconds >= 0.0 and (seconds <= length or is_equal_approx(seconds, length))


static func _clip_error(key: StringName) -> String:
	return 'Clip "%s" is unavailable or has no playable duration.' % key


static func _time_error(key: StringName, marker: StringName, endpoint: String) -> String:
	if marker != &"":
		return 'Clip "%s" is missing the Tweaker %s marker "%s".' % [key, endpoint, marker]
	return 'The %s time for clip "%s" is outside its duration.' % [endpoint, key]
