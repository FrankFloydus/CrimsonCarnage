@tool
class_name ArmsPresetCatalog
extends Resource

## Skin tone labels, albedo keys, and matching scar palettes in dropdown order.
@export var skin_tones: Array[Dictionary]
## Tattoo labels, atlas keys, and optional ink strength multipliers in dropdown order.
@export var tattoos: Array[Dictionary]
## Scar labels, atlas keys, and finish values in dropdown order.
@export var scars: Array[Dictionary]
## Shared level labels and atlas keys for grime and blood in dropdown order.
@export var surface_levels: Array[Dictionary]


func get_hint(entries: Array[Dictionary]) -> String:
	var labels := PackedStringArray()
	for entry in entries:
		labels.append(str(entry["label"]))
	return ",".join(labels)
