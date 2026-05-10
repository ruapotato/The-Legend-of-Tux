extends Node3D

# A chest. Walk up, press E, lid lifts, the configured pickup is
# spawned in front. One-shot — once opened, stays open and won't
# spawn again. No persistence between runs yet (per-scene state lives
# with the scene).

@export var contents_scene: PackedScene
# When the chest's contents is a small-key pickup, this overrides which
# dungeon key-group the spawned key counts toward. Empty = use the
# scene's current group (set by dungeon_root.gd). Forwarded onto the
# spawned pickup if it has a `key_group` property.
@export var contents_key_group: String = ""
@export var open_message: String = ""
# Cross-scene gating. If non-empty, the chest hides itself (visible +
# collisions disabled) on _ready unless GameState.has_flag(requires_flag)
# returns true. Used by Dungeon 5–8 item chests to keep the dungeon
# item locked behind the previous dungeon's boss kill (DESIGN §2).
@export var requires_flag: String = ""
# Cosmetic / pass-through fields the build script forwards from chest
# JSON. The pickup wires them; the chest itself never reads them. Kept
# as exports so Godot doesn't warn on the .tscn lines (and so the
# editor surfaces them if someone hand-tunes a chest).
@export var contents_amount: int = 0
@export var contents_item_name: String = ""

@onready var lid: MeshInstance3D = $Body/Lid
@onready var trigger: Area3D = $Trigger
@onready var hint: Label3D = $Hint

var _is_open: bool = false
var _player_inside: bool = false
var _start_lid_rot: Vector3


func _ready() -> void:
    add_to_group("ground_snap")
    _start_lid_rot = lid.rotation
    trigger.body_entered.connect(_on_enter)
    trigger.body_exited.connect(_on_exit)
    hint.visible = false
    # Quest-flag gate: if a `requires_flag` was wired in the dungeon JSON
    # (e.g. "cinder_tomato_defeated" for the Forge's hammer chest), keep
    # the chest hidden + non-interactive until the flag is set. We watch
    # GameState.flag_changed so the chest pops in the moment the player
    # earns it (handy if the boss is in the same scene).
    if requires_flag != "":
        if not GameState.has_flag(requires_flag):
            _set_gated(true)
            GameState.flag_changed.connect(_on_flag_changed)


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
        # Forward the per-chest key-group override onto the spawned
        # pickup if it carries that field. Pickups without it (pebble,
        # heart, items) silently ignore this.
        if contents_key_group != "" and "key_group" in item:
            item.set("key_group", contents_key_group)
        get_parent().add_child(item)
        item.global_position = global_position + Vector3(0, 0.5, 0)
        # Tiny pop animation
        var pop := create_tween().set_parallel(true)
        pop.tween_property(item, "global_position:y", global_position.y + 1.0, 0.25)
        pop.chain().tween_property(item, "global_position:y", global_position.y + 0.4, 0.25)
    if open_message != "":
        Dialog.show_message(open_message)


# ---- Quest-flag gating ------------------------------------------------

func _set_gated(gated: bool) -> void:
    visible = not gated
    set_process_unhandled_input(not gated)
    if trigger != null:
        trigger.set_deferred("monitoring", not gated)


func _on_flag_changed(flag_id: String, value) -> void:
    if flag_id != requires_flag:
        return
    if value:
        _set_gated(false)
