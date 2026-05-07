extends Area3D

# Scene-transition trigger. Walk in (and optionally press E if a prompt
# is set) to load `target_scene` and have the destination's DungeonRoot
# place Tux at the spawn matching `target_spawn`.

@export_file("*.tscn") var target_scene: String = ""
@export var target_spawn: String = "default"
@export_multiline var prompt: String = ""    # if non-empty: hold E to confirm
@export var auto_trigger: bool = true        # if true: walk-in triggers; if false: needs interact

@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _player_inside: bool = false
var _firing: bool = false


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    body_exited.connect(_on_exit)
    if hint:
        hint.text = prompt if prompt != "" else "[E] Travel"
        hint.visible = false


func _on_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _player_inside = true
    if auto_trigger and prompt == "":
        _fire()
    elif hint:
        hint.visible = true


func _on_exit(body: Node) -> void:
    if body.is_in_group("player"):
        _player_inside = false
        if hint:
            hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if not _player_inside or _firing:
        return
    if prompt == "" and auto_trigger:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        _fire()


func _fire() -> void:
    if _firing or target_scene == "":
        return
    _firing = true
    GameState.next_spawn_id = target_spawn
    # Defer the scene change one frame so any in-flight signals/inputs
    # finish cleanly before the tree is swapped out.
    call_deferred("_do_change_scene")


func _do_change_scene() -> void:
    get_tree().change_scene_to_file(target_scene)
