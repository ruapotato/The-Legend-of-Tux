extends Node3D

# Floor pressure plate. While the player (or any other CharacterBody3D /
# RigidBody3D) is standing in the trigger volume, the slab visually
# sinks and we hold target_id activated on the WorldEvents bus.
#
# `holds=true` latches: once activated, won't deactivate when the
# trigger empties. Useful when the puzzle wants the player free to
# leave the plate after stepping on it (e.g. plate gates a sequence
# of switches in a single room).

@export var target_id: String = ""
@export var holds: bool = false
@export var sink_offset: float = 0.10
@export var anim_time: float = 0.18

@onready var slab:    Node3D = $Slab
@onready var trigger: Area3D = $Trigger

var _start_y: float = 0.0
var _occupants: int = 0
var _active: bool = false


func _ready() -> void:
	if slab:
		_start_y = slab.position.y
	trigger.body_entered.connect(_on_enter)
	trigger.body_exited.connect(_on_exit)


func _on_enter(b: Node) -> void:
	# Count anything heavy enough to depress the plate. Player is
	# explicitly tagged; movable blocks register via the "pushable"
	# group set in their script.
	if b.is_in_group("player") or b.is_in_group("pushable"):
		_occupants += 1
		_set_active(true)


func _on_exit(b: Node) -> void:
	if b.is_in_group("player") or b.is_in_group("pushable"):
		_occupants = max(0, _occupants - 1)
		if _occupants == 0 and not holds:
			_set_active(false)


func _set_active(v: bool) -> void:
	if _active == v:
		return
	_active = v
	if slab:
		var t := create_tween()
		var target_y := _start_y - sink_offset if v else _start_y
		t.tween_property(slab, "position:y", target_y, anim_time)
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("crystal_hit", global_position, 0.15)
	if target_id == "":
		return
	if v:
		WorldEvents.activate(target_id)
	else:
		WorldEvents.deactivate(target_id)
