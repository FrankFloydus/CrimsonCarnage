@tool
class_name DynamicSkyCloudShadows
extends Node
## Bakes local sunlight transmission for volumetric and layered clouds.

const BLIT_MATERIAL_PATH := "res://addons/dynamic_sky/rendering/cloud_shadows/cloud_shadow_material.tres"
const DRAWABLE_TEXTURE := &"DrawableTexture2D"
const PROJECTOR_SIZE := &"directional_projector_size"
const METERS_TO_KILOMETERS := 0.001
const MIN_SUN_ELEVATION := 0.035
const IMMEDIATE_ROTATION_COSINE := 0.995
const VOLUMETRIC := 0
const STATIC := 1
const DYNAMIC_2D := 3
const VOLUME_PARAMETERS: Array[StringName] = [
	&"cloud_offset", &"cloud_base_km", &"cloud_thickness_km", &"cloud_extinction", &"low_cloud_scale",
]
const STATIC_PARAMETERS: Array[StringName] = [
	&"static_cloud_altitude_km", &"static_cloud_scale", &"static_cloud_yaw_degrees", &"static_cloud_opacity",
]
const DYNAMIC_2D_PARAMETERS: Array[StringName] = [
	&"cloud_offset", &"dynamic_2d_base_km", &"dynamic_2d_scale", &"dynamic_2d_pattern_phase",
	&"dynamic_2d_opacity",
]

## Projects cloud shadows in Forward+ on Godot builds with directional projectors.
@export var enabled: bool = false:
	set(value):
		enabled = value
		if not enabled:
			_release_projector()
		if Engine.is_editor_hint() and is_inside_tree():
			update_configuration_warnings()

## Width of the square shadow map measured perpendicular to sunlight, in meters.
@export_range(250.0, 20000.0, 50.0, "suffix:m") var map_size_meters: float = 6000.0

## Number of texels per map side. Higher resolutions retain finer cloud-shadow edges.
@export_range(64, 512, 32) var resolution: int = 192

## Maximum regular shadow-map refreshes per real second. Large camera or sun jumps refresh immediately.
@export_range(1.0, 30.0, 1.0, "suffix:Hz") var updates_per_second: float = 10.0

## Density samples along each light ray through volumetric clouds.
@export_range(4, 24, 1) var samples_per_ray: int = 12

## Amount of direct-light extinction to apply. One uses the full physical transmission.
@export_range(0.0, 1.0, 0.01) var shadow_strength: float = 1.0

var _native_support: bool = false
var _blit_material: ShaderMaterial
var _texture: Texture2D
var _sun: DirectionalLight3D
var _previous_texture: Texture2D
var _previous_size: float = 0.0
var _previous_position: Vector3 = Vector3.ZERO
var _drawn_basis: Basis = Basis.IDENTITY
var _drawn_center: Vector3 = Vector3.ZERO
var _drawn_size: float = 0.0
var _drawn_mode: int = -1
var _elapsed: float = 0.0


func _ready() -> void:
	_native_support = _supports_projector()


func _exit_tree() -> void:
	_release_projector()


func _get_configuration_warnings() -> PackedStringArray:
	if enabled and not _supports_projector():
		return ["Cloud Shadows requires Forward+ and a Godot build with directional projectors."]
	return []


## Updates the projector after the sky uniforms and Sun orientation have been applied.
## Returns true when the Sun receives per-pixel cloud transmission.
func apply_sky(
		sun: DirectionalLight3D, sky_material: ShaderMaterial, rig_origin: Vector3,
		camera: Camera3D, delta: float,
) -> bool:
	if not enabled or not _native_support or Engine.is_editor_hint():
		_release_projector()
		return false
	if not is_instance_valid(sun) or not sun.is_inside_tree() or sky_material == null or sky_material.shader == null:
		_release_projector()
		return false

	var basis := sun.global_basis.orthonormalized()
	var saved_mode: Variant = sky_material.get_shader_parameter(&"cloud_mode")
	var mode := int(saved_mode) if saved_mode != null else VOLUMETRIC
	var celestial_mode: Variant = sky_material.get_shader_parameter(&"celestial_mode")
	if (
		basis.z.y <= MIN_SUN_ELEVATION or shadow_strength <= 0.0 or celestial_mode == 1
		or (mode != VOLUMETRIC and mode != STATIC and mode != DYNAMIC_2D)
	):
		_release_projector()
		return false

	var coverage: Variant = _read_sky_parameter(sky_material, &"cloud_coverage")
	var noise := sky_material.get_shader_parameter(&"cloud_noise") as Texture3D
	var weather := sky_material.get_shader_parameter(&"cloud_weather") as Texture2D
	var sheet := sky_material.get_shader_parameter(&"dynamic_2d_cloud_map") as Texture2D
	if (
		coverage == null or float(coverage) <= 0.0
		or (mode == VOLUMETRIC and (noise == null or weather == null))
		or (mode != VOLUMETRIC and sheet == null)
	):
		_release_projector()
		return false

	var pixel_count := clampi(resolution, 64, 512)
	var map_size := clampf(map_size_meters, 250.0, 20000.0)
	var observer := camera.global_position if is_instance_valid(camera) and camera.is_inside_tree() else rig_origin
	var center := _projector_center(rig_origin, observer, basis, map_size / float(pixel_count))
	var old_texture := _texture
	var needs_texture := _texture == null or _texture.get_width() != pixel_count
	var changing_sun := _sun != sun
	var refresh_now := (
		needs_texture or changing_sun or sun.light_projector != old_texture
		or mode != _drawn_mode or _drawn_size != map_size
		or basis.z.dot(_drawn_basis.z) < IMMEDIATE_ROTATION_COSINE
		or basis.x.dot(_drawn_basis.x) < IMMEDIATE_ROTATION_COSINE
		or center.distance_squared_to(_drawn_center) > map_size * map_size * 0.0625
	)
	_elapsed += maxf(delta, 0.0)
	var interval := 1.0 / clampf(updates_per_second, 1.0, 30.0)
	if not refresh_now and _elapsed < interval:
		return true
	_elapsed = 0.0 if refresh_now else fposmod(_elapsed, interval)

	if not _prepare_blit_material():
		_release_projector()
		return false
	if changing_sun:
		_release_projector()
		_sun = sun
		_previous_texture = sun.light_projector
		_previous_size = sun.get(PROJECTOR_SIZE)
		_previous_position = sun.position
	if needs_texture:
		_texture = ClassDB.instantiate(DRAWABLE_TEXTURE) as Texture2D
		var format := ClassDB.class_get_integer_constant(DRAWABLE_TEXTURE, &"DRAWABLE_FORMAT_RGBA8")
		_texture.call(&"setup", pixel_count, pixel_count, format, Color.WHITE, false)

	var parameters: Dictionary[StringName, Variant] = {
		&"projector_center_km": (center - rig_origin) * METERS_TO_KILOMETERS,
		&"projector_right": basis.x,
		&"projector_up": basis.y,
		&"sun_direction": basis.z,
		&"projector_size_km": map_size * METERS_TO_KILOMETERS,
		&"shadow_strength": clampf(shadow_strength, 0.0, 1.0),
		&"cloud_coverage": coverage,
		&"shadow_cloud_mode": mode,
	}
	var mode_parameters: Array[StringName]
	match mode:
		VOLUMETRIC:
			parameters[&"samples_per_ray"] = clampi(samples_per_ray, 4, 24)
			parameters[&"cloud_noise"] = noise
			parameters[&"cloud_weather"] = weather
			parameters[&"cloud_formation"] = sky_material.get_shader_parameter(&"cloud_formation") as Texture3D
			mode_parameters = VOLUME_PARAMETERS
		STATIC:
			parameters[&"dynamic_2d_cloud_map"] = sheet
			mode_parameters = STATIC_PARAMETERS
		DYNAMIC_2D:
			parameters[&"dynamic_2d_cloud_map"] = sheet
			mode_parameters = DYNAMIC_2D_PARAMETERS
	for field in mode_parameters:
		parameters[field] = _read_sky_parameter(sky_material, field)

	var redraw := refresh_now
	for parameter in parameters:
		if _blit_material.get_shader_parameter(parameter) != parameters[parameter]:
			_blit_material.set_shader_parameter(parameter, parameters[parameter])
			redraw = true
	if redraw:
		var rect := Rect2i(Vector2i.ZERO, Vector2i(pixel_count, pixel_count))
		_texture.call(&"blit_rect", rect, null, Color.WHITE, 0, _blit_material)
		_drawn_basis = basis
		_drawn_center = center
		_drawn_size = map_size
		_drawn_mode = mode
		sun.global_position = center
		sun.set(PROJECTOR_SIZE, map_size)
		if sun.light_projector != _texture:
			sun.light_projector = _texture
	return true


func _supports_projector() -> bool:
	if (
		RenderingServer.get_current_rendering_method() != &"forward_plus"
		or RenderingServer.get_rendering_device() == null
		or not ClassDB.class_exists(DRAWABLE_TEXTURE)
	):
		return false
	for property in ClassDB.class_get_property_list(&"DirectionalLight3D", true):
		if property[&"name"] == PROJECTOR_SIZE:
			return true
	return false


func _projector_center(origin: Vector3, observer: Vector3, basis: Basis, texel: float) -> Vector3:
	# Snap on the light plane so camera motion below one texel keeps the same world rays.
	var offset := observer - origin
	var x := snappedf(offset.dot(basis.x), texel)
	var y := snappedf(offset.dot(basis.y), texel)
	return origin + basis.x * x + basis.y * y


func _read_sky_parameter(material: ShaderMaterial, parameter: StringName) -> Variant:
	var value: Variant = material.get_shader_parameter(parameter)
	if value != null:
		return value
	return RenderingServer.shader_get_parameter_default(material.shader.get_rid(), parameter)


func _prepare_blit_material() -> bool:
	if _blit_material == null:
		var authored := load(BLIT_MATERIAL_PATH) as ShaderMaterial
		if authored == null or authored.shader == null:
			return false
		_blit_material = authored.duplicate() as ShaderMaterial
	return true


func _release_projector() -> void:
	if is_instance_valid(_sun) and _texture != null and _sun.light_projector == _texture:
		_sun.light_projector = _previous_texture
		_sun.set(PROJECTOR_SIZE, _previous_size)
		_sun.position = _previous_position
	_sun = null
	_previous_texture = null
