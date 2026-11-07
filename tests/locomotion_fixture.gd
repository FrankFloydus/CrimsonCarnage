extends RefCounted
## Test-owned controller dimensions and locomotion tuning.

static var _standing_shape: CapsuleShape3D


static func install(player: CharacterBody3D) -> void:
	var movement := player.get_node("Movement") as FirstPersonMovement
	var crouch := player.get_node("Crouch") as FirstPersonCrouch
	var look := player.get_node("Look") as FirstPersonLook
	var collision := player.get_node("CollisionShape3D") as CollisionShape3D
	var attributes := player.get_node("Attributes") as ActorAttributes
	movement.settings = FirstPersonMovementSettings.new()
	movement.settings.normal_run_speed = 4.0
	movement.settings.crouch_speed_multiplier = 0.6
	movement.settings.ground_acceleration = 30.0
	movement.settings.ground_deceleration = 40.0
	movement.settings.air_acceleration = 9.0
	movement.settings.air_deceleration = 2.0
	movement.settings.gravity = 24.0
	movement.settings.jump_height = 1.5
	movement.settings.crouch_jump_height = 0.75
	movement.settings.coyote_time = 0.25
	movement.settings.max_step_height = 0.3
	movement.settings.max_slope_angle = 45.0
	crouch.settings = FirstPersonCrouchSettings.new()
	crouch.settings.mode = FirstPersonCrouchSettings.Mode.TOGGLE
	crouch.settings.crouched_height = 1.1
	crouch.settings.crouched_eye_height = 0.95
	crouch.settings.transition_time = 0.2
	look.settings = FirstPersonLookSettings.new()
	look.settings.mouse_sensitivity = 0.12
	look.settings.pitch_limit = 89.0
	look.settings.maximum_tilt = 3.0
	look.settings.full_tilt_speed = 6.0
	look.settings.tilt_response = 10.0
	look.settings.stair_smoothing_time = 0.1

	if _standing_shape == null:
		_standing_shape = CapsuleShape3D.new()
		_standing_shape.radius = 0.35
		_standing_shape.height = 1.8
	collision.shape = _standing_shape
	collision.position = Vector3(0.0, 0.9, 0.0)
	look.position = Vector3(0.0, 1.62, 0.0)
	look.get_node("Camera3D").position = Vector3.ZERO
	attributes.initial_modifiers = []
	attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 0.0)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 0.0)
