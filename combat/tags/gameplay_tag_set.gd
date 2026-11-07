class_name GameplayTagSet
extends RefCounted
## Reference-counted actor tags with hierarchical queries and no per-tag assets.

signal changed(tag: StringName, present: bool)

var _counts: Dictionary[StringName, int] = {}


func add_tag(tag: StringName) -> void:
	if _increment_tag(tag):
		changed.emit(tag, true)


## Makes every granted tag visible before any synchronous change listener runs.
func add_tags(tags: PackedStringArray) -> void:
	var newly_present: Array[StringName] = []
	for value in tags:
		var tag := StringName(value)
		if _increment_tag(tag):
			newly_present.append(tag)
	for tag in newly_present:
		if _counts.has(tag):
			changed.emit(tag, true)


func remove_tag(tag: StringName) -> void:
	var previous: int = _counts.get(tag, 0)
	if previous <= 0:
		return
	if previous == 1:
		_counts.erase(tag)
		changed.emit(tag, false)
	else:
		_counts[tag] = previous - 1


func has_tag(query: StringName) -> bool:
	if query.is_empty():
		return false
	for tag: StringName in _counts:
		if matches(tag, query):
			return true
	return false


## Returns true for an exact tag or a descendant of the nonempty query.
static func matches(tag: StringName, query: StringName) -> bool:
	return not query.is_empty() and (tag == query or String(tag).begins_with(String(query) + "."))


func has_any(queries: PackedStringArray) -> bool:
	for query: String in queries:
		if has_tag(StringName(query)):
			return true
	return false


func has_all(queries: PackedStringArray) -> bool:
	for query: String in queries:
		if not has_tag(StringName(query)):
			return false
	return true


func get_tags() -> PackedStringArray:
	var result := PackedStringArray()
	for tag: StringName in _counts:
		result.append(String(tag))
	result.sort()
	return result


func get_count(tag: StringName) -> int:
	return _counts.get(tag, 0)


func clear() -> void:
	var previous: Array[StringName] = _counts.keys()
	_counts.clear()
	for tag: StringName in previous:
		changed.emit(tag, false)


func _increment_tag(tag: StringName) -> bool:
	if tag.is_empty():
		return false
	var previous: int = _counts.get(tag, 0)
	_counts[tag] = previous + 1
	return previous == 0
