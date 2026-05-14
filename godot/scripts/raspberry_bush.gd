extends Node3D

# Wild raspberry bush: walk up, press E to pick. Yields 1-3 raspberries
# and despawns. Modeled on treasure_chest.gd's prompt + interact flow
# but one-shot and lighter — no lid tween, no flag gate.

@onready var prompt_area: Area3D = $PromptArea
@onready var hint: Label3D = $Hint

var _player_inside: bool = false
var _picked: bool = false


func _ready() -> void:
    add_to_group("ground_snap")
    hint.visible = false
    prompt_area.body_entered.connect(_on_enter)
    prompt_area.body_exited.connect(_on_exit)


func _on_enter(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = true
        if not _picked:
            hint.visible = true


func _on_exit(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = false
        hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if _picked or not _player_inside:
        return
    # Match treasure_chest's gate: don't pick while a dialog is open, so
    # the E press intended to advance dialog doesn't accidentally harvest.
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        _pick()


func _pick() -> void:
    _picked = true
    hint.visible = false
    var n: int = randi_range(1, 3)
    if GameState.has_method("add_resource"):
        GameState.add_resource("raspberry", n)
    _mark_destroyed()
    queue_free()


# Procedural-world persistence hook — see wood_bush.gd. The prop_id meta
# is stamped at spawn by world_chunk.apply_data; hand-placed bushes have
# no meta and this is a silent no-op.
func _mark_destroyed() -> void:
    if not has_meta("prop_id"):
        return
    if GameState == null:
        return
    GameState.destroyed_props[String(get_meta("prop_id"))] = true
