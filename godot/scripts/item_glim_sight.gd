extends Node

# Glim Sight — handheld lens. Held while the B-button is pressed: fades
# in a soft yellow vignette over the screen, slows Tux to 30% speed
# (player.gd reads `glim_sight_active` and applies the multiplier), and
# reveals nodes in the groups `invisible_figure`, `fake_wall`, and
# `hidden_chest` within a 12 m forward cone. Releasing B drops the
# vignette and restores hidden visibility.
#
# Like item_hammer.gd this is a thin static wrapper: open()/close() are
# state changes on a single helper Node parented under the player. The
# helper owns the CanvasLayer overlay, the ticking cone-reveal scan, and
# the per-node visibility cache used to restore state on close.

const VIGNETTE_COLOR := Color(1.0, 0.92, 0.45, 0.32)
const REVEAL_CONE_DEG: float = 75.0    # half-angle, ~150° total spread
const REVEAL_RANGE: float = 12.0
const SLOW_MULT: float = 0.30          # cached for player.gd to read
const FAKE_WALL_TRANSPARENCY: float = 0.4


# Open the sight. Returns the helper instance (or null if nothing happened
# — e.g. if the sight is already open). The player passes itself.
static func open(player: Node3D) -> Node:
    if player == null or not is_instance_valid(player):
        return null
    for child in player.get_children():
        if child.has_meta("glim_sight_active"):
            return child
    var helper := Node.new()
    helper.set_meta("glim_sight_active", true)
    helper.set_script(load("res://scripts/item_glim_sight.gd"))
    player.add_child(helper)
    helper.set("_player", player)
    helper.call_deferred("_begin")
    return helper


# Close any open sight on the player. No-op if none is up.
static func close(player: Node3D) -> void:
    if player == null or not is_instance_valid(player):
        return
    for child in player.get_children():
        if child.has_meta("glim_sight_active"):
            (child as Node).call("_end")
            return


# Quick status check used by player.gd's movement modifier path. Avoids
# storing a second flag in GameState — the helper's mere existence is
# the source of truth.
static func is_open_on(player: Node3D) -> bool:
    if player == null or not is_instance_valid(player):
        return false
    for child in player.get_children():
        if child.has_meta("glim_sight_active"):
            return true
    return false


# ---- Helper-instance behaviour -----------------------------------------

var _player: Node3D = null
var _layer: CanvasLayer = null
var _vignette: ColorRect = null
# Per-node cache: { node_path: { "kind": "show"|"alpha", ...prev state } }
# Used so _end() restores visibility/alpha to whatever the scene authored.
var _restore_set: Dictionary = {}
var _scan_cooldown: float = 0.0
const SCAN_INTERVAL: float = 0.10


func _begin() -> void:
    if _player == null or not is_instance_valid(_player):
        queue_free()
        return
    SoundBank.play_2d("glim_sight_open")
    # Terminal-corner narration. Lore-canon command: `ls -la <cone>` —
    # the `-a` flag is what makes hidden dotfile-things visible. Fires
    # once on open; the per-tick scan does NOT re-narrate.
    var tl: Node = _player.get_node_or_null("/root/TerminalLog")
    if tl:
        tl.cmd("ls -la ./cone")
    _layer = CanvasLayer.new()
    _layer.layer = 70    # behind the pause menu (80) but above the HUD
    _layer.process_mode = Node.PROCESS_MODE_ALWAYS
    _player.get_tree().current_scene.add_child(_layer)
    _vignette = ColorRect.new()
    _vignette.color = Color(VIGNETTE_COLOR.r, VIGNETTE_COLOR.g,
                            VIGNETTE_COLOR.b, 0.0)
    _vignette.anchor_right = 1.0
    _vignette.anchor_bottom = 1.0
    _vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _layer.add_child(_vignette)
    var t := create_tween()
    t.tween_property(_vignette, "color:a", VIGNETTE_COLOR.a, 0.20)
    set_process(true)


func _process(delta: float) -> void:
    _scan_cooldown -= delta
    if _scan_cooldown > 0.0:
        return
    _scan_cooldown = SCAN_INTERVAL
    _scan_cone()


func _end() -> void:
    set_process(false)
    _restore_revealed()
    if _vignette != null and is_instance_valid(_vignette):
        var t := create_tween()
        t.tween_property(_vignette, "color:a", 0.0, 0.12)
        t.tween_callback(func() -> void:
            if _layer != null and is_instance_valid(_layer):
                _layer.queue_free())
    elif _layer != null and is_instance_valid(_layer):
        _layer.queue_free()
    queue_free()


# Scan the three reveal-target groups; for each node within a forward
# cone of REVEAL_RANGE meters and REVEAL_CONE_DEG half-angle, flip its
# visibility (or, for fake_walls, lower its alpha) and remember the
# previous state so _end() can put it back.
func _scan_cone() -> void:
    if _player == null or not is_instance_valid(_player):
        return
    var tree: SceneTree = _player.get_tree()
    if tree == null:
        return
    var origin: Vector3 = _player.global_position + Vector3(0, 1.0, 0)
    var fwd: Vector3 = -_player.global_transform.basis.z
    fwd.y = 0.0
    if fwd.length() < 0.01:
        fwd = Vector3(0, 0, -1)
    fwd = fwd.normalized()
    var cos_min: float = cos(deg_to_rad(REVEAL_CONE_DEG))
    for group_name in ["invisible_figure", "hidden_chest"]:
        for n in tree.get_nodes_in_group(group_name):
            _try_reveal(n, origin, fwd, cos_min, "show")
    for n in tree.get_nodes_in_group("fake_wall"):
        _try_reveal(n, origin, fwd, cos_min, "alpha")


func _try_reveal(n: Node, origin: Vector3, fwd: Vector3,
                 cos_min: float, kind: String) -> void:
    if not (n is Node3D):
        return
    var n3: Node3D = n
    var to: Vector3 = n3.global_position - origin
    var d: float = to.length()
    if d > REVEAL_RANGE:
        return
    if d > 0.001:
        var dot: float = fwd.dot(to.normalized())
        if dot < cos_min:
            return
    var key: String = String(n3.get_path())
    if _restore_set.has(key):
        return    # already revealed this open
    if kind == "show":
        _restore_set[key] = {"kind": "show", "node": n3, "prev": n3.visible}
        n3.visible = true
    else:
        # fake_wall: lower the surface alpha. We walk the immediate
        # children for any MeshInstance3D and tweak its material's
        # albedo alpha. Cache the original albedo so we can restore.
        var mats: Array = []
        var stack: Array = [n3]
        while not stack.is_empty():
            var cur: Node = stack.pop_back()
            if cur is MeshInstance3D:
                var mi: MeshInstance3D = cur
                var m: Material = mi.get_active_material(0)
                if m is StandardMaterial3D:
                    var sm: StandardMaterial3D = m.duplicate() as StandardMaterial3D
                    sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                    var col: Color = sm.albedo_color
                    col.a = FAKE_WALL_TRANSPARENCY
                    sm.albedo_color = col
                    mats.append({"mi": mi, "prev": m})
                    mi.material_override = sm
            for c in cur.get_children():
                stack.append(c)
        _restore_set[key] = {"kind": "alpha", "node": n3, "mats": mats}


func _restore_revealed() -> void:
    for key in _restore_set.keys():
        var entry: Dictionary = _restore_set[key]
        var node: Node = entry.get("node")
        if node == null or not is_instance_valid(node):
            continue
        match String(entry.get("kind", "show")):
            "show":
                (node as Node3D).visible = bool(entry.get("prev", false))
            "alpha":
                for slot in entry.get("mats", []):
                    var mi: MeshInstance3D = slot.get("mi")
                    if mi != null and is_instance_valid(mi):
                        mi.material_override = null
    _restore_set.clear()
