@tool
class_name DynamicSkyModifierStack
extends Node
## Applies ordered optional layers to the controller's final sky, light, and environment outputs.
## Restore the preceding outputs before the controller computes its next base state.

## Requests a controller preview refresh after authored layers or their properties change.
signal changed

## Enables the complete stack. Disabling restores the last unmodified output values immediately.
@export var enabled: bool = true:
	set(value):
		enabled = value
		if not enabled:
			restore_base()
		_configuration_changed()

## Shows the authored modifier weights in the editor. Timed fades run only during the game.
@export var preview_in_editor: bool = true:
	set(value):
		preview_in_editor = value
		if not preview_in_editor and Engine.is_editor_hint():
			restore_base()
		_configuration_changed()

## Layers applied from first to last. An empty array preserves the controller's computed outputs.
@export var layers: Array[DynamicSkyModifier] = []:
	set(value):
		layers = value
		_configuration_changed()

var _states: Dictionary[DynamicSkyModifier, Dictionary] = {}
var _watched: Array[DynamicSkyModifier] = []
var _base_fields: Array[Dictionary] = []
var _captured_fields: Dictionary[String, bool] = {}
var _warned: Dictionary[String, bool] = {}


func _enter_tree() -> void:
	_sync_layers()


func _exit_tree() -> void:
	restore_base()
	for modifier in _watched:
		modifier.changed.disconnect(_configuration_changed)
	_watched.clear()


func _process(delta: float) -> void:
	advance(delta)


## Restores only fields changed by the last application, including absent shader overrides.
## Call this before the controller writes new base values. Target references are weak.
func restore_base() -> void:
	for field in _base_fields:
		var target: Object = (field.target as WeakRef).get_ref()
		if not is_instance_valid(target):
			continue
		if field.shader:
			if (field.shader_ref as WeakRef).get_ref() != (target as ShaderMaterial).shader:
				continue
			(target as ShaderMaterial).set_shader_parameter(field.name, field.value)
		else:
			target.set(field.name, field.value)
	_base_fields.clear()
	_captured_fields.clear()


## Applies layers after the controller computes its final outputs. Resources must be rig-local.
## The saved DynamicSky scene already gives its Environment and ShaderMaterial local ownership.
func apply_outputs(
	hour: float, sky_material: ShaderMaterial, environment: Environment,
	sun: DirectionalLight3D, moon: DirectionalLight3D,
) -> void:
	restore_base()
	_sync_layers()
	if not enabled or (Engine.is_editor_hint() and not preview_in_editor):
		return
	var targets: Array[Object] = [sky_material, environment, sun, moon]
	for modifier in layers:
		if modifier == null or not modifier.enabled:
			continue
		if modifier.weight_mode == DynamicSkyModifier.WeightMode.CLOCK_WINDOW and not modifier.has_valid_clock_window():
			_warn_once("clock:%s" % modifier.get_instance_id(), "A modifier clock window has overlapping or reversed fade ranges. Set each end at or after its start, with distinct fade-in and fade-out intervals.")
			continue
		var weight := get_modifier_weight(modifier, hour)
		if weight <= 0.0:
			continue
		for adjustment in modifier.properties:
			if adjustment == null:
				continue
			if adjustment.target < 0 or adjustment.target >= targets.size():
				_warn_adjustment(adjustment)
				continue
			var target := targets[adjustment.target]
			if not is_instance_valid(target):
				continue
			_apply_property(adjustment, weight, target)


## Advances runtime manual fades at a constant alpha rate. The node calls this automatically.
func advance(delta: float) -> void:
	_sync_layers()
	if Engine.is_editor_hint() or not is_finite(delta) or delta <= 0.0:
		return
	for modifier in layers.duplicate():
		if modifier == null or modifier.weight_mode != DynamicSkyModifier.WeightMode.MANUAL:
			continue
		var state: Dictionary = _states[modifier]
		state.alpha = move_toward(state.alpha, state.target, delta / state.duration) if state.duration > 0.0 else state.target
		if state.remove and is_zero_approx(state.alpha):
			_erase_layer(modifier)
	_sync_layers()


## Adds a layer at the end of the stack and fades its raw alpha toward one.
func add_modifier(modifier: DynamicSkyModifier, fade_seconds: float = 0.0) -> void:
	if not _can_control_manual(modifier):
		return
	var already_present := layers.has(modifier)
	_register_layer(modifier)
	if not already_present and fade_seconds > 0.0:
		_states[modifier].alpha = 0.0
	_set_runtime_target(modifier, 1.0, fade_seconds, false)


## Fades a manual layer to zero and removes it, restoring the result beneath it.
func remove_modifier(modifier: DynamicSkyModifier, fade_seconds: float = 0.0) -> void:
	if not layers.has(modifier) or not _can_control_manual(modifier):
		return
	if fade_seconds <= 0.0 or is_zero_approx(float(_states[modifier].alpha)):
		_erase_layer(modifier)
	else:
		_set_runtime_target(modifier, 0.0, fade_seconds, true)


## Sets per-stack manual alpha without changing the authored Resource. Adds the layer if needed.
func set_modifier_weight(modifier: DynamicSkyModifier, alpha: float, fade_seconds: float = 0.0) -> void:
	if not _can_control_manual(modifier) or not is_finite(alpha):
		return
	_register_layer(modifier)
	_set_runtime_target(modifier, clampf(alpha, 0.0, 1.0), fade_seconds, false)


## Immediately clears all layers and their runtime fades, then restores the last base outputs.
func clear_modifiers() -> void:
	restore_base()
	layers = []


## Returns eased influence, including maximum alpha and clock sampling, for one registered layer.
func get_modifier_weight(modifier: DynamicSkyModifier, hour: float = 0.0) -> float:
	if modifier == null or not enabled or not modifier.enabled:
		return 0.0
	var raw := modifier.sample_clock(hour) if modifier.weight_mode == DynamicSkyModifier.WeightMode.CLOCK_WINDOW else modifier.weight
	if modifier.weight_mode == DynamicSkyModifier.WeightMode.MANUAL and _states.has(modifier) and not Engine.is_editor_hint():
		raw = _states[modifier].alpha
	return modifier.ease_weight(raw)


func _configuration_changed() -> void:
	restore_base()
	_sync_layers()
	changed.emit()


func _sync_layers() -> void:
	for modifier in _watched.duplicate():
		if not layers.has(modifier):
			modifier.changed.disconnect(_configuration_changed)
			_watched.erase(modifier)
			_states.erase(modifier)
	var fading := false
	for modifier in layers:
		if modifier == null:
			continue
		if not _watched.has(modifier):
			_watched.append(modifier)
			modifier.changed.connect(_configuration_changed)
			var initial := 0.0 if modifier.fade_in_seconds > 0.0 and not Engine.is_editor_hint() else modifier.weight
			_states[modifier] = {"alpha": initial, "target": modifier.weight, "authored": modifier.weight, "duration": modifier.fade_in_seconds, "remove": false}
		var state: Dictionary = _states[modifier]
		if state.authored != modifier.weight:
			state.authored = modifier.weight
			state.target = modifier.weight
			state.duration = modifier.fade_in_seconds if state.target > state.alpha else modifier.fade_out_seconds
			state.remove = false
		if state.duration <= 0.0 or Engine.is_editor_hint():
			state.alpha = state.target
		fading = fading or (modifier.weight_mode == DynamicSkyModifier.WeightMode.MANUAL and not is_equal_approx(state.alpha, state.target))
	set_process(fading and not Engine.is_editor_hint())


func _register_layer(modifier: DynamicSkyModifier) -> void:
	if not layers.has(modifier):
		var next := layers.duplicate()
		next.append(modifier)
		layers = next


func _set_runtime_target(modifier: DynamicSkyModifier, alpha: float, duration: float, remove: bool) -> void:
	var state: Dictionary = _states[modifier]
	state.target = alpha
	state.duration = maxf(duration, 0.0) if is_finite(duration) else 0.0
	state.remove = remove
	_configuration_changed()


func _erase_layer(modifier: DynamicSkyModifier) -> void:
	restore_base()
	var next := layers.duplicate()
	next.erase(modifier)
	layers = next


func _can_control_manual(modifier: DynamicSkyModifier) -> bool:
	if modifier == null:
		return false
	if modifier.weight_mode == DynamicSkyModifier.WeightMode.CLOCK_WINDOW:
		_warn_once("manual:%s" % modifier.get_instance_id(), "A clock-window modifier is controlled by its hour ranges. Use a manual modifier for the runtime alpha and fade API.")
		return false
	return true


func _apply_property(adjustment: DynamicSkyModifierProperty, weight: float, target: Object) -> void:
	if not adjustment.get_supported_properties().has(String(adjustment.property_name)):
		_warn_adjustment(adjustment)
		return
	var is_shader := adjustment.target == DynamicSkyModifierProperty.Target.SKY_SHADER
	var current: Variant
	var original: Variant
	if is_shader:
		var material := target as ShaderMaterial
		if material.shader == null:
			return
		original = material.get_shader_parameter(adjustment.property_name)
		current = original
		var declared := material.shader.get_shader_uniform_list()
		if not declared.is_empty() and not _has_compatible_property(declared, adjustment):
			_warn_adjustment(adjustment)
			return
		if current == null:
			current = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), adjustment.property_name)
		if current is Vector3 and adjustment.value_type == DynamicSkyModifierProperty.ValueType.COLOR:
			current = Color(current.x, current.y, current.z)
	else:
		if not _has_compatible_property(target.get_property_list(), adjustment):
			_warn_adjustment(adjustment)
			return
		current = target.get(adjustment.property_name)
		original = current
	var scalar := adjustment.value_type == DynamicSkyModifierProperty.ValueType.FLOAT
	if (scalar and not (current is float or current is int)) or (not scalar and not current is Color):
		_warn_adjustment(adjustment)
		return
	var result: Variant = adjustment.blend(current, weight)
	if (scalar and not is_finite(float(result))) or (not scalar and not _is_finite_color(result)):
		_warn_adjustment(adjustment)
		return
	var key := "%s/%s" % [target.get_instance_id(), adjustment.property_name]
	if not _captured_fields.has(key):
		var field := {"target": weakref(target), "name": adjustment.property_name, "shader": is_shader, "value": original}
		if is_shader:
			field.shader_ref = weakref((target as ShaderMaterial).shader)
		_base_fields.append(field)
		_captured_fields[key] = true
	if is_shader:
		(target as ShaderMaterial).set_shader_parameter(adjustment.property_name, result)
	else:
		target.set(adjustment.property_name, result)


func _has_compatible_property(property_list: Array, adjustment: DynamicSkyModifierProperty) -> bool:
	for property in property_list:
		if property.name != adjustment.property_name:
			continue
		if adjustment.value_type == DynamicSkyModifierProperty.ValueType.FLOAT:
			return property.type == TYPE_FLOAT
		return property.type == TYPE_COLOR
	return false


func _is_finite_color(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)


func _warn_adjustment(adjustment: DynamicSkyModifierProperty) -> void:
	var key := "field:%s/%s/%s" % [adjustment.target, adjustment.value_type, adjustment.property_name]
	_warn_once(key, "Skipped sky modifier field '%s'. Select a supported property with a matching float or color type on the current target." % adjustment.property_name)


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
