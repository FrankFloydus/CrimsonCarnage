extends RefCounted
## Bounded, receiver-local compression and rim field. Horizontal positions use meters.

const MAX_AXIS_SAMPLES := 512
const RESTORATION_STEP := 5
const RESTORATION_SNAP := 3
const IMPACT_EXTENT := 1.44

var size: Vector2i
var extent: Vector2
var spacing: Vector2
var pixels: PackedByteArray
var _occupied: PackedInt32Array
var _strengths: PackedFloat32Array


func _init(extent_meters: Vector2, target_spacing: float) -> void:
	extent = extent_meters
	size = sample_count(extent, target_spacing)
	spacing = extent / Vector2(size)
	pixels.resize(size.x * size.y * 2)
	_strengths.resize(size.x * size.y)


static func sample_count(extent_meters: Vector2, target_spacing: float) -> Vector2i:
	return Vector2i(
		clampi(ceili(extent_meters.x / target_spacing), 4, MAX_AXIS_SAMPLES),
		clampi(ceili(extent_meters.y / target_spacing), 4, MAX_AXIS_SAMPLES)
	)


func contains(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, extent).has_point(point)


func stamp(from: Vector2, to: Vector2, diameter: float, pressure: float) -> bool:
	var radius := diameter * 0.5
	var margin := Vector2.ONE * (radius * IMPACT_EXTENT * 1.10)
	var lower := Vector2i(((from.min(to) - margin) / spacing).floor()).max(Vector2i.ZERO)
	var upper := Vector2i(((from.max(to) + margin) / spacing).ceil()).min(size)
	var segment := to - from
	var inverse_length_squared := 1.0 / maxf(segment.length_squared(), 0.000001)
	var changed := false
	for y in range(lower.y, upper.y):
		for x in range(lower.x, upper.x):
			var point := (Vector2(x, y) + Vector2(0.5, 0.5)) * spacing
			var along := clampf((point - from).dot(segment) * inverse_length_squared, 0.0, 1.0)
			var distance := point.distance_to(from + segment * along) / radius
			if distance >= IMPACT_EXTENT * 1.10:
				continue
			var uneven := _noise(point * 9.0)
			var granular := _noise(point * 27.0 + Vector2(16.0, 8.0))
			distance /= 0.91 + 0.12 * uneven + 0.07 * granular
			if distance >= IMPACT_EXTENT:
				continue
			var strength := pressure * (1.0 - distance / IMPACT_EXTENT)
			var index := y * size.x + x
			# The same closest or stronger imprint owns the bowl and lip.
			if strength <= _strengths[index] + 0.00001:
				continue
			var bowl := pow(maxf(1.0 - distance * distance, 0.0), 1.65)
			bowl *= pressure * lerpf(0.88, 1.0, granular)
			var rim := smoothstep(0.76, 1.04, distance) * (1.0 - smoothstep(1.04, IMPACT_EXTENT, distance))
			rim *= pressure * lerpf(0.26, 0.85, uneven * 0.63 + granular * 0.37)
			var offset := index * 2
			var next_depth := roundi(bowl * 255.0)
			var next_rim := roundi(rim * 255.0)
			if next_depth == 0 and next_rim == 0:
				continue
			if pixels[offset] == 0 and pixels[offset + 1] == 0:
				_occupied.append(index)
			_strengths[index] = strength
			if pixels[offset] != next_depth or pixels[offset + 1] != next_rim:
				pixels[offset] = next_depth
				pixels[offset + 1] = next_rim
				changed = true
	return changed


func restore_step() -> void:
	var remaining: PackedInt32Array
	for index in _occupied:
		var offset := index * 2
		var previous_peak := maxi(pixels[offset], pixels[offset + 1])
		var depression := pixels[offset] - RESTORATION_STEP
		var rim := pixels[offset + 1] - RESTORATION_STEP
		pixels[offset] = depression if depression > RESTORATION_SNAP else 0
		pixels[offset + 1] = rim if rim > RESTORATION_SNAP else 0
		var peak := maxi(pixels[offset], pixels[offset + 1])
		if peak > 0:
			_strengths[index] *= float(peak) / previous_peak
			remaining.append(index)
		else:
			_strengths[index] = 0.0
	_occupied = remaining


func clear() -> void:
	pixels.fill(0)
	_occupied.clear()
	_strengths.fill(0.0)


func has_marks() -> bool:
	return not _occupied.is_empty()


func get_image() -> Image:
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RG8, pixels)


func _noise(point: Vector2) -> float:
	var cell := Vector2i(point.floor())
	var t := point - Vector2(cell)
	t = t * t * (Vector2.ONE * 3.0 - t * 2.0)
	var low := lerpf(_hash(cell), _hash(cell + Vector2i.RIGHT), t.x)
	var high := lerpf(_hash(cell + Vector2i.DOWN), _hash(cell + Vector2i.ONE), t.x)
	return lerpf(low, high, t.y)


func _hash(cell: Vector2i) -> float:
	return float(hash(cell) & 65535) / 65535.0
