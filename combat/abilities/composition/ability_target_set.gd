class_name AbilityTargetSet
extends RefCounted
## Ordered query result. A failed query exposes its reason and no partial results.

var contacts: Array[AbilityTargetContact] = []
var transform: Transform3D = Transform3D.IDENTITY
var failure: StringName = &""
## Optional spatial carrier used for a contact query after its caster leaves the scene.
var query_space: WeakRef
var source_id: int
var source_faction: StringName
var hostile_factions: Array[StringName] = []


## Copies the selection with one contact for target-scoped conditions and actions.
func with_contact(contact: AbilityTargetContact) -> AbilityTargetSet:
	var selected := AbilityTargetSet.new()
	selected.copy_origin(self)
	selected.contacts.append(contact)
	return selected


func copy_origin(other: AbilityTargetSet) -> void:
	transform = other.transform
	query_space = other.query_space
	source_id = other.source_id
	source_faction = other.source_faction
	hostile_factions.assign(other.hostile_factions)
