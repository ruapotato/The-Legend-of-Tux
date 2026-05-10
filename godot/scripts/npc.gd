extends Node3D

# A talkable NPC. Walk into the prompt area, press the interact action
# (default E), and a Dialog tree opens. The body is a primitive penguin-
# ish figure (sphere body, dome head, robe cone, two short arms) so each
# NPC can be tinted via @export without authoring per-NPC art.
#
# `dialog_tree` accepts the same Dictionary schema as Dialog.show_tree.
# Trees coming from build_dungeon.py arrive as a JSON string and are
# parsed in _ready (see `dialog_tree_json`).

@export var npc_name: String = ""
@export_multiline var idle_hint: String = "[E] Talk"
@export var body_color: Color = Color(0.50, 0.55, 0.75)
@export var hat_color: Color = Color(0.30, 0.30, 0.40)
# Trees can be authored two ways:
#   1. Direct Dictionary literal (in code or in the editor inspector).
#   2. As a JSON string — much easier for the build pipeline to emit.
#      If `dialog_tree_json` is non-empty it overrides `dialog_tree`.
@export var dialog_tree: Dictionary = {}
@export_multiline var dialog_tree_json: String = ""

@onready var prompt_area: Area3D = $PromptArea
@onready var hint: Label3D = $Hint
@onready var body_pivot: Node3D = $BodyPivot
@onready var body_mesh: MeshInstance3D = $BodyPivot/Body
@onready var head_mesh: MeshInstance3D = $BodyPivot/Head
@onready var robe_mesh: MeshInstance3D = $BodyPivot/Robe
@onready var arm_l: MeshInstance3D = $BodyPivot/ArmL
@onready var arm_r: MeshInstance3D = $BodyPivot/ArmR

var _player: Node3D = null
var _player_inside: bool = false
var _t: float = 0.0
# Floating Label3D that fades in when the player is close. Built
# procedurally in _ready (no .tscn churn) so each NPC gets one for
# free without authoring it per-scene.
var _nameplate: Label3D = null


func _ready() -> void:
    add_to_group("ground_snap")
    if dialog_tree_json != "" and dialog_tree.is_empty():
        var parsed: Variant = JSON.parse_string(dialog_tree_json)
        if typeof(parsed) == TYPE_DICTIONARY:
            dialog_tree = parsed
        else:
            push_warning("npc '%s': dialog_tree_json failed to parse" % npc_name)
    # Tint the primitive body to taste.
    _tint_mesh(body_mesh, body_color)
    _tint_mesh(head_mesh, body_color)
    _tint_mesh(arm_l,    body_color)
    _tint_mesh(arm_r,    body_color)
    _tint_mesh(robe_mesh, hat_color)
    hint.visible = false
    hint.text = idle_hint
    prompt_area.body_entered.connect(_on_enter)
    prompt_area.body_exited.connect(_on_exit)
    _ensure_nameplate()


# Build the proximity-fade name label as a child Label3D. Sits 1.5m
# above the NPC origin (just above the [E] Talk hint at 1.85m, so the
# two stack cleanly without overlapping). Skipped silently if the NPC
# has no name to show — anonymous NPCs stay anonymous.
func _ensure_nameplate() -> void:
    if _nameplate != null:
        return
    if npc_name == "":
        return
    _nameplate = Label3D.new()
    _nameplate.set_script(load("res://scripts/npc_nameplate.gd"))
    # set() the script's exported fields BEFORE add_child so _ready on
    # the script runs with the correct values (height_offset, name).
    _nameplate.set("display_name", npc_name)
    _nameplate.set("height_offset", 2.25)    # above the [E] Talk hint
    _nameplate.set("proximity", 4.0)
    add_child(_nameplate)


func _tint_mesh(mi: MeshInstance3D, c: Color) -> void:
    if mi == null:
        return
    var mat := StandardMaterial3D.new()
    mat.albedo_color = c
    mat.roughness = 0.85
    mi.material_override = mat


func _on_enter(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = true
        _player = b as Node3D
        hint.visible = true
        _face_player()


func _on_exit(b: Node) -> void:
    if b.is_in_group("player"):
        _player_inside = false
        hint.visible = false


func _face_player() -> void:
    if _player == null:
        return
    var to_p: Vector3 = _player.global_position - global_position
    to_p.y = 0.0
    if to_p.length_squared() < 0.001:
        return
    var ang := atan2(to_p.x, to_p.z)
    body_pivot.rotation.y = ang


func _process(delta: float) -> void:
    _t += delta
    # Slow breathing scale on the body pivot.
    var s: float = 1.0 + 0.04 * sin(_t * 1.6)
    body_pivot.scale = Vector3(s, 1.0 + 0.025 * sin(_t * 1.6 + 0.3), s)
    if _player_inside:
        _face_player()


func _unhandled_input(event: InputEvent) -> void:
    if not _player_inside:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        if dialog_tree.is_empty():
            Dialog.show_message("...")
        else:
            Dialog.show_tree(dialog_tree)
