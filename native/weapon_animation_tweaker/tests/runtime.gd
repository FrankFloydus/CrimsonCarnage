# Copyright Francesco Di Blasi 2026 - All Rights Reserved

extends SceneTree


class LegacyTracks extends Resource:
	var version := 1
	var markers: Array[Dictionary] = []
	var notify_tracks: Array[Dictionary] = []
	var curve_tracks: Array[Dictionary] = []


class LegacyRichCurve extends Resource:
	var keys: Array[Dictionary] = []


class LegacyCombo extends Resource:
	var display_name := "Legacy combo"
	var clip_keys: Array[StringName] = [&"sword/swing", &"sword/recover"]
	var joins: Array[Dictionary] = [
		{"exit_marker": &"Contact", "entry_marker": &"Entry", "blend_duration": 0.12, "exit_time": 0.9},
		{"exit_time": 0.7, "entry_time": 0.1, "blend_duration": 0.05},
	]
	var loop := true


const TRACK_META := &"weapon_tweaker_tracks"
const SWING := &"sword/swing"
const RECOVER := &"sword/recover"
const THIRD := &"sword/salute"
const LIBRARY_PATH := "user://weapon_animation_runtime_library.tres"
const COMBO_PATH := "user://weapon_animation_runtime_combo.tres"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var source_clip := _make_swing()
	var target_clip := Animation.new()
	target_clip.length = 1.25
	var target_tracks := CrimsonWeaponAnimationTracks.new()
	target_tracks.markers = [{"name": &"Entry", "time": 0.25}]
	_expect(target_tracks.write_to(target_clip), "native target tracks attach")
	_expect(CrimsonWeaponAnimationClip.from_animation(Animation.new()) != null, "clip without tracks can be read")

	var library_asset := AnimationLibrary.new()
	library_asset.add_animation(&"swing", source_clip)
	library_asset.add_animation(&"recover", target_clip)
	library_asset.add_animation(&"salute", Animation.new())
	var player_node := AnimationPlayer.new()
	player_node.add_animation_library(&"sword", library_asset)
	_verify_read(player_node)
	_verify_track_round_trip(source_clip, library_asset)
	_verify_combo(player_node)

	player_node.free()
	print("CRIMSON_WEAPON_ANIMATION state=", "passed" if _failures == 0 else "failed", " checks=", _checks)
	quit(0 if _failures == 0 else 1)


func _verify_read(player_node: AnimationPlayer) -> void:
	_expect(CrimsonWeaponAnimationClip.from_player(player_node, &"missing") == null, "unknown library key rejected")
	var snapshot := CrimsonWeaponAnimationClip.from_player(player_node, SWING)
	_expect(snapshot != null, "legacy clip metadata resolves")
	if snapshot == null:
		return
	_expect(snapshot.get_duration() == 1.0, "clip duration retained")
	_expect(snapshot.get_marker_time(&"Contact") == 0.5, "authored marker wins over native name collision")
	_expect(snapshot.get_marker_time(&"unknown") == -1.0, "unknown marker uses default")
	var detached_markers := snapshot.get_markers()
	detached_markers[1].time = 0.9
	_expect(snapshot.get_marker_time(&"Contact") == 0.5, "returned marker rows are detached")
	_expect(snapshot.get_notify_track_names() == PackedStringArray(["Gameplay"]), "notify lane stored in order")
	_expect(snapshot.get_notifies(&"Sfx").size() == 1, "one-shot filter works")
	_expect(snapshot.get_notify_states().size() == 2, "notify states remain distinct")
	_expect(snapshot.get_active_notify_states(0.5, &"MeleeTrace")[0].name == &"Second", "states exclude end and include start")
	var simultaneous := snapshot.get_events_crossed(0.5, 0.5, true)
	var expected_events: Array[int] = [
		CrimsonWeaponAnimationClip.STATE_ENDED, CrimsonWeaponAnimationClip.STATE_STARTED,
		CrimsonWeaponAnimationClip.NOTIFY, CrimsonWeaponAnimationClip.MARKER,
	]
	var event_types: Array[int] = []
	for authored_event in simultaneous:
		event_types.append(authored_event.type)
	_expect(event_types == expected_events, "simultaneous events follow end-start-notify-marker order")
	_expect(snapshot.get_events_crossed(0.5, 0.5).is_empty(), "forward queries exclude start by default")
	var wrap := snapshot.get_loop_events_crossed(0.8, 0.1)
	_expect(wrap.size() == 3 and wrap[0].name == &"Finish" and wrap[1].name == &"Entry" \
			and wrap[2].type == CrimsonWeaponAnimationClip.STATE_STARTED, "loop reads tail then head")
	_expect(snapshot.get_events_crossed(0.7, 0.1).is_empty(), "backward range rejected")
	_expect(snapshot.get_loop_events_crossed(0.1, 0.8, 0.25, 0.75).is_empty(), "invalid region rejected")

	var bezier_parameter := 0.37
	var phase := _cubic(0.0, 0.23, 0.82, 1.0, bezier_parameter)
	var expected := _cubic(0.0, 0.46, 0.91, 1.0, bezier_parameter)
	_expect(is_equal_approx(snapshot.sample_curve_normalized(&"Ease", phase), expected), "weighted time inversion matches Bezier")
	var curve_keys := snapshot.get_curve_keys(&"Ease")
	_expect(curve_keys.size() == 2 and curve_keys[1].time == 1.0, "key read reports phase and seconds")
	curve_keys[1].value = -300.0
	_expect(snapshot.sample_curve(&"Ease", 1.0) == 1.0, "returned curve keys are detached")
	_expect(snapshot.sample_curve(&"Speed", 0.25) == 0.5, "legacy native Curve normalizes to linear keys")
	_expect(snapshot.sample_curve(&"missing", 0.5, 3.0) == 3.0, "unknown curve uses fallback")


func _verify_track_round_trip(source_clip: Animation, library_asset: AnimationLibrary) -> void:
	var draft := CrimsonWeaponAnimationTracks.from_animation(source_clip)
	_expect(draft != null, "legacy track storage opens as a native draft")
	if draft == null:
		return
	_expect(draft.curve_tracks[0].curve is Array, "scripted curve upgrades to detached normalized rows")
	var changed_rows := draft.markers
	changed_rows.append({"name": &"Extra", "time": 0.75})
	draft.markers = changed_rows
	_expect(draft.write_to(source_clip), "native tracks validate and save")
	changed_rows[0].time = 0.19
	var stored := CrimsonWeaponAnimationClip.from_animation(source_clip)
	_expect(stored != null and stored.get_marker_time(&"Entry") == 0.0, "saved rows are detached from draft input")
	_expect(source_clip.get_marker_time(&"Contact") > 0.59, "authored tracks preserve Godot native marker")
	_expect(ResourceSaver.save(library_asset, LIBRARY_PATH) == OK, "native clip metadata saves in animation library")
	var loaded := ResourceLoader.load(LIBRARY_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary
	_expect(loaded != null and loaded.get_animation(&"swing").get_meta(TRACK_META) is CrimsonWeaponAnimationTracks, "track type survives reload")
	if loaded != null:
		var reopened := CrimsonWeaponAnimationClip.from_animation(loaded.get_animation(&"swing"))
		_expect(reopened != null and reopened.get_marker_time(&"Extra") == 0.75, "native round trip preserves authored time")
	draft.markers = [{"name": &"Invalid", "time": 2.0}]
	_expect(not draft.write_to(source_clip), "out of range draft leaves animation untouched")
	_expect(CrimsonWeaponAnimationClip.from_animation(source_clip).get_marker_time(&"Extra") == 0.75, "failed write preserves previous data")


func _verify_combo(player_node: AnimationPlayer) -> void:
	var legacy := LegacyCombo.new()
	var combo_asset := CrimsonWeaponAnimationCombo.from_resource(legacy)
	_expect(combo_asset != null and combo_asset.display_name == "Legacy combo", "legacy combo loads")
	if combo_asset == null:
		return
	_expect(combo_asset.validate(player_node).is_empty(), "closed combo validates")
	_expect(combo_asset.get_join_count() == 2, "closing transition appears in count")
	var first_join := combo_asset.resolve_join(player_node, 0)
	_expect(first_join.get("exit_time") == 0.5 and first_join.get("entry_time") == 0.25, "named endpoint overrides numeric fallback")
	_expect(first_join.get("outgoing_key") == SWING and first_join.get("incoming_key") == RECOVER, "resolved clips identify library keys")
	_expect(is_equal_approx(float(first_join.get("blend_duration", -1.0)), 0.12), "legacy blend time preserved")
	combo_asset.loop = false
	_expect(combo_asset.get_join_count() == 1 and not combo_asset.resolve_join(player_node, 1).is_empty(), "open combo has one active transition")
	_expect(combo_asset.resolve_join(player_node, 1).has("error"), "inactive closing join cannot resolve")
	combo_asset.loop = true
	_expect(combo_asset.get_join(1).exit_time == 0.7, "closing settings survive loop toggle")
	var reordered: Array[StringName] = [SWING, RECOVER, THIRD]
	combo_asset.set_clips(reordered)
	_expect(combo_asset.get_join(0).exit_marker == &"Contact", "order edit retains unchanged directed pair")
	_expect(combo_asset.get_join(1).exit_time == -1.0, "new pair uses a natural clip end")
	combo_asset.set_join(1, &"", &"", 0.17, 0.3, 0.0)
	combo_asset.set_join(0, &"", &"", 0.1, 0.5, 0.6)
	_expect(not combo_asset.validate(player_node).is_empty(), "incoming trim past outgoing trim rejected")
	combo_asset.set_join(0, &"", &"Entry", 0.1, 0.5, 0.6)
	_expect(combo_asset.validate(player_node).is_empty(), "corrected trim remains valid")
	var detached := combo_asset.copy()
	detached.set_join(1, &"", &"", 0.19)
	_expect(combo_asset.get_join(1).blend_duration == 0.17, "combo draft copies are independent")
	_expect(legacy.joins[0].exit_marker == &"Contact", "native editing leaves legacy input alone")
	_expect(ResourceSaver.save(combo_asset, COMBO_PATH) == OK, "native combo saves independently")
	var reopened := ResourceLoader.load(COMBO_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as CrimsonWeaponAnimationCombo
	_expect(reopened != null and reopened.clip_keys == reordered and reopened.get_join(1).blend_duration == 0.17,
			"saved combo keeps clip order and join values")


func _make_swing() -> Animation:
	var source_clip := Animation.new()
	source_clip.length = 1.0
	source_clip.add_marker(&"Contact", 0.6)
	var legacy := LegacyTracks.new()
	legacy.markers = [{"name": "Entry", "time": 0.0}, {"name": "Contact", "time": 0.5}, {"name": "Finish", "time": 1.0}]
	legacy.notify_tracks = [{"name": "Gameplay", "notifies": [
		{"name": "First", "time": 0.1, "end_time": 0.5, "kind": &"MeleeTrace"},
		{"name": "Second", "time": 0.5, "end_time": 0.75, "kind": &"MeleeTrace"},
		{"name": "Sfx", "time": 0.5, "end_time": -1.0},
	]}]
	var legacy_curve := LegacyRichCurve.new()
	legacy_curve.keys = [
		{"phase": 0.0, "value": 0.0, "mode": 3, "in_slope": 0.0, "out_slope": 2.0,
			"in_weight": 0.0, "out_weight": 0.23 * sqrt(5.0), "weighted_in": false, "weighted_out": true},
		{"phase": 1.0, "value": 1.0, "mode": 3, "in_slope": 0.5, "out_slope": 0.0,
			"in_weight": 0.18 * sqrt(1.25), "out_weight": 0.0, "weighted_in": true, "weighted_out": false},
	]
	var engine_curve := Curve.new()
	engine_curve.max_value = 2.0
	engine_curve.add_point(Vector2(0.0, 0.0), 0.0, 0.0, Curve.TANGENT_FREE, Curve.TANGENT_LINEAR)
	engine_curve.add_point(Vector2(1.0, 2.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_FREE)
	legacy.curve_tracks = [{"name": "Ease", "curve": legacy_curve}, {"name": "Speed", "curve": engine_curve}]
	source_clip.set_meta(TRACK_META, legacy)
	return source_clip


func _cubic(first: float, first_control: float, second_control: float, last: float, phase: float) -> float:
	var remaining := 1.0 - phase
	return first * pow(remaining, 3.0) + 3.0 * first_control * remaining * remaining * phase \
		+ 3.0 * second_control * remaining * phase * phase + last * pow(phase, 3.0)


func _expect(condition: bool, explanation: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("CRIMSON_WEAPON_ANIMATION check failed: " + explanation)
