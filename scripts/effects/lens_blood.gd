class_name LensBlood
extends Node2D
## Draws temporary blood drops and smears over the local player's view.

const SCREEN_CENTER := Vector2(0.5, 0.5)
const FADE_OUT_START := 0.8

class Mark:
	var sprite: Sprite2D
	var screen_position: Vector2
	var size: float
	var aspect: float = 1.0
	var is_smear: bool
	var fall_speed: float
	var lifetime: float
	var opacity: float
	var age: float = 0.0
	var fade_in_fraction: float = 0.0
	var tint: Color = Color.WHITE

## Atlas regions used for the small drops that move down the screen.
@export var drop_textures: Array[Texture2D] = []
## Material that tints the small drops using the atlas alpha as a mask.
@export var drop_material: ShaderMaterial
## Atlas regions used for the stationary spray marks along the edges of the view.
@export var smear_textures: Array[Texture2D] = []
## Material that converts the grayscale edge spray into a tinted transparent mark.
@export var smear_material: Material
## Seconds after the hit at which to emit each batch of small drops.
@export var burst_delays: PackedFloat32Array = PackedFloat32Array()
## Number of small drops emitted in each batch.
@export_range(0, 24, 1) var drops_per_burst: int = 10
## Number of larger smears placed around the edge at the start of the effect.
@export_range(0, 12, 1) var edge_smears: int = 3
## Minimum and maximum side length of a spray quad, in fractions of half the viewport diagonal.
@export var smear_size: Vector2 = Vector2(0.30, 0.60)
## Minimum and maximum spray distance from the center in normalized screen coordinates.
## A radius of 0.5 reaches the center of each edge.
@export var smear_ring_radius: Vector2 = Vector2(0.40, 0.50)
## Minimum and maximum small-drop lifetime in seconds.
@export var drop_lifetime: Vector2 = Vector2(3.0, 5.0)
## Minimum and maximum drop quad height as fractions of the viewport height.
@export var drop_size: Vector2 = Vector2(0.010, 0.052)
## Minimum and maximum height-to-width ratio for drop quads.
@export var drop_aspect: Vector2 = Vector2(1.2, 1.85)
## Minimum and maximum per-drop alpha before the tint and overlay opacity are applied.
@export var drop_opacity: Vector2 = Vector2(0.32, 0.92)
## Minimum and maximum edge-smear lifetime in seconds.
@export var smear_lifetime: Vector2 = Vector2(3.0, 4.0)
## Minimum and maximum downward speed for drops, in fractions of the viewport height per second.
@export var drop_fall_speed: Vector2 = Vector2(0.004, 0.008)
## Color and alpha multiplier applied to the neutral edge spray artwork.
@export var edge_tint: Color = Color(0.065, 0.014, 0.022, 0.85)
## Multiplies the alpha of both kinds of mark.
@export_range(0.0, 1.0, 0.01) var opacity: float = 0.82
## Maximum simultaneous marks. New marks replace the oldest at the limit.
@export_range(1, 128, 1) var mark_limit: int = 64

var _marks: Array[Mark] = []
var _pending_bursts: Array[float] = []
var _last_drop_variant := -1
var _last_smear_variant := -1


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	for index in range(_marks.size() - 1, -1, -1):
		var mark := _marks[index]
		mark.age += delta
		if mark.age >= mark.lifetime:
			_remove_mark(index)
		else:
			_place_mark(mark, viewport_size)

	for index in range(_pending_bursts.size() - 1, -1, -1):
		_pending_bursts[index] -= delta
		if _pending_bursts[index] <= 0.0:
			_pending_bursts.remove_at(index)
			_spawn_marks(drops_per_burst, false, viewport_size)

	set_process(not _marks.is_empty() or not _pending_bursts.is_empty())


## Plays one splatter, adding its marks to any that are already fading.
func play_splatter() -> void:
	if opacity <= 0.0:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	_spawn_marks(edge_smears, true, viewport_size)
	if not drop_textures.is_empty() and drops_per_burst > 0:
		for delay in burst_delays:
			if delay <= 0.0:
				_spawn_marks(drops_per_burst, false, viewport_size)
			else:
				_pending_bursts.append(delay)
	set_process(not _marks.is_empty() or not _pending_bursts.is_empty())


func _spawn_marks(count: int, is_smear: bool, viewport_size: Vector2) -> void:
	var textures := smear_textures if is_smear else drop_textures
	if textures.is_empty():
		return
	var lifetime_range := smear_lifetime if is_smear else drop_lifetime
	for _index in count:
		var previous_variant := _last_smear_variant if is_smear else _last_drop_variant
		var variant := _pick_variant(textures.size(), previous_variant)
		if is_smear:
			_last_smear_variant = variant
		else:
			_last_drop_variant = variant
		var texture := textures[variant]
		if texture == null or texture.get_width() == 0 or texture.get_height() == 0:
			continue
		if _marks.size() >= mark_limit:
			_remove_mark(0)
		var mark := Mark.new()
		mark.sprite = Sprite2D.new()
		mark.sprite.texture = texture
		mark.sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mark.sprite.material = smear_material if is_smear else drop_material
		mark.sprite.flip_h = randf() < 0.5
		mark.is_smear = is_smear
		mark.lifetime = maxf(0.05, randf_range(lifetime_range.x, lifetime_range.y))
		var ray := Vector2.from_angle(randf_range(0.0, TAU))
		if is_smear:
			var radius := randf_range(smear_ring_radius.x, smear_ring_radius.y)
			mark.screen_position = SCREEN_CENTER + ray * radius
			mark.size = maxf(0.0, randf_range(smear_size.x, smear_size.y))
			mark.opacity = 1.0
			mark.fade_in_fraction = 0.03
			mark.tint = edge_tint
			mark.sprite.rotation = randf_range(-0.9, 0.9)
		else:
			mark.screen_position = SCREEN_CENTER + ray * randf_range(0.13, 0.53)
			mark.size = maxf(0.0, randf_range(drop_size.x, drop_size.y))
			mark.aspect = maxf(0.01, randf_range(drop_aspect.x, drop_aspect.y))
			mark.fall_speed = maxf(0.0, randf_range(drop_fall_speed.x, drop_fall_speed.y))
			mark.opacity = clampf(randf_range(drop_opacity.x, drop_opacity.y), 0.0, 1.0)
			mark.sprite.rotation = randf_range(-0.18, 0.18)
		add_child(mark.sprite)
		_marks.append(mark)
		_place_mark(mark, viewport_size)


func _pick_variant(count: int, previous: int) -> int:
	if previous < 0 or previous >= count or count == 1:
		return randi_range(0, count - 1)
	return (previous + randi_range(1, count - 1)) % count


func _place_mark(mark: Mark, viewport_size: Vector2) -> void:
	var age_fraction := mark.age / mark.lifetime
	var fade := 1.0 - smoothstep(FADE_OUT_START, 1.0, age_fraction)
	if mark.fade_in_fraction > 0.0:
		fade *= smoothstep(0.0, mark.fade_in_fraction, age_fraction)
	var texture_size := mark.sprite.texture.get_size()
	var motion := Vector2(0.0, mark.fall_speed * mark.age)
	mark.sprite.position = (mark.screen_position + motion) * viewport_size
	if mark.is_smear:
		var side := mark.size * viewport_size.length() * 0.5
		mark.sprite.scale = Vector2(side, side) / texture_size
	else:
		var height := mark.size * viewport_size.y
		mark.sprite.scale = Vector2(height / mark.aspect, height) / texture_size
	var tint := mark.tint
	tint.a *= mark.opacity * opacity * fade
	mark.sprite.self_modulate = tint


func _remove_mark(index: int) -> void:
	_marks[index].sprite.queue_free()
	_marks.remove_at(index)
