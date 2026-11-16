@tool
extends RefCounted
## Builds a replacement animation library for Save As without editing its source.


## Return an empty string when the clip name can be added to this library.
static func name_error(library: AnimationLibrary, name: String) -> String:
	if library == null:
		return "Select an animation library."
	if name.strip_edges().is_empty():
		return "Enter a clip name."
	# AnimationLibrary::is_valid_animation_name rejects these four characters.
	for character: String in ["/", ":", ",", "["]:
		if name.contains(character):
			return "Clip names cannot contain slash (/), colon (:), comma (,), or opening bracket ([)."
	if library.has_animation(StringName(name)):
		return 'An animation named "%s" already exists in this library.' % name
	return ""


## Add an independent copy of the draft while retaining existing clip references.
## Return null if the name cannot be added or the draft cannot be copied.
static func make_library(source: AnimationLibrary, name: StringName, draft: Animation) -> AnimationLibrary:
	if draft == null or not name_error(source, String(name)).is_empty():
		return null
	var result := source.duplicate(false) as AnimationLibrary
	var clip := draft.duplicate(true) as Animation
	if result == null or clip == null:
		return null
	clip.resource_name = String(name)
	if result.add_animation(name, clip) != OK:
		return null
	return result
