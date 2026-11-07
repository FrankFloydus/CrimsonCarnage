class_name DamageDummy
extends StaticBody3D
## Saved target with a Health bar and damage or failed Accuracy feedback.

## Saved billboard feedback instantiated for actual damage or MISS/RESIST outcomes.
@export var damage_number_scene: PackedScene
## Sideways spacing in meters for three alternating number lanes above the target.
@export_range(0.0, 1.0, 0.01) var damage_number_spacing: float = 0.22

var _damage_number_sequence: int = 0

@onready var attributes: ActorAttributes = $Attributes
@onready var ability_system: AbilitySystem = $AbilitySystem
@onready var _damage_number_origin: Marker3D = $DamageNumberOrigin
@onready var _damage_numbers: Node3D = $DamageNumbers


func _ready() -> void:
	ability_system.combat_event.connect(_on_combat_event)


func reset_actor() -> void:
	for number in _damage_numbers.get_children():
		number.queue_free()
	_damage_number_sequence = 0
	ability_system.clear_transient_effects()
	attributes.restore_resources()


func _on_combat_event(event: Dictionary) -> void:
	if StringName(event.get("type", &"")) == &"hit_outcome":
		var outcome := StringName(event.get("outcome", &""))
		if outcome in [&"miss", &"resist"]:
			var feedback := _spawn_number()
			if feedback != null:
				feedback.show_outcome(outcome)
		return
	if StringName(event.get("type", &"")) != &"damage":
		return
	var amount := float(event.get("amount", 0.0))
	if amount <= 0.0:
		return
	var number := _spawn_number()
	if number != null:
		number.show_damage(amount, bool(event.get("is_critical", false)))


func _spawn_number() -> FloatingDamageNumber:
	if damage_number_scene == null:
		return null
	var instance := damage_number_scene.instantiate()
	var number := instance as FloatingDamageNumber
	if number == null:
		instance.free()
		push_warning("Damage number scene must have a FloatingDamageNumber root.")
		return null
	_damage_numbers.add_child(number)
	var lane := (_damage_number_sequence % 3) - 1
	_damage_number_sequence += 1
	number.global_position = _damage_number_origin.global_position \
			+ _damage_number_origin.global_basis.x * damage_number_spacing * lane
	return number
