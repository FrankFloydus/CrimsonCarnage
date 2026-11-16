@tool
class_name WeaponRichFloatCurve
extends Resource
## A float curve with independent incoming and outgoing cubic tangent attributes.

## Interpolation and tangent behavior for a key's outgoing segment.
enum Mode {
	## Hold the key's value until the following key.
	CONSTANT,
	## Interpolate between the two key values along a straight line.
	LINEAR,
	## Compute a smooth tangent from the neighboring keys.
	AUTO,
	## Edit incoming and outgoing tangents independently.
	BREAK,
	## Preserve a saved Godot Curve's independent linear or free tangent rules.
	LEGACY,
}

const MIN_HANDLE_TIME := 0.00000001
const ROOT_TOLERANCE := 0.000000000001

## Sorted keys in normalized clip time, with slopes in value per unit of clip time.
@export_storage var keys: Array[Dictionary] = []

var point_count: int:
	get:
		return keys.size()


## Convert a native Godot Curve without changing its sampled shape.
func load_native(curve: Curve) -> bool:
	if curve == null or curve.min_domain != 0.0 or curve.max_domain != 1.0:
		return false
	keys.clear()
	var all_linear := true
	for index in curve.point_count:
		var position := curve.get_point_position(index)
		var key := _key(position.x, position.y, Mode.LEGACY)
		key.in_slope = curve.get_point_left_tangent(index)
		key.out_slope = curve.get_point_right_tangent(index)
		key.in_linear = curve.get_point_left_mode(index) == Curve.TANGENT_LINEAR
		key.out_linear = curve.get_point_right_mode(index) == Curve.TANGENT_LINEAR
		all_linear = all_linear and (index == 0 or key.in_linear) \
				and (index == curve.point_count - 1 or key.out_linear)
		if index > 0 and is_zero_approx(position.x - curve.get_point_position(index - 1).x):
			all_linear = false
		keys.append(key)
	if all_linear:
		for index in keys.size():
			var key := keys[index]
			keys[index] = _key(key.phase, key.value, Mode.LINEAR)
	return is_valid()


## Return a key's normalized time and value.
func get_point_position(index: int) -> Vector2:
	return Vector2(keys[index].phase, keys[index].value)


## Return the authored time without narrowing it to a Vector2 coordinate.
func get_key_phase(index: int) -> float:
	return keys[index].phase


## Return the authored value without rounding through Vector2.
func get_key_value(index: int) -> float:
	return keys[index].value


## Return a key's serialized interpolation mode.
func get_key_mode(index: int) -> int:
	return keys[index].mode


## Return detached key attributes with automatic slopes resolved for display.
func key_info(index: int) -> Dictionary:
	var info := keys[index].duplicate()
	info.in_slope = _slope(index, true)
	info.out_slope = _slope(index, false)
	return info


## Whether the key side belongs to a cubic segment and can be edited.
func has_handle(index: int, incoming: bool) -> bool:
	var next_index := index - 1 if incoming else index + 1
	return _has_index(index) and _has_index(next_index) and _is_cubic(keys[index].mode) \
			and (not incoming or _is_cubic(keys[next_index].mode))


## Return the actual control point's offset in normalized time and value coordinates.
func get_handle_offset(index: int, incoming: bool) -> Vector2:
	var slope := _slope(index, incoming)
	var offset := _handle_time(index, incoming, slope)
	return Vector2(offset, offset * slope)


## Sample the piecewise curve at normalized clip time.
func sample(phase: float) -> float:
	if keys.is_empty() or not is_finite(phase):
		return 0.0
	var right_index := _lower_bound(keys, phase)
	if right_index == keys.size():
		return keys[-1].value
	var right := keys[right_index]
	if right_index == 0 or phase == right.phase:
		return right.value
	var left_index := right_index - 1
	var left := keys[left_index]
	var span: float = right.phase - left.phase
	if left.mode == Mode.LEGACY and is_zero_approx(span):
		return right.value
	var direction: float = (phase - left.phase) / span
	match left.mode:
		Mode.CONSTANT:
			return left.value
		Mode.LINEAR:
			return lerpf(left.value, right.value, direction)
	var out_slope := _slope(left_index, false)
	var in_slope := _slope(right_index, true)
	var out_time := _handle_time(left_index, false, out_slope)
	var in_time := _handle_time(right_index, true, in_slope)
	if left.weighted_out or right.weighted_in:
		direction = _parameter_at_time(direction, out_time / span, 1.0 + in_time / span)
	return _cubic(left.value, left.value + out_time * out_slope,
			right.value + in_time * in_slope, right.value, direction)


## Insert a key with a distinct time, returning its index or -1 on failure.
func add_key(phase: float, value: float) -> int:
	if not _valid_position(phase, value):
		return -1
	var index := _lower_bound(keys, phase)
	if _has_index(index) and keys[index].phase == phase:
		return -1
	keys.insert(index, _key(phase, value, Mode.LINEAR))
	return index


## Move one key to an exact time and value, returning its new index.
func set_key_position(index: int, phase: float, value: float) -> int:
	if not _has_index(index) or not _valid_position(phase, value):
		return -1
	var location := _lower_bound(keys, phase)
	if _has_index(location) and keys[location].phase == phase and location != index:
		return -1
	if keys[index].phase == phase and keys[index].value == value:
		return index
	var key := keys[index].duplicate()
	key.phase = phase
	key.value = value
	keys.remove_at(index)
	if location > index:
		location -= 1
	keys.insert(location, key)
	return location


## Apply one delta to the entire selection. Return new indexes in the same order.
## Invalid destinations or coincident times reject the whole gesture.
func move_keys(selection: Variant, delta: Vector2) -> PackedInt32Array:
	var indexes := _selection_indexes(selection)
	if indexes.is_empty() or not delta.is_finite() or delta == Vector2.ZERO:
		return PackedInt32Array()
	var phase_delta := _exact_endpoint_delta(indexes, delta.x)
	var candidate := keys.duplicate()
	var times := PackedFloat64Array()
	for index in indexes:
		var key := keys[index].duplicate()
		key.phase += phase_delta
		key.value += delta.y
		if not _valid_position(key.phase, key.value):
			return PackedInt32Array()
		times.append(key.phase)
		candidate[index] = key
	candidate.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.phase < b.phase)
	for index in range(1, candidate.size()):
		if candidate[index - 1].phase == candidate[index].phase:
			return PackedInt32Array()
	var remapped := PackedInt32Array()
	for phase in times:
		remapped.append(_lower_bound(candidate, phase))
	keys = candidate
	return remapped


## Blend selected values toward the preceding (-1) or following (+1) neighbor.
## Each contiguous group has its own neighbor. At a curve boundary, use that group's edge value.
func blend_neighbor(selection: Variant, amount: float) -> bool:
	if not is_finite(amount) or amount == 0.0 or absf(amount) > 1.0:
		return false
	var indexes := _selection_indexes(selection)
	if indexes.is_empty():
		return false
	indexes.sort()
	var direction := -1 if amount < 0.0 else 1
	if direction > 0:
		indexes.reverse()

	var strength := absf(amount)
	var neighbor_value := 0.0
	var last_index := -2
	var blended_values := PackedFloat64Array()
	var changed := false
	for index in indexes:
		if index + direction != last_index:
			var neighbor := clampi(index + direction, 0, keys.size() - 1)
			neighbor_value = keys[neighbor].value
		var original: float = keys[index].value
		var blended := neighbor_value if strength == 1.0 else lerpf(original, neighbor_value, strength)
		if not _valid_position(keys[index].phase, blended):
			return false
		blended_values.append(blended)
		changed = changed or blended != original
		last_index = index

	if changed:
		for offset in indexes.size():
			keys[indexes[offset]].value = blended_values[offset]
	return changed


func _exact_endpoint_delta(indexes: PackedInt32Array, delta: float) -> float:
	if delta == 0.0:
		return delta
	var min_phase := 1.0
	var max_phase := 0.0
	for index in indexes:
		min_phase = minf(min_phase, keys[index].phase)
		max_phase = maxf(max_phase, keys[index].phase)
	# A graph clamps its delta at the clip edges, then passes it in a Vector2.
	# Restore that exact limit if float32 rounding changed the bound.
	var limit := -min_phase if delta < 0.0 else 1.0 - max_phase
	return limit if Vector2(limit, 0.0).x == delta else delta


## Delete accepted key indexes as one edit.
func remove_keys(selection: Variant) -> bool:
	var indexes := _selection_indexes(selection)
	if indexes.is_empty():
		return false
	indexes.sort()
	for index in range(indexes.size() - 1, -1, -1):
		keys.remove_at(indexes[index])
	return true


## Assign interpolation to a selection, preserving the current slopes when breaking tangents.
func set_keys_mode(selection: Variant, mode: int) -> bool:
	var indexes := _selection_indexes(selection)
	if indexes.is_empty() or mode < Mode.CONSTANT or mode > Mode.BREAK:
		return false
	var changed := false
	for index in indexes:
		var key := keys[index]
		if key.mode == mode:
			continue
		if mode == Mode.BREAK:
			key.in_slope = _slope(index, true)
			key.out_slope = _slope(index, false)
		key.erase("in_linear")
		key.erase("out_linear")
		if not _is_cubic(mode):
			key.weighted_in = false
			key.weighted_out = false
		key.mode = mode
		changed = true
	return changed


## Toggle tangent weights on both sides, or pass a side to edit only that tangent.
func set_keys_weighted(selection: Variant, weighted: bool, incoming: Variant = null) -> bool:
	var indexes := _selection_indexes(selection)
	if indexes.is_empty():
		return false
	var changed := false
	for index in indexes:
		if incoming == null or incoming:
			changed = _set_weighted(index, true, weighted) or changed
		if incoming == null or not incoming:
			changed = _set_weighted(index, false, weighted) or changed
	return changed


## Move a tangent handle, converting Auto to Break while retaining the opposite slope.
func set_key_tangent(index: int, incoming: bool, offset: Vector2) -> bool:
	if not has_handle(index, incoming) or not offset.is_finite():
		return false
	var key := keys[index]
	var time := minf(offset.x, -MIN_HANDLE_TIME) if incoming else maxf(offset.x, MIN_HANDLE_TIME)
	var slope := offset.y / time
	var side := "in" if incoming else "out"
	var weighted: bool = key["weighted_" + side]
	var weight: float = sqrt(time * time + float(offset.y) * offset.y)
	if key.mode == Mode.BREAK and key[side + "_slope"] == slope \
			and (not weighted or key[side + "_weight"] == weight):
		return false
	set_keys_mode(PackedInt32Array([index]), Mode.BREAK)
	key[side + "_slope"] = slope
	if weighted:
		key[side + "_weight"] = weight
	return true


## Validate serialized key positions and tangent attributes.
func is_valid() -> bool:
	var previous := -1.0
	for key in keys:
		if not _number(key.get("phase")) or not _number(key.get("value")) \
				or not _valid_position(key.phase, key.value) or key.phase <= previous \
				or not key.get("mode") is int or key.mode < Mode.CONSTANT or key.mode > Mode.LEGACY:
			return false
		for side: String in ["in", "out"]:
			if not _number(key.get(side + "_slope")) or not _number(key.get(side + "_weight")) \
					or key[side + "_weight"] < 0.0 or not key.get("weighted_" + side) is bool:
				return false
			if key.mode == Mode.LEGACY and not key.get(side + "_linear") is bool:
				return false
		previous = key.phase
	return true


## Compare authored keys, including values shortened by Godot's text resource writer.
func same_keys(other: Resource) -> bool:
	if keys == other.keys:
		return true
	if keys.size() != other.keys.size():
		return false
	for index in keys.size():
		var first := keys[index]
		var second: Dictionary = other.keys[index]
		if first.size() != second.size():
			return false
		for field: Variant in first:
			var left: Variant = first[field]
			var right: Variant = second.get(field)
			if left == right:
				continue
			if not left is float or not right is float or not _same_saved_float(left, right):
				return false
	return true


static func _same_saved_float(left: float, right: float) -> bool:
	# VariantWriter can shorten an exactly representable float32 to that width's
	# decimal round-trip value, then load it as a double.
	var left_as_float := Vector2(left, 0.0).x
	var right_as_float := Vector2(right, 0.0).x
	return left_as_float == right_as_float and (left_as_float == left or right_as_float == right)


func _set_weighted(index: int, incoming: bool, weighted: bool) -> bool:
	if not has_handle(index, incoming):
		return false
	var key := keys[index]
	var side := "in" if incoming else "out"
	if key["weighted_" + side] == weighted:
		return false
	if weighted:
		var slope := _slope(index, incoming)
		var time := _handle_time(index, incoming, slope)
		key[side + "_weight"] = absf(time) * sqrt(1.0 + slope * slope)
	key["weighted_" + side] = weighted
	return true


func _slope(index: int, incoming: bool) -> float:
	var key := keys[index]
	var next := index - 1 if incoming else index + 1
	var side := "in" if incoming else "out"
	match key.mode:
		Mode.AUTO:
			return _secant(index - 1, index + 1) if index > 0 and index + 1 < keys.size() else 0.0
		Mode.LINEAR:
			return _secant(index, next) if _has_index(next) else 0.0
		Mode.LEGACY:
			if key[side + "_linear"] and _has_index(next):
				return _secant(index, next)
	return key[side + "_slope"]


func _secant(first: int, second: int) -> float:
	return (keys[second].value - keys[first].value) / (keys[second].phase - keys[first].phase)


func _handle_time(index: int, incoming: bool, slope: float) -> float:
	var key := keys[index]
	var next := index - 1 if incoming else index + 1
	if not _has_index(next):
		return 0.0
	var side := "in" if incoming else "out"
	if key["weighted_" + side]:
		return (-1.0 if incoming else 1.0) * key[side + "_weight"] / sqrt(1.0 + slope * slope)
	return (keys[next].phase - key.phase) / 3.0


func _selection_indexes(selection: Variant) -> PackedInt32Array:
	if not selection is PackedInt32Array and not selection is Array:
		return PackedInt32Array()
	var indexes := PackedInt32Array()
	var seen := {}
	for index: Variant in selection:
		if not index is int or not _has_index(index) or seen.has(index):
			return PackedInt32Array()
		indexes.append(index)
		seen[index] = true
	return indexes


func _has_index(index: int) -> bool:
	return index >= 0 and index < keys.size()


static func _key(phase: float, value: float, mode: int) -> Dictionary:
	return {
		"phase": phase, "value": value, "mode": mode, "in_slope": 0.0, "out_slope": 0.0,
		"in_weight": 0.0, "out_weight": 0.0, "weighted_in": false, "weighted_out": false,
	}


static func _is_cubic(mode: int) -> bool:
	return mode in [Mode.AUTO, Mode.BREAK, Mode.LEGACY]


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _valid_position(phase: float, value: float) -> bool:
	return is_finite(phase) and phase >= 0.0 and phase <= 1.0 and is_finite(value) \
			and Vector2(phase, value).is_finite()


static func _lower_bound(list: Array[Dictionary], phase: float) -> int:
	var lower := 0
	var upper := list.size()
	while lower < upper:
		var mid := (lower + upper) >> 1
		if list[mid].phase < phase:
			lower = mid + 1
		else:
			upper = mid
	return lower


static func _cubic(a: float, b: float, c: float, d: float, t: float) -> float:
	var s := 1.0 - t
	return a * s * s * s + 3.0 * b * s * s * t + 3.0 * c * s * t * t + d * t * t * t


static func _parameter_at_time(time: float, x1: float, x2: float) -> float:
	# Most handles stay between their neighboring keys, yielding a monotonic curve.
	if x1 >= 0.0 and x1 <= 1.0 and x2 >= 0.0 and x2 <= 1.0:
		return _solve_time(time, x1, x2, 0.0, 1.0, true)

	# Long weighted handles can fold time. Split at stationary points and solve
	# the last interval containing this time, choosing the largest valid root.
	var cuts := PackedFloat64Array([0.0, 1.0])
	var a := 1.0 + 3.0 * (x1 - x2)
	var b := 2.0 * (x2 - 2.0 * x1)
	var c := x1
	if absf(a) <= ROOT_TOLERANCE:
		if absf(b) > ROOT_TOLERANCE:
			_add_cut(cuts, -c / b)
	else:
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var root := sqrt(discriminant) * (1.0 if b >= 0.0 else -1.0)
			var numerator := -0.5 * (b + root)
			_add_cut(cuts, numerator / a)
			if numerator != 0.0:
				_add_cut(cuts, c / numerator)
	cuts.sort()
	for index in range(cuts.size() - 2, -1, -1):
		var lower := cuts[index]
		var upper := cuts[index + 1]
		var start := _cubic(0.0, x1, x2, 1.0, lower)
		var end := _cubic(0.0, x1, x2, 1.0, upper)
		if time >= minf(start, end) and time <= maxf(start, end):
			return _solve_time(time, x1, x2, lower, upper, start <= end)
	return time


static func _add_cut(cuts: PackedFloat64Array, value: float) -> void:
	if value > 0.0 and value < 1.0:
		cuts.append(value)


static func _solve_time(time: float, x1: float, x2: float, lower: float, upper: float,
		increasing: bool) -> float:
	var parameter := time if time > lower and time < upper else (upper + lower) * 0.5
	# Newton converges with few evaluations for ordinary tangent lengths. Fall
	# back to the bracket midpoint when the derivative or proposed step is unusable.
	for iteration in 48:
		if upper - lower <= ROOT_TOLERANCE:
			break
		var error := _cubic(0.0, x1, x2, 1.0, parameter) - time
		if error == 0.0:
			return parameter
		if (error < 0.0) == increasing:
			lower = parameter
		else:
			upper = parameter
		var remaining := 1.0 - parameter
		var derivative := 3.0 * (x1 * remaining * remaining \
				+ 2.0 * (x2 - x1) * remaining * parameter + (1.0 - x2) * parameter * parameter)
		if derivative != 0.0:
			var correction := error / derivative
			if absf(correction) <= ROOT_TOLERANCE:
				return parameter
			var next := parameter - correction
			if next > lower and next < upper:
				parameter = next
				continue
		parameter = (upper + lower) * 0.5
	return (upper + lower) * 0.5
