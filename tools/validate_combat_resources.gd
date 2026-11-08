extends SceneTree
## Validates ability and effect JSON paths supplied after the -- separator.


func _initialize() -> void:
	var paths := OS.get_cmdline_user_args()
	if paths.is_empty():
		printerr("Pass one or more res:// ability/effect paths after --.")
		quit(2)
		return
	var issues := CombatResourceValidator.validate_paths(paths)
	for issue: String in issues:
		printerr(issue)
	print("Combat resource validation: %d roots, %d issues." % [paths.size(), issues.size()])
	quit(0 if issues.is_empty() else 1)
