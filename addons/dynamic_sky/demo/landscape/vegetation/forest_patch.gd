@tool
extends MultiMeshInstance3D
## Selects saved vegetation meshes for each distance band of an authored patch.

## Detailed vegetation shown close to the active camera.
@export var nearby_mesh: Mesh

## Reduced vegetation geometry used across the middle distance.
@export var middle_mesh: Mesh

## Small silhouette geometry retained at the farthest visible distance.
@export var distant_mesh: Mesh

## Distance from the patch boundary at which the detailed mesh gives way to the middle mesh.
@export_range(10.0, 500.0, 1.0, "suffix:m") var nearby_distance: float = 105.0

## Distance from the patch boundary at which the middle mesh gives way to the distant mesh.
@export_range(100.0, 2000.0, 1.0, "suffix:m") var distant_distance: float = 450.0

## Radius of the authored patch, used to retain detail while the camera enters a stand.
@export_range(1.0, 200.0, 1.0, "suffix:m") var patch_radius: float = 70.0

var _time_until_update: float = 0.0


func _ready() -> void:
	set_process(not Engine.is_editor_hint())


func _process(delta: float) -> void:
	_time_until_update -= delta
	if _time_until_update > 0.0:
		return
	_time_until_update = 0.35
	var camera := get_viewport().get_camera_3d()
	if camera == null or multimesh == null:
		return
	var distance := maxf(global_position.distance_to(camera.global_position) - patch_radius, 0.0)
	var selected := middle_mesh
	if distance < nearby_distance:
		selected = nearby_mesh
	elif distance > distant_distance:
		selected = distant_mesh
	if selected != null and multimesh.mesh != selected:
		multimesh.mesh = selected
