@tool
extends EditorPlugin
## Installs the shared project tag picker for authored gameplay properties.

var _inspector := TagInspector.new()


func _enter_tree() -> void:
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	remove_inspector_plugin(_inspector)


class TagInspector extends EditorInspectorPlugin:
	const TAG_PROPERTY = preload("res://addons/gameplay_tag_picker/gameplay_tag_property.tscn")

	func _can_handle(object: Object) -> bool:
		return object is Resource or object is Node


	func _parse_property(
			object: Object, type: Variant.Type, property: String, _hint_type: PropertyHint,
			_hint_string: String, usage_flags: int, _wide: bool
	) -> bool:
		if (usage_flags & PROPERTY_USAGE_EDITOR) == 0:
			return false
		var kind := GameplayTagRegistry.field_kind(object, StringName(property), type)
		if kind == GameplayTagRegistry.FieldKind.NONE:
			return false
		var editor := TAG_PROPERTY.instantiate()
		editor.configure(type == TYPE_PACKED_STRING_ARRAY, kind == GameplayTagRegistry.FieldKind.QUERY)
		add_property_editor(property, editor)
		return true
