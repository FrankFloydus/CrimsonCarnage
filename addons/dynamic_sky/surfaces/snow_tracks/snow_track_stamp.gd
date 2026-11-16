@tool
class_name DynamicSkySnowTrackStamp
extends Marker3D
## Turns footfalls or a moving ground contact into marks on one authored snow receiver.

const SAMPLE_INTERVAL := 1.0 / 15.0

## Opted-in snow surface this marker may affect.
@export var receiver: DynamicSkySnowTrackReceiver

## Diameter of the contact brush, in meters. The source rolling sphere uses 0.40 m.
@export_range(0.08, 1.0, 0.01, "suffix:m") var diameter_meters: float = 0.40

## How much of the receiver's available compression and rim this marker can apply.
@export_range(0.0, 1.0, 0.01) var pressure: float = 1.0

## Samples moving contact continuously. Leave off for individual calls from footfall animation events.
@export var continuous_contact: bool = false:
	set(value):
		continuous_contact = value
		_had_previous = false
		if is_node_ready() and not Engine.is_editor_hint():
			set_physics_process(value or _queued)

## Physics body to exclude from contact and roof probes, such as the marker's owning character.
@export var actor_body: CollisionObject3D

var _queued: bool
var _queued_position: Vector3
var _sample_elapsed: float
var _had_previous: bool
var _previous_contact: Vector2


func _ready() -> void:
	set_physics_process(not Engine.is_editor_hint() and (continuous_contact or _queued))


## Requests one mark at the current marker position for the next physics tick.
func stamp_contact() -> void:
	if Engine.is_editor_hint():
		return
	_queued_position = global_position
	_queued = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _queued:
		_queued = false
		_sample_contact(_queued_position, false)
	if continuous_contact:
		_sample_elapsed += delta
		if _sample_elapsed >= SAMPLE_INTERVAL:
			_sample_elapsed = fmod(_sample_elapsed, SAMPLE_INTERVAL)
			_sample_contact(global_position, true)
	else:
		set_physics_process(false)


func _sample_contact(point: Vector3, swept: bool) -> void:
	if not is_instance_valid(receiver):
		_had_previous = false
		return
	var body := actor_body.get_rid() if is_instance_valid(actor_body) else RID()
	var contact := receiver.resolve_contact(point, diameter_meters, body)
	if contact.is_empty():
		_had_previous = false
		return
	var current: Vector2 = contact[&"position"]
	var start := current
	# A dropped contact or a teleport should never bridge disconnected tracks.
	if swept and _had_previous and _previous_contact.distance_to(current) <= diameter_meters * 1.6:
		start = _previous_contact
	receiver.write_contact(start, current, diameter_meters, pressure * float(contact[&"pressure"]))
	_previous_contact = current
	_had_previous = swept
