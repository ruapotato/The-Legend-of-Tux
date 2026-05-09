extends Node3D

# Auto-opening gate. Listens to the WorldEvents bus for `listen_id`
# and slides its body up out of the way (mirroring door.gd's
# open_offset trick). Symmetric on deactivate — slides back down. No
# key required: this is the puzzle door, not the lock door.
#
# If the listen_id is already active when the gate spawns (e.g., the
# player solved a puzzle, exited, and re-entered), we open immediately
# without animation so the player isn't surprised by a reset.

@export var listen_id: String = ""
@export var open_offset: Vector3 = Vector3(0, 3.0, 0)
@export var open_duration: float = 0.55

@onready var body: Node3D = $Body

var _is_open: bool = false
var _start_body_pos: Vector3


func _ready() -> void:
	_start_body_pos = body.position
	if listen_id == "":
		return
	WorldEvents.activated.connect(_on_activated)
	WorldEvents.deactivated.connect(_on_deactivated)
	# Late-bind: if the puzzle was already solved before this scene
	# loaded, snap to open without the slide animation.
	if WorldEvents.is_active(listen_id):
		_is_open = true
		body.position = _start_body_pos + open_offset


func _on_activated(id: String) -> void:
	if id != listen_id or _is_open:
		return
	_is_open = true
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("gate_open", global_position)
	var t := create_tween()
	t.tween_property(body, "position", _start_body_pos + open_offset, open_duration)


func _on_deactivated(id: String) -> void:
	if id != listen_id or not _is_open:
		return
	_is_open = false
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("gate_close", global_position)
	var t := create_tween()
	t.tween_property(body, "position", _start_body_pos, open_duration)
