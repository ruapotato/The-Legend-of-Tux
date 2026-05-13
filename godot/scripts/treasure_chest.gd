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
# Cross-scene gating. If non-empty, the chest stays closed-but-visible
# until GameState.has_flag(requires_flag) returns true; opening it
# beforehand surfaces a "Permission denied — needs <bit>:<path>" hint
# (see _perm_msg_for + FLAG_TO_PERM_HINT below). Used by Dungeon 5–8
# item chests to keep the dungeon item locked behind the previous
# dungeon's boss kill (DESIGN §2).
@export var requires_flag: String = ""
# Cosmetic / pass-through fields the build script forwards from chest
# JSON. The pickup wires them; the chest itself never reads them. Kept
# as exports so Godot doesn't warn on the .tscn lines (and so the
# editor surfaces them if someone hand-tunes a chest).
@export var contents_amount: int = 0
@export var contents_item_name: String = ""

# Direct grants: when set, the chest adds the item to GameState.inventory
# and / or sets the flag on open. Lets a chest hand out a sword or
# shield without needing a bespoke pickup scene — the chest IS the
# pickup. Either or both may be set independently of contents_scene.
@export var grants_item: String = ""
@export var grants_flag: String = ""

# v2.5 permission-bit reframe (LORE §v2.4–v2.5, DESIGN §v2.2). When a
# `requires_flag` chest is opened without the flag set, the failure
# message tells the player exactly which permission bit they're
# missing. Keys are the strings used in the dungeon JSON `requires`
# field; values are the display fragment that follows
# "Permission denied — needs ".
const FLAG_TO_PERM_HINT: Dictionary = {
    "wyrdking_defeated":      "r:var",
    "codex_knight_defeated":  "w:etc",
    "gale_roost_defeated":    "x:bin/cd",
    "cinder_tomato_defeated": "x:bin/rm",
    "forge_wyrm_defeated":    "rwx:dev",
    "backwater_maw_defeated": "x:usr/bin/chroot",
    "censor_defeated":        "r:hidden",
    "triglyph_assembled":     "sudo",
}

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
    # v2.5 permission reframe: chests with a `requires_flag` stay
    # visible and interactive — opening before the flag is set now
    # surfaces a "Permission denied — needs <bit>:<path>" message that
    # tells the player which boss/grant unlocks this chest. (Previously
    # the chest hid itself entirely, which left the player no clue it
    # existed.) We still listen on flag_changed so the failure message
    # naturally stops firing the moment the gate clears.


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
        # v2.5 permission gate. If the chest still needs its quest
        # flag, refuse to open and tell the player exactly which bit
        # they're missing. The chest remains closed and interactable
        # so they can come back after earning the grant.
        if requires_flag != "" and not GameState.has_flag(requires_flag):
            _push_chest_cmd(true)
            Dialog.show_message(_perm_msg_for(requires_flag))
            return
        _open()


func _open() -> void:
    _is_open = true
    hint.visible = false
    # Terminal-corner narration. Lore-canon command for opening a
    # chest is `cat <chest>` against its scene-name path. Fires once
    # on the actual open.
    _push_chest_cmd(false)
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
    # Direct grants — used for items that don't have a dedicated pickup
    # scene yet (early-game sword + shield). The chest acts as both
    # container and pickup.
    if grants_item != "":
        GameState.acquire_item(grants_item)
    if grants_flag != "":
        GameState.set_flag(grants_flag, true)
    if open_message != "":
        Dialog.show_message(open_message)


# ---- Permission-bit messaging -----------------------------------------

# Map a `requires_flag` string to the player-facing failure message.
# Known boss / quest flags map through FLAG_TO_PERM_HINT into a literal
# permission-bit hint (e.g. "x:bin/rm"); the multi-stage trade quest
# steps fall back to a softer "needs prior step" line; anything else
# (the catch-all) just names the missing flag so we never produce a
# blank message during dev.
func _perm_msg_for(flag: String) -> String:
    if FLAG_TO_PERM_HINT.has(flag):
        return "Permission denied — needs %s" % FLAG_TO_PERM_HINT[flag]
    if flag.begins_with("trade_step_"):
        return "Permission denied — needs prior step"
    return "Permission denied — needs %s" % flag


# ---- Terminal-corner narration -----------------------------------------

# Push a `cat <chest>` line to the live shell. `is_locked` controls
# whether we follow with a permission-denied error on the next frame
# (so the player reads the cmd first, then the failure underneath it,
# matching the spec's "I tried" → "denied" sequence).
func _push_chest_cmd(is_locked: bool) -> void:
    var tl: Node = get_node_or_null("/root/TerminalLog")
    if tl == null:
        return
    tl.cmd("cat %s" % name)
    if is_locked:
        var hint_bit: String = FLAG_TO_PERM_HINT.get(requires_flag, requires_flag)
        # Defer the err line by one frame so the cmd renders first;
        # otherwise both land on the same redraw and the order in the
        # buffer is undefined relative to what the player sees.
        call_deferred("_push_chest_locked_err", hint_bit)


func _push_chest_locked_err(hint_bit: String) -> void:
    var tl: Node = get_node_or_null("/root/TerminalLog")
    if tl == null:
        return
    tl.err("Permission denied — needs %s" % hint_bit)


# Compatibility shim — older draft of this hook called this name.
func _push_locked_chest_cmds() -> void:
    _push_chest_cmd(true)
