extends GPUParticles3D
## Drives independent near, middle, and distant world-space rain volumes.

const RainContactCache = preload("res://addons/dynamic_sky/precipitation/rain/rain_contact_cache.gd")
const RainContactNormalField = preload("res://addons/dynamic_sky/precipitation/rain/contact_normals/rain_contact_normal_field.gd")
const CONTACT_NORMAL_FIELD_SCENE: PackedScene = preload("res://addons/dynamic_sky/precipitation/rain/contact_normals/rain_contact_normal_field.tscn")
const CONTACT_SEARCH_SECONDS: float = 0.40
const MAX_WATER_REGIONS: int = 8
const NO_WATER_PLANE: float = -1e20

## Main-rig rain layers and contact settings. Standalone scenes retain the same saved defaults.
@export var settings: DynamicSkyRainSettings = preload("res://addons/dynamic_sky/precipitation/rain/rain_settings.tres"):
	set(value):
		if settings != null and settings.changed.is_connected(refresh_settings):
			settings.changed.disconnect(refresh_settings)
		settings = value
		if settings != null and not settings.changed.is_connected(refresh_settings):
			settings.changed.connect(refresh_settings)
		if is_node_ready():
			refresh_settings()

var _intensity: float = -1.0
var _wind: Vector2
var _active: bool
var _view_camera: Camera3D
var _view_transform: Transform3D
var _camera_motion: Vector3
var _surface_collision_enabled: bool = true
var _camera_biased_fall: bool
var _fall_observer_position := Vector3.INF
var _fall_observer_forward := Vector3.INF
var _contact_cache: RainContactCache
var _contact_normal_field: RainContactNormalField
var _contact_receivers: Array[MeshInstance3D]
var _falling_drop_contacts: bool
var _contact_forward: Vector2 = Vector2(0.0, -1.0)
var _contact_water_plane: float = NO_WATER_PLANE
var _contact_water_regions: PackedVector4Array

@onready var _middle: GPUParticles3D = $MiddleRain
@onready var _distant: GPUParticles3D = $DistantRain
@onready var _near_mesh := draw_pass_1 as QuadMesh
@onready var _middle_mesh := _middle.draw_pass_1 as QuadMesh
@onready var _distant_mesh := _distant.draw_pass_1 as QuadMesh
@onready var _near_fall_defaults := {
	"amount": amount,
	"lifetime": lifetime,
	"bounds": visibility_aabb,
	"width": _near_mesh.size.x,
	"depth_range": (_near_mesh.material as ShaderMaterial).get_shader_parameter(&"view_depth_range"),
}
@onready var _spray: GPUParticles3D = $StormSpray
@onready var _splashes: GPUParticles3D = get_node_or_null("../RainSplashes")
@onready var _authored_sub_emitter := sub_emitter
@onready var _exposure: DynamicSkyWeatherExposure = get_node_or_null("../../WeatherExposure")


func _ready() -> void:
	set_physics_process(false)
	if settings != null and not settings.changed.is_connected(refresh_settings):
		settings.changed.connect(refresh_settings)
	refresh_settings()
	if _intensity >= 0.0:
		_update_layers()


## Applies the authored physical assets without replacing their shaders or runtime weather inputs.
func refresh_settings() -> void:
	if settings == null:
		return
	var camera_biased := settings.fall_distribution == DynamicSkyRainSettings.FallDistribution.CAMERA_BIASED_VOLUME
	var distribution_changed := camera_biased != _camera_biased_fall
	if distribution_changed and not camera_biased and settings.near_layer == null:
		amount = _near_fall_defaults.amount
		lifetime = _near_fall_defaults.lifetime
		visibility_aabb = _near_fall_defaults.bounds
		_near_mesh.size.x = _near_fall_defaults.width
		(_near_mesh.material as ShaderMaterial).set_shader_parameter(&"view_depth_range", _near_fall_defaults.depth_range)
	_apply_layer_settings(self, _near_mesh, settings.near_layer, _splashes == null and settings.splashes_enabled, not camera_biased)
	_apply_layer_settings(_middle, _middle_mesh, settings.middle_layer, settings.spray_enabled)
	_apply_layer_settings(_distant, _distant_mesh, settings.distant_layer, true)
	if distribution_changed:
		_middle.draw_pass_1 = null if camera_biased else _middle_mesh
		_distant.draw_pass_1 = null if camera_biased else _distant_mesh
	_camera_biased_fall = camera_biased
	(process_material as ShaderMaterial).set_shader_parameter(&"camera_biased_volume", camera_biased)
	if camera_biased:
		_apply_fall_volume_settings()
	if _splashes != null:
		_splashes.amount = settings.splash_amount
		_splashes.set_instance_shader_parameter(&"impact_lifetime", settings.splash_lifetime)
		var contacts := _splashes.process_material as ShaderMaterial
		_configure_contact_search(contacts)
		contacts.set_shader_parameter(&"impact_lifetime", settings.splash_lifetime)
		contacts.set_shader_parameter(&"collision_radius", _splashes.collision_base_size)
		if settings.near_layer != null:
			contacts.set_shader_parameter(&"contact_chance", settings.near_layer.contact_chance)
			contacts.set_shader_parameter(&"contact_surface_offset", settings.near_layer.contact_surface_offset)
		_set_impact_pass(_splashes, 0, settings.ripple_size, settings.ripple_tint)
		_set_impact_pass(_splashes, 1, settings.crown_size, settings.crown_tint)
		_set_impact_pass(_splashes, 2, settings.bounce_size, settings.bounce_tint)
		var ripple := _splashes.get_draw_pass_mesh(0).material as ShaderMaterial
		ripple.set_shader_parameter(&"contact_tint", settings.contact_tint)
		var crown := _splashes.get_draw_pass_mesh(1).material as ShaderMaterial
		crown.set_shader_parameter(&"visible_fraction", settings.crown_visible_fraction)
		var bounce := _splashes.get_draw_pass_mesh(2).material as ShaderMaterial
		bounce.set_shader_parameter(&"visible_fraction", settings.bounce_visible_fraction)
		bounce.set_shader_parameter(&"launch_speed_range", settings.bounce_launch_speed_range)
		bounce.set_shader_parameter(&"outward_speed_range", settings.bounce_outward_speed_range)
		_splashes.visible = settings.enabled and settings.splashes_enabled and _surface_collision_enabled
	_spray.amount = settings.spray_amount
	_spray.lifetime = settings.spray_lifetime
	_spray.set_instance_shader_parameter(&"impact_lifetime", _spray.lifetime)
	_set_impact_pass(_spray, 0, settings.spray_size, settings.spray_tint)
	for pass_index in range(1, 4):
		var side := settings.spray_droplet_sizes[pass_index - 1]
		_set_impact_pass(_spray, pass_index, Vector2(side, side), settings.spray_droplet_tint)
	_spray.visible = settings.enabled and settings.spray_enabled
	visible = settings.enabled
	if _intensity >= 0.0:
		_update_layers()
		if distribution_changed and emitting:
			restart(true)


func _apply_layer_settings(
	layer: GPUParticles3D,
	mesh: QuadMesh,
	authored: DynamicSkyRainLayerSettings,
	contacts_enabled: bool,
	apply_fall_shape: bool = true,
) -> void:
	var process := layer.process_material as ShaderMaterial
	process.set_shader_parameter(&"collision_radius", layer.collision_base_size)
	if authored == null:
		return
	layer.position.y = authored.vertical_offset
	for field in [&"spawn_radii", &"spawn_half_height", &"fall_speed_range", &"drop_scale_range", &"contact_surface_offset", &"storm_spray_contact"]:
		process.set_shader_parameter(field, authored.get(field))
	process.set_shader_parameter(&"contact_chance", authored.contact_chance if contacts_enabled else 0.0)
	var draw := mesh.material as ShaderMaterial
	if apply_fall_shape:
		layer.amount = authored.amount
		layer.lifetime = authored.lifetime
		layer.visibility_aabb = authored.visibility_aabb
		mesh.size.x = authored.sprite_width
		draw.set_shader_parameter(&"view_depth_range", authored.view_depth_range)
	var color := authored.tint
	color.a = authored.opacity
	draw.set_shader_parameter(&"tint", color)
	for field in [&"surface_fade_distance", &"shutter_seconds", &"minimum_pixel_width", &"refraction_pixels", &"transmission_weight", &"storm_opacity_boost", &"storm_shutter_boost"]:
		draw.set_shader_parameter(field, authored.get(field))


func _apply_fall_volume_settings() -> void:
	var radius := maxf(settings.fall_volume_radius, 0.1)
	var offset := maxf(settings.fall_volume_forward_offset, 0.0)
	var near_fade := maxf(settings.fall_volume_minimum_view_distance, 0.05)
	var volume_edge := maxf(radius + offset, near_fade + 0.30)
	lifetime = maxf(settings.fall_volume_lifetime, 0.05)
	amount = maxi(1, roundi(settings.fall_volume_maximum_rate * lifetime))
	var bounds := Vector3.ONE * (volume_edge + position.length() + 1.0)
	visibility_aabb = AABB(-bounds, 2.0 * bounds)
	_near_mesh.size.x = maxf(settings.fall_volume_sprite_width, 0.001)
	var draw := _near_mesh.material as ShaderMaterial
	draw.set_shader_parameter(&"view_depth_range", Vector4(near_fade, near_fade + 0.05, volume_edge - 0.25, volume_edge))
	var process := process_material as ShaderMaterial
	process.set_shader_parameter(&"fall_volume", Vector4(
		radius, maxf(settings.fall_volume_height, 0.1), offset, maxf(settings.fall_volume_forward_bias, 0.0),
	))
	process.set_shader_parameter(&"fall_radial_distribution", maxf(settings.fall_volume_radial_distribution, 0.1))
	_update_fall_observer(_view_camera)


func _update_fall_observer(camera: Camera3D) -> void:
	var observer := camera if is_instance_valid(camera) else get_viewport().get_camera_3d()
	var view := observer.get_camera_transform() if observer != null else global_transform
	var forward := -view.basis.z.normalized()
	if _fall_observer_position == view.origin and _fall_observer_forward == forward:
		return
	_fall_observer_position = view.origin
	_fall_observer_forward = forward
	var process := process_material as ShaderMaterial
	process.set_shader_parameter(&"fall_camera_position", view.origin)
	process.set_shader_parameter(&"fall_camera_forward", forward)


func _configure_contact_search(material: ShaderMaterial) -> void:
	var cached := settings.splash_collision == DynamicSkyRainSettings.SplashCollision.TRAJECTORY_CACHE
	var renderer := RenderingServer.get_current_rendering_method()
	var falling := settings.splash_collision == DynamicSkyRainSettings.SplashCollision.FALLING_DROP_CONTACT \
		and _camera_biased_fall and renderer in ["forward_plus", "mobile"]
	var changed := cached != (_contact_cache != null) or falling != _falling_drop_contacts
	if _falling_drop_contacts and not falling:
		sub_emitter = _authored_sub_emitter
		(process_material as ShaderMaterial).set_shader_parameter(&"contact_chance", 0.0)
	_falling_drop_contacts = falling
	if falling:
		_splashes.emitting = false
	_splashes.lifetime = settings.splash_lifetime if cached or falling else settings.splash_lifetime + CONTACT_SEARCH_SECONDS
	material.set_shader_parameter(&"external_impacts", falling)
	material.set_shader_parameter(&"cached_impacts", cached)
	if cached:
		if _contact_cache == null:
			_contact_cache = RainContactCache.new()
		_contact_cache.configure(settings)
		material.set_shader_parameter(&"impact_cache", _contact_cache.texture)
		material.set_shader_parameter(&"impact_path_count", _contact_cache.texture.get_width())
		material.set_shader_parameter(&"duplicate_radius", maxf(settings.splash_duplicate_radius, 0.0))
		material.set_shader_parameter(&"trajectory_radius", maxf(settings.fall_volume_radius, 0.1))
	elif _contact_cache != null:
		_contact_cache = null
		material.set_shader_parameter(&"impact_cache", null)
	if changed:
		# GPUParticles3D.restart() would enable autonomous emission in the passive receiver.
		RenderingServer.particles_restart(_splashes.get_base())


func _physics_process(delta: float) -> void:
	if _contact_cache == null:
		return
	var observer := _view_camera if is_instance_valid(_view_camera) else get_viewport().get_camera_3d()
	if observer != null:
		_contact_cache.update(delta, get_world_3d(), observer.get_camera_transform(), _wind)


func _set_impact_pass(particles: GPUParticles3D, pass_index: int, size: Vector2, tint: Color) -> void:
	var mesh := particles.get_draw_pass_mesh(pass_index) as QuadMesh
	mesh.size = size
	var material := mesh.material as ShaderMaterial
	material.set_shader_parameter(&"tint", tint)


## Applies rain and wind, optionally tracking the current view over a frame for streak motion.
func apply_rain(
	intensity: float,
	wind: Vector2,
	active: bool,
	camera: Camera3D = null,
	delta: float = 0.0,
	collision_enabled: bool = true,
) -> void:
	var next_intensity := clampf(intensity, 0.0, 1.0)
	if is_node_ready():
		var visible_rain := active and next_intensity > 0.0 and (settings == null or settings.enabled)
		_update_camera_motion(camera, delta, visible_rain)
		if visible_rain and _camera_biased_fall:
			_update_fall_observer(camera)
		if visible_rain and collision_enabled and camera != null and _splashes != null:
			_update_contact_view(camera)
		_update_contact_normal_field(camera, visible_rain and collision_enabled)
	if _intensity == next_intensity and _wind == wind and _active == active and _surface_collision_enabled == collision_enabled:
		return
	_intensity = next_intensity
	_wind = wind
	_active = active
	_surface_collision_enabled = collision_enabled
	if is_node_ready():
		_update_layers()


## Stores the automatic weather material owner's eligible mesh instances.
func set_contact_receivers(receivers: Array[MeshInstance3D]) -> void:
	_contact_receivers = receivers


func _update_contact_normal_field(camera: Camera3D, active: bool) -> void:
	if (
		not active or camera == null or _splashes == null or not _falling_drop_contacts
		or not is_visible_in_tree() or not _splashes.is_visible_in_tree()
		or settings == null or not settings.splashes_enabled or settings.contact_normal_strength <= 0.0
		or _contact_receivers.is_empty() or RenderingServer.get_current_rendering_method() != "forward_plus"
		or DisplayServer.get_name() == "headless"
	):
		if _contact_normal_field != null:
			_contact_normal_field.deactivate()
		return
	if _contact_normal_field == null:
		_contact_normal_field = CONTACT_NORMAL_FIELD_SCENE.instantiate() as RainContactNormalField
		add_child(_contact_normal_field)
	_contact_normal_field.update_contacts(_splashes, camera, _contact_receivers, settings.contact_normal_strength)


func _update_camera_motion(camera: Camera3D, delta: float, active: bool) -> void:
	if not active or camera == null:
		_view_camera = null
		_set_camera_motion(Vector3.ZERO)
		return
	var view := camera.get_camera_transform()
	if _view_camera != camera:
		_view_camera = camera
		_view_transform = view
		_set_camera_motion(Vector3.ZERO)
		return
	if delta <= 0.0:
		return
	var translation := view.origin - _view_transform.origin
	var forward := -view.basis.z.normalized()
	var previous_forward := -_view_transform.basis.z.normalized()
	_view_transform = view
	# A camera cut should not make a single frame of enormous streaks.
	if delta > 0.25 or translation.length_squared() > 16.0 or forward.dot(previous_forward) < 0.70:
		_set_camera_motion(Vector3.ZERO)
		return
	_set_camera_motion((translation * 0.5 + (forward - previous_forward)) / delta)


func _set_camera_motion(value: Vector3) -> void:
	if _camera_motion.is_equal_approx(value):
		return
	_camera_motion = value
	set_instance_shader_parameter(&"camera_motion", value)
	_middle.set_instance_shader_parameter(&"camera_motion", value)
	_distant.set_instance_shader_parameter(&"camera_motion", value)


func _update_contact_view(camera: Camera3D) -> void:
	var view := camera.get_camera_transform()
	var forward := Vector2(-view.basis.z.x, -view.basis.z.z).normalized()
	if not forward.is_equal_approx(_contact_forward):
		_contact_forward = forward
		_splashes.process_material.set_shader_parameter(&"camera_forward", forward)
	_sync_contact_water(view.origin)


func _sync_contact_water(center: Vector3) -> void:
	var plane := NO_WATER_PLANE
	var regions: Array[DynamicSkyWaterRegion] = []
	var exposure: DynamicSkyExposureSettings = _exposure.settings if _exposure != null else null
	if exposure != null and exposure.enabled:
		if exposure.global_water_enabled and is_finite(exposure.global_water_level):
			plane = exposure.global_water_level
		if exposure.local_water_regions_enabled:
			regions = _nearby_water_regions(center)
	var rows := PackedVector4Array()
	if not regions.is_empty():
		rows.resize(MAX_WATER_REGIONS * 3)
	for index in regions.size():
		var region := regions[index]
		var world := region.global_transform
		var local := world.affine_inverse()
		var height := world.origin.y
		var half_extents := _water_region_extents(region)
		rows[index * 3] = Vector4(
			local.basis.x.x, local.basis.z.x, local.origin.x + local.basis.y.x * height, half_extents.x,
		)
		rows[index * 3 + 1] = Vector4(
			local.basis.x.z, local.basis.z.z, local.origin.z + local.basis.y.z * height, half_extents.y,
		)
		rows[index * 3 + 2] = Vector4(height, float(region.region is SphereShape3D), 0.0, 0.0)
	if plane == _contact_water_plane and rows == _contact_water_regions:
		return
	_contact_water_plane = plane
	_contact_water_regions = rows
	var materials := [_splashes.process_material, _splashes.get_draw_pass_mesh(0).material, _middle.process_material, process_material]
	for material: ShaderMaterial in materials:
		material.set_shader_parameter(&"rain_water_plane", plane)
		material.set_shader_parameter(&"rain_water_count", regions.size())
		if not rows.is_empty():
			material.set_shader_parameter(&"rain_water_regions", rows)


func _nearby_water_regions(center: Vector3) -> Array[DynamicSkyWaterRegion]:
	var regions: Array[DynamicSkyWaterRegion] = []
	var world := get_world_3d()
	var center_xz := Vector2(center.x, center.z)
	var reach: float = 36.0
	if settings != null and settings.middle_layer != null:
		reach = maxf(16.0, settings.middle_layer.spawn_radii.y + 8.0)
	for candidate in get_tree().get_nodes_in_group(DynamicSkyWaterRegion.GROUP):
		var region := candidate as DynamicSkyWaterRegion
		if region == null or not region.enabled or region.get_world_3d() != world:
			continue
		var basis := region.global_basis
		if absf(basis.determinant()) < 0.000001 or basis.y.normalized().dot(Vector3.UP) < 0.9999:
			continue
		var half_extents := _water_region_extents(region)
		if half_extents == Vector2.ZERO:
			continue
		var origin := region.global_position
		var footprint_radius := basis.x.length() * half_extents.x + basis.z.length() * half_extents.y
		if center_xz.distance_to(Vector2(origin.x, origin.z)) <= reach + footprint_radius:
			regions.append(region)
	regions.sort_custom(func(a: DynamicSkyWaterRegion, b: DynamicSkyWaterRegion) -> bool:
		var aa := a.global_position - center
		var bb := b.global_position - center
		return Vector2(aa.x, aa.z).length_squared() < Vector2(bb.x, bb.z).length_squared()
	)
	if regions.size() > MAX_WATER_REGIONS:
		regions.resize(MAX_WATER_REGIONS)
	return regions


func _water_region_extents(region: DynamicSkyWaterRegion) -> Vector2:
	if region.region is BoxShape3D:
		var size := (region.region as BoxShape3D).size
		return Vector2(size.x, size.z) * 0.5
	if region.region is SphereShape3D:
		return Vector2.ONE * (region.region as SphereShape3D).radius
	return Vector2.ZERO


func _update_layers() -> void:
	var storm := smoothstep(0.68, 1.0, _intensity) * smoothstep(7.0, 13.5, _wind.length())
	# The middle emitter can supply StormSpray even when its visible drop pass is detached.
	var spray_active := storm > 0.0 and _surface_collision_enabled and (settings == null or settings.spray_enabled)
	_apply_layer(self, storm)
	_apply_layer(_middle, storm, not _camera_biased_fall or spray_active)
	_apply_layer(_distant, storm, not _camera_biased_fall)
	if _splashes != null:
		var visible_contacts := (settings == null or (settings.enabled and settings.splashes_enabled)) and _surface_collision_enabled
		_splashes.visible = visible_contacts
		_splashes.amount_ratio = _intensity
		_splashes.process_material.set_shader_parameter(&"wind", _wind)
		var should_emit := visible_contacts and _active and _intensity > 0.0
		if _falling_drop_contacts:
			_update_falling_drop_contact_source(should_emit, visible_contacts)
		elif _splashes.emitting != should_emit:
			if not should_emit and _contact_cache != null:
				_contact_cache.clear()
			_splashes.emitting = should_emit
		set_physics_process(should_emit and _contact_cache != null)


func _update_falling_drop_contact_source(active: bool, visible_contacts: bool) -> void:
	var target := get_path_to(_splashes) if active else NodePath()
	if sub_emitter != target:
		sub_emitter = target
		if not visible_contacts:
			RenderingServer.particles_restart(_splashes.get_base())
	var chance: float = settings.near_layer.contact_chance if settings.near_layer != null else 0.92
	(process_material as ShaderMaterial).set_shader_parameter(&"contact_chance", chance if active else 0.0)


func _apply_layer(layer: GPUParticles3D, storm: float, should_simulate: bool = true) -> void:
	layer.amount_ratio = _intensity
	var material := layer.process_material as ShaderMaterial
	material.set_shader_parameter(&"wind", _wind)
	material.set_shader_parameter(&"storm", storm)
	layer.set_instance_shader_parameter(&"storm", storm)
	var should_emit := should_simulate and _active and _intensity > 0.0 and (settings == null or settings.enabled)
	if layer.emitting != should_emit:
		layer.emitting = should_emit
