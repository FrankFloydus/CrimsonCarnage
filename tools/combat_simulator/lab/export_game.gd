extends SceneTree
## The Python lab retains the pre-2.0 model and cannot export current Godot data.


func _initialize() -> void:
	printerr("COMBAT_LAB_EXPORT_ERROR Combat 2.0 is not supported by the legacy Combat Lab. "
			+ "Use the bundled pre-2.0 snapshot for legacy experiments. "
			+ "Importing the current Godot project requires a simulator migration.")
	quit(1)
