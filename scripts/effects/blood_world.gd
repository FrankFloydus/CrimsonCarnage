extends Node3D
## Sweeps invisible droplets through the world and projects splatter at their first contact.

const IMPACT_TOLERANCE := 0.001
const HEAD_ON_TANGENT_FRACTION_SQUARED := 0.04
const FLOOR_MIN_UP_DOT := 0.70

## Saved Decal scene instanced at each world impact.
@export var decal_scene: PackedScene
## Shared mask, tint, roughness, and footprint variation for callers without a blood profile.
@export_storage var splatter_style: BloodSplatterStyle
## Base width and length of a floor deposit in meters, before variation and impact stretch.
@export_storage var floor_footprint := Vector2(1.16, 1.42)
## Projection depth in meters for uneven floors and shallow steps.
@export_storage var floor_projection_depth := 0.16
## Extra length multiplier as a floor impact approaches parallel with the surface.
@export_storage var floor_grazing_stretch := 1.46
## Maximum wall decal center shift along the surface as a fraction of its length. Zero centers marks on impact.
@export_storage var wall_center_shift := 0.08
## Physics layers a cosmetic droplet can land on.
@export_flags_3d_physics var world_mask: int = 1
## Radius of the droplet collision query, in meters.
@export_range(0.001, 0.05, 0.001, "suffix:m") var droplet_radius := 0.01
## Initial speed along the swing, in meters per second.
@export_storage var droplet_speed := 5.0
## Maximum angle in degrees between the swing direction and its main world droplet.
@export_storage var character_spray_spread := 22.0
## Downward speed of the near-target fallout, in meters per second. Zero disables it.
@export_storage var fallout_speed := 5.8
## Fraction of the normal floor footprint left by near-target fallout.
@export_storage var fallout_footprint_scale := 0.76
## Multiplier of the world's 3D gravity.
@export_range(0.0, 3.0, 0.05) var gravity_scale := 1.0
## Maximum flight time before a droplet expires, in seconds.
@export_range(0.1, 5.0, 0.1, "suffix:s") var droplet_lifetime := 2.0
## Time a world splatter remains visible, in seconds.
@export_range(0.1, 120.0, 0.1, "suffix:s") var decal_lifetime := 30.0
## Maximum world splatters. A new splatter replaces the oldest at this limit.
@export_range(1, 100, 1) var decal_limit := 50

var _droplets: Array[Droplet] = []
var _splatters: Array[Splatter] = []
var _sphere := SphereShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()
var _cast := PhysicsCastMotionResult3D.new()
var _rest := PhysicsGetRestInfoResult3D.new()
var _gravity: Vector3
var _legacy_history := PlacementHistory.new()
var _profile_histories: Dictionary[BloodProfile, PlacementHistory] = {}
var _droplet_wires: MultiMeshInstance3D
var _droplet_wire_source: ArrayMesh


func _ready() -> void:
	var gravity_direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var gravity_strength: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	_gravity = gravity_direction * gravity_strength
	_sphere.radius = droplet_radius
	_query.shape = _sphere
	set_physics_process(not _droplets.is_empty())


func _physics_process(delta: float) -> void:
	for index in range(_splatters.size() - 1, -1, -1):
		var splatter := _splatters[index]
		splatter.time_left -= delta
		if not is_instance_valid(splatter.decal) or splatter.time_left <= 0.0:
			_remove_splatter(index)

	if not _droplets.is_empty():
		_query.collision_mask = world_mask
		if not is_equal_approx(_sphere.radius, droplet_radius):
			_sphere.radius = droplet_radius
		var space := get_world_3d().direct_space_state
		var gravity := _gravity * gravity_scale
		for index in range(_droplets.size() - 1, -1, -1):
			if _advance_droplet(_droplets[index], space, gravity, delta):
				_droplets.remove_at(index)

	if not _droplets.is_empty() or (_droplet_wires != null and _droplet_wires.visible):
		_update_droplet_wires()
	if _droplets.is_empty() and _splatters.is_empty():
		set_physics_process(false)


func _update_droplet_wires() -> void:
	var positions := PackedVector3Array()
	for droplet in _droplets:
		if droplet.profile != null and droplet.profile.show_droplet_wires:
			positions.append(droplet.position)
	if positions.is_empty():
		if _droplet_wires != null:
			_droplet_wires.hide()
		return

	if _droplet_wires == null:
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 0.55, 0.12)
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.no_depth_test = true
		material.render_priority = 100

		_droplet_wires = MultiMeshInstance3D.new()
		_droplet_wires.name = &"DropletWires"
		_droplet_wires.top_level = true
		_droplet_wires.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_droplet_wires.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_droplet_wires.material_override = material
		_droplet_wires.multimesh = MultiMesh.new()
		_droplet_wires.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		add_child(_droplet_wires, false, Node.INTERNAL_MODE_BACK)
		_droplet_wires.global_transform = Transform3D.IDENTITY

	var wires := _droplet_wires.multimesh
	var source := _sphere.get_debug_mesh()
	if _droplet_wire_source != source:
		_droplet_wire_source = source
		# Shape3D supplies wire lines as its first surface, followed by any fill.
		var wire_mesh := ArrayMesh.new()
		wire_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, source.surface_get_arrays(0))
		wires.mesh = wire_mesh
	if wires.instance_count != positions.size():
		wires.instance_count = positions.size()
	for index in positions.size():
		wires.set_instance_transform(index, Transform3D(Basis.IDENTITY, positions[index]))
	_droplet_wires.show()


func _exit_tree() -> void:
	for index in range(_splatters.size() - 1, -1, -1):
		_remove_splatter(index)


## Queues a directional droplet. Character hits use the supplied profile for launch and fallout.
func spawn_droplet(
		point: Vector3, direction: Vector3, excluded: Array[RID], character_hit: bool = false,
		profile: BloodProfile = null
) -> void:
	if direction.is_zero_approx() or decal_scene == null or world_mask == 0:
		return
	var launch := direction.normalized()
	var spread := profile.character_spray_spread if profile != null else character_spray_spread
	if character_hit and spread > 0.0:
		var reference := Vector3.RIGHT if absf(launch.y) > 0.99 else Vector3.UP
		var axis := launch.cross(reference).normalized().rotated(launch, randf() * TAU)
		launch = launch.rotated(axis, deg_to_rad(spread) * sqrt(randf()))
	var speed := profile.droplet_speed if profile != null else droplet_speed
	_queue_droplet(point, launch * speed, excluded, profile)
	var downward_speed := profile.fallout_speed if profile != null else fallout_speed
	if character_hit and downward_speed > 0.0:
		var tangent := direction.slide(Vector3.UP).normalized()
		tangent = tangent.rotated(Vector3.UP, randf_range(-0.7, 0.7))
		var velocity := (Vector3.DOWN + tangent * 0.34) * downward_speed
		_queue_droplet(point, velocity, excluded, profile, true)
	set_physics_process(true)


func _queue_droplet(
		point: Vector3, velocity: Vector3, excluded: Array[RID], profile: BloodProfile, fallout: bool = false
) -> void:
	var droplet := Droplet.new()
	droplet.position = point
	droplet.velocity = velocity
	droplet.time_left = droplet_lifetime
	droplet.excluded = excluded.duplicate()
	droplet.fallout = fallout
	droplet.profile = profile
	_droplets.append(droplet)


func _advance_droplet(
		droplet: Droplet, space: PhysicsDirectSpaceState3D, gravity: Vector3, delta: float
) -> bool:
	var step := minf(delta, droplet.time_left)
	var motion := (droplet.velocity + gravity * (step * 0.5)) * step
	_query.exclude = droplet.excluded
	_query.transform = Transform3D(Basis.IDENTITY, droplet.position)
	_query.motion = Vector3.ZERO
	_query.margin = 0.0

	# Motion casts skip starting overlaps.
	if space.get_rest_info_into(_query, _rest):
		_place_splatter(droplet.velocity, droplet.fallout, droplet.profile)
		return true

	_query.motion = motion
	if space.cast_motion_into(_query, _cast):
		var impact_fraction := _cast.unsafe_fraction
		var impact_center := droplet.position + motion * impact_fraction
		_query.transform = Transform3D(Basis.IDENTITY, impact_center)
		_query.motion = Vector3.ZERO
		_query.margin = IMPACT_TOLERANCE
		if space.get_rest_info_into(_query, _rest):
			_place_splatter(droplet.velocity + gravity * (step * impact_fraction), droplet.fallout, droplet.profile)
			return true

	droplet.position += motion
	droplet.velocity += gravity * step
	droplet.time_left -= step
	return droplet.time_left <= 0.0


func _place_splatter(incoming: Vector3, fallout: bool, profile: BloodProfile) -> void:
	var normal := _rest.normal.normalized()
	var is_floor := normal.dot(Vector3.UP) >= FLOOR_MIN_UP_DOT
	if normal.is_zero_approx() or (fallout and not is_floor):
		return
	var tangent := incoming.slide(normal)
	var grazing := clampf(tangent.length_squared() / maxf(incoming.length_squared(), 0.0001), 0.0, 1.0)
	var head_on := grazing <= HEAD_ON_TANGENT_FRACTION_SQUARED
	if tangent.is_zero_approx():
		tangent = Vector3.UP.slide(normal)
		if tangent.is_zero_approx():
			tangent = Vector3.RIGHT.slide(normal)
	tangent = tangent.normalized()

	var scene_root := decal_scene.instantiate()
	var decal := scene_root as Decal
	if decal == null:
		scene_root.free()
		push_warning("The blood splatter scene needs a Decal root.")
		return
	var style := splatter_style
	if profile != null and profile.splatter_style != null:
		style = profile.splatter_style
	if is_floor and (profile != null or style != null):
		var footprint := profile.floor_footprint if profile != null else floor_footprint
		var depth := profile.floor_projection_depth if profile != null else floor_projection_depth
		var stretch := profile.floor_grazing_stretch if profile != null else floor_grazing_stretch
		decal.size = Vector3(footprint.x, depth, footprint.y * lerpf(1.0, stretch, grazing))
		decal.upper_fade = 0.35
		decal.lower_fade = 0.35
	elif not is_floor and profile != null:
		decal.size = profile.wall_size
	if style != null:
		var history := _get_placement_history(profile, style)
		var variant := style.pick_floor_variant(history.last_floor_albedo) if is_floor else _next_wall_variant(history)
		if is_floor:
			history.last_floor_angle = style.sample_angle(head_on, history.last_floor_angle)
			tangent = tangent.rotated(normal, history.last_floor_angle)
		else:
			history.last_wall_angle = style.sample_angle(head_on, history.last_wall_angle)
			var angle := history.last_wall_angle
			if variant != null and variant.wall_drips:
				var downhill := _gravity.slide(normal)
				if not downhill.is_zero_approx():
					tangent = downhill.normalized()
					angle *= 0.16
			tangent = tangent.rotated(normal, angle)
		_apply_style(decal, is_floor, variant, history)
	if fallout:
		var scale := profile.fallout_footprint_scale if profile != null else fallout_footprint_scale
		decal.size *= Vector3(scale, 1.0, scale)
	while _splatters.size() >= maxi(decal_limit, 1):
		_remove_splatter(0)

	var receiver := instance_from_id(_rest.collider_id) as Node3D
	if is_instance_valid(receiver) and receiver.is_inside_tree():
		receiver.add_child(decal)
	else:
		add_child(decal)

	# Decals project along local -Y. The masks open toward local +Z.
	var orientation := Basis(normal.cross(tangent), normal, tangent)
	var center := _rest.point
	var shift := profile.wall_center_shift if profile != null else wall_center_shift
	if not is_floor and shift > 0.0:
		# Keep the offset in the impact plane and the hit inside the projection.
		center += tangent * decal.size.z * shift * randf_range(0.65, 1.0)
	decal.global_transform = Transform3D(orientation, center)
	decal.reset_physics_interpolation()
	var splatter := Splatter.new()
	splatter.decal = decal
	splatter.time_left = decal_lifetime
	_splatters.append(splatter)


func _get_placement_history(profile: BloodProfile, style: BloodSplatterStyle) -> PlacementHistory:
	if profile == null:
		if _legacy_history.style != style:
			_legacy_history = PlacementHistory.new()
			_legacy_history.style = style
		return _legacy_history

	var history: PlacementHistory = _profile_histories.get(profile)
	if history == null or history.style != style:
		history = PlacementHistory.new()
		history.style = style
		_profile_histories[profile] = history
	return history


func _apply_style(
		decal: Decal, is_floor: bool, variant: BloodFloorSplatter, history: PlacementHistory
) -> void:
	var style := history.style
	if variant != null:
		decal.texture_albedo = variant.albedo
		decal.texture_orm = variant.orm
		decal.texture_normal = variant.normal
		if is_floor:
			decal.albedo_mix = style.floor_albedo_mix
			history.last_floor_albedo = variant.albedo
	else:
		var masks := style.masks
		var mask_index := style.pick_mask(history.last_mask_index, masks)
		if mask_index >= 0:
			decal.texture_albedo = masks[mask_index]
			decal.texture_orm = style.compact_orm if mask_index == 0 else style.fan_orm
			history.last_mask_index = mask_index

	var footprint := style.sample_size()
	decal.size *= Vector3(footprint.x, 1.0, footprint.y)
	var tint := style.sample_tint()
	if is_floor and variant != null:
		# Floor deposit maps already encode thin edges and opaque pools in alpha.
		tint.a = 1.0
	decal.modulate = tint

	if decal.texture_orm != null:
		return
	var roughness := clampf(style.wet_roughness, 0.0, 1.0)
	if history.orm_texture == null or not is_equal_approx(history.orm_roughness, roughness):
		# One shared flat ORM texture keeps the wet mark nonmetallic under direct light.
		var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(Color(1.0, roughness, 0.0))
		history.orm_texture = ImageTexture.create_from_image(image)
		history.orm_roughness = roughness
	decal.texture_orm = history.orm_texture


func _next_wall_variant(history: PlacementHistory) -> BloodFloorSplatter:
	if history.wall_variant_bag.is_empty():
		var seen: Dictionary[Texture2D, bool] = {}
		for variant in history.style.floor_variants:
			if variant != null and variant.albedo != null and not seen.has(variant.albedo):
				seen[variant.albedo] = true
				history.wall_variant_bag.append(variant)
		if history.wall_variant_bag.is_empty():
			return null
		history.wall_variant_bag.shuffle()
		if history.wall_variant_bag.size() > 1 and history.wall_variant_bag.back().albedo == history.last_wall_albedo:
			history.wall_variant_bag.push_front(history.wall_variant_bag.pop_back())
	var selected: BloodFloorSplatter = history.wall_variant_bag.pop_back()
	history.last_wall_albedo = selected.albedo
	return selected


func _remove_splatter(index: int) -> void:
	var decal := _splatters[index].decal
	_splatters.remove_at(index)
	if is_instance_valid(decal):
		decal.hide()
		decal.queue_free()


class Droplet:
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var excluded: Array[RID] = []
	var fallout := false
	var time_left := 0.0
	var profile: BloodProfile


class PlacementHistory:
	var style: BloodSplatterStyle
	var last_mask_index := -1
	var last_floor_albedo: Texture2D
	var wall_variant_bag: Array[BloodFloorSplatter] = []
	var last_wall_albedo: Texture2D
	var last_floor_angle := 0.0
	var last_wall_angle := 0.0
	var orm_texture: ImageTexture
	var orm_roughness := -1.0


class Splatter:
	var decal: Decal
	var time_left := 0.0
