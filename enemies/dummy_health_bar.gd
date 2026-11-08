class_name DummyHealthBar
extends Node3D
## Text-free saved world health bar, updated by the actor's attribute events.

## Actor whose current and maximum Health determine the bar's fill.
@export var attributes: ActorAttributes

var fill_ratio: float = 1.0
var _full_width: float = 1.0
var _full_fill_scale: Vector3 = Vector3.ONE

@onready var _fill: MeshInstance3D = $Fill


func _ready() -> void:
	_full_fill_scale = _fill.scale
	_full_width = _fill.get_aabb().size.x * _full_fill_scale.x
	if attributes != null:
		attributes.attribute_changed.connect(_on_attribute_changed)
	update_health()


func update_health() -> void:
	if _fill == null:
		return
	if attributes == null:
		fill_ratio = 0.0
	else:
		var maximum := attributes.get_value(CombatAttributes.Id.MAX_HEALTH)
		fill_ratio = clampf(
				attributes.get_value(CombatAttributes.Id.HEALTH) / maxf(maximum, 0.001),
				0.0, 1.0
		)
	_fill.visible = fill_ratio > 0.0
	_fill.scale = Vector3(
			_full_fill_scale.x * maxf(fill_ratio, 0.00001),
			_full_fill_scale.y, _full_fill_scale.z
	)
	_fill.position.x = (fill_ratio - 1.0) * _full_width * 0.5


func _on_attribute_changed(attribute: int, _previous: float, _value: float) -> void:
	if attribute in [CombatAttributes.Id.HEALTH, CombatAttributes.Id.MAX_HEALTH]:
		update_health()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var direction := camera.global_position - global_position
	if direction.length_squared() > 0.0001 \
			and absf(direction.normalized().dot(Vector3.UP)) < 0.999:
		look_at(camera.global_position, Vector3.UP, true)
