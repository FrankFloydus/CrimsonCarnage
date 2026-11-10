@tool
class_name ItemDefinition
extends Resource
## An item record authored in the Inspector and indexed by its stable ID.

## Controls which item-specific fields are available in the Inspector.
enum Category {
	## An item with a use effect.
	CONSUMABLE,
	## An item with only the shared item fields.
	MATERIAL,
	## An item with an equipment profile.
	EQUIPMENT,
}
## Selects the kind of equipment and the available slot rules.
enum EquipmentGroup {
	## A weapon, magical implement, or shield held in one or both hands.
	HANDHELD,
	## Armor assigned to a body slot.
	ARMOR,
	## Jewelry or a trinket assigned to an accessory slot.
	ACCESSORY,
}
## Classifies handheld equipment.
enum WeaponType {
	## One-handed axe.
	AXE_1H,
	## Two-handed axe.
	AXE_2H,
	## One-handed mace.
	MACE_1H,
	## Two-handed mace.
	MACE_2H,
	## One-handed sword.
	SWORD_1H,
	## Two-handed sword.
	SWORD_2H,
	## One-handed dagger.
	DAGGER_1H,
	## Two-handed bow.
	BOW_2H,
	## One-handed talisman.
	TALISMAN_1H,
	## One-handed fetish.
	FETISH_1H,
	## One-handed orb.
	ORB_1H,
	## Off-hand shield.
	SHIELD,
}
## Specifies where the equipment can be worn or held.
enum EquipProfile {
	## May be held in either hand.
	EITHER_HAND,
	## Must be held in the main hand.
	MAIN_HAND,
	## Must be held in the off hand.
	OFF_HAND,
	## Occupies both hands.
	BOTH_HANDS,
	## Head armor.
	HELM,
	## Chest armor.
	CHEST,
	## Leg armor.
	PANTS,
	## Foot armor.
	BOOTS,
	## Hand armor.
	GLOVES,
	## Shoulder armor.
	SHOULDERS,
	## Waist armor.
	BELT,
	## Uses either ring slot.
	EITHER_RING,
	## Uses either bracelet slot.
	EITHER_BRACELET,
	## Uses the trinket slot.
	TRINKET,
}

## Stable, case-preserving ID. Start with an ASCII letter, then use letters, digits, or underscores.
@export var item_id: StringName
## Nonblank item name shown to the player.
@export var display_name: String
## Selects the item-specific fields shown below.
@export var category: Category = Category.MATERIAL:
	set(value):
		category = value
		notify_property_list_changed()
## Optional text shown when inspecting the item.
@export_multiline var description: String
## Optional inventory icon.
@export var icon: Texture2D
## Optional scene representing this item in the world.
@export var world_scene: PackedScene
## Item footprint width in inventory cells.
@export_range(1, 32) var width: int = 1
## Item footprint height in inventory cells.
@export_range(1, 32) var height: int = 1
## Maximum quantity in one inventory stack.
@export_range(1, 9999) var stack_limit: int = 1
## Nonnegative base vendor value.
@export_range(0, 2147483647) var vendor_value: int = 0

@export_group("Equipment")
## Classifies the item as handheld equipment, armor, or an accessory.
@export var equipment_group: EquipmentGroup = EquipmentGroup.HANDHELD:
	set(value):
		equipment_group = value
		notify_property_list_changed()
## Weapon or shield type for handheld equipment.
@export var weapon_type: WeaponType = WeaponType.SWORD_1H
## Slot or hands the item can occupy. Choose a profile compatible with its group and weapon type.
@export var equip_profile: EquipProfile = EquipProfile.EITHER_HAND

@export_group("Consumable")
## Health restored when consumed, greater than zero and at most 1,000,000.
@export var restore_health_amount: float = 1.0


## Returns the first validation issue, or an empty string for a usable item.
func get_validation_error() -> String:
	if not _is_item_id(String(item_id)):
		return "ID must start with an ASCII letter and contain up to 64 letters, digits, or underscores."
	if display_name.strip_edges().is_empty():
		return "Name must be nonblank text."
	if width < 1 or width > 32 or height < 1 or height > 32:
		return "Width and height must be whole numbers from 1 to 32."
	if stack_limit < 1 or stack_limit > 9999:
		return "Stack limit must be a whole number from 1 to 9999."
	if vendor_value < 0 or vendor_value > 2147483647:
		return "Vendor value must be a whole number from 0 to 2147483647."
	match category:
		Category.MATERIAL:
			return ""
		Category.CONSUMABLE:
			if (
					not is_finite(restore_health_amount)
					or restore_health_amount <= 0.0
					or restore_health_amount > 1000000.0
			):
				return "Restore health amount must be greater than 0 and at most 1000000."
			return ""
		Category.EQUIPMENT:
			return _get_equipment_validation_error()
	return "Choose a valid item category."


func _validate_property(property: Dictionary) -> void:
	match property.name:
		&"equipment_group", &"equip_profile":
			if category != Category.EQUIPMENT:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"weapon_type":
			if category != Category.EQUIPMENT or equipment_group != EquipmentGroup.HANDHELD:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"restore_health_amount":
			if category != Category.CONSUMABLE:
				property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_equipment_validation_error() -> String:
	match equipment_group:
		EquipmentGroup.ARMOR:
			if equip_profile >= EquipProfile.HELM and equip_profile <= EquipProfile.BELT:
				return ""
			return "Choose an armor equip profile."
		EquipmentGroup.ACCESSORY:
			if equip_profile >= EquipProfile.EITHER_RING and equip_profile <= EquipProfile.TRINKET:
				return ""
			return "Choose an accessory equip profile."
		EquipmentGroup.HANDHELD:
			if not WeaponType.values().has(weapon_type):
				return "Choose a valid weapon type."
			match weapon_type:
				WeaponType.SHIELD:
					return "" if equip_profile == EquipProfile.OFF_HAND else "Shields require the Off Hand profile."
				WeaponType.AXE_2H, WeaponType.MACE_2H, WeaponType.SWORD_2H, WeaponType.BOW_2H:
					return "" if equip_profile == EquipProfile.BOTH_HANDS else "Two-handed weapons require the Both Hands profile."
				_:
					if equip_profile >= EquipProfile.EITHER_HAND and equip_profile <= EquipProfile.OFF_HAND:
						return ""
					return "Choose a one-handed equip profile."
	return "Choose a valid equipment group."


func _is_item_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index: int in value.length():
		var character := value[index]
		var letter := (character >= "a" and character <= "z") or (character >= "A" and character <= "Z")
		if index == 0 and not letter:
			return false
		var digit := character >= "0" and character <= "9"
		if not letter and not digit and character != "_":
			return false
	return true
