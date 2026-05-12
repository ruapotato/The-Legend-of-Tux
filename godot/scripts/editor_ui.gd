extends CanvasLayer

# Top-level editor UI overlay. CanvasLayer at layer 70 (above HUD's 50,
# below pause's 80). Owns nearly every interaction surface in edit mode.
#
# UX model — Godot-editor-style:
#   - Mouse cursor is FREE by default; UI widgets are clickable.
#   - Hold RMB → camera fly mode (cursor hidden, WASD/QE/Shift/Ctrl).
#     editor_camera.gd handles this directly; we don't intercept RMB.
#   - A crosshair at viewport center IS the world-targeting reticle.
#     All world-space picking / placement / brushing raycasts from camera
#     origin along -Z, regardless of mouse position.
#   - LMB click is contextual: select / place / wall corner / etc.
#     depending on what's active. Mouse position drives only UI hits.
#
# Subsystems composed in here:
#   - EditorPalette (bottom)        — placeable catalog, 1-9 keys
#   - EditorInspector (right)       — per-node property editor
#   - EditorMinimap (top-right)     — 2D world overview
#   - EditorUndo (this script)      — Ctrl+Z / Ctrl+Y stack
#   - EditorClipboard               — Ctrl+C / Ctrl+V
#   - EditorSculpt / EditorPaint    — terrain brushes (B / P)
#   - EditorWallTool                — point-to-point wall placement (W)

const EditorPlacementCls = preload("res://scripts/editor_placement.gd")
const EditorPaletteCls   = preload("res://scripts/editor_palette.gd")
const EditorInspectorCls = preload("res://scripts/editor_inspector.gd")
const EditorMinimapCls   = preload("res://scripts/editor_minimap.gd")
const EditorUndoCls      = preload("res://scripts/editor_undo.gd")
const EditorClipboardCls = preload("res://scripts/editor_clipboard.gd")
const EditorSculptCls    = preload("res://scripts/editor_sculpt.gd")
const EditorPaintCls     = preload("res://scripts/editor_paint.gd")
const EditorWallToolCls  = preload("res://scripts/editor_wall_tool.gd")
const EditorMaterialsCls = preload("res://scripts/editor_materials.gd")
const LevelTemplateCls   = preload("res://scripts/level_template.gd")

# Layout dimensions (constants so we can tweak in one place).
const TOPBAR_H: int = 32
const TOOLBAR_W: int = 48
const INSPECTOR_W: int = 300
const PALETTE_H: int = 88
const MINIMAP_SIZE: int = 240
const RETICLE_PX: int = 10

# ---- UI nodes
var _root: Control = null                # full-screen container, NEVER blocks
var _status: Label = null
var _palette: Control = null
var _palette_ctrl = null
var _inspector: PanelContainer = null
var _inspector_ctrl = null
var _minimap: PanelContainer = null
var _minimap_ctrl = null
var _hint_panel: PanelContainer = null
var _hint_bar: Label = null
var _hint_collapsed: bool = false
var _hint_toggle: Button = null
var _toolbar: PanelContainer = null
var _topbar: PanelContainer = null
var _snap_check: CheckBox = null
var _snap_step: SpinBox = null
var _bookmark_row: HBoxContainer = null
var _bookmark_buttons: Array = []
var _brush_panel: PanelContainer = null
var _brush_label: Label = null
var _paint_palette_row: HBoxContainer = null
var _wall_panel: PanelContainer = null
var _wall_height_spin: SpinBox = null
var _wall_thick_spin: SpinBox = null
var _wall_mat_option: OptionButton = null
var _wall_chain_check: CheckBox = null
var _reticle: Control = null

var _file_dialog: FileDialog = null
var _new_level_dialog: AcceptDialog = null
var _new_level_input: LineEdit = null
var _new_level_pending_lz: Node = null

# ---- Selection / tool state
enum Tool { NONE, GRAB, ROTATE, SCALE, WALL, SCULPT, PAINT }
var _selected: Array = []          # Array of Node3D — multi-select
var _outlines: Array = []          # parallel outline marker per selection
var _tool: int = Tool.NONE

# Modal transform drag (G/R/S with selection). Click starts; mouse motion
# drives transform until next click commits or Esc cancels.
var _transforming: bool = false
var _transform_start: Vector2 = Vector2.ZERO
var _transform_start_poses: Array = []

# Snap + grid
var _grid_snap: bool = false
var _grid_step: float = 1.0

# Catalog + palette index
var _catalog: Array = []
var _selected_palette: int = -1

# Subsystem singletons
var _undo: EditorUndoCls = null
var _clipboard: EditorClipboardCls = null
var _sculpt: EditorSculptCls = null
var _paint: EditorPaintCls = null
var _wall: EditorWallToolCls = null

# Camera bookmarks 1..9
var _bookmarks: Array = []

# Wireframe + bounding-box toggles
var _wireframe_on: bool = false
var _bbox_on: bool = false
var _bbox_overlays: Array = []

# Brush cursor (terrain disc).
var _brush_cursor: MeshInstance3D = null
# Wall first-corner anchor marker (visible red dot in the world).
var _wall_anchor_marker: MeshInstance3D = null
# Whether the user is currently holding LMB during a brush stroke.
var _brush_lmb_held: bool = false


func _ready() -> void:
	layer = 70
	visible = false
	_undo = EditorUndoCls.new()
	_clipboard = EditorClipboardCls.new()
	_sculpt = EditorSculptCls.new()
	_paint = EditorPaintCls.new()
	_wall = EditorWallToolCls.new()
	_bookmarks.resize(10)
	for i in 10:
		_bookmarks[i] = {}
	_build_layout()
	_catalog = EditorPlacementCls.build_catalog()
	_palette_ctrl.set_catalog(_catalog)
	EditorMode.mode_changed.connect(_on_mode_changed)
	EditorMode.dirty_changed.connect(_on_dirty_changed)
	visible = EditorMode.is_edit
	_refresh_status()
	set_process(true)


func _process(_delta: float) -> void:
	if not EditorMode.is_edit:
		return
	_update_brush_cursor()
	_update_wall_preview()
	_update_transform_drag()
	_tick_active_brush(_delta)
	_tick_brush_lmb()
	queue_redraw_reticle()


func _on_mode_changed(is_edit: bool) -> void:
	visible = is_edit
	if not is_edit:
		_clear_selection()
		_tool = Tool.NONE
		_sculpt.exit()
		_paint.exit()
		_wall.exit()
		_undo.clear()
		_clear_bbox_overlays()
		_clear_wall_anchor_marker()
		if _wireframe_on:
			_apply_wireframe_state_off()
	else:
		_undo.clear()
		_apply_wireframe_state()
	_refresh_status()
	if _reticle:
		_reticle.visible = is_edit


func _on_dirty_changed(_is_dirty: bool) -> void:
	_refresh_status()


# ---- Layout ----------------------------------------------------------

func _build_layout() -> void:
	# Root: a full-screen Control that NEVER eats mouse events. Each panel
	# we add is parented here. Default MOUSE_FILTER_PASS on containers,
	# STOP only on actual buttons/spin boxes.
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_topbar()
	_build_toolbar()
	_build_palette()
	_build_inspector()
	_build_minimap()
	_build_brush_panel()
	_build_wall_panel()
	_build_hint_panel()
	_build_reticle()


func _build_topbar() -> void:
	# Top strip — height TOPBAR_H. The PanelContainer's mouse_filter is
	# PASS so empty space doesn't eat clicks; its child widgets STOP.
	_topbar = PanelContainer.new()
	_topbar.anchor_left = 0.0
	_topbar.anchor_right = 1.0
	_topbar.anchor_top = 0.0
	_topbar.offset_left = 0
	_topbar.offset_right = 0
	_topbar.offset_top = 0
	_topbar.offset_bottom = TOPBAR_H
	_topbar.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_topbar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	_topbar.add_child(row)

	_status = Label.new()
	_status.text = "EDIT"
	_status.add_theme_font_size_override("font_size", 12)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_status)

	_snap_check = CheckBox.new()
	_snap_check.text = "Snap"
	_snap_check.button_pressed = _grid_snap
	_snap_check.toggled.connect(func(p): _grid_snap = p)
	row.add_child(_snap_check)

	_snap_step = SpinBox.new()
	_snap_step.min_value = 0.1
	_snap_step.max_value = 16.0
	_snap_step.step = 0.1
	_snap_step.value = _grid_step
	_snap_step.value_changed.connect(func(v): _grid_step = v)
	row.add_child(_snap_step)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_save_level)
	row.add_child(save_btn)

	var open_btn := Button.new()
	open_btn.text = "Open"
	open_btn.pressed.connect(_open_load_dialog)
	row.add_child(open_btn)

	_bookmark_row = HBoxContainer.new()
	_bookmark_row.add_theme_constant_override("separation", 2)
	_bookmark_row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_bookmark_row)
	for i in range(1, 10):
		var b := Button.new()
		b.text = str(i)
		b.tooltip_text = "Click: jump to bookmark %d  Shift+%d to save" % [i, i]
		b.custom_minimum_size = Vector2(22, 22)
		b.pressed.connect(_on_bookmark_click.bind(i))
		_bookmark_row.add_child(b)
		_bookmark_buttons.append(b)


func _build_toolbar() -> void:
	# Vertical strip on the left. PASS on the container so the viewport
	# beneath gets clicks if the cursor is outside any actual button.
	_toolbar = PanelContainer.new()
	_toolbar.anchor_top = 0.0
	_toolbar.anchor_bottom = 1.0
	_toolbar.offset_top = TOPBAR_H
	_toolbar.offset_bottom = -PALETTE_H
	_toolbar.offset_left = 0
	_toolbar.offset_right = TOOLBAR_W
	_toolbar.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_toolbar)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	_toolbar.add_child(v)
	_make_tool_btn(v, "Sel", Tool.NONE,   "Select / pan (no tool)")
	_make_tool_btn(v, "G",   Tool.GRAB,   "Grab (G) — move selection to reticle")
	_make_tool_btn(v, "R",   Tool.ROTATE, "Rotate (R)")
	_make_tool_btn(v, "S",   Tool.SCALE,  "Scale (S)")
	_make_tool_btn(v, "W",   Tool.WALL,   "Wall tool (W) — click two reticle points")
	_make_tool_btn(v, "B",   Tool.SCULPT, "Sculpt (B) — terrain")
	_make_tool_btn(v, "P",   Tool.PAINT,  "Paint (P) — terrain")


func _make_tool_btn(parent: VBoxContainer, label: String, tool_id: int, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(TOOLBAR_W - 4, 36)
	b.pressed.connect(_on_tool_btn.bind(tool_id))
	parent.add_child(b)
	return b


func _build_palette() -> void:
	# Bottom strip — height PALETTE_H. Lives between toolbar and inspector.
	_palette = Control.new()
	_palette.anchor_left = 0.0
	_palette.anchor_right = 1.0
	_palette.anchor_bottom = 1.0
	_palette.offset_top = -PALETTE_H
	_palette.offset_bottom = 0
	_palette.offset_left = TOOLBAR_W
	_palette.offset_right = -INSPECTOR_W
	_palette.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_palette)
	_palette_ctrl = EditorPaletteCls.new()
	_palette_ctrl.anchor_right = 1.0
	_palette_ctrl.anchor_bottom = 1.0
	_palette_ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_ctrl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette.add_child(_palette_ctrl)
	_palette_ctrl.entry_selected.connect(_on_palette_entry_selected)


func _build_inspector() -> void:
	# Right strip — width INSPECTOR_W. Sits below minimap.
	_inspector = PanelContainer.new()
	_inspector.anchor_top = 0.0
	_inspector.anchor_bottom = 1.0
	_inspector.anchor_left = 1.0
	_inspector.anchor_right = 1.0
	_inspector.offset_left = -INSPECTOR_W
	_inspector.offset_right = 0
	_inspector.offset_top = TOPBAR_H + MINIMAP_SIZE + 4
	_inspector.offset_bottom = -PALETTE_H
	_inspector.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_inspector)
	_inspector_ctrl = EditorInspectorCls.new()
	_inspector_ctrl.anchor_right = 1.0
	_inspector_ctrl.anchor_bottom = 1.0
	_inspector_ctrl.set_owner_ui(self)
	_inspector.add_child(_inspector_ctrl)


func _build_minimap() -> void:
	# Top of the right column, above the inspector.
	_minimap = PanelContainer.new()
	_minimap.anchor_left = 1.0
	_minimap.anchor_right = 1.0
	_minimap.offset_left = -INSPECTOR_W
	_minimap.offset_right = 0
	_minimap.offset_top = TOPBAR_H
	_minimap.offset_bottom = TOPBAR_H + MINIMAP_SIZE
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_minimap)
	_minimap_ctrl = EditorMinimapCls.new()
	_minimap_ctrl.anchor_right = 1.0
	_minimap_ctrl.anchor_bottom = 1.0
	_minimap_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.add_child(_minimap_ctrl)


func _build_brush_panel() -> void:
	# Centered below the top bar, only visible during sculpt/paint.
	_brush_panel = PanelContainer.new()
	_brush_panel.anchor_left = 0.5
	_brush_panel.anchor_right = 0.5
	_brush_panel.anchor_top = 0.0
	_brush_panel.offset_left = -260
	_brush_panel.offset_right = 260
	_brush_panel.offset_top = TOPBAR_H + 4
	_brush_panel.offset_bottom = TOPBAR_H + 90
	_brush_panel.visible = false
	_brush_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_brush_panel)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	_brush_panel.add_child(v)
	_brush_label = Label.new()
	_brush_label.text = "Brush"
	_brush_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_brush_label)
	_paint_palette_row = HBoxContainer.new()
	_paint_palette_row.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_paint_palette_row)
	for sid in range(7):
		var b := Button.new()
		b.text = EditorMaterialsCls.surface_name(sid)
		b.modulate = EditorMaterialsCls.surface_color(sid)
		b.tooltip_text = "Paint as %s (key %d)" % [b.text, sid + 1]
		b.pressed.connect(_on_paint_color_pick.bind(sid))
		_paint_palette_row.add_child(b)


func _build_wall_panel() -> void:
	# Centered below the top bar, visible during wall tool.
	_wall_panel = PanelContainer.new()
	_wall_panel.anchor_left = 0.5
	_wall_panel.anchor_right = 0.5
	_wall_panel.anchor_top = 0.0
	_wall_panel.offset_left = -260
	_wall_panel.offset_right = 260
	_wall_panel.offset_top = TOPBAR_H + 4
	_wall_panel.offset_bottom = TOPBAR_H + 110
	_wall_panel.visible = false
	_wall_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_wall_panel)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	_wall_panel.add_child(v)
	var hdr := Label.new()
	hdr.text = "Wall — LMB places two reticle corners"
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(hdr)
	_wall_height_spin = SpinBox.new()
	_wall_height_spin.min_value = 1.0
	_wall_height_spin.max_value = 10.0
	_wall_height_spin.step = 0.25
	_wall_height_spin.value = _wall.wall_height
	_wall_height_spin.value_changed.connect(func(val): _wall.wall_height = val)
	v.add_child(_labelled("Height", _wall_height_spin))
	_wall_thick_spin = SpinBox.new()
	_wall_thick_spin.min_value = 0.1
	_wall_thick_spin.max_value = 2.0
	_wall_thick_spin.step = 0.05
	_wall_thick_spin.value = _wall.wall_thickness
	_wall_thick_spin.value_changed.connect(func(val): _wall.wall_thickness = val)
	v.add_child(_labelled("Thickness", _wall_thick_spin))
	_wall_mat_option = OptionButton.new()
	var wall_kinds: Array[String] = ["stone", "wood", "brick", "dirt", "metal"]
	for kind in wall_kinds:
		_wall_mat_option.add_item(kind.capitalize())
	_wall_mat_option.item_selected.connect(func(idx):
		var kinds: Array[String] = ["stone", "wood", "brick", "dirt", "metal"]
		_wall.material_kind = kinds[idx])
	v.add_child(_labelled("Material", _wall_mat_option))
	_wall_chain_check = CheckBox.new()
	_wall_chain_check.text = "Chain (C)"
	_wall_chain_check.tooltip_text = "When on, the last corner becomes the next wall's start."
	_wall_chain_check.button_pressed = _wall.chain_mode
	_wall_chain_check.toggled.connect(func(p): _wall.chain_mode = p)
	v.add_child(_wall_chain_check)


func _build_hint_panel() -> void:
	# Bottom-right, tucked above the palette and BELOW the minimap+inspector
	# column. Currently overlays the right strip at the very bottom only.
	# Collapsible.
	_hint_panel = PanelContainer.new()
	_hint_panel.anchor_left = 1.0
	_hint_panel.anchor_right = 1.0
	_hint_panel.anchor_bottom = 1.0
	_hint_panel.offset_left = -INSPECTOR_W
	_hint_panel.offset_right = 0
	_hint_panel.offset_top = -(PALETTE_H + 130)
	_hint_panel.offset_bottom = -PALETTE_H
	_hint_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_hint_panel)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	_hint_panel.add_child(col)
	var hdr := HBoxContainer.new()
	hdr.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(hdr)
	var title := Label.new()
	title.text = "Hotkeys"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hdr.add_child(title)
	_hint_toggle = Button.new()
	_hint_toggle.text = "—"
	_hint_toggle.tooltip_text = "Collapse / expand"
	_hint_toggle.custom_minimum_size = Vector2(24, 22)
	_hint_toggle.pressed.connect(_toggle_hint_collapsed)
	hdr.add_child(_hint_toggle)
	_hint_bar = Label.new()
	_hint_bar.text = _hotkey_text()
	_hint_bar.add_theme_font_size_override("font_size", 10)
	_hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_hint_bar)


func _hotkey_text() -> String:
	return ("RMB hold     fly camera\n"
			+ "WASD          move (in fly)\n"
			+ "Q E           up / down\n"
			+ "Shift / Ctrl  fast / slow\n"
			+ "F             focus on selection\n"
			+ "Wheel         fly speed (in fly)\n"
			+ "LMB           interact at reticle\n"
			+ "Esc           cancel tool / deselect\n"
			+ "G R S         grab / rotate / scale\n"
			+ "W             wall tool   C chain\n"
			+ "B / P         sculpt / paint\n"
			+ "Del           delete\n"
			+ "Ctrl+Z/Y      undo / redo\n"
			+ "Ctrl+C/V      copy / paste\n"
			+ "Ctrl+S/O      save / open\n"
			+ "Tab           swap to Play")


func _toggle_hint_collapsed() -> void:
	_hint_collapsed = not _hint_collapsed
	_hint_bar.visible = not _hint_collapsed
	if _hint_collapsed:
		_hint_panel.offset_top = -(PALETTE_H + 32)
		_hint_toggle.text = "+"
	else:
		_hint_panel.offset_top = -(PALETTE_H + 130)
		_hint_toggle.text = "—"


func _build_reticle() -> void:
	# Center-screen crosshair (+ shape) drawn over the viewport. We use
	# a custom Control with _draw() so it scales with the canvas stretch.
	_reticle = Control.new()
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.anchor_left = 0.5
	_reticle.anchor_right = 0.5
	_reticle.anchor_top = 0.5
	_reticle.anchor_bottom = 0.5
	_reticle.offset_left = -RETICLE_PX
	_reticle.offset_right = RETICLE_PX
	_reticle.offset_top = -RETICLE_PX
	_reticle.offset_bottom = RETICLE_PX
	_reticle.draw.connect(_draw_reticle)
	_root.add_child(_reticle)


func _draw_reticle() -> void:
	if _reticle == null:
		return
	var sz: Vector2 = _reticle.size
	var c: Vector2 = sz * 0.5
	var col := Color(1, 1, 1, 0.85)
	var col2 := Color(0, 0, 0, 0.6)
	# Outline (slightly thicker dark) for contrast over any backdrop.
	_reticle.draw_line(Vector2(c.x, 0), Vector2(c.x, sz.y), col2, 3.0)
	_reticle.draw_line(Vector2(0, c.y), Vector2(sz.x, c.y), col2, 3.0)
	# Foreground.
	_reticle.draw_line(Vector2(c.x, 2), Vector2(c.x, sz.y - 2), col, 1.0)
	_reticle.draw_line(Vector2(2, c.y), Vector2(sz.x - 2, c.y), col, 1.0)
	_reticle.draw_circle(c, 1.5, col)


func queue_redraw_reticle() -> void:
	# Hide the reticle when the cursor is over a UI panel — keeps the
	# crosshair from competing visually with widgets.
	if _reticle == null:
		return
	var mp: Vector2 = get_viewport().get_mouse_position()
	_reticle.visible = EditorMode.is_edit and not _mouse_on_ui(mp)
	# Tint by tool for quick visual feedback.
	pass


func _on_tool_btn(id: int) -> void:
	_set_tool(id)


func _labelled(text: String, child: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_PASS
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(80, 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(child)
	return h


func _refresh_status() -> void:
	if _status == null:
		return
	var sc := get_tree().current_scene
	var path: String = ""
	var sname: String = ""
	if sc:
		path = sc.scene_file_path
		sname = sc.name
	var badge := "EDIT" if EditorMode.is_edit else "PLAY"
	var dirty_marker := " *" if EditorMode.dirty else ""
	var tool_name: String = "—"
	match _tool:
		Tool.GRAB:   tool_name = "GRAB"
		Tool.ROTATE: tool_name = "ROT"
		Tool.SCALE:  tool_name = "SCL"
		Tool.WALL:   tool_name = "WALL"
		Tool.SCULPT: tool_name = "SCULPT"
		Tool.PAINT:  tool_name = "PAINT"
	var sel_count := _selected.size()
	var sel_str: String = ""
	if sel_count > 0:
		sel_str = " | sel=%d" % sel_count
	_status.text = "[%s%s] %s — %s  [%s]%s" % [badge, dirty_marker, sname, path, tool_name, sel_str]


# ---- Input dispatch --------------------------------------------------

func _input(event: InputEvent) -> void:
	if not EditorMode.is_edit:
		return
	if event is InputEventKey:
		_handle_key(event as InputEventKey)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		# Brush hover etc. handled in _process via center raycast — nothing
		# to do here unless we extend to mouse drag.
		pass


func _handle_key(ev: InputEventKey) -> void:
	if not ev.pressed or ev.echo:
		return

	# While flying (RMB held), WASD/QE belong to the camera. Don't let
	# them trigger tool hotkeys (W → wall tool, S → scale, etc.).
	var cam: Camera3D = _get_editor_camera()
	var flying: bool = cam and cam.has_method("is_flying") and cam.is_flying()
	if flying and ev.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E]:
		return

	if ev.ctrl_pressed:
		match ev.keycode:
			KEY_S:
				if ev.shift_pressed:
					_open_save_as_dialog()
				else:
					_save_level()
				get_viewport().set_input_as_handled()
				return
			KEY_O:
				_open_load_dialog()
				get_viewport().set_input_as_handled()
				return
			KEY_D:
				_duplicate_selected()
				get_viewport().set_input_as_handled()
				return
			KEY_C:
				_copy_selection()
				get_viewport().set_input_as_handled()
				return
			KEY_V:
				_paste_clipboard()
				get_viewport().set_input_as_handled()
				return
			KEY_Z:
				if ev.shift_pressed:
					_redo()
				else:
					_undo_action()
				get_viewport().set_input_as_handled()
				return
			KEY_Y:
				_redo()
				get_viewport().set_input_as_handled()
				return
			KEY_G:
				if ev.shift_pressed:
					_ungroup_selected()
				else:
					_group_selected()
				get_viewport().set_input_as_handled()
				return

	# Number keys 1-9: palette slot OR bookmark jump.
	if ev.keycode >= KEY_1 and ev.keycode <= KEY_9:
		var num: int = ev.keycode - KEY_0
		if ev.shift_pressed:
			_save_bookmark(num)
			get_viewport().set_input_as_handled()
			return
		if _tool == Tool.SCULPT:
			_sculpt.set_strength(0.1 * num)
			_refresh_brush_panel()
			get_viewport().set_input_as_handled()
			return
		if _tool == Tool.PAINT:
			_paint.set_surface(num - 1)
			_refresh_brush_panel()
			get_viewport().set_input_as_handled()
			return
		var visible_entries: Array = _palette_ctrl.get_visible_entries()
		if num - 1 < visible_entries.size():
			_palette_ctrl.select_index(_palette_ctrl.scroll_offset + num - 1)
			get_viewport().set_input_as_handled()
			return
		_jump_bookmark(num)
		get_viewport().set_input_as_handled()
		return

	match ev.keycode:
		KEY_ESCAPE:
			# Cancel cascade: pending wall corner > transform drag > tool > palette > selection.
			if _wall.have_anchor:
				_wall.have_anchor = false
				_clear_wall_anchor_marker()
			elif _transforming:
				_cancel_transform_drag()
			elif _selected_palette >= 0:
				_palette_ctrl.select_index(-1)
			elif _tool != Tool.NONE:
				_set_tool(Tool.NONE)
			else:
				_clear_selection()
			get_viewport().set_input_as_handled()
		KEY_F:
			_focus_on_selection()
			get_viewport().set_input_as_handled()
		KEY_G:
			if not _selected.is_empty():
				_set_tool(Tool.GRAB)
				get_viewport().set_input_as_handled()
		KEY_R:
			if not _selected.is_empty():
				_set_tool(Tool.ROTATE)
				get_viewport().set_input_as_handled()
		KEY_S:
			# Plain S — switch to Scale tool if a selection exists.
			if not _selected.is_empty():
				_set_tool(Tool.SCALE)
				get_viewport().set_input_as_handled()
		KEY_W:
			_set_tool(Tool.WALL)
			get_viewport().set_input_as_handled()
		KEY_C:
			# Toggle wall chain mode while wall tool is active.
			if _tool == Tool.WALL:
				_wall.chain_mode = not _wall.chain_mode
				if _wall_chain_check:
					_wall_chain_check.button_pressed = _wall.chain_mode
				get_viewport().set_input_as_handled()
		KEY_B:
			if _selected.size() == 1 and _selected[0].is_in_group("terrain_patch"):
				if _tool == Tool.SCULPT:
					_set_tool(Tool.NONE)
				else:
					_set_tool(Tool.SCULPT)
				get_viewport().set_input_as_handled()
		KEY_P:
			if _selected.size() == 1 and _selected[0].is_in_group("terrain_patch"):
				if _tool == Tool.PAINT:
					_set_tool(Tool.NONE)
				else:
					_set_tool(Tool.PAINT)
				get_viewport().set_input_as_handled()
		KEY_BRACKETLEFT:
			if _tool == Tool.SCULPT:
				_sculpt.set_radius_delta(-0.5); _refresh_brush_panel()
			elif _tool == Tool.PAINT:
				_paint.set_radius_delta(-0.5); _refresh_brush_panel()
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			if _tool == Tool.SCULPT:
				_sculpt.set_radius_delta(0.5); _refresh_brush_panel()
			elif _tool == Tool.PAINT:
				_paint.set_radius_delta(0.5); _refresh_brush_panel()
			get_viewport().set_input_as_handled()
		KEY_T:
			_apply_top_view()
			get_viewport().set_input_as_handled()
		KEY_PERIOD:
			_grid_snap = not _grid_snap
			_snap_check.button_pressed = _grid_snap
			get_viewport().set_input_as_handled()
		KEY_Z:
			_toggle_wireframe()
			get_viewport().set_input_as_handled()
		KEY_V:
			_toggle_bbox()
			get_viewport().set_input_as_handled()
		KEY_DELETE, KEY_BACKSPACE:
			_delete_selected()
			get_viewport().set_input_as_handled()


func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	# Mouse wheel routes to palette only when the cursor is over the palette.
	if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		if _mouse_on_panel(_palette, mb.position):
			_palette_ctrl.scroll(-1)
			get_viewport().set_input_as_handled()
		return
	if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if _mouse_on_panel(_palette, mb.position):
			_palette_ctrl.scroll(1)
			get_viewport().set_input_as_handled()
		return

	# RMB: when wall tool has a pending first corner, RMB cancels it and
	# we consume the event so the camera doesn't also enter fly. Without
	# a pending corner, we let RMB fall through to the camera for fly mode.
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if _tool == Tool.WALL and _wall.have_anchor and not _mouse_on_ui(mb.position):
			_wall.have_anchor = false
			_clear_wall_anchor_marker()
			get_viewport().set_input_as_handled()
		return

	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	# UI click: let it through to widgets; do nothing world-side.
	if _mouse_on_ui(mb.position):
		return

	if mb.pressed:
		_on_viewport_lmb_pressed()
		get_viewport().set_input_as_handled()
	else:
		_on_viewport_lmb_released()
		get_viewport().set_input_as_handled()


# ---- LMB state machine ------------------------------------------------

func _on_viewport_lmb_pressed() -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_center(cam)

	# Transform tools with selection: clicking commits to reticle hit.
	if _tool in [Tool.GRAB, Tool.ROTATE, Tool.SCALE] and not _selected.is_empty():
		if _transforming:
			_commit_transform_drag()
		else:
			_begin_transform_drag(hit)
		return

	# Wall tool: two-click placement.
	if _tool == Tool.WALL:
		var pos: Vector3 = hit["position"]
		if _grid_snap:
			pos = EditorPlacementCls.snap_to_grid(pos, _grid_step)
		var parent: Node = EditorMode.get_or_create_placed_container()
		var placed: Node3D = _wall.pick(pos, parent)
		_update_wall_anchor_marker()
		if placed:
			_push_place_action(placed)
			EditorMode.dirty = true
		return

	# Sculpt / paint stroke begins on press.
	if _tool == Tool.SCULPT and _selected.size() == 1 \
			and _selected[0].is_in_group("terrain_patch"):
		_sculpt.enter(_selected[0])
		var mode := EditorSculptCls.MODE_RAISE
		if Input.is_key_pressed(KEY_SHIFT):
			mode = EditorSculptCls.MODE_LOWER
		elif Input.is_key_pressed(KEY_CTRL):
			mode = EditorSculptCls.MODE_SMOOTH
		elif Input.is_key_pressed(KEY_ALT):
			mode = EditorSculptCls.MODE_FLATTEN
		_sculpt.begin_stroke(mode)
		_brush_lmb_held = true
		return
	if _tool == Tool.PAINT and _selected.size() == 1 \
			and _selected[0].is_in_group("terrain_patch"):
		_paint.enter(_selected[0])
		_paint.begin_stroke()
		_brush_lmb_held = true
		return

	# Palette selected: drop one at reticle and stay armed for more.
	if _selected_palette >= 0:
		_place_at_reticle(hit)
		return

	# No tool, no palette: pick whatever's at the reticle.
	_pick_at_reticle(hit)


func _on_viewport_lmb_released() -> void:
	if _sculpt.painting:
		var action: Dictionary = _sculpt.end_stroke()
		if not action.is_empty() and _selected.size() == 1:
			action["target"] = _node_path_for(_selected[0])
			_undo.push(action)
			EditorMode.dirty = true
		_brush_lmb_held = false
		return
	if _paint.painting:
		var paction: Dictionary = _paint.end_stroke()
		if not paction.is_empty() and _selected.size() == 1:
			paction["target"] = _node_path_for(_selected[0])
			_undo.push(paction)
			EditorMode.dirty = true
		_brush_lmb_held = false
		return


# ---- Picking (center reticle) ----------------------------------------

func _pick_at_reticle(hit: Dictionary) -> void:
	if not hit.get("hit", false):
		_clear_selection()
		return
	var collider = hit.get("collider", null)
	if collider == null:
		_clear_selection()
		return
	var node: Node3D = _resolve_select_ancestor(collider)
	if node == null:
		_clear_selection()
		return
	var additive: bool = Input.is_key_pressed(KEY_CTRL)
	if additive:
		if _selected.has(node):
			_deselect_one(node)
		else:
			_add_to_selection(node)
	else:
		_select_single(node)


func _resolve_select_ancestor(collider: Node) -> Node3D:
	# Walk up to the top-level child of the scene root or Placed container.
	# Stop short of EditorCamera / EditorUI nodes.
	var sc: Node = get_tree().current_scene
	var placed: Node = sc.get_node_or_null("Placed") if sc else null
	var cur: Node = collider
	var last: Node3D = collider as Node3D
	while cur and cur.get_parent():
		if cur.name == "EditorCamera" or cur.name == "EditorUI":
			return last
		if cur is Node3D:
			last = cur as Node3D
		var p := cur.get_parent()
		if p == sc or p == placed:
			return cur as Node3D
		cur = p
	return last


# ---- Placement -------------------------------------------------------

func _place_at_reticle(hit: Dictionary) -> void:
	if _selected_palette < 0 or _selected_palette >= _catalog.size():
		return
	var entry: Dictionary = _catalog[_selected_palette]
	if entry.get("kind", "") == "mesh_placeholder":
		return
	var pos: Vector3 = hit["position"]
	if _grid_snap:
		pos = EditorPlacementCls.snap_to_grid(pos, _grid_step)
	var parent: Node = EditorMode.get_or_create_placed_container()
	if parent == null:
		return
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, parent)
	if node == null:
		return
	node.global_position = pos
	if entry.get("kind", "") == "spawn" and "spawn_id" in node:
		node.spawn_id = "spawn_%d" % parent.get_child_count()
	EditorMode.dirty = true
	_push_place_action(node)
	# Don't auto-select — let the user keep dropping more. They can click
	# the empty toolbar slot or press Esc to clear.


func _push_place_action(node: Node3D) -> void:
	if node == null:
		return
	_undo.push({
		"type": "place",
		"target": _node_path_for(node),
	})


# ---- Transform drag (G/R/S, modal) ----------------------------------

func _begin_transform_drag(hit: Dictionary) -> void:
	if _selected.is_empty():
		return
	_transforming = true
	_transform_start = get_viewport().get_mouse_position()
	_transform_start_poses.clear()
	for n in _selected:
		var n3d: Node3D = n
		_transform_start_poses.append({
			"node": n3d,
			"pos": n3d.global_position,
			"rot": n3d.rotation,
			"scale": n3d.scale,
		})
	# Snap to reticle on Grab — first commit happens immediately on the
	# initial click so the object jumps to where you're aiming.
	if _tool == Tool.GRAB:
		var target: Vector3 = hit["position"]
		if _grid_snap:
			target = EditorPlacementCls.snap_to_grid(target, _grid_step)
		var centroid: Vector3 = Vector3.ZERO
		for entry in _transform_start_poses:
			centroid += entry["pos"]
		centroid /= float(_transform_start_poses.size())
		var delta: Vector3 = target - centroid
		for entry in _transform_start_poses:
			(entry["node"] as Node3D).global_position = entry["pos"] + delta


func _commit_transform_drag() -> void:
	if not _transforming:
		return
	_transforming = false
	# Build undo entry: multi-action of per-node transform snapshots.
	var subs: Array = []
	for entry in _transform_start_poses:
		var n: Node3D = entry["node"]
		if not is_instance_valid(n):
			continue
		var before: Dictionary = {
			"pos": entry["pos"],
			"rot": entry["rot"],
			"scale": entry["scale"],
		}
		var after: Dictionary = {
			"pos": n.global_position,
			"rot": n.rotation,
			"scale": n.scale,
		}
		subs.append({
			"type": "transform",
			"target": _node_path_for(n),
			"before": before,
			"after": after,
		})
	if not subs.is_empty():
		_undo.push({"type": "multi", "before": subs, "after": subs})
		EditorMode.dirty = true
	_transform_start_poses.clear()
	# Re-position outlines.
	for i in _selected.size():
		var o = _outlines[i] if i < _outlines.size() else null
		if o and is_instance_valid(o):
			(o as MeshInstance3D).global_transform = (_selected[i] as Node3D).global_transform


func _cancel_transform_drag() -> void:
	if not _transforming:
		return
	# Restore originals.
	for entry in _transform_start_poses:
		var n: Node3D = entry["node"]
		if is_instance_valid(n):
			n.global_position = entry["pos"]
			n.rotation = entry["rot"]
			n.scale = entry["scale"]
	_transforming = false
	_transform_start_poses.clear()


func _update_transform_drag() -> void:
	# Called every frame while a transform tool is mid-drag. For Grab we
	# follow the reticle. For Rotate / Scale we use mouse-X / mouse-Y
	# delta relative to drag start.
	if not _transforming or _selected.is_empty():
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var centroid: Vector3 = Vector3.ZERO
	for entry in _transform_start_poses:
		centroid += entry["pos"]
	centroid /= float(_transform_start_poses.size())

	match _tool:
		Tool.GRAB:
			var hit: Dictionary = EditorPlacementCls.raycast_from_center(cam)
			var target: Vector3 = hit["position"]
			if _grid_snap:
				target = EditorPlacementCls.snap_to_grid(target, _grid_step)
			var delta: Vector3 = target - centroid
			for entry in _transform_start_poses:
				(entry["node"] as Node3D).global_position = entry["pos"] + delta
		Tool.ROTATE:
			var mp: Vector2 = get_viewport().get_mouse_position()
			var dx: float = (mp.x - _transform_start.x) * 0.01
			var axis: Vector3 = Vector3.UP
			if Input.is_key_pressed(KEY_SHIFT):
				axis = Vector3.RIGHT
			elif Input.is_key_pressed(KEY_CTRL):
				axis = Vector3.FORWARD
			for entry in _transform_start_poses:
				var n: Node3D = entry["node"]
				if _selected.size() == 1:
					n.rotation = entry["rot"] + axis * dx
				else:
					var rel: Vector3 = entry["pos"] - centroid
					rel = rel.rotated(axis, dx)
					n.global_position = centroid + rel
					n.rotation = entry["rot"] + axis * dx
		Tool.SCALE:
			var mp2: Vector2 = get_viewport().get_mouse_position()
			var dy: float = (_transform_start.y - mp2.y) * 0.01
			var k: float = max(0.05, 1.0 + dy)
			for entry in _transform_start_poses:
				var n: Node3D = entry["node"]
				n.scale = entry["scale"] * k
	# Keep outlines glued.
	for i in _selected.size():
		var o = _outlines[i] if i < _outlines.size() else null
		if o and is_instance_valid(o):
			(o as MeshInstance3D).global_transform = (_selected[i] as Node3D).global_transform


func _focus_on_selection() -> void:
	if _selected.is_empty():
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	if cam.has_method("focus_on"):
		cam.focus_on(_selected[0])


# ---- Tool switching --------------------------------------------------

func _set_tool(t: int) -> void:
	if _tool == t:
		return
	# Tear down old tool.
	if _tool == Tool.SCULPT:
		_sculpt.exit()
	elif _tool == Tool.PAINT:
		_paint.exit()
	elif _tool == Tool.WALL:
		_wall.exit()
		_clear_wall_anchor_marker()
	if _transforming:
		_cancel_transform_drag()
	_tool = t
	# Bring up new tool.
	if t == Tool.SCULPT and _selected.size() == 1:
		_sculpt.enter(_selected[0])
	elif t == Tool.PAINT and _selected.size() == 1:
		_paint.enter(_selected[0])
	elif t == Tool.WALL:
		_wall.enter(get_tree().current_scene)
	_brush_panel.visible = (t == Tool.SCULPT or t == Tool.PAINT)
	_wall_panel.visible = (t == Tool.WALL)
	_refresh_brush_panel()
	_refresh_status()


func _refresh_brush_panel() -> void:
	if _brush_label == null:
		return
	if _tool == Tool.SCULPT:
		_brush_label.text = "Sculpt — r=%.1fm  str=%.2f  [Shift=lower Ctrl=smooth Alt=flatten]" \
				% [_sculpt.radius, _sculpt.strength]
		_paint_palette_row.visible = false
	elif _tool == Tool.PAINT:
		_brush_label.text = "Paint — r=%.1fm  surface=%s" \
				% [_paint.radius, EditorMaterialsCls.surface_name(_paint.surf_id)]
		_paint_palette_row.visible = true
	else:
		_brush_label.text = ""


# ---- Selection management -------------------------------------------

func _select_single(node: Node3D) -> void:
	_clear_selection()
	_add_to_selection(node)


func _add_to_selection(node: Node3D) -> void:
	if node == null or _selected.has(node):
		return
	_selected.append(node)
	var o := _build_outline(node)
	_outlines.append(o)
	_inspector_ctrl.set_target_multi(_selected)
	_refresh_status()


func _deselect_one(node: Node3D) -> void:
	var i: int = _selected.find(node)
	if i < 0:
		return
	_selected.remove_at(i)
	if i < _outlines.size():
		var o = _outlines[i]
		if o and is_instance_valid(o):
			o.queue_free()
		_outlines.remove_at(i)
	_inspector_ctrl.set_target_multi(_selected)
	_refresh_status()


func _clear_selection() -> void:
	for o in _outlines:
		if o and is_instance_valid(o):
			o.queue_free()
	_outlines.clear()
	_selected.clear()
	if _inspector_ctrl:
		_inspector_ctrl.set_target(null)
	_refresh_status()


func get_selected() -> Node3D:
	# Back-compat for minimap.
	if _selected.is_empty():
		return null
	return _selected[0]


func get_selection_list() -> Array:
	return _selected


func _build_outline(node: Node3D) -> Node3D:
	# Build a yellow no-depth overlay for *all* MeshInstance3D descendants
	# of `node`. We use top-level ghost meshes that mirror each mesh's
	# transform so rigs with multiple parts (Tux, complex enemies) show
	# fully outlined. The parent returned holds the ghosts so we can
	# free them with one queue_free call.
	var container := Node3D.new()
	container.top_level = true
	# Find any MeshInstance3D descendants.
	var meshes: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			meshes.append(n)
	if meshes.is_empty():
		# Fallback: AABB-ish box at the node position so something is shown.
		var ghost := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.8, 0.8, 0.8)
		ghost.mesh = bm
		ghost.material_override = _outline_material()
		container.add_child(ghost)
		ghost.top_level = true
		ghost.global_transform = node.global_transform
		ghost.scale = ghost.scale * 1.05
	else:
		for mi in meshes:
			var g := MeshInstance3D.new()
			g.mesh = (mi as MeshInstance3D).mesh
			g.material_override = _outline_material()
			g.top_level = true
			container.add_child(g)
			var xform: Transform3D = (mi as MeshInstance3D).global_transform
			g.global_transform = xform
			g.scale = xform.basis.get_scale() * 1.04
	node.add_child(container)
	return container


func _outline_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.95, 0.2, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


# ---- Hotkey actions -------------------------------------------------

func _delete_selected() -> void:
	if _selected.is_empty():
		return
	var subs: Array = []
	for n in _selected:
		var packed: PackedScene = EditorUndoCls.pack_for_delete(n)
		var parent: Node = n.get_parent()
		subs.append({
			"type": "delete",
			"target": _node_path_for(n),
			"packed": packed,
			"transform": (n as Node3D).transform,
			"name": n.name,
			"parent_path": _node_path_for(parent) if parent else ".",
		})
	_undo.push({"type": "multi", "before": subs, "after": subs})
	for n in _selected:
		n.queue_free()
	_clear_selection()
	EditorMode.dirty = true


func _duplicate_selected() -> void:
	if _selected.is_empty():
		return
	var clones: Array = []
	for n in _selected:
		var n3d: Node3D = n
		var clone: Node = n3d.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
		var parent: Node = n3d.get_parent()
		if parent == null:
			continue
		parent.add_child(clone)
		if clone is Node3D:
			(clone as Node3D).global_position = n3d.global_position + Vector3(1, 0, 1)
		clones.append(clone)
	_clear_selection()
	for c in clones:
		_add_to_selection(c)
		_push_place_action(c)
	EditorMode.dirty = true


func _copy_selection() -> void:
	_clipboard.copy(_selected)


func _paste_clipboard() -> void:
	if _clipboard.is_empty():
		return
	# Paste at the current center-reticle hit.
	var cam: Camera3D = _get_editor_camera()
	var pos: Vector3 = Vector3.ZERO
	if cam:
		var hit: Dictionary = EditorPlacementCls.raycast_from_center(cam)
		pos = hit["position"]
	var parent: Node = EditorMode.get_or_create_placed_container()
	var pasted: Array = _clipboard.paste(parent, pos)
	_clear_selection()
	for n in pasted:
		if n is Node3D:
			_add_to_selection(n as Node3D)
			_push_place_action(n as Node3D)
	EditorMode.dirty = true


# ---- Group / ungroup ------------------------------------------------

func _group_selected() -> void:
	if _selected.size() < 2:
		return
	var parent: Node = EditorMode.get_or_create_placed_container()
	if parent == null:
		parent = get_tree().current_scene
	var group_root := Node3D.new()
	group_root.name = "Group"
	var c := Vector3.ZERO
	for n in _selected:
		c += (n as Node3D).global_position
	c /= float(_selected.size())
	parent.add_child(group_root)
	group_root.global_position = c
	for n in _selected.duplicate():
		var prev_xform: Transform3D = (n as Node3D).global_transform
		(n as Node3D).reparent(group_root)
		(n as Node3D).global_transform = prev_xform
	_clear_selection()
	_add_to_selection(group_root)
	EditorMode.dirty = true


func _ungroup_selected() -> void:
	if _selected.size() != 1:
		return
	var g: Node = _selected[0]
	if not (g is Node3D):
		return
	var parent: Node = g.get_parent()
	if parent == null:
		return
	var to_select: Array = []
	for c in g.get_children().duplicate():
		var cn: Node = c
		var prev_xform: Transform3D = (cn as Node3D).global_transform if cn is Node3D else Transform3D.IDENTITY
		cn.reparent(parent)
		if cn is Node3D:
			(cn as Node3D).global_transform = prev_xform
		to_select.append(cn)
	g.queue_free()
	_clear_selection()
	for c in to_select:
		if c is Node3D:
			_add_to_selection(c as Node3D)
	EditorMode.dirty = true


# ---- Undo / redo wiring ----------------------------------------------

func _undo_action() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	_undo.undo(sc)
	_clear_selection()
	EditorMode.dirty = true


func _redo() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	_undo.redo(sc)
	_clear_selection()
	EditorMode.dirty = true


# ---- Bookmarks -------------------------------------------------------

func _save_bookmark(slot: int) -> void:
	if slot < 1 or slot > 9:
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null or not cam.has_method("capture_bookmark"):
		return
	_bookmarks[slot] = cam.capture_bookmark()
	if slot - 1 < _bookmark_buttons.size():
		(_bookmark_buttons[slot - 1] as Button).modulate = Color(1.2, 1.2, 0.6, 1)


func _jump_bookmark(slot: int) -> void:
	if slot < 1 or slot > 9:
		return
	var b: Dictionary = _bookmarks[slot]
	if b.is_empty():
		return
	var cam: Camera3D = _get_editor_camera()
	if cam and cam.has_method("apply_bookmark"):
		cam.apply_bookmark(b)


func _on_bookmark_click(slot: int) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		_save_bookmark(slot)
	else:
		_jump_bookmark(slot)


# ---- Views -----------------------------------------------------------

func _apply_top_view() -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam and cam.has_method("view_top"):
		cam.view_top()


# ---- Wireframe / bbox ------------------------------------------------

func _toggle_wireframe() -> void:
	_wireframe_on = not _wireframe_on
	_apply_wireframe_state()


func _apply_wireframe_state() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	if _wireframe_on:
		vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	else:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _apply_wireframe_state_off() -> void:
	var vp := get_viewport()
	if vp:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _toggle_bbox() -> void:
	_bbox_on = not _bbox_on
	_clear_bbox_overlays()
	if not _bbox_on:
		return
	var sc := get_tree().current_scene
	if sc == null:
		return
	for n in _walk(sc):
		if not (n is CollisionShape3D):
			continue
		var cs: CollisionShape3D = n
		var ov := _shape_to_wireframe(cs)
		if ov:
			_bbox_overlays.append(ov)


func _clear_bbox_overlays() -> void:
	for o in _bbox_overlays:
		if o and is_instance_valid(o):
			o.queue_free()
	_bbox_overlays.clear()


func _shape_to_wireframe(cs: CollisionShape3D) -> MeshInstance3D:
	if cs.shape == null:
		return null
	var size: Vector3 = Vector3.ONE
	if cs.shape is BoxShape3D:
		size = (cs.shape as BoxShape3D).size
	elif cs.shape is SphereShape3D:
		var r: float = (cs.shape as SphereShape3D).radius
		size = Vector3(r * 2, r * 2, r * 2)
	elif cs.shape is CylinderShape3D:
		var c: CylinderShape3D = cs.shape
		size = Vector3(c.radius * 2, c.height, c.radius * 2)
	elif cs.shape is CapsuleShape3D:
		var cap: CapsuleShape3D = cs.shape
		size = Vector3(cap.radius * 2, cap.height, cap.radius * 2)
	var mi := MeshInstance3D.new()
	mi.top_level = true
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 0.2, 0.18)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	cs.add_child(mi)
	mi.global_transform = cs.global_transform
	return mi


# ---- Brush cursor preview (driven by reticle) ----------------------

func _update_brush_cursor() -> void:
	if _tool != Tool.SCULPT and _tool != Tool.PAINT:
		if _brush_cursor and is_instance_valid(_brush_cursor):
			_brush_cursor.visible = false
		return
	if _selected.size() != 1 or not _selected[0].is_in_group("terrain_patch"):
		if _brush_cursor and is_instance_valid(_brush_cursor):
			_brush_cursor.visible = false
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_center(cam)
	var pos: Vector3 = hit["position"]
	if _tool == Tool.SCULPT:
		_sculpt.cursor_world = pos
	else:
		_paint.cursor_world = pos
	if _brush_cursor == null or not is_instance_valid(_brush_cursor):
		_brush_cursor = MeshInstance3D.new()
		_brush_cursor.top_level = true
		var tm := TorusMesh.new()
		_brush_cursor.mesh = tm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0.9, 0.2, 0.55)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_brush_cursor.material_override = mat
		var sc := get_tree().current_scene
		if sc:
			sc.add_child(_brush_cursor)
	var r: float = _sculpt.radius if _tool == Tool.SCULPT else _paint.radius
	var tm: TorusMesh = _brush_cursor.mesh
	tm.outer_radius = r
	tm.inner_radius = max(0.05, r - 0.15)
	_brush_cursor.global_position = pos + Vector3(0, 0.05, 0)
	_brush_cursor.visible = true


func _update_wall_preview() -> void:
	if _tool != Tool.WALL:
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_center(cam)
	_wall.preview(hit["position"], get_tree().current_scene)
	_update_wall_anchor_marker()


func _update_wall_anchor_marker() -> void:
	# Red dot at the wall tool's first-corner anchor.
	if _tool != Tool.WALL or not _wall.have_anchor:
		_clear_wall_anchor_marker()
		return
	if _wall_anchor_marker == null or not is_instance_valid(_wall_anchor_marker):
		_wall_anchor_marker = MeshInstance3D.new()
		_wall_anchor_marker.top_level = true
		var sm := SphereMesh.new()
		sm.radius = 0.18
		sm.height = 0.36
		_wall_anchor_marker.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.20, 0.20, 1)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		_wall_anchor_marker.material_override = mat
		var sc := get_tree().current_scene
		if sc:
			sc.add_child(_wall_anchor_marker)
	_wall_anchor_marker.global_position = _wall.anchor + Vector3(0, 0.2, 0)
	_wall_anchor_marker.visible = true


func _clear_wall_anchor_marker() -> void:
	if _wall_anchor_marker and is_instance_valid(_wall_anchor_marker):
		_wall_anchor_marker.queue_free()
	_wall_anchor_marker = null


func _tick_active_brush(delta: float) -> void:
	if _sculpt.painting:
		_sculpt.tick(delta)
	if _paint.painting:
		_paint.tick()


func _tick_brush_lmb() -> void:
	# Mouse-button polling fallback in case some quirk loses the release
	# event during a stroke — if LMB is no longer down, end the stroke.
	if _brush_lmb_held and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_on_viewport_lmb_released()


func _on_paint_color_pick(sid: int) -> void:
	_paint.set_surface(sid)
	_refresh_brush_panel()


# ---- File dialogs ---------------------------------------------------

func _ensure_file_dialog() -> void:
	if _file_dialog and is_instance_valid(_file_dialog):
		return
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.filters = PackedStringArray(["*.tscn ; Scenes"])
	_file_dialog.size = Vector2i(720, 520)
	add_child(_file_dialog)


func _open_save_as_dialog() -> void:
	_ensure_file_dialog()
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.current_dir = "res://scenes"
	_file_dialog.title = "Save Level As"
	if _file_dialog.file_selected.is_connected(_on_save_as_selected):
		_file_dialog.file_selected.disconnect(_on_save_as_selected)
	if _file_dialog.file_selected.is_connected(_on_open_selected):
		_file_dialog.file_selected.disconnect(_on_open_selected)
	_file_dialog.file_selected.connect(_on_save_as_selected)
	_file_dialog.popup_centered()


func _open_load_dialog() -> void:
	_ensure_file_dialog()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.current_dir = "res://scenes"
	_file_dialog.title = "Open Level"
	if _file_dialog.file_selected.is_connected(_on_save_as_selected):
		_file_dialog.file_selected.disconnect(_on_save_as_selected)
	if _file_dialog.file_selected.is_connected(_on_open_selected):
		_file_dialog.file_selected.disconnect(_on_open_selected)
	_file_dialog.file_selected.connect(_on_open_selected)
	_file_dialog.popup_centered()


func _on_save_as_selected(path: String) -> void:
	EditorMode.save_level_as(path)
	_refresh_status()


func _on_open_selected(path: String) -> void:
	get_tree().change_scene_to_file(path)


func _save_level() -> void:
	EditorMode.save_level()
	_refresh_status()


# ---- Palette ---------------------------------------------------------

func _on_palette_entry_selected(index: int) -> void:
	_selected_palette = index
	if index >= 0:
		_clear_selection()
		_set_tool(Tool.NONE)


# ---- + NEW LEVEL flow (preserved from previous version) -------------

func prompt_new_level(load_zone: Node) -> void:
	_new_level_pending_lz = load_zone
	if _new_level_dialog and is_instance_valid(_new_level_dialog):
		_new_level_dialog.popup_centered()
		return
	_new_level_dialog = AcceptDialog.new()
	_new_level_dialog.title = "New Linked Level"
	_new_level_dialog.dialog_text = "Level id (alphanumeric + underscore):"
	_new_level_input = LineEdit.new()
	_new_level_input.placeholder_text = "forge_basement"
	_new_level_dialog.add_child(_new_level_input)
	_new_level_dialog.register_text_enter(_new_level_input)
	_new_level_dialog.confirmed.connect(_on_new_level_confirmed)
	add_child(_new_level_dialog)
	_new_level_dialog.popup_centered(Vector2(360, 140))


func _on_new_level_confirmed() -> void:
	if _new_level_input == null or _new_level_pending_lz == null:
		return
	var level_id: String = _new_level_input.text.strip_edges().to_lower()
	if not LevelTemplateCls.valid_level_id(level_id):
		push_warning("invalid level id: %s" % level_id)
		return
	var current_id: String = _current_level_id()
	var path: String = LevelTemplateCls.create_level(level_id, current_id)
	if path == "":
		push_warning("level template creation failed (already exists?)")
		return
	var lz: Node = _new_level_pending_lz
	if lz and is_instance_valid(lz):
		if "target_scene" in lz:
			lz.target_scene = path
		if "target_spawn" in lz:
			lz.target_spawn = "from_%s" % current_id
		EditorMode.dirty = true
		if _inspector_ctrl:
			_inspector_ctrl.set_target(lz)
	_new_level_pending_lz = null


func _current_level_id() -> String:
	var sc := get_tree().current_scene
	if sc == null:
		return "level"
	var p: String = sc.scene_file_path
	if p.begins_with("res://scenes/"):
		p = p.substr("res://scenes/".length())
	if p.ends_with(".tscn"):
		p = p.substr(0, p.length() - ".tscn".length())
	return p


# ---- helpers --------------------------------------------------------

func _get_editor_camera() -> Camera3D:
	var sc := get_tree().current_scene
	if sc == null:
		return null
	var n := sc.find_child("EditorCamera", true, false)
	return n as Camera3D


# Public — used by inspector's Delete button.
func delete_selected_external() -> void:
	_delete_selected()


# Snap-to-floor: raycast from selected node down to ground.
func snap_selected_to_floor() -> void:
	if _selected.is_empty():
		return
	for n in _selected:
		var n3d: Node3D = n
		var world := n3d.get_world_3d()
		if world == null:
			continue
		var space := world.direct_space_state
		var from: Vector3 = n3d.global_position + Vector3(0, 1.5, 0)
		var to: Vector3 = from + Vector3.DOWN * 200.0
		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.collision_mask = 1
		var exclude: Array = []
		for c in n3d.get_children():
			if c is CollisionObject3D:
				exclude.append((c as CollisionObject3D).get_rid())
		if n3d is CollisionObject3D:
			exclude.append((n3d as CollisionObject3D).get_rid())
		params.exclude = exclude
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			continue
		n3d.global_position = Vector3(n3d.global_position.x,
				float(hit["position"].y) + 0.05,
				n3d.global_position.z)
	EditorMode.dirty = true


func _mouse_on_ui(pos: Vector2) -> bool:
	# Any visible interactive panel. Toolbar / topbar / inspector /
	# minimap / palette / brush / wall / hint. (Minimap is non-interactive
	# but we still treat it as UI for reticle-hide purposes — clicks pass
	# through it because its mouse_filter is IGNORE.)
	var panels := [_palette, _inspector, _minimap, _toolbar, _topbar,
			_brush_panel, _wall_panel, _hint_panel]
	for p in panels:
		if p == null or not p.visible:
			continue
		if _mouse_on_panel(p, pos):
			return true
	return false


func _mouse_on_panel(panel: Control, pos: Vector2) -> bool:
	if panel == null:
		return false
	var rect := Rect2(panel.global_position, panel.size)
	return rect.has_point(pos)


func _walk(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# NodePath relative to the scene root, for the undo stack.
func _node_path_for(n: Node) -> String:
	var sc := get_tree().current_scene
	if sc == null or n == null:
		return ""
	return String(sc.get_path_to(n))
