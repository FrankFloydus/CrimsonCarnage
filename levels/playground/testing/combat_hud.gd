extends VBoxContainer
## Resource bars, cast progress and retained effect icons for the bound player.

const EFFECT_ICON = preload("res://levels/playground/testing/effect_hud_icon.tscn")

var _attributes: ActorAttributes
var _effects: GameplayEffectRuntime
var _casting: AbilitySystem
var _effect_icons: Dictionary[int, PanelContainer] = {}

@onready var _cast_bar_slot: MarginContainer = $CastBarSlot
@onready var _cast_bar: ProgressBar = $CastBarSlot/CastBar
@onready var _effect_strips: MarginContainer = $EffectStrips
@onready var _buffs: HFlowContainer = $EffectStrips/Rows/Buffs
@onready var _debuffs: HFlowContainer = $EffectStrips/Rows/Debuffs
@onready var _health: ProgressBar = $Health
@onready var _mana: ProgressBar = $Mana
@onready var _stamina: ProgressBar = $Stamina


func _ready() -> void:
	_refresh_all()
	_refresh_effect_icons()


func _process(_delta: float) -> void:
	_refresh_cast_bar()


func _exit_tree() -> void:
	_disconnect_attributes()
	_disconnect_effects()


## Rebinds the resource bars and optionally the effects and cast progress of the same actor.
func bind_attributes(
		attributes: ActorAttributes, effects: GameplayEffectRuntime = null,
		casting: AbilitySystem = null
) -> void:
	_disconnect_attributes()
	_disconnect_effects()
	for handle: int in _effect_icons.keys():
		_remove_effect_icon(handle)
	_attributes = attributes
	_effects = effects
	_casting = casting
	set_process(is_instance_valid(_casting))
	if is_instance_valid(_attributes):
		_attributes.attribute_changed.connect(_on_attribute_changed)
		_attributes.tree_exiting.connect(_on_attributes_exiting)
	if _effects != null:
		_effects.retained_effects_changed.connect(_refresh_effect_icons)
	if is_node_ready():
		_refresh_all()
		_refresh_effect_icons()
		_refresh_cast_bar()


func _disconnect_attributes() -> void:
	if not is_instance_valid(_attributes):
		return
	if _attributes.attribute_changed.is_connected(_on_attribute_changed):
		_attributes.attribute_changed.disconnect(_on_attribute_changed)
	if _attributes.tree_exiting.is_connected(_on_attributes_exiting):
		_attributes.tree_exiting.disconnect(_on_attributes_exiting)


func _disconnect_effects() -> void:
	if _effects != null and _effects.retained_effects_changed.is_connected(_refresh_effect_icons):
		_effects.retained_effects_changed.disconnect(_refresh_effect_icons)


func _on_attributes_exiting() -> void:
	bind_attributes(null)


func _on_attribute_changed(attribute: int, _previous: float, _value: float) -> void:
	if not is_node_ready():
		return
	match attribute:
		CombatAttributes.Id.HEALTH, CombatAttributes.Id.MAX_HEALTH:
			_refresh_bar(_health, CombatAttributes.Id.HEALTH)
		CombatAttributes.Id.MANA, CombatAttributes.Id.MAX_MANA:
			_refresh_bar(_mana, CombatAttributes.Id.MANA)
		CombatAttributes.Id.STAMINA, CombatAttributes.Id.MAX_STAMINA:
			_refresh_bar(_stamina, CombatAttributes.Id.STAMINA)


func _refresh_all() -> void:
	_refresh_bar(_health, CombatAttributes.Id.HEALTH)
	_refresh_bar(_mana, CombatAttributes.Id.MANA)
	_refresh_bar(_stamina, CombatAttributes.Id.STAMINA)


func _refresh_bar(bar: ProgressBar, resource: int) -> void:
	bar.max_value = _attributes.get_value(CombatAttributes.maximum_for(resource)) \
			if is_instance_valid(_attributes) else 1.0
	bar.set_value_no_signal(_attributes.get_value(resource) if is_instance_valid(_attributes) else 0.0)


func _refresh_cast_bar() -> void:
	var progress := -1.0
	if is_instance_valid(_casting):
		var cast := _casting.get_animation_cast()
		if cast != null and GameplayEffectContext.is_spell_delivery(cast.context.ability_tags):
			var execution := cast.definition.execution
			if execution != null:
				progress = execution.get_windup_progress(cast)
	_cast_bar_slot.visible = progress >= 0.0
	_cast_bar.set_value_no_signal(maxf(0.0, progress))


func _refresh_effect_icons() -> void:
	if not is_node_ready():
		return
	var retained: Dictionary[int, GameplayEffectDefinition] = {}
	if _effects != null:
		retained = _effects.get_retained_effects()
	for handle: int in _effect_icons.keys():
		if not retained.has(handle):
			_remove_effect_icon(handle)
	for handle: int in retained:
		var definition: GameplayEffectDefinition = retained[handle]
		if _effect_icons.has(handle) or definition.icon == null:
			continue
		var strip: HFlowContainer
		match definition.hud_category:
			GameplayEffectDefinition.HudCategory.BUFF:
				strip = _buffs
			GameplayEffectDefinition.HudCategory.DEBUFF:
				strip = _debuffs
			_:
				continue
		var icon := EFFECT_ICON.instantiate() as PanelContainer
		var texture := icon.get_node("Texture") as TextureRect
		texture.texture = definition.icon
		icon.tooltip_text = definition.display_name
		if icon.tooltip_text.is_empty():
			icon.tooltip_text = "Effect %d" % definition.effect_id if definition.effect_id > 0 else "Effect"
		_effect_icons[handle] = icon
		strip.add_child(icon)
	_effect_strips.visible = not _effect_icons.is_empty()


func _remove_effect_icon(handle: int) -> void:
	var icon := _effect_icons[handle]
	_effect_icons.erase(handle)
	icon.get_parent().remove_child(icon)
	icon.queue_free()
