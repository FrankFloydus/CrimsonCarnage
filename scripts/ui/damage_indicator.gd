@tool
class_name DamageIndicator
extends Control
## Draws short-lived HUD markers that point toward recorded hit positions.

## Identifies the authored alpha mask drawn by the marker.
enum MarkerStyle {
	## Irregular, feathered A1 crest.
	WORN_A1,
	## Original smooth A1 crest.
	ORIGINAL_A1,
	## Broad classic chevron.
	CLASSIC,
	## Shallow, diffuse arc.
	ASH_ARC,
	## Arc made of broken brush marks.
	SPLIT_BRUSH,
	## Chevron with uneven, torn edges.
	TORN_CHEVRON,
}

const REFERENCE_SIZE := Vector2(1920.0, 1080.0)
const REFERENCE_MARKER_WIDTH := 423.0
const FEATHER_PADDING_PIXELS := 24.0
const MAX_MARKERS := 3
const MERGE_ANGLE_DEGREES := 40.0

class Marker:
	var source_position: Vector3
	var tint: Color
	var age: float = 0.0

## Player body used for the marker's world position and horizontal facing direction.
@export var observer: Node3D
## Neutral artwork pointing up, indexed by MarkerStyle.
@export_storage var style_textures: Array[AtlasTexture]

@export_group("Editor Preview")
## Show steady markers with HDR bloom for this editor session.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var preview_enabled: bool = false:
	set(value):
		preview_enabled = value
		_request_refresh()
## Number of simultaneous preview markers, added clockwise from the top at 45° intervals.
@export_range(1, 8, 1) var preview_marker_count: int = 1:
	set(value):
		preview_marker_count = clampi(value, 1, 8)
		_request_refresh()
## Opacity and emission multiplier for the preview markers.
@export_range(0.0, 1.0, 0.01) var preview_strength: float = 1.0:
	set(value):
		preview_strength = value
		_request_refresh()
## Preview the friendly-fire tint instead of the hostile tint.
@export var preview_friendly_fire: bool = false:
	set(value):
		preview_friendly_fire = value
		_request_refresh()

@export_group("Marker")
## Selects the artwork used for incoming hits and the editor preview.
@export var marker_style: MarkerStyle = MarkerStyle.WORN_A1:
	set(value):
		marker_style = value
		_request_refresh()
## Fraction of the 423-pixel marker width to draw at 1920 × 1080.
@export_range(0.1, 1.0, 0.01, "suffix:×") var marker_scale: float = 0.28:
	set(value):
		marker_scale = value
		_request_refresh()
## Distance from screen center to the texture's near edge at 1920 × 1080.
@export_range(0.0, 400.0, 1.0, "suffix:px") var marker_distance: float = 400.0:
	set(value):
		marker_distance = value
		_request_refresh()
## Seconds for the marker to fade from full strength to clear in play.
@export_range(0.01, 25.0, 0.01, "suffix:s") var fade_time: float = 0.65
## Tint of a marker for a hit from an enemy or hostile source.
@export var hostile_tint: Color = Color(0.804, 0.196, 0.196):
	set(value):
		hostile_tint = value
		_request_refresh()
## Tint of a marker when the hit is flagged as friendly fire.
@export var friendly_tint: Color = Color(0.196, 0.804, 0.196):
	set(value):
		friendly_tint = value
		_request_refresh()

@export_group("Body")
## Opacity of the tinted mask before the inward feather.
@export_range(0.0, 1.0, 0.01) var crest_opacity: float = 0.38:
	set(value):
		crest_opacity = value
		_request_refresh()
## Minimum texture mip level used to soften the body edge.
@export_range(0.0, 5.0, 0.05) var edge_softness: float = 2.4:
	set(value):
		edge_softness = value
		_request_refresh()
## Opacity of the soft trail pointing inward toward screen center.
@export_range(0.0, 1.0, 0.01) var feather_opacity: float = 0.44:
	set(value):
		feather_opacity = value
		_request_refresh()
## Length of the inward trail, in pixels of the source atlas.
@export_range(0.0, 100.0, 1.0, "suffix:px") var feather_length: float = 96.0:
	set(value):
		feather_length = value
		_request_refresh()

@export_group("Glow")
## Render native HDR bloom around visible markers.
@export var glow_enabled: bool = true:
	set(value):
		glow_enabled = value
		_request_refresh()
## Peak linear light sent to the HDR viewport before bloom.
@export_range(0.0, 12.0, 0.05) var emission_energy: float = 4.0:
	set(value):
		emission_energy = value
		_request_refresh()
## Brightness of the composited bloom.
@export_range(0.0, 2.0, 0.01) var glow_intensity: float = 0.3:
	set(value):
		glow_intensity = value
		_request_refresh()
## Weight of the wider native bloom levels. Zero keeps only the compact level.
@export_range(0.0, 3.0, 0.01) var glow_spread: float = 1.0:
	set(value):
		glow_spread = value
		_request_refresh()
## HDR brightness at which the glow pass starts collecting light.
@export_range(0.0, 4.0, 0.01) var glow_threshold: float = 0.65:
	set(value):
		glow_threshold = value
		_request_refresh()

var marker_texture: AtlasTexture:
	get:
		if marker_style < 0 or marker_style >= style_textures.size():
			return null
		return style_textures[marker_style]

var _markers: Array[Marker] = []
var _refresh_pending: bool = false

@onready var _body_material: ShaderMaterial = material as ShaderMaterial
@onready var _bloom_viewport: SubViewport = $BloomViewport
@onready var _bloom_composite: Control = $BloomComposite
@onready var _emission: Node2D = $BloomViewport/Emission
@onready var _emission_material: ShaderMaterial = _emission.material as ShaderMaterial
@onready var _bloom_environment: Environment = ($BloomViewport/Environment as WorldEnvironment).environment


func _ready() -> void:
	set_process(false)
	resized.connect(_resize_bloom_viewport)
	if Engine.is_editor_hint():
		tree_entered.connect(_apply_configuration, CONNECT_DEFERRED)
		tree_exiting.connect(_set_bloom_active.bind(false))
	_resize_bloom_viewport()
	_apply_configuration()


func _notification(what: int) -> void:
	if not Engine.is_editor_hint() or not is_node_ready():
		return
	# Save the scene with its internal bloom nodes idle, even while previewing.
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_set_bloom_active(false)
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_update_bloom_activity()


## Displays an incoming hit from a fixed world position.
func show_hit(source_position: Vector3, friendly_fire: bool = false) -> void:
	if Engine.is_editor_hint() or not is_instance_valid(observer) or marker_texture == null or fade_time <= 0.0:
		return
	var direction := _horizontal_offset(source_position).normalized()
	if direction.is_zero_approx():
		return

	var merge_dot := cos(deg_to_rad(MERGE_ANGLE_DEGREES))
	for index in range(_markers.size() - 1, -1, -1):
		var old_direction := _horizontal_offset(_markers[index].source_position).normalized()
		var alignment := old_direction.dot(direction)
		if alignment >= merge_dot or is_equal_approx(alignment, merge_dot):
			_markers.remove_at(index)
	if _markers.size() >= MAX_MARKERS:
		_markers.pop_front()

	var marker := Marker.new()
	marker.source_position = source_position
	marker.tint = friendly_tint if friendly_fire else hostile_tint
	_markers.append(marker)
	set_process(true)
	_update_bloom_activity()
	_redraw_markers()


func _process(delta: float) -> void:
	for index in range(_markers.size() - 1, -1, -1):
		var marker := _markers[index]
		marker.age += delta
		if marker.age >= fade_time:
			_markers.remove_at(index)
	if _markers.is_empty():
		set_process(false)
		_update_bloom_activity()
	_redraw_markers()


func _draw() -> void:
	_draw_markers(self)


func _on_emission_draw() -> void:
	_draw_markers(_emission)


func _on_bloom_composite_draw() -> void:
	if not _has_markers():
		return
	_bloom_composite.draw_texture_rect(
		_bloom_viewport.get_texture(), Rect2(Vector2.ZERO, _bloom_composite.size), false
	)


func _draw_markers(canvas: CanvasItem) -> void:
	var artwork := marker_texture
	if not _has_markers() or artwork == null or artwork.atlas == null:
		return

	var center := size * 0.5
	var ui_scale := minf(size.x / REFERENCE_SIZE.x, size.y / REFERENCE_SIZE.y)
	var art_size := artwork.region.size
	if art_size.x <= 0.0 or ui_scale <= 0.0 or marker_scale <= 0.0:
		return
	var art_scale := REFERENCE_MARKER_WIDTH * marker_scale / art_size.x
	var marker_size := art_size * art_scale
	var rect := Rect2(Vector2(-marker_size.x * 0.5, -marker_distance - marker_size.y), marker_size)
	# Let the inward feather extend beyond the artwork crop.
	var padding := FEATHER_PADDING_PIXELS / ui_scale
	var draw_rect := rect.grow(padding)
	var source_rect := artwork.region.grow(padding / art_scale)
	if Engine.is_editor_hint():
		var preview_tint := friendly_tint if preview_friendly_fire else hostile_tint
		preview_tint.a *= preview_strength
		for index in range(preview_marker_count):
			var angle := float(index) * PI / 4.0
			canvas.draw_set_transform(center, angle, Vector2.ONE * ui_scale)
			canvas.draw_texture_rect_region(artwork.atlas, draw_rect, source_rect, preview_tint, false, false)
		return

	var back := observer.global_basis.z
	var forward := Vector2(-back.x, -back.z).normalized()
	var right := Vector2(-forward.y, forward.x)
	for marker in _markers:
		var offset := _horizontal_offset(marker.source_position)
		if offset.is_zero_approx():
			continue
		var bearing := atan2(right.dot(offset), forward.dot(offset))
		var progress := clampf(marker.age / maxf(fade_time, 0.01), 0.0, 1.0)
		var tint := marker.tint
		tint.a *= 1.0 - progress * progress * progress
		canvas.draw_set_transform(center, bearing, Vector2.ONE * ui_scale)
		canvas.draw_texture_rect_region(artwork.atlas, draw_rect, source_rect, tint, false, false)


func _has_markers() -> bool:
	if Engine.is_editor_hint():
		var edited_scene := get_tree().edited_scene_root
		return (
			preview_enabled and preview_strength > 0.0 and is_instance_valid(edited_scene)
			and (edited_scene == self or edited_scene.is_ancestor_of(self))
		)
	return not _markers.is_empty() and is_instance_valid(observer)


func _request_refresh() -> void:
	if not is_node_ready() or _refresh_pending:
		return
	_refresh_pending = true
	_apply_configuration.call_deferred()


func _apply_configuration() -> void:
	_refresh_pending = false
	if not is_inside_tree():
		return
	_body_material.set_shader_parameter(&"crest_opacity", crest_opacity)
	_body_material.set_shader_parameter(&"edge_softness", edge_softness)
	_body_material.set_shader_parameter(&"feather_opacity", feather_opacity)
	_body_material.set_shader_parameter(&"feather_length", feather_length)
	_emission_material.set_shader_parameter(&"emission_energy", emission_energy)
	_bloom_environment.glow_enabled = glow_enabled
	_bloom_environment.glow_intensity = glow_intensity
	_bloom_environment.glow_hdr_threshold = glow_threshold
	_bloom_environment.set_glow_level(2, 0.4 * glow_spread)
	_bloom_environment.set_glow_level(3, 0.1 * glow_spread * glow_spread)
	_update_bloom_activity()
	_redraw_markers()


func _update_bloom_activity() -> void:
	var active := _has_markers() and marker_texture != null and glow_enabled and emission_energy > 0.0 and glow_intensity > 0.0
	_set_bloom_active(active)


func _set_bloom_active(active: bool) -> void:
	_emission.visible = active
	_bloom_composite.visible = active
	_bloom_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if active else SubViewport.UPDATE_DISABLED
	_bloom_composite.queue_redraw()


func _resize_bloom_viewport() -> void:
	_bloom_viewport.size = Vector2i(size.ceil()).max(Vector2i(2, 2))
	_redraw_markers()


func _redraw_markers() -> void:
	queue_redraw()
	_emission.queue_redraw()


func _horizontal_offset(source_position: Vector3) -> Vector2:
	var offset := source_position - observer.global_position
	return Vector2(offset.x, offset.z)
