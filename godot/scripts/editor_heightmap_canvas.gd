extends Control

# In-inspector heightmap painter. Bind to a terrain_patch_edit node via
# set_patch(node); LMB-drag raises the heightfield under the cursor,
# RMB-drag lowers, wheel adjusts brush radius. The canvas redraws each
# event and writes patch.set_heights so the 3D mesh updates live.
#
# The texture is a (grid_size+1)² grayscale image: black = min height,
# white = max height, both clamped to [-VIS_RANGE, +VIS_RANGE] for the
# preview only (the underlying float values are not clipped).

const VIS_RANGE: float = 6.0      # half-range for visualisation only
const DEFAULT_RADIUS: int = 3
const DEFAULT_STRENGTH: float = 0.5

var _patch: Node = null

var _img: Image = null
var _tex: ImageTexture = null

var _brush_radius: int = DEFAULT_RADIUS
var _brush_strength: float = DEFAULT_STRENGTH
var _dragging: bool = false
var _drag_dir: float = 1.0
var _cursor_grid: Vector2 = Vector2(-1, -1)


func _ready() -> void:
	custom_minimum_size = Vector2(280, 280)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func set_patch(node: Node) -> void:
	_patch = node
	_refresh_texture()


func _refresh_texture() -> void:
	if _patch == null or not is_instance_valid(_patch):
		_tex = null
		queue_redraw()
		return
	var gs: int = int(_patch.grid_size) + 1
	if _img == null or _img.get_width() != gs or _img.get_height() != gs:
		_img = Image.create(gs, gs, false, Image.FORMAT_RGB8)
	var heights: PackedFloat32Array = _patch.get_heights()
	if heights.size() != gs * gs:
		return
	for z in gs:
		for x in gs:
			var h: float = heights[z * gs + x]
			var v: float = clamp((h + VIS_RANGE) / (VIS_RANGE * 2.0), 0.0, 1.0)
			# Tint up the bright end greenish, dark end brownish so the
			# user can tell hills from valleys at a glance.
			var col := Color(0.30 + 0.55 * v, 0.20 + 0.65 * v, 0.18 + 0.50 * v, 1.0)
			_img.set_pixel(x, z, col)
	_tex = ImageTexture.create_from_image(_img)
	queue_redraw()


func _draw() -> void:
	if _tex == null:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.15, 0.15, 0.18, 1))
		var l := "Select a Terrain Patch"
		draw_string(get_theme_default_font(), Vector2(12, size.y * 0.5), l,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.6, 0.6, 1))
		return
	# Pixel-perfect-ish: scale the texture to fill, no filtering for
	# clarity at small canvas sizes.
	draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)
	# Brush ring at the cursor.
	if _cursor_grid.x >= 0:
		var px_per_cell: Vector2 = size / float(int(_patch.grid_size))
		var c := _cursor_grid * px_per_cell
		var r: float = _brush_radius * max(px_per_cell.x, px_per_cell.y)
		draw_arc(c, r, 0.0, TAU, 24, Color(1, 1, 1, 0.9), 1.5, true)
		draw_arc(c, r, 0.0, TAU, 24, Color(0, 0, 0, 0.8), 0.7, true)


func _gui_input(event: InputEvent) -> void:
	if _patch == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed
				_drag_dir = 1.0
				if mb.pressed:
					_paint_at(mb.position)
				accept_event()
			MOUSE_BUTTON_RIGHT:
				_dragging = mb.pressed
				_drag_dir = -1.0
				if mb.pressed:
					_paint_at(mb.position)
				accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				_brush_radius = clamp(_brush_radius + 1, 1, 32)
				queue_redraw()
				accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				_brush_radius = clamp(_brush_radius - 1, 1, 32)
				queue_redraw()
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_cursor_grid = _canvas_to_grid(mm.position)
		queue_redraw()
		if _dragging:
			_paint_at(mm.position)
		accept_event()


func _canvas_to_grid(pos: Vector2) -> Vector2:
	var gs: int = int(_patch.grid_size)
	var u: float = clamp(pos.x / size.x, 0.0, 1.0)
	var v: float = clamp(pos.y / size.y, 0.0, 1.0)
	return Vector2(u * gs, v * gs)


func _paint_at(pos: Vector2) -> void:
	if _patch == null or not is_instance_valid(_patch):
		return
	var gs: int = int(_patch.grid_size) + 1
	var g: Vector2 = _canvas_to_grid(pos)
	var heights: PackedFloat32Array = _patch.get_heights()
	if heights.size() != gs * gs:
		return
	var changed := false
	var xmin: int = max(0, int(floor(g.x - _brush_radius)))
	var xmax: int = min(gs - 1, int(ceil(g.x + _brush_radius)))
	var zmin: int = max(0, int(floor(g.y - _brush_radius)))
	var zmax: int = min(gs - 1, int(ceil(g.y + _brush_radius)))
	var r: float = max(_brush_radius, 0.001)
	for z in range(zmin, zmax + 1):
		for x in range(xmin, xmax + 1):
			var d: float = Vector2(x - g.x, z - g.y).length()
			if d > r:
				continue
			var fall: float = 1.0 - (d / r)
			fall = fall * fall * (3.0 - 2.0 * fall)
			heights[z * gs + x] += _drag_dir * _brush_strength * fall
			changed = true
	if changed:
		_patch.set_heights(heights)
		_refresh_texture()
		EditorMode.dirty = true
