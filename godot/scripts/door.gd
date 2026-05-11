extends Node3D

# Wall-blocking door. Variants are purely data:
#   requires_key = true  → consumes a small key on first open ("locked")
#   requires_key = false → opens on interact ("unlocked")
#
# Once opened, stays open (no auto-close). The door's visible body is
# a child StaticBody3D ("Body") that we tween upward so it retracts
# into a decorative lintel above the frame. Trigger is a sibling
# Area3D the player walks into to expose the [E] open prompt.

@export var requires_key: bool = true
# Optional per-door override for which key group unlocks this door.
# Empty = inherit the scene's current key group (set by dungeon_root.gd).
# Useful when an antechamber's key should open a door in the main
# dungeon — give the door the dungeon's group explicitly here.
@export var key_group: String = ""
@export var open_offset: Vector3 = Vector3(0, 2.6, 0)
@export var open_duration: float = 0.55
# v2.5 permission reframe: the locked message reads
# "Permission denied — needs key:<key_group>" so the player sees which
# dungeon-specific key group unlocks this door. The static export here
# is now only used as a fallback for doors whose key_group somehow ends
# up empty (shouldn't happen — dungeon_root.gd seeds it).
@export var locked_message: String = "Permission denied — needs key"
@export var unlock_message: String = "The lock turns. The door opens."

@onready var body: Node3D = $Body
@onready var trigger: Area3D = $Trigger
@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _is_open: bool = false
var _start_body_pos: Vector3
var _player_inside: bool = false


func _ready() -> void:
    _start_body_pos = body.position
    trigger.body_entered.connect(_on_trigger_enter)
    trigger.body_exited.connect(_on_trigger_exit)
    if hint:
        hint.visible = false


func _on_trigger_enter(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = true
        if hint and not _is_open:
            hint.visible = true


func _on_trigger_exit(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = false
        if hint:
            hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if _is_open or not _player_inside:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        if requires_key:
            if GameState.consume_key(key_group):
                _open()
                Dialog.show_message(unlock_message)
            else:
                Dialog.show_message(_locked_msg())
        else:
            _open()


# v2.5 permission-bit phrasing for the locked-door refusal message.
# `key_group` is the dungeon-scoped group (e.g. "wyrdkin_glade") that
# the player would need a small key from. Doors whose group is missing
# fall back to the bare exported `locked_message`.
func _locked_msg() -> String:
    if key_group == "":
        return locked_message
    return "Permission denied — needs key:%s" % key_group


func _open() -> void:
    _is_open = true
    if hint:
        hint.visible = false
    SoundBank.play_3d("gate_open", global_position)
    var t := create_tween()
    t.tween_property(body, "position", _start_body_pos + open_offset, open_duration)
