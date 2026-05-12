extends PanelContainer

# 240x240 top-down view of the level. Implemented as a Control that
# draws dots for each interesting node and a yellow triangle for the
# editor camera. We don't bother with a SubViewport — pure 2D draw is
# plenty for a level of this scale and avoids the cost + complexity of
# a second 3D render pass.
#
# Lifetime: rebuilt every frame (cheap; tree walk per frame is a few
# hundred ops at most for a typical level). Selected object is shown
# with a flashing white ring.

const MAP_RADIUS_M: float = 30.0        # half-width of world shown
const ICON_GROUND := Color(0.40, 0.42, 0.36, 0.7)
const ICON_WALL   := Color(0.55, 0.55, 0.58, 1.0)
const ICON_NPC    := Color(0.40, 0.95, 0.45, 1.0)
const ICON_ENEMY  := Color(0.95, 0.30, 0.30, 1.0)
const ICON_CHEST  := Color(0.85, 0.65, 0.30, 1.0)
const ICON_OWL    := Color(0.95, 0.85, 0.40, 1.0)
const ICON_WATER  := Color(0.30, 0.60, 0.95, 1.0)
const ICON_TREE   := Color(0.30, 0.50, 0.30, 1.0)
const ICON_LZ     := Color(0.85, 0.55, 0.85, 1.0)
const ICON_SPAWN  := Color(0.30, 0.95, 0.45, 0.8)
const ICON_PROP   := Color(0.78, 0.72, 0.50, 1.0)
const ICON_CAMERA := Color(1, 0.95, 0.4, 1.0)
const ICON_SELECT := Color(1, 1, 1, 1)


var _t: float = 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(240, 240)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.06, 0.07, 0.10, 0.85))
	draw_rect(rect, Color(0.4, 0.4, 0.4, 0.6), false, 1)

	var sc := get_tree().current_scene
	if sc == null:
		return
	var center := size * 0.5

	# Walk the tree once.
	for n in _walk(sc):
		_draw_node(n, center)

	# Editor camera as yellow triangle.
	var cam := sc.find_child("EditorCamera", true, false) as Camera3D
	if cam:
		_draw_camera(cam, center)

	# Selected node ring (flashing).
	var ui := sc.find_child("EditorUI", true, false)
	if ui and ui.has_method("get_selected"):
		var sel = ui.get_selected()
		if sel and sel is Node3D:
			var p := _world_to_map((sel as Node3D).global_position, center)
			var pulse: float = 0.5 + 0.5 * sin(_t * 8.0)
			draw_circle(p, 6.0 + pulse * 3.0, Color(1, 1, 1, 0.4 + pulse * 0.4))


func _draw_node(n: Node, center: Vector2) -> void:
	if not (n is Node3D):
		return
	var n3d: Node3D = n
	var p := _world_to_map(n3d.global_position, center)
	if not Rect2(Vector2.ZERO, size).has_point(p):
		return
	# Classify.
	if n.is_in_group("ground_patch"):
		# Render the patch as a translucent rectangle based on its size.
		# We don't know the actual size without reading the script — use
		# a 30m default modulated by scale.
		var s_world := 30.0 * (n3d.scale.x if n3d.scale.x > 0 else 1.0)
		var s_px := (s_world / (MAP_RADIUS_M * 2.0)) * size.x
		var r := Rect2(p - Vector2(s_px * 0.5, s_px * 0.5), Vector2(s_px, s_px))
		draw_rect(r, ICON_GROUND)
		return
	if n.is_in_group("wall_segment"):
		draw_rect(Rect2(p - Vector2(4, 1), Vector2(8, 2)), ICON_WALL)
		return
	if n.is_in_group("water_volume"):
		draw_circle(p, 4.0, ICON_WATER)
		return
	if n.is_in_group("npc"):
		draw_circle(p, 3.0, ICON_NPC); return
	if n.is_in_group("enemy"):
		draw_circle(p, 3.0, ICON_ENEMY); return
	if n.is_in_group("chest") or n.name.contains("Chest"):
		draw_circle(p, 3.0, ICON_CHEST); return
	if n.name.contains("Owl"):
		draw_circle(p, 3.0, ICON_OWL); return
	if n.is_in_group("tree") or n.name.contains("Tree"):
		draw_circle(p, 2.0, ICON_TREE); return
	if n.is_in_group("load_zone"):
		draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), ICON_LZ); return
	if n.is_in_group("spawn_marker"):
		draw_circle(p, 2.0, ICON_SPAWN); return


func _draw_camera(cam: Camera3D, center: Vector2) -> void:
	var p := _world_to_map(cam.global_position, center)
	# Forward in XZ → yaw angle in screen space.
	var f: Vector3 = -cam.global_transform.basis.z
	var ang: float = atan2(f.x, f.z)
	var a := p + Vector2(sin(ang), -cos(ang)) * 8.0
	var b := p + Vector2(sin(ang + 2.5), -cos(ang + 2.5)) * 5.0
	var c := p + Vector2(sin(ang - 2.5), -cos(ang - 2.5)) * 5.0
	draw_polygon(PackedVector2Array([a, b, c]), PackedColorArray([ICON_CAMERA, ICON_CAMERA, ICON_CAMERA]))


func _world_to_map(w: Vector3, center: Vector2) -> Vector2:
	# Map (-MAP_RADIUS_M .. MAP_RADIUS_M) → (0 .. size). z+ → down.
	var x := (w.x / MAP_RADIUS_M) * (size.x * 0.5) + center.x
	var y := (w.z / MAP_RADIUS_M) * (size.y * 0.5) + center.y
	return Vector2(x, y)


func _walk(root: Node) -> Array:
	var out: Array = [root]
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out
