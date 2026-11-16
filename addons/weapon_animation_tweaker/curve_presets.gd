@tool
class_name WeaponAnimationCurvePresets
extends Resource
## Project-wide named curve templates copied independently into each clip.

const ClipTracks := preload("clip_tracks.gd")
const DEFAULT_PATH := "res://data/animation/weapon_curve_presets.tres"

## Saved curve templates. The Tweaker validates and copies these when adding them to a clip.
@export_storage var presets: Array[Dictionary] = []


## Read a fresh catalog. A missing file starts an empty catalog. An unreadable file returns null.
static func load_library(path: String = DEFAULT_PATH) -> WeaponAnimationCurvePresets:
	if not FileAccess.file_exists(path):
		return (load("res://addons/weapon_animation_tweaker/curve_presets.gd") as GDScript).new()
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as WeaponAnimationCurvePresets


## List the saved names in alphabetical order.
func names() -> PackedStringArray:
	var result := PackedStringArray()
	for preset in presets:
		var name: Variant = preset.get("name")
		if name is String and not name.is_empty():
			result.append(name)
	result.sort()
	return result


## Return a copy of a named template, or an empty dictionary for an unknown name.
func get_preset(name: String) -> Dictionary:
	var index := _index_of(name)
	if index < 0:
		return {}
	var tracks := ClipTracks.new()
	if tracks.apply_edit(&"add_curve_preset", {"row": presets[index]}, 1.0) < 0:
		return {}
	return tracks.curve_tracks[0]


## Save a copy of the clip's curve. Require an explicit replacement for an existing name.
func save_preset(curve_row: Dictionary, replace: bool = false, path: String = DEFAULT_PATH) -> Error:
	var tracks := ClipTracks.new()
	if tracks.apply_edit(&"add_curve_preset", {"row": curve_row}, 1.0) < 0:
		return ERR_INVALID_DATA
	var preset := tracks.curve_tracks[0]
	var updated := load_library(path)
	if updated == null:
		return ERR_FILE_CORRUPT
	var index := updated._index_of(preset.name)
	if index >= 0:
		if not replace:
			return ERR_ALREADY_EXISTS
		updated.presets[index] = preset
	else:
		updated.presets.append(preset)
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK:
		return error
	error = ResourceSaver.save(updated, path)
	if error == OK:
		presets = updated.presets
	return error


func _index_of(name: String) -> int:
	for index in presets.size():
		if presets[index].get("name") == name:
			return index
	return -1
