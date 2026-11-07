class_name CombatStatisticsPanel
extends VBoxContainer
## Per-ability actual damage and delivery outcomes for the current test session.

const COLUMNS := [
	["Source / ability", "ability_name", 210, "Actor and ability credited with the events."],
	["Uses", "casts", 65, "Accepted ability activations."],
	["Deliveries", "attempts", 80, "Payload deliveries reported by actual contacts."],
	["Hits", "hits", 65, "Successful payload deliveries."],
	["Critical hits", "critical_hits", 100,
			"Successful critical damage contacts, counted once per payload rather than per component."],
	["Misses", "misses", 65, "Connected attacks rejected by the shared Accuracy check."],
	["Resists", "resists", 65, "Connected spells rejected by the shared Accuracy check."],
	["Damage events", "damage_events", 110, "Individual damage applications."],
	["Damage", "damage", 95, "Actual Health removed; overkill is excluded."],
	["DPS", "dps", 85, "Actual damage divided by elapsed measurement time."],
	["Failed uses", "failed_casts", 100, "Rejected ability activation requests."],
]

var recorder: CombatTestRecorder
var _selected_source: int = 0
var _displayed_sources: Array[Dictionary] = []

@onready var _source_filter: OptionButton = $Toolbar/SourceFilter
@onready var _table: Tree = $TableScroll/Table
@onready var _summary: Label = $Summary


func _ready() -> void:
	_table.columns = COLUMNS.size()
	_table.column_titles_visible = true
	var column_descriptions := PackedStringArray()
	for index: int in COLUMNS.size():
		_table.set_column_title(index, COLUMNS[index][0])
		column_descriptions.append("%s: %s" % [COLUMNS[index][0], COLUMNS[index][3]])
		_table.set_column_custom_minimum_width(index, COLUMNS[index][2])
		_table.set_column_expand(index, index == 0)
	_table.tooltip_text = "\n".join(column_descriptions)
	$Toolbar/Reset.pressed.connect(_reset_statistics)
	_source_filter.item_selected.connect(_select_source)
	_source_filter.get_popup().popup_hide.connect(_on_source_popup_hidden)
	$Refresh.timeout.connect(_refresh_visible)
	_refresh()


func bind_recorder(value: CombatTestRecorder) -> void:
	if recorder != null and recorder.changed.is_connected(_refresh):
		recorder.changed.disconnect(_refresh)
	recorder = value
	if recorder != null:
		recorder.changed.connect(_refresh)
	if is_node_ready():
		_refresh()


func _refresh_visible() -> void:
	if is_visible_in_tree():
		_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	_update_sources()
	_table.clear()
	var root := _table.create_item()
	if recorder == null:
		_summary.text = "No combat recorded."
		return
	for row: Dictionary in recorder.get_rows(_selected_source):
		var item := _table.create_item(root)
		for index: int in COLUMNS.size():
			var field: String = COLUMNS[index][1]
			var value: Variant = row.get(field, 0)
			if index == 0:
				item.set_text(index, "%s / %s" % [row["source_name"], value])
				item.set_tooltip_text(index, "%s\nAbility ID: %s" % [
						COLUMNS[index][3], row["ability_id"]])
			elif value is float:
				item.set_text(index, "%.1f" % value)
			else:
				item.set_text(index, str(value))
			if index != 0:
				item.set_tooltip_text(index, COLUMNS[index][3])
	var totals := recorder.get_totals(_selected_source)
	_summary.text = ("%.1fs  |  Damage %.1f  |  DPS %.1f  |  Deliveries %d"
			+ "  |  Hits %d  |  Critical hits %d  |  Misses %d  |  Resists %d") % [
		recorder.elapsed_seconds(), totals["damage"], totals["dps"],
		totals["attempts"], totals["hits"], totals["critical_hits"], totals["misses"], totals["resists"],
	]


func _update_sources() -> void:
	var sources: Array[Dictionary] = [{"id": 0, "name": "All sources"}]
	if recorder != null:
		sources.append_array(recorder.get_sources())
	if sources == _displayed_sources or _source_filter.get_popup().visible:
		return
	_displayed_sources = sources
	_source_filter.clear()
	for source: Dictionary in sources:
		_source_filter.add_item(str(source["name"]))
		var index := _source_filter.item_count - 1
		_source_filter.set_item_metadata(index, source["id"])
		if int(source["id"]) == _selected_source:
			_source_filter.select(index)


func _on_source_popup_hidden() -> void:
	# Let an item-selected callback resolve its existing index before applying new sources.
	_update_sources.call_deferred()


func _select_source(index: int) -> void:
	_selected_source = int(_source_filter.get_item_metadata(index))
	_refresh()


func _reset_statistics() -> void:
	if recorder != null:
		recorder.reset()
