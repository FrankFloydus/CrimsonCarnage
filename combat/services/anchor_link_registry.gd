class_name AnchorLinkRegistry
extends RefCounted
## Owns scene-scoped anchors, recipient links and fixed acquisition sets for tethers.

signal invalidated(handle: int, reason: RemovalReason)

## Why an anchor or link handle was invalidated.
enum RemovalReason {
	## A caller explicitly removed the handle.
	REMOVED,
	## A new record took over the same owner's slot.
	REPLACED,
	## The record reached its lifetime deadline.
	EXPIRED,
	## One or more endpoints required for the link to function are no longer valid.
	ENDPOINT_LOST,
	## The link's world was unloaded.
	WORLD_UNLOADED,
	## Cleanup released the owner's records.
	OWNER_REMOVED,
}

## Determines how the registry validates endpoints and tracks their movement.
enum Kind {
	## A fixed anchor, actor link, or travel pair whose endpoints must all stay valid.
	LINK,
	## A center and an original set of targets checked for movement beyond a threshold.
	TETHER,
}


class Endpoint extends RefCounted:
	var id: StringName
	var _body: WeakRef
	var _position: Vector3

	static func at(id_value: StringName, position_value: Vector3) -> Endpoint:
		var endpoint := Endpoint.new()
		endpoint.id = id_value
		endpoint._position = position_value
		return endpoint

	static func actor(id_value: StringName, body: Node3D) -> Endpoint:
		if not is_instance_valid(body):
			return null
		var endpoint := Endpoint.new()
		endpoint.id = id_value
		endpoint._body = weakref(body)
		return endpoint

	func get_body() -> Node3D:
		return _body.get_ref() as Node3D if _body != null else null

	func get_position() -> Vector3:
		var body := get_body()
		return body.global_position if is_instance_valid(body) and body.is_inside_tree() else _position

	func is_valid() -> bool:
		if id.is_empty():
			return false
		if _body == null:
			return _position.is_finite()
		var body := get_body()
		return is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion()

	func _copy() -> Endpoint:
		var endpoint := Endpoint.at(id, _position)
		endpoint._body = _body
		return endpoint


class LinkRecord extends RefCounted:
	var handle: int
	var owner_id: StringName
	var slot_id: StringName
	var world_id: StringName
	var version: int = 1
	var kind: Kind = Kind.LINK
	var duration: float = 0.0
	var replace_existing: bool = false
	var endpoints: Array[Endpoint] = []
	var _expires_at: float = 0.0
	var _broken_tethers: Dictionary[StringName, bool] = {}

	func _copy() -> LinkRecord:
		var record := LinkRecord.new()
		record.handle = handle
		record.owner_id = owner_id
		record.slot_id = slot_id
		record.world_id = world_id
		record.version = version
		record.kind = kind
		record.duration = duration
		record.replace_existing = replace_existing
		for endpoint: Endpoint in endpoints:
			record.endpoints.append(endpoint._copy())
		return record


var _clock: float = 0.0
var _next_handle: int = 1
var _links: Dictionary[int, LinkRecord] = {}
# Traveler reuse is keyed by stable traveler and authored reuse group, independent of link handles.
var _traveler_reuse: Dictionary[StringName, Dictionary] = {}
var _travel_pending: Dictionary[StringName, bool] = {}


func create(record: LinkRecord) -> int:
	if record == null or record.owner_id.is_empty() or record.slot_id.is_empty() \
			or record.world_id.is_empty() or record.version <= 0 \
			or not is_finite(record.duration) or record.duration < 0.0 \
			or (record.kind == Kind.TETHER and record.endpoints.size() < 2) \
			or not _valid_endpoints(record.endpoints):
		return 0
	var previous := _find_slot(record.owner_id, record.slot_id)
	if previous != null and not record.replace_existing and _invalid_reason(previous) < 0:
		return 0
	var owned := record._copy()
	owned.handle = _next_handle
	_next_handle += 1
	if owned.duration > 0.0:
		owned._expires_at = _clock + owned.duration
	_links[owned.handle] = owned
	if previous != null:
		remove(previous.handle, RemovalReason.REPLACED)
	return owned.handle


func resolve(owner_id: StringName, slot_id: StringName, world_id: StringName) -> LinkRecord:
	var record := _find_slot(owner_id, slot_id)
	return resolve_handle(record.handle, world_id) if record != null else null


func resolve_handle(handle: int, world_id: StringName) -> LinkRecord:
	var record := _links.get(handle) as LinkRecord
	if record == null or record.world_id != world_id:
		return null
	var reason := _invalid_reason(record)
	if reason >= 0:
		remove(handle, reason as RemovalReason)
		return null
	return record._copy()


func remove(handle: int, reason: RemovalReason = RemovalReason.REMOVED) -> bool:
	if not _links.erase(handle):
		return false
	invalidated.emit(handle, reason)
	return true


func remove_owner(owner_id: StringName) -> void:
	for record: LinkRecord in _links.values():
		if record.owner_id == owner_id:
			remove(record.handle, RemovalReason.OWNER_REMOVED)
	_traveler_reuse.erase(owner_id)


func unload_world(world_id: StringName) -> void:
	for record: LinkRecord in _links.values():
		if record.world_id == world_id:
			remove(record.handle, RemovalReason.WORLD_UNLOADED)


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_clock += delta
	for record: LinkRecord in _links.values():
		var reason := _invalid_reason(record)
		if reason >= 0:
			remove(record.handle, reason as RemovalReason)
	for traveler_id: StringName in _traveler_reuse.keys():
		var groups: Dictionary = _traveler_reuse[traveler_id]
		for group_id: StringName in groups.keys():
			if float(groups[group_id]) <= _clock:
				groups.erase(group_id)
		if groups.is_empty():
			_traveler_reuse.erase(traveler_id)


## Tests originally acquired endpoints against the first endpoint's current position.
## A target is returned once, on the first sample beyond the authored distance.
func take_tether_breaks(handle: int, world_id: StringName, distance: float) -> Array[StringName]:
	var broken: Array[StringName] = []
	var record := _links.get(handle) as LinkRecord
	if record == null or record.kind != Kind.TETHER or record.world_id != world_id \
			or not is_finite(distance) or distance < 0.0:
		return broken
	var reason := _invalid_reason(record)
	if reason >= 0:
		remove(handle, reason as RemovalReason)
		return broken
	var center := record.endpoints[0].get_position()
	for index: int in range(1, record.endpoints.size()):
		var endpoint := record.endpoints[index]
		if endpoint.is_valid() and not record._broken_tethers.has(endpoint.id) \
				and center.distance_to(endpoint.get_position()) > distance:
			record._broken_tethers[endpoint.id] = true
			broken.append(endpoint.id)
	return broken


## The teleport adapter validates placement and returns true only after moving the traveler.
## The entry adapter owns interaction range, permissions and faction rules.
func try_travel(handle: int, world_id: StringName, entry_id: StringName, traveler_id: StringName,
		reuse_group: StringName, reuse_seconds: float, permits_entry: Callable,
		teleport_safely: Callable) -> bool:
	if traveler_id.is_empty() or reuse_group.is_empty() or not is_finite(reuse_seconds) \
			or reuse_seconds < 0.0 or not permits_entry.is_valid() or not teleport_safely.is_valid() \
			or _travel_pending.has(traveler_id):
		return false
	var groups: Dictionary = _traveler_reuse.get(traveler_id, {})
	if float(groups.get(reuse_group, 0.0)) > _clock:
		return false
	var pair := resolve_handle(handle, world_id)
	if pair == null or pair.kind != Kind.LINK or pair.endpoints.size() != 2:
		return false
	var entry_index := 0 if pair.endpoints[0].id == entry_id else 1
	if pair.endpoints[entry_index].id != entry_id:
		return false
	_travel_pending[traveler_id] = true
	var traveled := false
	if bool(permits_entry.call(traveler_id, pair.endpoints[entry_index])):
		pair = resolve_handle(handle, world_id)
		if pair != null:
			traveled = bool(teleport_safely.call(traveler_id, pair.endpoints[1 - entry_index].get_position()))
	if traveled and reuse_seconds > 0.0:
		groups[reuse_group] = _clock + reuse_seconds
		_traveler_reuse[traveler_id] = groups
	_travel_pending.erase(traveler_id)
	return traveled


func _find_slot(owner_id: StringName, slot_id: StringName) -> LinkRecord:
	for record: LinkRecord in _links.values():
		if record.owner_id == owner_id and record.slot_id == slot_id:
			return record
	return null


func _invalid_reason(record: LinkRecord) -> int:
	if record._expires_at > 0.0 and record._expires_at <= _clock:
		return RemovalReason.EXPIRED
	if record.kind == Kind.TETHER:
		if record.endpoints[0].is_valid():
			for index: int in range(1, record.endpoints.size()):
				if record.endpoints[index].is_valid():
					return -1
		return RemovalReason.ENDPOINT_LOST
	return -1 if _valid_endpoints(record.endpoints) else RemovalReason.ENDPOINT_LOST


static func _valid_endpoints(endpoints: Array[Endpoint]) -> bool:
	if endpoints.is_empty():
		return false
	var ids: Dictionary[StringName, bool] = {}
	for endpoint: Endpoint in endpoints:
		if endpoint == null or not endpoint.is_valid() or ids.has(endpoint.id):
			return false
		ids[endpoint.id] = true
	return true
