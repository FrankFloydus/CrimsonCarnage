extends CanvasLayer
## Displays the item definitions loaded by the current Playground session.

var _catalog := ItemCatalog.new()

@onready var _hint: Label = %Hint
@onready var _panel: PanelContainer = %Panel
@onready var _report: RichTextLabel = %Report


func _ready() -> void:
	_catalog.load_from_directory()
	var report := PackedStringArray()
	if not _catalog.errors.is_empty():
		report.append("Load errors\n%s" % "\n".join(_catalog.errors))
		for error: String in _catalog.errors:
			push_warning("Item definitions: %s" % error)
	if _catalog.records.is_empty():
		report.append("No valid item definitions found.")
	for record: ItemDefinition in _catalog.records.values():
		report.append(_format_record(record))

	var count := _catalog.records.size()
	var errors := _catalog.errors.size()
	_hint.text = "F4   Item definitions (%d loaded)" % count
	if errors > 0:
		_hint.text = "F4   Item definitions (%d loaded, %d rejected)" % [count, errors]
	_report.text = "\n\n".join(report)
	print("Item definitions loaded from %s\n%s" % [ItemCatalog.CONTENT_DIRECTORY, _report.text])


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F4:
		_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


func _format_record(record: ItemDefinition) -> String:
	var fields := PackedStringArray([
		"%s  [%s]" % [record.display_name, record.item_id],
		"%s · %d × %d · Stack %d · Vendor value %d" % [
			_label(ItemDefinition.Category.find_key(record.category)),
			record.width, record.height, record.stack_limit, record.vendor_value,
		],
	])
	match record.category:
		ItemDefinition.Category.EQUIPMENT:
			var detail := String(ItemDefinition.EquipmentGroup.find_key(record.equipment_group))
			if record.equipment_group == ItemDefinition.EquipmentGroup.HANDHELD:
				detail = String(ItemDefinition.WeaponType.find_key(record.weapon_type))
			fields.append("%s · %s" % [
				_label(detail),
				_label(ItemDefinition.EquipProfile.find_key(record.equip_profile)),
			])
		ItemDefinition.Category.CONSUMABLE:
			fields.append("On consume · Restore %s health" % record.restore_health_amount)
	if not record.description.is_empty():
		fields.append(record.description)
	if record.icon != null:
		fields.append("Icon · %s" % record.icon.resource_path)
	if record.world_scene != null:
		fields.append("World scene · %s" % record.world_scene.resource_path)
	return "\n".join(fields)


func _label(value: String) -> String:
	return value.capitalize().replace("1h", "1H").replace("2h", "2H")
