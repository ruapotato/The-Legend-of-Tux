extends CanvasLayer

# Toggleable debug HUD: prints position + clock-face angle of tracked
# points (sword tip, shield center) relative to the player. Shows angles
# in BOTH conventions because "12 o'clock" is ambiguous in 3D:
#
#   front-view : 12 = up,      3 = right,  6 = down, 9 = left   (Z ignored)
#   top-down   : 12 = forward, 3 = right,  6 = back, 9 = left   (Y ignored)
#
# Use this to compare against verbal descriptions like "sword at 7
# o'clock" — you read the value off the HUD instead of guessing.
#
# Press F3 to toggle.

@export var visible_initial: bool = true

var player: Node3D = null
var blade: MeshInstance3D = null
var shield_board: MeshInstance3D = null
var label: Label


func _ready() -> void:
    visible = visible_initial
    label = Label.new()
    label.position = Vector2(20, 140)
    label.add_theme_font_size_override("font_size", 13)
    label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
    label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
    label.add_theme_constant_override("outline_size", 4)
    add_child(label)


func _process(_delta: float) -> void:
    if not visible:
        return
    if not player or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]
    if not player:
        label.text = "(no player found — F3 to hide)"
        return
    if not blade or not is_instance_valid(blade):
        blade = player.find_child("Blade", true, false) as MeshInstance3D
    if not shield_board or not is_instance_valid(shield_board):
        shield_board = player.find_child("Board", true, false) as MeshInstance3D

    var lines := PackedStringArray()
    lines.append("Debug overlay (F3 to toggle)")
    lines.append("face_yaw: %.1f°" % rad_to_deg(player.rotation.y))
    lines.append("Front-view clock: 12=up, 3=right, 6=down, 9=left")
    lines.append("Top-down  clock: 12=forward, 3=right, 6=back, 9=left")
    lines.append("")

    if blade:
        # Sword tip is offset along the blade-mesh's local -Y axis by
        # half its length (mesh height = 0.50, so tip at y=-0.25).
        var tip: Vector3 = blade.to_global(Vector3(0, -0.25, 0))
        _track("Sword tip", tip, lines)
    if shield_board:
        _track("Shield center", shield_board.global_position, lines)

    label.text = "\n".join(lines)


func _track(point_name: String, world_pos: Vector3, lines: PackedStringArray) -> void:
    var rel: Vector3 = player.to_local(world_pos)
    lines.append("%s" % point_name)
    lines.append("  body-local: (%+.2f, %+.2f, %+.2f)" % [rel.x, rel.y, rel.z])
    lines.append("  front: %s | top-down: %s" % [_clock_front(rel), _clock_top(rel)])


# Front-view clock: 12 = up (+Y), 3 = right (+X), 6 = down (-Y), 9 = left (-X).
# Z is ignored — we project onto the player's frontal plane.
func _clock_front(local: Vector3) -> String:
    var ang: float = atan2(local.x, local.y)   # clockwise from +Y
    var hours: float = ang / (PI / 6.0)
    if hours <= 0:
        hours += 12.0
    return "%.1f o'clock" % hours


# Top-down clock: 12 = forward (-Z), 3 = right (+X), 6 = back (+Z), 9 = left (-X).
# Y is ignored.
func _clock_top(local: Vector3) -> String:
    var ang: float = atan2(local.x, -local.z)
    var hours: float = ang / (PI / 6.0)
    if hours <= 0:
        hours += 12.0
    return "%.1f o'clock" % hours


func _input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
        visible = not visible
