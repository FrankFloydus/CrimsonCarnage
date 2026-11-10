# Item authoring in Godot

Save item definitions as `ItemDefinition` resources directly in `res://data/items/`. Select an existing `.tres` in the FileSystem dock to edit it in the Inspector. To create a definition, use the FileSystem dock's resource creation menu, select **ItemDefinition**, and save the new resource in that folder. [Bastard Sword](../data/items/bastard_sword.tres) · [Minor Health Potion](../data/items/minor_health_potion.tres)

## Inspector fields

| Field | Value |
| --- | --- |
| **Item ID** | 1–64 ASCII characters, starting with a letter and followed by letters, digits, or underscores |
| **Display Name** | Nonblank text |
| **Category** | Material, Consumable, or Equipment |
| **Description** | Optional text |
| **Icon** | Optional `Texture2D` |
| **World Scene** | Optional `PackedScene` |
| **Width**, **Height** | Inventory footprint in cells, 1–32 each |
| **Stack Limit** | Maximum quantity in one stack, 1–9999 for each category |
| **Vendor Value** | Nonnegative integer up to 2147483647 |

**Category** controls which additional fields the Inspector shows. Consumables expose **Restore Health Amount**, greater than 0 and at most 1,000,000. Equipment exposes **Equipment Group** and **Equip Profile**. The handheld group also exposes **Weapon Type**. Shields use **Off Hand**, two-handed weapons use **Both Hands**, and one-handed weapons use **Either Hand**, **Main Hand**, or **Off Hand**. Armor and accessories use a profile appropriate to their group. [Resource fields and validation](../scripts/items/item_definition.gd)

## Catalog and verification

The catalog scans `.tres` files directly under `res://data/items/` in filename order. The **Item ID** is the catalog key and retains its authored casing. IDs must be unique regardless of case, and the resource filename can differ from its ID. Assign a fresh ID when duplicating an item. [Catalog loader](../scripts/items/item_catalog.gd)

The Playground loads the catalog once at startup. Restart with **F5**, then press **F4** to view the read-only report. Godot also prints the report at launch. Invalid resources and duplicate IDs are reported by filename while the remaining valid items load. [Inspector scene](../scenes/ui/item_definition_inspector.tscn)

The Playground inspector displays definition metadata. The test swords are mounted directly in the Player scene, and the potion's heal amount is displayed as definition data. [Player scene](../scenes/player/player.tscn)
