extends Node

# Autoloaded watcher for the game's terminal beat. Listens for
# GameState.boss_defeated and, when the Sleeper at the Null Door falls
# (boss_id == "init"), waits long enough for the boss-arena fanfare
# (~2.4s plus the optional Save prompt) to land in the player's eye,
# then transitions to the credits scene.
#
# We deliberately do nothing for any other boss — the regular fanfare,
# heart-container drop, and save flow handle those. This watcher is the
# one and only producer of the end-of-game transition.
#
# Idempotent: once we've fired we set _fired so a second emission
# (replayed save, debug re-kill) cannot stack a second transition.

const FINAL_BOSS_ID: String = "init"
const CREDITS_SCENE: String = "res://scenes/credits.tscn"
# Long enough for the boss-arena fanfare jingle (~2.4s) plus a beat for
# the Save prompt to surface, but short enough that the player isn't
# left wondering whether anything else is going to happen.
const POST_KILL_DELAY: float = 4.0

var _fired: bool = false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # GameState is autoloaded earlier in the [autoload] order so the
    # singleton exists by the time we run.
    if GameState and GameState.has_signal("boss_defeated"):
        GameState.boss_defeated.connect(_on_boss_defeated)
    else:
        push_warning("GameEndWatcher: GameState.boss_defeated signal missing")


func _on_boss_defeated(boss_id: String) -> void:
    if _fired:
        return
    if boss_id != FINAL_BOSS_ID:
        return
    _fired = true
    _run_end_sequence()


func _run_end_sequence() -> void:
    # Let the fanfare breathe. We use a SceneTreeTimer rather than
    # await get_tree().create_timer so the wait survives a paused tree
    # (the boss-arena fanfare may pause to surface its Save prompt).
    var timer := get_tree().create_timer(POST_KILL_DELAY, true)
    await timer.timeout
    get_tree().change_scene_to_file(CREDITS_SCENE)
