extends RefCounted
## Project files shared by the standalone catalog and authoring commands.

const CATALOG_IGNORED := ["addons", "builds", "exports", "tests"]
const AUTHORING_IGNORED := ["builds", "exports"]
const DEFINITION_EXTENSIONS := ["res", "tres"]
const SCENE_EXTENSIONS := ["scn", "tscn"]
const ICON_EXTENSIONS := ["svg", "png", "webp", "jpg", "jpeg", "bmp", "tga", "dds", "ktx", "exr", "hdr", "ctex"]
const BINARY_HEADER_BYTES := 4096
const BINARY_UID_FLAG := 2


static func collect(
		path: String, paths: Array[String], issues: Array[String],
		extensions: Array = DEFINITION_EXTENSIONS, ignored_directories: Array = CATALOG_IGNORED
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


static func has_script_dependency(path: String) -> bool:
	# Combat definitions have GDScript dependencies. Skip native resources such as materials.
	for dependency: String in ResourceLoader.get_dependencies(path):
		var dependency_path := dependency.get_slice("::", 2) if "::" in dependency else dependency
		if dependency_path.get_extension().to_lower() == "gd":
			return true
	return false


static func composer_assets(issues: Array[String]) -> Dictionary:
	var paths: Array[String] = []
	collect("res://", paths, issues, ICON_EXTENSIONS + SCENE_EXTENSIONS + DEFINITION_EXTENSIONS)
	paths.sort()
	var icons: Array[String] = []
	var projectiles: Array[String] = []
	for path: String in paths:
		var extension := path.get_extension().to_lower()
		if extension in ICON_EXTENSIONS:
			if ResourceLoader.exists(path, "Texture2D"):
				icons.append(path)
		elif extension in SCENE_EXTENSIONS:
			var scene := ResourceLoader.load(path, "PackedScene") as PackedScene
			if scene != null and is_projectile_scene(scene):
				projectiles.append(path)
		elif ResourceLoader.exists(path, "Texture2D") and ResourceLoader.load(path) is Texture2D:
			icons.append(path)
	return {"icons": icons, "projectiles": projectiles}


static func is_projectile_scene(scene: PackedScene) -> bool:
	var state := scene.get_state()
	while state != null:
		if state.get_node_count() > 0:
			for index: int in state.get_node_property_count(0):
				if state.get_node_property_name(0, index) == &"script":
					var script := state.get_node_property_value(0, index) as Script
					while script != null:
						if script.get_global_name() == &"AbilityProjectile":
							return true
						script = script.get_base_script()
					return false
		state = state.get_base_scene_state()
	return false


## Reads the serialized UID. Runtime ResourceLoader only knows UIDs in the imported cache.
static func saved_uid(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ResourceUID.INVALID_ID
	if path.get_extension().to_lower() == "tres":
		var header := file.get_line()
		var uid_prefix := ' uid="'
		var index := header.find(uid_prefix)
		if index >= 0:
			return ResourceUID.text_to_id(header.substr(index + uid_prefix.length()).get_slice('"', 0))
		return ResourceUID.INVALID_ID
	var magic := file.get_buffer(4).get_string_from_ascii()
	var binary_header: PackedByteArray
	if magic == "RSRC":
		binary_header = file.get_buffer(mini(file.get_length() - 4, BINARY_HEADER_BYTES))
	elif magic == "RSCC":
		binary_header = _compressed_header(file)
	if binary_header.size() < 36:
		return ResourceUID.INVALID_ID
	var reader := StreamPeerBuffer.new()
	reader.data_array = binary_header
	reader.big_endian = reader.get_u32() != 0
	# Endian, real precision, major, minor, format, then the length-prefixed resource type.
	reader.seek(20)
	var type_length := reader.get_u32()
	var flags_offset := reader.get_position() + type_length + 8  # Skip the import metadata offset.
	if flags_offset + 12 > reader.get_size():
		return ResourceUID.INVALID_ID
	reader.seek(flags_offset)
	return reader.get_u64() if reader.get_u32() & BINARY_UID_FLAG else ResourceUID.INVALID_ID


static func is_compressed_resource(path: String) -> bool:
	if path.get_extension().to_lower() != "res":
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	return file != null and file.get_buffer(4).get_string_from_ascii() == "RSCC"


static func _compressed_header(file: FileAccess) -> PackedByteArray:
	# Godot binary resources store a table of compressed blocks. The first block holds the UID.
	if file.get_length() < 20:
		return PackedByteArray()
	var mode := file.get_32()
	var block_size := file.get_32()
	var total_size := file.get_32()
	var compressed_size := file.get_32()
	if (mode > FileAccess.COMPRESSION_BROTLI or block_size == 0 or block_size > 1048576
			or total_size == 0 or compressed_size == 0 or compressed_size > 2097152):
		return PackedByteArray()
	var block_count := floori(float(total_size) / block_size) + 1
	var first_block := 16 + block_count * 4
	if first_block + compressed_size > file.get_length():
		return PackedByteArray()
	file.seek(first_block)
	return file.get_buffer(compressed_size).decompress(mini(block_size, total_size), mode)
