extends CanvasLayer

# World-disc pause menu. Esc toggles. Owns the mouse-capture state
# while open so the player can actually use the cursor; on close, the
# mouse re-captures so the orbit camera works again.
#
# Tabs:
#   Resume   — closes the menu.
#   Inventory — lists owned resources (with counts) + crafted key items.
#   Quit     — returns to main_menu.
#
# Lives as a CanvasLayer in world_disc.tscn at a high layer so it
# draws over the rest of the HUD.

const RESOURCE_DISPLAY: Dictionary = {
	"wood":        "Wood",
	"stone":       "Stone",
	"raspberry":   "Raspberry",
	"mushroom":    "Mushroom",
	"meat_raw":    "Raw Meat",
	"cooked_meat": "Cooked Meat",
	"antler":      "Antler",
	"flint":       "Flint",
	"arrow":       "Arrow",
}

const KEY_ITEMS: Array = [
	["sapling_blade", "Sapling Blade"],
	["bark_round",    "Bark Round"],
	["hammer",        "Builder's Hammer"],
	["stone_axe",     "Stone Axe"],
]

var _root: Control = null
var _open: bool = false
var _res_list: VBoxContainer = null
var _item_list: VBoxContainer = null


func _ready() -> void:
	layer = 95
	_build_layout()
	_close()
	set_process_input(true)


func _build_layout() -> void:
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	_root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 480)
	center.add_child(panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.97)
	sb.border_color = Color(0.55, 0.40, 0.25, 1)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.95, 0.90, 0.70, 1))
	v.add_child(title)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	v.add_child(btn_row)

	var resume_btn := Button.new()
	resume_btn.text = "Resume  (Esc)"
	resume_btn.custom_minimum_size = Vector2(180, 36)
	resume_btn.pressed.connect(_close)
	btn_row.add_child(resume_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit to Main Menu"
	quit_btn.custom_minimum_size = Vector2(180, 36)
	quit_btn.pressed.connect(_on_quit)
	btn_row.add_child(quit_btn)

	v.add_child(HSeparator.new())

	# Two columns: Resources (counts) + Crafted Items (booleans).
	var two_col := HBoxContainer.new()
	two_col.add_theme_constant_override("separation", 24)
	v.add_child(two_col)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	two_col.add_child(left)
	var left_hdr := Label.new()
	left_hdr.text = "RESOURCES"
	left_hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	left.add_child(left_hdr)
	_res_list = VBoxContainer.new()
	_res_list.add_theme_constant_override("separation", 2)
	left.add_child(_res_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	two_col.add_child(right)
	var right_hdr := Label.new()
	right_hdr.text = "ITEMS"
	right_hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	right.add_child(right_hdr)
	_item_list = VBoxContainer.new()
	_item_list.add_theme_constant_override("separation", 2)
	right.add_child(_item_list)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _open:
			_close()
		else:
			_open_menu()


func _open_menu() -> void:
	_open = true
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_inventory()
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS


func _close() -> void:
	_open = false
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false


func _refresh_inventory() -> void:
	for c in _res_list.get_children():
		c.queue_free()
	for c in _item_list.get_children():
		c.queue_free()

	# Resources — alphabetical by display.
	var keys: Array = GameState.resources.keys()
	keys.sort()
	if keys.is_empty():
		var empty := Label.new()
		empty.text = "(none yet — punch trees for wood)"
		empty.add_theme_color_override("font_color", Color(0.55, 0.55, 0.50, 1))
		_res_list.add_child(empty)
	else:
		for k in keys:
			var name: String = String(RESOURCE_DISPLAY.get(k, k))
			var count: int = int(GameState.resources[k])
			var l := Label.new()
			l.text = "  %s × %d" % [name, count]
			l.add_theme_font_size_override("font_size", 14)
			_res_list.add_child(l)

	# Items — fixed roster so the player can see what's craftable.
	for pair in KEY_ITEMS:
		var id: String = String(pair[0])
		var display: String = String(pair[1])
		var owned: bool = bool(GameState.inventory.get(id, false))
		var l := Label.new()
		l.text = "  %s %s" % ["✓" if owned else "·", display]
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color",
				Color(0.85, 0.95, 0.70, 1) if owned else Color(0.55, 0.55, 0.50, 1))
		_item_list.add_child(l)


func _on_quit() -> void:
	_close()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
