class_name ItemCatalog
extends RefCounted
## Reads item definition Resources authored in the Godot editor.

const CONTENT_DIRECTORY := "res://data/items"

## Definitions keyed by their authored, case-preserving IDs in filename order.
var records: Dictionary[String, ItemDefinition] = {}
## Diagnostics from the most recent load, including the affected file.
var errors: PackedStringArray = []


## Reloads the catalog, keeping valid definitions and reporting rejected files.
func load_from_directory(path: String = CONTENT_DIRECTORY) -> void:
	records.clear()
	errors.clear()
	if not DirAccess.dir_exists_absolute(path):
		errors.append("%s: Cannot open item directory." % path)
		return

	var files := ResourceLoader.list_directory(path)
	files.sort()
	var seen_ids: Dictionary[String, bool] = {}
	for file_name: String in files:
		if file_name.get_extension() == "tres":
			_read_record(path.path_join(file_name), seen_ids)


func _read_record(path: String, seen_ids: Dictionary[String, bool]) -> void:
	var file_name := path.get_file()
	var record := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ItemDefinition
	if record == null:
		errors.append("%s: Expected an ItemDefinition resource." % file_name)
		return

	var error := record.get_validation_error()
	if not error.is_empty():
		errors.append("%s: %s" % [file_name, error])
		return

	var id := String(record.item_id)
	var comparison_id := id.to_lower()
	if seen_ids.has(comparison_id):
		errors.append("%s: Duplicate item ID '%s'." % [file_name, id])
		return
	seen_ids[comparison_id] = true
	records[id] = record
