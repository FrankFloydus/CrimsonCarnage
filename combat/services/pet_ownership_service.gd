class_name PetOwnershipService
extends RefCounted
## Reserves creature identity and a stable owner slot before persistent acquisition.

signal acquired(owner_id: StringName, pet_id: StringName, slot_id: StringName)

const SAVE_VERSION := 1

class PetRecord extends RefCounted:
	var pet_id: StringName
	var owner_id: StringName
	var slot_id: StringName
	var species_id: StringName

	func _copy() -> PetRecord:
		var record := PetRecord.new()
		record.pet_id = pet_id
		record.owner_id = owner_id
		record.slot_id = slot_id
		record.species_id = species_id
		return record


class Reservation extends RefCounted:
	var record: PetRecord
	var world_id: StringName
	var _committing: bool = false
	var _validating: bool = false

class ActiveBinding extends RefCounted:
	var pet_id: StringName
	var world_id: StringName


var _next_handle: int = 1
var _records: Dictionary[StringName, PetRecord] = {}
var _reservations: Dictionary[int, Reservation] = {}
var _active_pets: Dictionary[StringName, ActiveBinding] = {}


## Eligibility is a read-only domain check on a candidate record and its current world ID.
func reserve_acquisition(record: PetRecord, world_id: StringName, eligible: Callable) -> int:
	if not _is_valid_record(record) or world_id.is_empty() or not eligible.is_valid() \
			or not _is_available(record):
		return 0
	var candidate := record._copy()
	if not bool(eligible.call(candidate._copy(), world_id)) or not _is_available(candidate):
		return 0
	var reservation := Reservation.new()
	reservation.record = candidate
	reservation.world_id = world_id
	var handle := _next_handle
	_next_handle += 1
	_reservations[handle] = reservation
	return handle


## Revalidate after channeling. The synchronous binding adapter owns the scene's creature handoff.
## It must return true only after applying ownership and leave the actor unchanged on failure.
func complete_acquisition(handle: int, world_id: StringName, eligible: Callable,
		bind_actor: Callable) -> bool:
	var reservation := _reservations.get(handle) as Reservation
	if reservation == null or reservation._committing or reservation._validating:
		return false
	if reservation.world_id != world_id or not eligible.is_valid() or not bind_actor.is_valid():
		cancel_acquisition(handle)
		return false
	var record := reservation.record
	reservation._validating = true
	var still_eligible := bool(eligible.call(record._copy(), world_id))
	reservation._validating = false
	if not still_eligible or not _reservations.has(handle):
		cancel_acquisition(handle)
		return false
	reservation._committing = true
	if not bool(bind_actor.call(record._copy(), world_id)):
		_reservations.erase(handle)
		return false
	_records[record.pet_id] = record
	_reservations.erase(handle)
	acquired.emit(record.owner_id, record.pet_id, record.slot_id)
	return true


func cancel_acquisition(handle: int) -> bool:
	var reservation := _reservations.get(handle) as Reservation
	return reservation != null and not reservation._committing and _reservations.erase(handle)


func cancel_actor(actor_id: StringName) -> void:
	for handle: int in _reservations.keys():
		var record := _reservations[handle].record
		if record.owner_id == actor_id or record.pet_id == actor_id:
			cancel_acquisition(handle)
	_active_pets.erase(actor_id)
	for owner_id: StringName in _active_pets.keys():
		if _active_pets[owner_id].pet_id == actor_id:
			_active_pets.erase(owner_id)


func unload_world(world_id: StringName) -> void:
	for handle: int in _reservations.keys():
		if _reservations[handle].world_id == world_id:
			cancel_acquisition(handle)
	for owner_id: StringName in _active_pets.keys():
		if _active_pets[owner_id].world_id == world_id:
			_active_pets.erase(owner_id)


func get_record(pet_id: StringName) -> PetRecord:
	var record := _records.get(pet_id) as PetRecord
	return record._copy() if record != null else null


## The scene adapter calls this when a persistent pet representation is available in the world.
func set_active_pet(owner_id: StringName, pet_id: StringName, world_id: StringName) -> bool:
	var record := _records.get(pet_id) as PetRecord
	if record == null or record.owner_id != owner_id or world_id.is_empty():
		return false
	_bind_active_pet(owner_id, pet_id, world_id)
	return true


## A scene's summon adapter may supply a commandable pet without creating a persistent record.
func set_temporary_pet(owner_id: StringName, pet_id: StringName, world_id: StringName) -> bool:
	if owner_id.is_empty() or pet_id.is_empty() or owner_id == pet_id or world_id.is_empty() \
			or _records.has(pet_id):
		return false
	for other_owner: StringName in _active_pets:
		if other_owner != owner_id and _active_pets[other_owner].pet_id == pet_id:
			return false
	for reservation: Reservation in _reservations.values():
		if reservation.record.pet_id == pet_id:
			return false
	_bind_active_pet(owner_id, pet_id, world_id)
	return true


func _bind_active_pet(owner_id: StringName, pet_id: StringName, world_id: StringName) -> void:
	var binding := ActiveBinding.new()
	binding.pet_id = pet_id
	binding.world_id = world_id
	_active_pets[owner_id] = binding


func get_active_pet(owner_id: StringName, world_id: StringName) -> StringName:
	var binding := _active_pets.get(owner_id) as ActiveBinding
	return binding.pet_id if binding != null and binding.world_id == world_id else &""


func save_records() -> Dictionary:
	var records: Array[Dictionary] = []
	var pet_ids := _records.keys()
	pet_ids.sort()
	for pet_id: StringName in pet_ids:
		var record := _records[pet_id]
		records.append({"pet": String(record.pet_id), "owner": String(record.owner_id),
			"slot": String(record.slot_id), "species": String(record.species_id)})
	return {"version": SAVE_VERSION, "records": records}


## Restore only persistent records. Reservations and scene bindings require fresh validation.
func load_records(data: Dictionary) -> bool:
	if not _reservations.is_empty() or data.get("version") != SAVE_VERSION \
			or not data.get("records") is Array:
		return false
	var records: Dictionary[StringName, PetRecord] = {}
	for value: Variant in data["records"]:
		if not value is Dictionary:
			return false
		var fields: Dictionary = value
		for field: String in ["pet", "owner", "slot", "species"]:
			if not fields.get(field) is String:
				return false
		var record := PetRecord.new()
		record.pet_id = StringName(fields["pet"])
		record.owner_id = StringName(fields["owner"])
		record.slot_id = StringName(fields["slot"])
		record.species_id = StringName(fields["species"])
		if not _is_valid_record(record) or records.has(record.pet_id):
			return false
		for other: PetRecord in records.values():
			if _matches_slot(record, other):
				return false
		records[record.pet_id] = record
	_records = records
	_active_pets.clear()
	return true


func _is_available(record: PetRecord) -> bool:
	if _records.has(record.pet_id):
		return false
	for other: PetRecord in _records.values():
		if _matches_slot(record, other):
			return false
	for reservation: Reservation in _reservations.values():
		if reservation.record.pet_id == record.pet_id or _matches_slot(record, reservation.record):
			return false
	for binding: ActiveBinding in _active_pets.values():
		if binding.pet_id == record.pet_id:
			return false
	return true


static func _is_valid_record(record: PetRecord) -> bool:
	return record != null and not record.pet_id.is_empty() and not record.owner_id.is_empty() \
		and record.pet_id != record.owner_id and not record.slot_id.is_empty() \
		and not record.species_id.is_empty()


static func _matches_slot(record: PetRecord, other: PetRecord) -> bool:
	return other.owner_id == record.owner_id and other.slot_id == record.slot_id
