extends Area3D

# Scene-transition trigger. Walking the player into the volume fires
# the change. The Hint label is a signpost; the prompt text is shown
# above the portal so the player knows where it leads.
#
# Spawn-overlap suppression: when the destination scene's "from_X"
# spawn marker sits next to the back-to-X portal, the player's
# capsule materializes already overlapping the trigger and
# body_entered fires on the very next physics tick — bouncing the
# player back to the source. The earlier "check overlapping_bodies on
# _ready" approach was racy because physics hadn't run yet by the
# time the deferred check ran. We just use a time-based grace window
# instead: ignore body entries for SPAWN_GRACE seconds after _ready.

const SPAWN_GRACE: float = 0.6

@export_file("*.tscn") var target_scene: String = ""
@export var target_spawn: String = "default"
@export_multiline var prompt: String = ""
@export var auto_trigger: bool = true

@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _firing: bool = false
var _ready_at: float = 0.0


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    if hint:
        hint.text = prompt if prompt != "" else "Travel"
        hint.visible = true
    _ready_at = Time.get_ticks_msec() / 1000.0


func _on_enter(body: Node) -> void:
    if _firing or not auto_trigger:
        return
    if not body.is_in_group("player"):
        return
    var elapsed: float = Time.get_ticks_msec() / 1000.0 - _ready_at
    if elapsed < SPAWN_GRACE:
        # Player materialized inside us at scene load — not a real
        # crossing. Ignore.
        return
    _fire(body)


func _fire(player: Node) -> void:
    if _firing or target_scene == "":
        return
    _firing = true
    GameState.next_spawn_id = target_spawn
    # Mirror the destination spawn into current_spawn_id ahead of the
    # save so the snapshot we take here represents where Tux will be
    # *after* the transition, not where he was.
    GameState.current_spawn_id = target_spawn
    # Pretend we're already on the target scene for the save snapshot
    # so reloading from this autosave puts the player on the other
    # side of the door, not back inside the load zone.
    if GameState.last_slot >= 0:
        var prior_scene_path: String = ""
        var scene := get_tree().current_scene
        if scene:
            prior_scene_path = scene.scene_file_path
            scene.scene_file_path = target_scene
        GameState.save_game(GameState.last_slot)
        if scene and prior_scene_path != "":
            scene.scene_file_path = prior_scene_path
    if player and player is CharacterBody3D:
        player.set_physics_process(false)
    SceneFader.change_scene(target_scene)
