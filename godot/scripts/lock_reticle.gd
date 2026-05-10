extends Control

# Lock-on reticle. A full-screen Control that listens to the player's
# lock state and paints a 4-corner triangular bracket around the
# locked target's screen position.
#
# Owner contract: this is added as a child of the HUD CanvasLayer (see
# hud.gd._ensure_lock_reticle). It finds the player via the `player`
# group on _process so it survives scene swaps and works even when the
# HUD is instantiated before the player.
#
# Visual: four small filled triangles arranged at the corners of an
# invisible square centred on the target. Bright yellow when locked,
# fades in over FADE_IN_TIME on acquisition and out over FADE_OUT_TIME
# on release so the lock feels assertive without flashing.

const BRACKET_SIZE: float = 60.0    # square edge in pixels
const TRI_LEG: float = 14.0         # length of each corner-tri leg
const COLOR_LOCK := Color(1.0, 0.92, 0.20, 1.0)
const FADE_IN_TIME: float = 0.15
const FADE_OUT_TIME: float = 0.15

var _player: Node = null
var _alpha: float = 0.0
var _target_alpha: float = 0.0
var _last_screen_pos: Vector2 = Vector2.ZERO
var _has_screen_pos: bool = false


func _ready() -> void:
    # Cover the full viewport so we can draw anywhere; ignore mouse
    # events so the reticle never eats clicks meant for other HUD.
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    z_index = 10


func _process(delta: float) -> void:
    _ensure_player()
    var locked: bool = false
    var target: Node3D = null
    if _player and is_instance_valid(_player) and _player.has_method("get_lock_target"):
        target = _player.get_lock_target()
        locked = target != null

    if locked:
        _target_alpha = 1.0
        var cam := get_viewport().get_camera_3d()
        if cam and not cam.is_position_behind(target.global_position):
            _last_screen_pos = cam.unproject_position(target.global_position)
            _has_screen_pos = true
        else:
            # Behind-the-camera or no cam — keep last known position so
            # the reticle holds on the edge for one frame instead of
            # snapping to (0,0). Fade will catch up if the lock drops.
            pass
    else:
        _target_alpha = 0.0

    var fade_rate: float = (1.0 / FADE_IN_TIME) if _target_alpha > _alpha else (1.0 / FADE_OUT_TIME)
    _alpha = move_toward(_alpha, _target_alpha, fade_rate * delta)
    if _alpha <= 0.001:
        _has_screen_pos = false
    queue_redraw()


func _ensure_player() -> void:
    if _player and is_instance_valid(_player):
        return
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        _player = ps[0]


func _draw() -> void:
    if _alpha <= 0.001 or not _has_screen_pos:
        return
    var col := COLOR_LOCK
    col.a = _alpha
    var c: Vector2 = _last_screen_pos
    var h: float = BRACKET_SIZE * 0.5
    var leg: float = TRI_LEG
    # Four corners: TL, TR, BL, BR. Each is a small filled triangle that
    # opens away from the centre, so together they read as a "[ ]"
    # frame around the target.
    _draw_corner_tri(c + Vector2(-h, -h), Vector2(1, 0), Vector2(0, 1), leg, col)   # TL
    _draw_corner_tri(c + Vector2( h, -h), Vector2(-1, 0), Vector2(0, 1), leg, col)  # TR
    _draw_corner_tri(c + Vector2(-h,  h), Vector2(1, 0), Vector2(0, -1), leg, col)  # BL
    _draw_corner_tri(c + Vector2( h,  h), Vector2(-1, 0), Vector2(0, -1), leg, col) # BR


func _draw_corner_tri(corner: Vector2, dir_a: Vector2, dir_b: Vector2,
        leg: float, col: Color) -> void:
    # The corner point itself is the apex; the two legs run inward
    # toward the bracket's centre. Three vertices = one filled tri.
    var pts := PackedVector2Array([
        corner,
        corner + dir_a * leg,
        corner + dir_b * leg,
    ])
    draw_colored_polygon(pts, col)
