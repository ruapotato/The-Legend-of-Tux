extends Control

# Persistent on-screen control legend, top-right under the cold/wet/clock
# pills. Lists the keys for the moves you ALWAYS have (move, attack,
# shield, jump, etc.) plus a dynamic line for the currently-equipped
# B-item — when the hammer is active that line shows "F  Build Mode",
# when the bow is active it shows "F  Fire Bow", and so on. The hint
# rebinds itself via the GameState.active_item_changed signal so
# crafting auto-updates the cue.
#
# Intentionally minimal: no images, no animations, single column,
# small font. The point is the player can SEE the keys in their first
# session without alt-tabbing to a wiki.

const ALWAYS_ON: Array = [
	["WASD",   "Move"],
	["Space",  "Jump"],
	["Shift",  "Sprint"],
	["Ctrl",   "Roll"],
	["L Mouse", "Attack"],
	["R Mouse", "Shield"],
	["E",      "Interact"],
	["Esc",    "Pause / Inventory"],
	["M",      "Map"],
	["F5",     "Dev Console"],
]

# Per-item label for the F key — falls back to "Use Item" if the
# active id has no entry.
const ITEM_LABEL: Dictionary = {
	"":           "—",
	"hammer":     "Build Mode",
	"stone_axe":  "Swing Axe",
	"bow":        "Fire Bow",
	"slingshot":  "Fire Slingshot",
	"bomb":       "Throw Bomb",
	"hookshot":   "Hookshot",
	"glim_sight": "Glim Sight",
	"boomerang":  "Throw Boomerang",
}

var _rows: VBoxContainer = null
var _f_label: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	# Stack BELOW the pills row (y=90..118) so the WASD/Move list doesn't
	# overlap the cold/wet/clock pills or the legacy HUD's pebble counter.
	offset_left = -240
	offset_top = 130
	offset_right = -8
	offset_bottom = 380

	# Outer panel with a faint border so it reads as "info pane" without
	# fighting the rest of the HUD.
	var panel := PanelContainer.new()
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.55)
	sb.border_color = Color(0.55, 0.40, 0.25, 0.75)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	panel.add_child(_rows)

	var hdr := Label.new()
	hdr.text = "CONTROLS"
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	_rows.add_child(hdr)

	for entry in ALWAYS_ON:
		_rows.add_child(_make_row(String(entry[0]), String(entry[1])))

	_f_label = _make_row("F", _label_for_active(""))
	_rows.add_child(_f_label)

	if GameState and GameState.has_signal("active_item_changed"):
		GameState.active_item_changed.connect(_on_active_item_changed)
	if GameState:
		_on_active_item_changed(String(GameState.active_b_item))


func _make_row(key: String, action: String) -> Label:
	# Single line per binding; the key is column-left and the action
	# follows after two spaces. A single Label is cheaper than HBox+two
	# Labels, and the readability isn't worth the layout overhead at
	# 10 bindings.
	var l := Label.new()
	l.text = "  %-8s %s" % [key, action]
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.86, 0.90, 0.78, 1))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func _label_for_active(id: String) -> String:
	if ITEM_LABEL.has(id):
		return String(ITEM_LABEL[id])
	return "Use %s" % id.capitalize() if id != "" else "—"


func _on_active_item_changed(id: String) -> void:
	if _f_label == null:
		return
	_f_label.text = "  %-8s %s" % ["F", _label_for_active(String(id))]
