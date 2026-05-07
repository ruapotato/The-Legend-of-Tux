extends Node3D

# A chest. Walk up, press E, lid lifts, the configured pickup is
# spawned in front. One-shot — once opened, stays open and won't
# spawn again. No persistence between runs yet (per-scene state lives
# with the scene).

@export var contents_scene: PackedScene
@export var open_message: String = ""

@onready var lid: MeshInstance3D = $Body/Lid
@onready var trigger: Area3D = $Trigger
@onready var hint: Label3D = $Hint

var _is_open: bool = false
var _player_inside: bool = false
var _start_lid_rot: Vector3


func _ready() -> void:
    _start_lid_rot = lid.rotation
    trigger.body_entered.connect(_on_enter)
    trigger.body_exited.connect(_on_exit)
    hint.visible = false


func _on_enter(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = true
        if not _is_open:
            hint.visible = true


func _on_exit(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = false
        hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if _is_open or not _player_inside:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        _open()


func _open() -> void:
    _is_open = true
    hint.visible = false
    SoundBank.play_3d("crystal_hit", global_position)
    var t := create_tween()
    t.tween_property(lid, "rotation:x", _start_lid_rot.x - 1.4, 0.5)
    if contents_scene:
        var item: Node3D = contents_scene.instantiate()
        get_parent().add_child(item)
        item.global_position = global_position + Vector3(0, 0.5, 0)
        # Tiny pop animation
        var pop := create_tween().set_parallel(true)
        pop.tween_property(item, "global_position:y", global_position.y + 1.0, 0.25)
        pop.chain().tween_property(item, "global_position:y", global_position.y + 0.4, 0.25)
    if open_message != "":
        Dialog.show_message(open_message)
