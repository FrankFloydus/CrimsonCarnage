@tool
extends Node3D

const _CATALOG: ArmsPresetCatalog = preload("res://materials/arms/arms_preset_catalog.tres")
const _BASE_MATERIAL: ShaderMaterial = preload("res://materials/arms/arms_skin.tres")
const _TEXTURES := "res://materials/arms/textures/"
const _MESH_NAME := "SKM_Arms_Manny_Textured"

## Skin albedo and scar pigment palette for both arms.
@export var skin_tone: int = 2:
	set(value):
		skin_tone = value
		_apply_skin_tone()

@export_group("Skin Surface")
## Base skin and nail normal strength on both arms. 0 flattens the detail, 1 uses the authored relief, and 2 doubles its strength.
@export_range(0.0, 2.0, 0.01) var skin_normal_strength: float = 1.0:
	set(value):
		skin_normal_strength = value
		_apply_skin_surface()
## Base skin roughness on both arms. 0 is smooth, 1 uses the material's base roughness, and 2 is fully matte.
@export_range(0.0, 2.0, 0.01) var skin_roughness_strength: float = 1.0:
	set(value):
		skin_roughness_strength = value
		_apply_skin_surface()

@export_group("Left Arm", "left_")
## Tattoo design for the left arm. None hides the ink.
@export var left_tattoo: int = 8:
	set(value):
		left_tattoo = value
		_apply_left()
## Scar design for the left arm. None hides the scar.
@export var left_scar: int = 0:
	set(value):
		left_scar = value
		_apply_left()
## Grime coverage for the left arm. Heavy reaches the forearm.
@export var left_grime: int = 0:
	set(value):
		left_grime = value
		_apply_left()
## Blood coverage for the left arm. Heavy reaches the forearm.
@export var left_blood: int = 0:
	set(value):
		left_blood = value
		_apply_left()

@export_group("Right Arm", "right_")
## Tattoo design for the right arm. None hides the ink.
@export var right_tattoo: int = 8:
	set(value):
		right_tattoo = value
		_apply_right()
## Scar design for the right arm. None hides the scar.
@export var right_scar: int = 0:
	set(value):
		right_scar = value
		_apply_right()
## Grime coverage for the right arm. Heavy reaches the forearm.
@export var right_grime: int = 0:
	set(value):
		right_grime = value
		_apply_right()
## Blood coverage for the right arm. Heavy reaches the forearm.
@export var right_blood: int = 0:
	set(value):
		right_blood = value
		_apply_right()

var _material: ShaderMaterial


func _ready() -> void:
	var arms_mesh := find_child(_MESH_NAME, true, false) as MeshInstance3D
	if arms_mesh == null:
		push_warning("Arms Appearance could not find " + _MESH_NAME + ".")
		return

	# Each scene instance owns its selected textures and shader parameters.
	_material = _BASE_MATERIAL.duplicate() as ShaderMaterial
	_material.resource_local_to_scene = true
	_apply_skin_tone()
	_apply_skin_surface()
	_apply_left()
	_apply_right()
	arms_mesh.material_override = _material


func _validate_property(property: Dictionary) -> void:
	var entries: Array[Dictionary]
	match property.name:
		&"skin_tone":
			entries = _CATALOG.skin_tones
		&"left_tattoo", &"right_tattoo":
			entries = _CATALOG.tattoos
		&"left_scar", &"right_scar":
			entries = _CATALOG.scars
		&"left_grime", &"right_grime", &"left_blood", &"right_blood":
			entries = _CATALOG.surface_levels
		_:
			return
	property.hint = PROPERTY_HINT_ENUM
	property.hint_string = _CATALOG.get_hint(entries)


func _apply_skin_tone() -> void:
	if _material == null:
		return
	var tone := _CATALOG.skin_tones[clampi(skin_tone, 0, _CATALOG.skin_tones.size() - 1)]
	_material.set_shader_parameter(&"skin_albedo", _load_map("skin/skin_" + str(tone["key"])))
	_material.set_shader_parameter(&"scar_light_pigment", tone["light_pigment"])
	_material.set_shader_parameter(&"left_scar_dark_pigment", tone["dark_pigment"])
	_material.set_shader_parameter(&"right_scar_dark_pigment", tone["dark_pigment"])


func _apply_skin_surface() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"skin_normal_strength", skin_normal_strength)
	_material.set_shader_parameter(&"skin_roughness_strength", skin_roughness_strength)


func _apply_left() -> void:
	_apply_arm("left_", left_tattoo, left_scar, left_grime, left_blood)


func _apply_right() -> void:
	_apply_arm("right_", right_tattoo, right_scar, right_grime, right_blood)


func _apply_arm(prefix: String, tattoo_id: int, scar_id: int, grime_id: int, blood_id: int) -> void:
	if _material == null:
		return

	var tattoo := _layer(_CATALOG.tattoos, tattoo_id)
	var tattoo_key: String = tattoo["key"]
	var ink := _load_layer_map("tattoos/tattoo_", tattoo_key, "_ink")
	var ink_mask := _load_layer_map("tattoos/tattoo_", tattoo_key, "_mask")
	_material.set_shader_parameter(prefix + "tattoo_ink", ink)
	_material.set_shader_parameter(prefix + "tattoo_mask", ink_mask)
	_material.set_shader_parameter(prefix + "tattoo_type", tattoo_id if ink and ink_mask else 0)
	var ink_scale := float(tattoo.get("ink_strength_scale", 1.0))
	var base_tattoo_id := int(_BASE_MATERIAL.get_shader_parameter(prefix + "tattoo_type"))
	var base_tattoo := _layer(_CATALOG.tattoos, base_tattoo_id)
	var base_scale := float(base_tattoo.get("ink_strength_scale", 1.0))
	var base_strength := float(_BASE_MATERIAL.get_shader_parameter(prefix + "tattoo_ink_strength"))
	_material.set_shader_parameter(prefix + "tattoo_ink_strength", base_strength * ink_scale / base_scale)

	var scar := _layer(_CATALOG.scars, scar_id)
	var scar_key: String = scar["key"]
	var scar_mask := _load_layer_map("scars/scar_", scar_key, "_mask")
	var scar_normal := _load_layer_map("scars/scar_", scar_key, "_normal")
	_material.set_shader_parameter(prefix + "scar_mask", scar_mask)
	_material.set_shader_parameter(prefix + "scar_normal_map", scar_normal)
	_material.set_shader_parameter(prefix + "scar_finish", scar.get("finish", Vector3.ZERO))
	_material.set_shader_parameter(prefix + "scar_type", scar_id if scar_mask and scar_normal else 0)

	var grime_key: String = _layer(_CATALOG.surface_levels, grime_id)["key"]
	var grime_color := _load_layer_map("surface_layers/grime_", grime_key, "_color")
	var grime_finish := _load_layer_map("surface_layers/grime_", grime_key, "_finish")
	_material.set_shader_parameter(prefix + "grime_color", grime_color)
	_material.set_shader_parameter(prefix + "grime_finish", grime_finish)
	_material.set_shader_parameter(prefix + "grime_level", grime_id if grime_color and grime_finish else 0)

	var blood_key: String = _layer(_CATALOG.surface_levels, blood_id)["key"]
	var blood_data := _load_layer_map("surface_layers/blood_", blood_key)
	_material.set_shader_parameter(prefix + "blood_data", blood_data)
	_material.set_shader_parameter(prefix + "blood_level", blood_id if blood_data else 0)


func _layer(entries: Array[Dictionary], id: int) -> Dictionary:
	return entries[id] if id > 0 and id < entries.size() else entries[0]


func _load_layer_map(prefix: String, key: String, suffix: String = "") -> Texture2D:
	return null if key.is_empty() else _load_map(prefix + key + suffix)


func _load_map(path: String) -> Texture2D:
	return load(_TEXTURES + path + ".png") as Texture2D
