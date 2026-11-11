class_name DynamicSkyLightning
extends Node3D
## Generates distant cloud-to-cloud and cloud-to-ground lightning channels.

## Reports a ground endpoint or the center of a cloud channel at its first bright stroke.
signal struck(world_position: Vector3, intensity: float)

const BoltMesh = preload("res://addons/dynamic_sky/lightning/lightning_bolt_mesh.gd")
const PLACEMENT_ATTEMPTS: int = 5

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

## Peak energy of the local OmniLight3D. Zero disables ground illumination.
@export_range(0.0, 32.0, 0.1, "or_greater") var impact_light_energy: float = 3.8

@export_group("Timing")
## Seconds for the faint leader to travel from cloud to ground. Zero starts on impact.
@export_range(0.0, 0.2, 0.005, "suffix:s") var leader_duration: float = 0.045

## Seconds from impact until the last return stroke fades away.
@export_range(0.05, 1.0, 0.01, "suffix:s") var return_duration: float = 0.24

var _random := RandomNumberGenerator.new()
var _auto_requested: bool = false
var _sheet_requested: bool = false
var _elapsed: float = 0.0
var _hit_ground: bool = false
var _return_intensity: float = 0.0
var _second_stroke: float = 0.0
var _third_stroke: float = 0.0
var _third_strength: float = 0.0
var _cloud_channel: bool = false
var _reported_position: Vector3 = Vector3.ZERO
var _flash_position: Vector3 = Vector3.ZERO

@onready var _bolt: MeshInstance3D = $Bolt
@onready var _impact_light: OmniLight3D = $ImpactLight
@onready var _material: ShaderMaterial = _bolt.material_override as ShaderMaterial


func _ready() -> void:
	set_process(false)
	set_physics_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < leader_duration:
		_show_bolt(_elapsed / leader_duration, 0.12 * _return_intensity)
		return

	if not _hit_ground:
		_begin_return_stroke()
		return

	var progress := _elapsed / return_duration
	if progress >= 1.0:
		_bolt.hide()
		_impact_light.hide()
		set_process(false)
		return

	var energy := 0.88 * exp(-12.0 * progress) + 0.12 * (1.0 - progress)
	if progress >= _second_stroke:
		energy += 0.62 * exp(-18.0 * (progress - _second_stroke))
	if progress >= _third_stroke:
		energy += _third_strength * exp(-22.0 * (progress - _third_stroke))
	_apply_return_stroke(energy * _return_intensity)


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
	_cloud_channel = cloud_arc > 0.0
	_reported_position = start.lerp(end, 0.5) if _cloud_channel else end
	_flash_position = _reported_position if _cloud_channel else start

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
	_impact_light.global_position = end + Vector3.UP * 1.8
	_impact_light.hide()
	_return_intensity = intensity * _random.randf_range(0.86, 1.0)
	_second_stroke = _random.randf_range(0.25, 0.45)
	_third_stroke = _random.randf_range(0.55, 0.67)
	_third_strength = _random.randf_range(0.18, 0.44) if _random.randf() > 0.25 else 0.0
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
	_elapsed = 0.0
	_apply_return_stroke(_return_intensity)
	struck.emit(_reported_position, _return_intensity)


func _apply_return_stroke(energy: float) -> void:
	_show_bolt(1.055, energy)
	_impact_light.light_energy = impact_light_energy * energy
	_impact_light.visible = not _cloud_channel and _impact_light.light_energy > 0.01


func _show_bolt(progress: float, brightness: float) -> void:
	_material.set_shader_parameter(&"leader_progress", progress)
	_material.set_shader_parameter(&"brightness", brightness)
