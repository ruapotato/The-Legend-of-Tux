extends CanvasLayer

# Modal craft panel. workbench.gd calls `open_for_station(station_id)`
# when the player presses E; we populate a list of buttons (one per
# recipe registered against that station) showing the cost and current
# craftability. Click a button → Recipes.craft() spends and grants.

const PANEL_W: int = 520
const PANEL_H: int = 420

var _station: String = ""
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _list: VBoxContainer = null
var _hint: Label = null


func _ready() -> void:
	layer = 90
	_build_layout()


func _build_layout() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.45)
	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	center.add_child(_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.96)
	sb.border_color = Color(0.55, 0.40, 0.25, 1)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	_panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_panel.add_child(v)

	var title := Label.new()
	title.text = "CRAFTING"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.95, 0.90, 0.70, 1))
	v.add_child(title)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.60, 1))
	_hint.text = "Esc to close"
	v.add_child(_hint)

	v.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_W - 32, PANEL_H - 100)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)


func open_for_station(station: String) -> void:
	_station = station
	_refresh()
	# Re-refresh when resources change so the buttons go green/grey
	# without the player needing to close + reopen the panel.
	if not GameState.resource_changed.is_connected(_on_resource_changed):
		GameState.resource_changed.connect(_on_resource_changed)


func _on_resource_changed(_id: String, _n: int) -> void:
	if visible:
		_refresh()


func _refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var recipes: Array = Recipes.recipes_for_station(_station)
	for entry in recipes:
		_list.add_child(_make_row(entry["id"], entry["data"]))


func _make_row(id: String, data: Dictionary) -> Control:
	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.16, 0.85)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	row.add_theme_stylebox_override("panel", sb)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	row.add_child(box)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = String(data.get("display", id))
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.add_theme_color_override("font_color", Color(0.95, 0.90, 0.70, 1))
	info.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = String(data.get("description", ""))
	desc_lbl.add_theme_font_size_override("font_size", 11)
	desc_lbl.add_theme_color_override("font_color", Color(0.70, 0.70, 0.68, 1))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc_lbl)

	var cost_lbl := Label.new()
	cost_lbl.text = _cost_string(data.get("cost", {}))
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55, 1))
	info.add_child(cost_lbl)

	var btn := Button.new()
	btn.text = "Craft"
	btn.custom_minimum_size = Vector2(96, 56)
	btn.disabled = not Recipes.can_craft(id)
	btn.pressed.connect(func(): _on_craft(id))
	box.add_child(btn)

	return row


func _cost_string(cost: Dictionary) -> String:
	if cost.is_empty():
		return "(free)"
	var parts: PackedStringArray = []
	for k in cost.keys():
		var have: int = GameState.resource_count(String(k))
		var need: int = int(cost[k])
		var ok: String = "✓" if have >= need else "✗"
		parts.append("%s %s %d/%d" % [ok, k, have, need])
	return "  ".join(parts)


func _on_craft(id: String) -> void:
	if Recipes.craft(id):
		_refresh()
