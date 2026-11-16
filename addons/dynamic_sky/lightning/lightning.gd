class_name DynamicSkyLightning
extends Node3D
## Generates distant cloud-to-cloud and cloud-to-ground lightning channels.

## Reports a ground endpoint or the center of a cloud channel at its first bright stroke.
signal struck(world_position: Vector3, intensity: float)

const BoltMesh = preload("res://addons/dynamic_sky/lightning/lightning_bolt_mesh.gd")
const CloudRays = preload("res://addons/dynamic_sky/lightning/cloud_rays.gd")
const PLACEMENT_ATTEMPTS: int = 5
const NOMINAL_FLASH_DURATION: float = 1.975
const FLASH_DURATION_VARIATION: float = 0.225 / NOMINAL_FLASH_DURATION
const FULL_LIGHT_NEAR_DISTANCE: float = 1550.0
const FULL_LIGHT_FAR_DISTANCE: float = 6500.0

@export_group("Placement")
## Optional origin and forward direction for automatic strikes. Empty uses the active camera.
@export var observer: Node3D

## Physics layers that can receive distant ground strikes. Zero uses cloud channels only.
@export_flags_3d_physics var ground_mask: int = 1

## Closest automatic strike distance along the ground, in meters from the observer.
@export_range(500.0, 6000.0, 10.0, "or_greater", "suffix:m") var near_distance: float = 1400.0

## Farthest automatic strike distance, in meters. Values below Near Distance use Near Distance.
@export_range(500.0, 6000.0, 10.0, "or_greater", "suffix:m") var far_distance: float = 3000.0

## Maximum angular deviation to either side of the observer's horizontal view.
@export_range(0.0, 180.0, 1.0, "degrees") var strike_angle: float = 16.0

## How far below the observer to search for ground, in meters.
@export_range(1.0, 3000.0, 1.0, "or_greater", "suffix:m") var ground_search_depth: float = 1600.0

## Fraction of automatic strikes that stay in the storm deck. Missed ground rays also stay in clouds.
@export_range(0.0, 1.0, 0.01) var cloud_to_cloud_fraction: float = 0.66

@export_group("Bolt")
## Height of the lower storm deck above this node's origin, in meters.
@export_range(250.0, 4000.0, 10.0, "or_greater", "suffix:m") var cloud_base_height: float = 650.0

## Average depth inside the cloud where the first leader point forms, in meters.
@export_range(30.0, 650.0, 5.0, "or_greater", "suffix:m") var channel_depth: float = 190.0

## Halo half-width in meters. The narrow bright filament uses only the center of this width.
@export_range(0.1, 15.0, 0.05, "or_greater", "suffix:m") var bolt_radius: float = 6.5

## Number of main branches before the generator adds smaller forks.
@export_range(0, 8) var branch_count: int = 3

## Peak return-stroke multiplier for the bolt and the emitted impact intensity.
@export_range(0.1, 3.0, 0.05) var intensity: float = 1.0

## Nominal energy of the aimed, shadow-casting full-strike light. Zero disables its direct lighting.
@export_range(0.0, 32.0, 0.1, "or_greater") var impact_light_energy: float = 5.0

## Strength of the depth-masked optical glow during a full strike on Forward+.
@export_range(0.0, 8.0, 0.05, "or_greater") var flash_glow_intensity: float = 2.0

@export_group("Timing")
## Seconds for the faint leader to travel from cloud to ground. Zero starts on impact.
@export_range(0.0, 0.2, 0.005, "suffix:s") var leader_duration: float = 0.045

## Nominal full-strike lighting duration in seconds after the leader, with 11.4% random variation.
@export_range(0.05, 4.0, 0.005, "or_greater", "suffix:s") var return_duration: float = NOMINAL_FLASH_DURATION

var cloud_ray_intensity: float = 1.0:
	set(value):
		cloud_ray_intensity = value
		if is_instance_valid(_rays):
			_rays.intensity = value

var cloud_ray_envelope: Curve:
	set(value):
		cloud_ray_envelope = value
		if is_instance_valid(_rays):
			_rays.envelope = value

var _random := RandomNumberGenerator.new()
var _envelope_random := RandomNumberGenerator.new()
var _auto_requested: bool = false
var _sheet_requested: bool = false
var _elapsed: float = 0.0
var _hit_ground: bool = false
var _return_intensity: float = 0.0
var _full_flash_intensity: float = 0.0
var _active_return_duration: float = NOMINAL_FLASH_DURATION
var _light_distance_scale: float = 1.0
var _noise_phase: float = 0.0
var _reported_position: Vector3 = Vector3.ZERO
var _flash_position: Vector3 = Vector3.ZERO

@onready var _bolt: MeshInstance3D = $Bolt
@onready var _impact_light: DirectionalLight3D = $ImpactLight
@onready var _material: ShaderMaterial = _bolt.material_override as ShaderMaterial
@onready var _glow := get_node_or_null(^"FlashGlow") as MeshInstance3D
@onready var _glow_material := _glow.material_override as ShaderMaterial if _glow != null else null
@onready var _rays := get_node_or_null(^"CloudRays") as CloudRays


func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	if _glow_material != null:
		_glow.hide()
		_glow_material.set_shader_parameter(&"cloud_base_m", global_position.y + cloud_base_height)


## Supplies world-space cloud bounds, sun elevation, and wind to the optical effects.
func set_glow_environment(
	sun_elevation: float, cloud_base_m: float, cloud_top_m: float = 1000000.0, wind: Vector2 = Vector2.ZERO
) -> void:
	if _glow_material != null:
		_glow_material.set_shader_parameter(&"sun_elevation", sun_elevation)
		_glow_material.set_shader_parameter(&"cloud_base_m", cloud_base_m)
	if _rays != null:
		_rays.set_environment(cloud_top_m, wind)


func _process(delta: float) -> void:
	_elapsed += delta
	if not _hit_ground:
		if _elapsed < leader_duration:
			_show_bolt(_elapsed / leader_duration, 0.12 * _return_intensity)
			return
		_begin_return_stroke()
		return

	if _elapsed >= _active_return_duration * 1.1:
		_end_channel()
		return

	_apply_return_stroke()


func _physics_process(_delta: float) -> void:
	set_physics_process(false)
	if not _auto_requested:
		return
	_auto_requested = false
	var view := _get_observer()
	if view == null:
		return

	var forward := -view.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var candidate := _distant_candidate(view.global_position, forward)
	if _sheet_requested:
		candidate.y = global_position.y + cloud_base_height + channel_depth * 0.68
		_flash_position = candidate
		struck.emit(candidate, intensity * _random.randf_range(0.45, 0.64))
		return
	if ground_mask == 0 or _random.randf() < cloud_to_cloud_fraction:
		_strike_in_clouds(candidate, forward, view)
		return

	var deck_y := global_position.y + cloud_base_height
	var space := get_world_3d().direct_space_state
	for _attempt in PLACEMENT_ATTEMPTS:
		var start := Vector3(candidate.x, deck_y + channel_depth, candidate.z)
		var end := Vector3(
			candidate.x, minf(view.global_position.y, deck_y) - ground_search_depth, candidate.z
		)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(start, end, ground_mask))
		if not hit.is_empty():
			var ground_position: Vector3 = hit.position
			if ground_position.y < deck_y:
				strike_at(ground_position)
				return
		candidate = _distant_candidate(view.global_position, forward)
	_strike_in_clouds(candidate, forward, view)


## Queues a distant strike in the observer's forward sector for the next physics tick.
## Sheet-only events illuminate the cloud deck and emit thunder without a visible channel.
func strike_near_observer(sheet_only: bool = false) -> void:
	if not is_node_ready() or is_processing():
		return
	_sheet_requested = sheet_only if not _auto_requested else _sheet_requested and sheet_only
	_auto_requested = true
	set_physics_process(true)


## Starts a ground bolt terminating at an explicit world-space point.
func strike_at(world_position: Vector3) -> void:
	if not is_node_ready() or not world_position.is_finite():
		return
	_auto_requested = false
	set_physics_process(false)
	var deck_y := global_position.y + cloud_base_height
	var start_y := maxf(
		deck_y + channel_depth * _random.randf_range(0.75, 1.25), world_position.y + 35.0
	)
	var drift := (start_y - world_position.y) * _random.randf_range(0.07, 0.19)
	var yaw := _random.randf_range(0.0, TAU)
	var start := Vector3(
		world_position.x + cos(yaw) * drift, start_y, world_position.z + sin(yaw) * drift
	)
	_begin_channel(start, world_position, _get_observer(), 0.0)


## Returns the world-space source of the current storm-deck flash.
func get_flash_position() -> Vector3:
	return _flash_position


## Returns the active full-strike envelope for the sky and its surrounding haze.
func get_full_flash_intensity() -> float:
	return _full_flash_intensity


## Clears a pending request or active channel when transient flash state resets.
func clear_flash() -> void:
	if _auto_requested:
		_auto_requested = false
		_sheet_requested = false
		set_physics_process(false)
	if is_processing():
		_end_channel()


func _distant_candidate(view_position: Vector3, forward: Vector3) -> Vector3:
	var direction := forward.rotated(
		Vector3.UP, deg_to_rad(_random.randf_range(-strike_angle, strike_angle))
	)
	var distance := _random.randf_range(near_distance, maxf(far_distance, near_distance))
	return view_position + direction * distance


func _strike_in_clouds(candidate: Vector3, forward: Vector3, view: Node3D) -> void:
	var deck_y := global_position.y + cloud_base_height
	var span := forward.cross(Vector3.UP) * _random.randf_range(160.0, 340.0)
	span = span.rotated(Vector3.UP, _random.randf_range(-0.52, 0.52))
	if _random.randf() < 0.5:
		span = -span
	var start := candidate + span
	var end := candidate - span
	start.y = deck_y + channel_depth * _random.randf_range(0.67, 1.28)
	end.y = deck_y + channel_depth * _random.randf_range(0.54, 1.06)
	var dip := (start.y + end.y) * 0.5 - deck_y + _random.randf_range(32.0, 105.0)
	_begin_channel(start, end, view, dip)


func _begin_channel(start: Vector3, end: Vector3, view: Node3D, cloud_arc: float) -> void:
	var cloud_channel := cloud_arc > 0.0
	_reported_position = start.lerp(end, 0.5) if cloud_channel else end
	_flash_position = _reported_position if cloud_channel else start

	var view_offset := Vector3.BACK * far_distance
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		view_offset = camera.global_position - end
	elif view != null:
		view_offset = view.global_position - end

	_bolt.global_transform = Transform3D(Basis.IDENTITY, end)
	_bolt.mesh = BoltMesh.build(start - end, bolt_radius, branch_count, view_offset, _random, cloud_arc)
	var relative_base := global_position.y + cloud_base_height - end.y
	_material.set_shader_parameter(&"cloud_base_local", relative_base)
	_material.set_shader_parameter(&"cloud_veil_depth", maxf(channel_depth, 25.0))
	_bolt.show()
	var eye := end + view_offset
	var light_origin := start + (end - start) * Vector3(0.3, 0.0, 0.3)
	var light_direction := eye - light_origin
	if not light_direction.is_zero_approx():
		var up := Vector3.BACK if absf(light_direction.normalized().y) > 0.99 else Vector3.UP
		_impact_light.global_basis = Basis.looking_at(light_direction, up)
	if _glow_material != null:
		_glow.global_position = eye
		_glow.hide()
		_glow_material.set_shader_parameter(&"strike_position", start)
		_glow_material.set_shader_parameter(&"strike_forward", -_impact_light.global_basis.z)
	_light_distance_scale = clampf(
		inverse_lerp(FULL_LIGHT_FAR_DISTANCE, FULL_LIGHT_NEAR_DISTANCE, eye.distance_to(start)), 0.15, 1.0
	)
	_impact_light.light_energy = 0.0
	_impact_light.hide()
	_return_intensity = intensity * _random.randf_range(0.86, 1.0)
	_active_return_duration = maxf(return_duration, 0.05) * _envelope_random.randf_range(
		1.0 - FLASH_DURATION_VARIATION, 1.0 + FLASH_DURATION_VARIATION
	)
	_noise_phase = _envelope_random.randf_range(0.0, 25.6)
	if _rays != null:
		_rays.intensity = cloud_ray_intensity
		_rays.envelope = cloud_ray_envelope
		_rays.begin(_flash_position, _active_return_duration, _noise_phase)
	_full_flash_intensity = 0.0
	_hit_ground = false
	_elapsed = 0.0
	_show_bolt(0.0, 0.0)
	set_process(true)
	if leader_duration == 0.0:
		_begin_return_stroke()


func _get_observer() -> Node3D:
	if is_instance_valid(observer) and observer.is_inside_tree():
		return observer
	return get_viewport().get_camera_3d()


func _begin_return_stroke() -> void:
	_hit_ground = true
	_elapsed = maxf(_elapsed - leader_duration, 0.0)
	if _elapsed < _active_return_duration * 1.1:
		_apply_return_stroke()
	struck.emit(_reported_position, _return_intensity)
	# Keep the signal classified as a channel even when one tick crosses its entire lifetime.
	# Read the current state after signal handlers, which may cancel or start another strike.
	if is_processing() and _elapsed >= _active_return_duration * 1.1:
		_end_channel()


func _apply_return_stroke() -> void:
	var progress := minf(_elapsed / _active_return_duration, 1.0)
	var light_pulse := 1.0 - 2.0 * absf(pow(progress, 0.4) - 0.5)
	var modulation := 1.0 + 0.25 * _flash_noise((_noise_phase + _elapsed) * 10.0)
	var light_curve := pow(light_pulse * light_pulse * modulation, 3.0)
	_full_flash_intensity = light_curve * _return_intensity * _light_distance_scale
	_impact_light.light_energy = impact_light_energy * _full_flash_intensity
	_impact_light.visible = _impact_light.light_energy > 0.01
	if _glow_material != null:
		var glow_energy := _impact_light.light_energy * flash_glow_intensity / 170.0
		_glow.visible = glow_energy > 0.0001 and RenderingServer.get_current_rendering_method() == "forward_plus"
		if _glow.visible:
			_glow_material.set_shader_parameter(&"energy", glow_energy)
	var bolt_age := _elapsed / (_active_return_duration * 1.1)
	_show_bolt(1.055, _bolt_intensity(bolt_age) * _return_intensity)


func _end_channel() -> void:
	_bolt.hide()
	_impact_light.light_energy = 0.0
	_impact_light.hide()
	if _glow != null:
		_glow.hide()
	if _rays != null:
		_rays.clear()
	_full_flash_intensity = 0.0
	set_process(false)


static func _bolt_intensity(age: float) -> float:
	# The visible channel has an earlier peak than the light reaching the scene.
	const PEAK_AGE: float = 0.10
	const PEAK_TANGENT: float = -3.509785
	var curve: float
	if age <= PEAK_AGE:
		curve = _hermite(0.0, 1.0, 0.0, PEAK_TANGENT * PEAK_AGE, age / PEAK_AGE)
	else:
		var tail := 1.0 - PEAK_AGE
		curve = _hermite(1.0, 0.0, PEAK_TANGENT * tail, 0.0, (age - PEAK_AGE) / tail)
	return pow(maxf(curve, 0.0), 3.0)


static func _hermite(first: float, last: float, first_tangent: float, last_tangent: float, t: float) -> float:
	var t2 := t * t
	var t3 := t2 * t
	return (
		(2.0 * t3 - 3.0 * t2 + 1.0) * first + (t3 - 2.0 * t2 + t) * first_tangent
		+ (-2.0 * t3 + 3.0 * t2) * last + (t3 - t2) * last_tangent
	)


static func _flash_noise(sample: float) -> float:
	var cell := floori(sample)
	var phase := sample - float(cell)
	var weight := phase * phase * phase * (phase * (phase * 6.0 - 15.0) + 10.0)
	return 2.0 * lerpf(_flash_gradient(cell) * phase, _flash_gradient(cell + 1) * (phase - 1.0), weight)


static func _flash_gradient(cell: int) -> float:
	var index := hash(cell) & 15
	return float(index - 8 if index < 8 else index - 7) / 8.0


func _show_bolt(progress: float, brightness: float) -> void:
	_material.set_shader_parameter(&"leader_progress", progress)
	_material.set_shader_parameter(&"brightness", brightness)
