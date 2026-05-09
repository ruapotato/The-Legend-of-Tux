extends Node3D

# Owl statue — interactable shrine prop. Walking up + pressing the
# `interact` action unlocks this owl's warp in GameState.unlocked_warps,
# then opens a CanvasLayer overlay listing every warp Tux has activated
# anywhere in the world. Selecting one calls SceneFader.change_scene
# and stashes GameState.next_spawn_id so the dungeon_root receives the
# player at the right Marker3D.
#
# Visual is a small dark stone owl on a plinth; on first activation a
# dim ember glow turns on inside the chest. The prop is placed via
# JSON's `props` list; build_dungeon.py threads warp_id / warp_name /
# warp_target_scene / warp_target_spawn through to these exports.

@export var warp_id:            String = ""
@export var warp_name:          String = ""
@export var warp_target_scene:  String = ""
@export var warp_target_spawn:  String = "default"
@export var hint_label:         String = "[E] Bow to the Owl"

var _player_inside: bool = false
var _hint: Label3D = null
var _glow_light: OmniLight3D = null


func _ready() -> void:
    add_to_group("owl_statue")
    _build_visual()
    _build_trigger()
    _refresh_glow()
    if GameState.has_signal("warps_changed"):
        GameState.warps_changed.connect(_on_warps_changed)


func _build_visual() -> void:
    # Plinth — wide, low cylinder of grey stone.
    var plinth_mesh := CylinderMesh.new()
    plinth_mesh.top_radius    = 0.55
    plinth_mesh.bottom_radius = 0.65
    plinth_mesh.height        = 0.45
    var plinth_mat := StandardMaterial3D.new()
    plinth_mat.albedo_color = Color(0.36, 0.36, 0.40, 1.0)
    plinth_mat.roughness    = 0.95
    var plinth_node := MeshInstance3D.new()
    plinth_node.name = "Plinth"
    plinth_node.mesh = plinth_mesh
    plinth_node.material_override = plinth_mat
    plinth_node.position = Vector3(0, 0.225, 0)
    add_child(plinth_node)

    # Body — taller cylinder, darker stone.
    var body_mat := StandardMaterial3D.new()
    body_mat.albedo_color = Color(0.20, 0.20, 0.24, 1.0)
    body_mat.roughness    = 0.92

    var body_mesh := CylinderMesh.new()
    body_mesh.top_radius    = 0.30
    body_mesh.bottom_radius = 0.40
    body_mesh.height        = 0.85
    var body_node := MeshInstance3D.new()
    body_node.name = "Body"
    body_node.mesh = body_mesh
    body_node.material_override = body_mat
    body_node.position = Vector3(0, 0.45 + 0.425, 0)
    add_child(body_node)

    # Head — sphere on top.
    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.28
    head_mesh.height = 0.56
    var head_node := MeshInstance3D.new()
    head_node.name = "Head"
    head_node.mesh = head_mesh
    head_node.material_override = body_mat
    head_node.position = Vector3(0, 0.45 + 0.85 + 0.20, 0)
    add_child(head_node)

    # Eyes — two small bright spheres flush to the front of the head.
    var eye_mat := StandardMaterial3D.new()
    eye_mat.albedo_color      = Color(0.95, 0.78, 0.30, 1.0)
    eye_mat.emission_enabled  = true
    eye_mat.emission          = Color(1.0, 0.6, 0.2, 1.0)
    eye_mat.emission_energy_multiplier = 0.7
    for sx in [-1.0, 1.0]:
        var eye_mesh := SphereMesh.new()
        eye_mesh.radius = 0.07
        eye_mesh.height = 0.14
        var eye := MeshInstance3D.new()
        eye.mesh = eye_mesh
        eye.material_override = eye_mat
        eye.position = Vector3(sx * 0.13, 0.45 + 0.85 + 0.22, 0.21)
        add_child(eye)

    # Solid collision for the owl body so the player can't walk through
    # it. A simple capsule covers plinth + body without needing two
    # separate shapes.
    var body_static := StaticBody3D.new()
    body_static.name = "Solid"
    body_static.collision_layer = 1
    body_static.collision_mask  = 0
    var col := CollisionShape3D.new()
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.45
    capsule.height = 1.6
    col.shape = capsule
    col.position = Vector3(0, 0.8, 0)
    body_static.add_child(col)
    add_child(body_static)

    # Ember glow — child of the body; toggled visible once activated.
    _glow_light = OmniLight3D.new()
    _glow_light.name = "EmberGlow"
    _glow_light.light_color  = Color(1.0, 0.55, 0.22, 1.0)
    _glow_light.light_energy = 0.8
    _glow_light.omni_range   = 3.5
    _glow_light.position     = Vector3(0, 0.45 + 0.55, 0.0)
    _glow_light.visible      = false
    add_child(_glow_light)


func _build_trigger() -> void:
    var area := Area3D.new()
    area.name = "Trigger"
    area.collision_layer = 64
    area.collision_mask  = 2
    area.monitoring      = true
    var col := CollisionShape3D.new()
    var sh := BoxShape3D.new()
    sh.size = Vector3(2.6, 2.0, 2.6)
    col.shape = sh
    col.position = Vector3(0, 1.0, 0)
    area.add_child(col)
    area.body_entered.connect(_on_enter)
    area.body_exited.connect(_on_exit)
    add_child(area)

    _hint = Label3D.new()
    _hint.name = "Hint"
    _hint.text = hint_label
    _hint.font_size = 32
    _hint.outline_size = 8
    _hint.position = Vector3(0, 2.2, 0)
    _hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    _hint.no_depth_test = true
    _hint.visible = false
    add_child(_hint)


func _on_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _player_inside = true
    if _hint:
        _hint.visible = true


func _on_exit(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _player_inside = false
    if _hint:
        _hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if not _player_inside:
        return
    if Dialog.is_active():
        return
    if event.is_action_pressed("interact"):
        get_viewport().set_input_as_handled()
        _activate()


func _activate() -> void:
    var first_time: bool = (warp_id != "" and not GameState.is_warp_unlocked(warp_id))
    if warp_id != "":
        GameState.unlock_warp(warp_id, {
            "name":  warp_name if warp_name != "" else warp_id,
            "scene": warp_target_scene,
            "spawn": warp_target_spawn,
        })
    _refresh_glow()
    if first_time:
        var pretty: String = warp_name if warp_name != "" else warp_id
        Dialog.show_message(
            "The Owl Statue speaks: 'Now you may warp to %s.'" % pretty)
    _open_menu()


func _refresh_glow() -> void:
    if _glow_light == null:
        return
    _glow_light.visible = (warp_id != "" and GameState.is_warp_unlocked(warp_id))


func _on_warps_changed() -> void:
    _refresh_glow()


# ---- Warp menu overlay --------------------------------------------------

func _open_menu() -> void:
    var menu := WarpMenu.new()
    # Parent to the active scene's root so it survives the owl being
    # culled / out of view; lifecycle ends when the menu closes itself.
    var holder: Node = get_tree().current_scene
    if holder == null:
        holder = self
    holder.add_child(menu)


# Inner class — small CanvasLayer overlay listing every unlocked warp.
# Built procedurally so we don't need a separate scene file. ESC closes
# without consuming pause input (the menu pauses the tree the same way
# pause_menu.gd does).
class WarpMenu extends CanvasLayer:
    const BACKDROP_COLOR := Color(0.05, 0.04, 0.08, 0.92)
    const TITLE_COLOR    := Color(0.98, 0.85, 0.40, 1.0)
    const LABEL_COLOR    := Color(0.92, 0.90, 0.85, 1.0)
    const HINT_COLOR     := Color(0.72, 0.70, 0.65, 1.0)

    var _was_mouse_captured: bool = false

    func _ready() -> void:
        layer = 90
        process_mode = Node.PROCESS_MODE_ALWAYS
        get_tree().paused = true
        _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
        _build_ui()

    func _build_ui() -> void:
        var root := Control.new()
        root.anchor_right  = 1.0
        root.anchor_bottom = 1.0
        root.mouse_filter  = Control.MOUSE_FILTER_STOP
        add_child(root)

        var bg := ColorRect.new()
        bg.color = BACKDROP_COLOR
        bg.anchor_right = 1.0
        bg.anchor_bottom = 1.0
        root.add_child(bg)

        var title := Label.new()
        title.text = "Owl Statue — Choose a Warp"
        title.anchor_left  = 0.0
        title.anchor_right = 1.0
        title.offset_top    = 32.0
        title.offset_bottom = 76.0
        title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        title.add_theme_font_size_override("font_size", 26)
        title.add_theme_color_override("font_color", TITLE_COLOR)
        root.add_child(title)

        var list := VBoxContainer.new()
        list.alignment = BoxContainer.ALIGNMENT_BEGIN
        list.add_theme_constant_override("separation", 8)
        list.anchor_left  = 0.5
        list.anchor_right = 0.5
        list.offset_left  = -220.0
        list.offset_right = 220.0
        list.offset_top    = 100.0
        list.offset_bottom = -80.0
        root.add_child(list)

        var warps: Array = GameState.get_unlocked_warps()
        if warps.is_empty():
            var none := Label.new()
            none.text = "(no warps unlocked yet)"
            none.add_theme_color_override("font_color", HINT_COLOR)
            none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            list.add_child(none)
        else:
            for w in warps:
                var btn := Button.new()
                btn.text = String(w.get("name", w.get("id", "?")))
                btn.custom_minimum_size = Vector2(440, 40)
                btn.add_theme_font_size_override("font_size", 18)
                var captured: Dictionary = w.duplicate(true)
                btn.pressed.connect(func(): _warp_to(captured))
                list.add_child(btn)

        var hint := Label.new()
        hint.text = "[Esc] cancel"
        hint.anchor_left  = 0.0
        hint.anchor_right = 1.0
        hint.anchor_top    = 1.0
        hint.anchor_bottom = 1.0
        hint.offset_top    = -36.0
        hint.offset_bottom = -8.0
        hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        hint.add_theme_color_override("font_color", HINT_COLOR)
        root.add_child(hint)

    func _input(event: InputEvent) -> void:
        if event.is_action_pressed("ui_cancel"):
            get_viewport().set_input_as_handled()
            _close()

    func _warp_to(w: Dictionary) -> void:
        var scene_id: String = String(w.get("scene", ""))
        if scene_id == "":
            _close()
            return
        var spawn_id: String = String(w.get("spawn", "default"))
        GameState.next_spawn_id = spawn_id
        var scene_path: String = scene_id
        if not scene_path.begins_with("res://"):
            scene_path = "res://scenes/%s.tscn" % scene_id
        # Restore mouse + unpause before the fade so the new scene
        # comes up in its normal input mode.
        get_tree().paused = false
        if _was_mouse_captured:
            Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
        SceneFader.change_scene(scene_path)
        queue_free()

    func _close() -> void:
        get_tree().paused = false
        if _was_mouse_captured:
            Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
        queue_free()
