extends Area3D

# Scene-transition trigger. Walking the player into the volume fires
# the change. The Hint label is a signpost, not a gate — players can
# see where they're going without needing to fish for an interact key.
#
# Re-entry suppression: when a corresponding return-portal is placed
# right next to the destination's spawn (so "back to wyrdwood" goes
# right back to "from_wyrdwood" which spawns NEXT TO the back-to-glade
# portal), the player materializes already-overlapping the trigger and
# body_entered fires on the first tick — bouncing them right back.
# Fix: on _ready check overlapping bodies; if the player is already
# inside, suppress until they walk out and back in.

@export_file("*.tscn") var target_scene: String = ""
@export var target_spawn: String = "default"
@export_multiline var prompt: String = ""
@export var auto_trigger: bool = true

@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _firing: bool = false
var _suppressed: bool = false


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    body_exited.connect(_on_exit)
    if hint:
        hint.text = prompt if prompt != "" else "Travel"
        hint.visible = true
    # Defer so DungeonRoot has had a chance to position the player at
    # the named spawn before we check.
    call_deferred("_check_initial_overlap")


func _check_initial_overlap() -> void:
    if not is_inside_tree():
        return
    # Bodies inside on first tick are spawn-overlap, not real "enter"
    # events. Wait until they leave before counting future entries.
    for body in get_overlapping_bodies():
        if body.is_in_group("player"):
            _suppressed = true
            return


func _on_enter(body: Node) -> void:
    if _firing or _suppressed or not auto_trigger:
        return
    if not body.is_in_group("player"):
        return
    _fire(body)


func _on_exit(body: Node) -> void:
    if body.is_in_group("player"):
        _suppressed = false


func _fire(player: Node) -> void:
    if _firing or target_scene == "":
        return
    _firing = true
    GameState.next_spawn_id = target_spawn
    if player and player is CharacterBody3D:
        player.set_physics_process(false)
    SceneFader.change_scene(target_scene)
