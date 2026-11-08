extends RefCounted
## Collects saved project files for native authoring checks.

const AUTHORING_IGNORED := ["builds", "exports"]


static func collect(
		path: String, paths: Array[String], issues: Array[String],
		extensions: Array, ignored_directories: Array
) -> void:
	if FileAccess.file_exists(path.path_join(".gdignore")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		issues.append("Could not read folder %s." % path)
		return
	for file_name: String in directory.get_files():
		if file_name.begins_with(".") or directory.is_link(file_name):
			continue
		if file_name.get_extension().to_lower() in extensions:
			paths.append(path.path_join(file_name))
	for folder_name: String in directory.get_directories():
		if folder_name.begins_with(".") or directory.is_link(folder_name):
			continue
		if path == "res://" and folder_name in ignored_directories:
			continue
		collect(path.path_join(folder_name), paths, issues, extensions, ignored_directories)
