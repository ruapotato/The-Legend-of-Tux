extends Area3D

# Scene-transition trigger. Walking the player into the volume fires
# the change — the prompt label is now purely a signpost so the player
# knows where they're going, not a gate they have to confirm at. The
# scene swap goes through SceneFader for a clean fade-to-black.
#
# `auto_trigger` (default true) gates whether body-enter actually
# fires. Set false on a load zone if you want it to require explicit
# interact, but you'll need to wire that flow yourself.

@export_file("*.tscn") var target_scene: String = ""
@export var target_spawn: String = "default"
@export_multiline var prompt: String = ""
@export var auto_trigger: bool = true

@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _firing: bool = false


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    if hint:
        hint.text = prompt if prompt != "" else "Travel"
        hint.visible = true


func _on_enter(body: Node) -> void:
    if _firing or not auto_trigger:
        return
    if not body.is_in_group("player"):
        return
    _fire(body)


func _fire(player: Node) -> void:
    if _firing or target_scene == "":
        return
    _firing = true
    GameState.next_spawn_id = target_spawn
    # Freeze the player so they can't keep walking off the world while
    # the fade plays out. Scene change disposes the player anyway, so
    # we don't need to re-enable.
    if player and player is CharacterBody3D:
        player.set_physics_process(false)
    SceneFader.change_scene(target_scene)
