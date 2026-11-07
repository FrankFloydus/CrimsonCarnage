class_name ThreatService
extends RefCounted
## Maintains per-observer threat and scoped attention policies keyed by stable actor identity.

signal attention_changed(observer_id: StringName)


class Entry extends RefCounted:
	var actor_id: StringName
	var observer_id: StringName
	var recipient_id: StringName
	var transaction_tag: StringName
	var expires_at: float
	var priority: int


var _clock: float = 0.0
var _next_handle: int = 1
var _accepts_override: Dictionary[StringName, bool] = {}
var _ledgers: Dictionary[StringName, Dictionary] = {}
var _overrides: Dictionary[int, Entry] = {}
var _redirects: Dictionary[int, Entry] = {}
var _suppressions: Dictionary[int, Entry] = {}


## Register known observers. Human-controlled actors pass false unless their ruleset permits overrides.
func register_observer(observer_id: StringName, accepts_override: bool) -> bool:
	if observer_id.is_empty() or _ledgers.has(observer_id):
		return false
	_ledgers[observer_id] = {}
	_accepts_override[observer_id] = accepts_override
	return true


## Record an already committed transaction for one observer. Return the actor actually credited.
func add_threat(observer_id: StringName, actor_credit: StringName, committed_amount: float,
		profile: ThreatGenerationProfile) -> StringName:
	if not _ledgers.has(observer_id) or actor_credit.is_empty() or actor_credit == observer_id \
			or profile == null or profile.version <= 0 or profile.transaction_tag.is_empty():
		return &""
	var amount := committed_amount * profile.multiplier
	if not is_finite(amount) or amount <= 0.0 or committed_amount <= 0.0:
		return &""
	var recipient_id := _redirected_credit(actor_credit, profile.transaction_tag)
	if recipient_id == observer_id or _is_suppressed(recipient_id):
		return &""
	var ledger := _ledgers[observer_id]
	var total := float(ledger.get(recipient_id, 0.0)) + amount
	if not is_finite(total):
		return &""
	ledger[recipient_id] = total
	attention_changed.emit(observer_id)
	return recipient_id


func get_threat(observer_id: StringName, actor_id: StringName) -> float:
	var ledger: Dictionary = _ledgers.get(observer_id, {})
	return float(ledger.get(actor_id, 0.0))


## Apply to a single AI observer. Returns a handle, including for a normalization-only taunt.
func apply_taunt(observer_id: StringName, actor_id: StringName, profile: ThreatTauntProfile) -> int:
	if not _accepts_override.get(observer_id, false) or actor_id.is_empty() \
			or actor_id == observer_id or _is_suppressed(actor_id) or profile == null \
			or profile.version <= 0 or not is_finite(profile.override_seconds) \
			or profile.override_seconds < 0.0:
		return 0
	var ledger := _ledgers[observer_id]
	if profile.match_highest_threat:
		var highest := 0.0
		for amount: float in ledger.values():
			highest = maxf(highest, amount)
		ledger[actor_id] = highest
	var handle := _allocate_handle()
	if profile.override_seconds > 0.0:
		var entry := Entry.new()
		entry.actor_id = actor_id
		entry.observer_id = observer_id
		entry.expires_at = _clock + profile.override_seconds
		entry.priority = profile.priority
		_overrides[handle] = entry
	attention_changed.emit(observer_id)
	return handle


## Redirect matching transactions once. The latest active matching handle wins.
func redirect_threat(actor_id: StringName, recipient_id: StringName, transaction_tag: StringName,
		duration: float) -> int:
	if actor_id.is_empty() or recipient_id.is_empty() or actor_id == recipient_id \
			or not is_finite(duration) or duration <= 0.0:
		return 0
	var handle := _allocate_handle()
	var entry := Entry.new()
	entry.actor_id = actor_id
	entry.recipient_id = recipient_id
	entry.transaction_tag = transaction_tag
	entry.expires_at = _clock + duration
	_redirects[handle] = entry
	return handle


## Request attention reevaluation for one actor without changing its lifecycle or its pet's threat.
func suppress_attention(actor_id: StringName, duration: float, clear_threat: bool = false) -> int:
	if actor_id.is_empty() or not is_finite(duration) or duration <= 0.0:
		return 0
	var handle := _allocate_handle()
	var entry := Entry.new()
	entry.actor_id = actor_id
	entry.expires_at = _clock + duration
	_suppressions[handle] = entry
	if clear_threat:
		for ledger: Dictionary in _ledgers.values():
			ledger.erase(actor_id)
	_notify_all_observers()
	return handle


func get_target(observer_id: StringName) -> StringName:
	if not _ledgers.has(observer_id):
		return &""
	var best_handle := 0
	var best_override: Entry
	for handle: int in _overrides:
		var entry := _overrides[handle]
		if entry.observer_id == observer_id and not _is_suppressed(entry.actor_id) \
				and (best_override == null or entry.priority > best_override.priority \
				or (entry.priority == best_override.priority and handle > best_handle)):
			best_override = entry
			best_handle = handle
	if best_override != null:
		return best_override.actor_id
	var ledger := _ledgers[observer_id]
	var target_id := &""
	var highest := 0.0
	for actor_id: StringName in ledger:
		var amount: float = ledger[actor_id]
		if not _is_suppressed(actor_id) and (amount > highest or (amount == highest \
				and not target_id.is_empty() and String(actor_id) < String(target_id))):
			target_id = actor_id
			highest = amount
	return target_id


func remove(handle: int) -> bool:
	if _overrides.has(handle):
		var observer_id := _overrides[handle].observer_id
		_overrides.erase(handle)
		attention_changed.emit(observer_id)
		return true
	if _suppressions.erase(handle):
		_notify_all_observers()
		return true
	return _redirects.erase(handle)


func remove_actor(actor_id: StringName) -> void:
	_ledgers.erase(actor_id)
	_accepts_override.erase(actor_id)
	for ledger: Dictionary in _ledgers.values():
		ledger.erase(actor_id)
	for handle: int in _overrides.keys():
		var entry := _overrides[handle]
		if entry.actor_id == actor_id or entry.observer_id == actor_id:
			_overrides.erase(handle)
	for handle: int in _redirects.keys():
		var entry := _redirects[handle]
		if entry.actor_id == actor_id or entry.recipient_id == actor_id:
			_redirects.erase(handle)
	for handle: int in _suppressions.keys():
		if _suppressions[handle].actor_id == actor_id:
			_suppressions.erase(handle)
	_notify_all_observers()


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_clock += delta
	var observers_changed: Dictionary[StringName, bool] = {}
	for handle: int in _overrides.keys():
		var entry := _overrides[handle]
		if entry.expires_at <= _clock:
			_overrides.erase(handle)
			observers_changed[entry.observer_id] = true
	for handle: int in _redirects.keys():
		if _redirects[handle].expires_at <= _clock:
			_redirects.erase(handle)
	var suppression_expired := false
	for handle: int in _suppressions.keys():
		if _suppressions[handle].expires_at <= _clock:
			_suppressions.erase(handle)
			suppression_expired = true
	if suppression_expired:
		_notify_all_observers()
		return
	for observer_id: StringName in observers_changed:
		attention_changed.emit(observer_id)


func _redirected_credit(actor_id: StringName, transaction_tag: StringName) -> StringName:
	var newest := 0
	var recipient_id := actor_id
	for handle: int in _redirects:
		var entry := _redirects[handle]
		if handle > newest and entry.actor_id == actor_id \
				and (entry.transaction_tag.is_empty() or entry.transaction_tag == transaction_tag):
			newest = handle
			recipient_id = entry.recipient_id
	return recipient_id


func _is_suppressed(actor_id: StringName) -> bool:
	for entry: Entry in _suppressions.values():
		if entry.actor_id == actor_id:
			return true
	return false


func _notify_all_observers() -> void:
	for observer_id: StringName in _ledgers.keys():
		attention_changed.emit(observer_id)


func _allocate_handle() -> int:
	var handle := _next_handle
	_next_handle += 1
	return handle
