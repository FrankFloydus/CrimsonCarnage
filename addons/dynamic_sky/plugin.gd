@tool
extends EditorPlugin

const SKY_SCENE_PATH := "res://addons/dynamic_sky/dynamic_sky.tscn"
const DEMO_SCENE_PATH := "res://addons/dynamic_sky/demo/dynamic_sky_demo.tscn"
const COMPARISON_SCENE_PATH := "res://addons/dynamic_sky/demo/udw_comparison/udw_demo_map.tscn"
const ADD_SKY_MENU := "Add Dynamic Sky"
const OPEN_DEMO_MENU := "Open Dynamic Sky Demo"
const OPEN_COMPARISON_MENU := "Open UDW Comparison"


func _enter_tree() -> void:
	add_tool_menu_item(ADD_SKY_MENU, _add_dynamic_sky)
	add_tool_menu_item(OPEN_DEMO_MENU, _open_demo)
	add_tool_menu_item(OPEN_COMPARISON_MENU, _open_comparison)


func _exit_tree() -> void:
	remove_tool_menu_item(ADD_SKY_MENU)
	remove_tool_menu_item(OPEN_DEMO_MENU)
	remove_tool_menu_item(OPEN_COMPARISON_MENU)


func _add_dynamic_sky() -> void:
	var scene_root := EditorInterface.get_edited_scene_root() as Node3D
	if scene_root == null:
		EditorInterface.get_editor_toaster().push_toast(
			"Open a scene with a Node3D root to add Dynamic Sky.",
			EditorToaster.SEVERITY_WARNING,
		)
		return
	if (
		scene_root is DirectionalLight3D
		or not scene_root.find_children("*", "WorldEnvironment", true, false).is_empty()
		or not scene_root.find_children("*", "DirectionalLight3D", true, false).is_empty()
	):
		EditorInterface.get_editor_toaster().push_toast(
			"This scene already has a world environment or directional light.",
			EditorToaster.SEVERITY_WARNING,
		)
		return

	var sky_scene := load(SKY_SCENE_PATH) as PackedScene
	if sky_scene == null:
		EditorInterface.get_editor_toaster().push_toast(
			"The Dynamic Sky scene could not be loaded.",
			EditorToaster.SEVERITY_ERROR,
		)
		return

	var sky := sky_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var selection := EditorInterface.get_selection()
	var undo_redo := get_undo_redo()
	undo_redo.create_action(ADD_SKY_MENU, UndoRedo.MERGE_DISABLE, scene_root)
	undo_redo.add_do_method(scene_root, "add_child", sky, true)
	undo_redo.add_do_method(sky, "set_owner", scene_root)
	undo_redo.add_do_method(selection, "clear")
	undo_redo.add_do_method(selection, "add_node", sky)
	undo_redo.add_do_reference(sky)
	undo_redo.add_undo_method(scene_root, "remove_child", sky)
	undo_redo.commit_action()


func _open_demo() -> void:
	EditorInterface.open_scene_from_path(DEMO_SCENE_PATH)


func _open_comparison() -> void:
	EditorInterface.open_scene_from_path(COMPARISON_SCENE_PATH)
