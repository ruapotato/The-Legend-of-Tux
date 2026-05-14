extends Control

# Top-right environmental status row. Three pill labels (cold / wet /
# rain) that fade in and out as PlayerStatus + Weather state flips.
# Built procedurally — no external icon assets needed.

const COLD_COLOR := Color(0.55, 0.75, 1.0, 1.0)
const WET_COLOR  := Color(0.55, 0.85, 1.0, 1.0)
const RAIN_COLOR := Color(0.70, 0.80, 0.95, 1.0)
const SNOW_COLOR := Color(0.95, 0.95, 1.0, 1.0)
const BUFF_COLOR := Color(0.85, 1.00, 0.65, 1.0)
const CLOCK_COLOR := Color(1.00, 0.92, 0.75, 1.0)

# Glyph + label per food-buff id. Matches BuffManager.BUFF_DEFS keys.
const BUFF_GLYPHS: Dictionary = {
	"fast":     "⚡ ENERGIZED",
	"regen":    "❤ HEALING",
	"satiated": "🍖 SATIATED",
}

var _row: HBoxContainer
var _cold_pill: Label
var _wet_pill: Label
var _weather_pill: Label
var _clock_pill: Label
var _buff_pills: Dictionary = {}    # id -> Label (one per known buff)
var _clock_accum: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	# Sit BELOW the legacy hud.tscn TopRight column (Pebbles / Item /
	# Arrow / Seed labels span y=12..80), so the pills don't overlap
	# the pebble counter when it ticks.
	offset_left = -440
	offset_top = 90
	offset_right = -8
	offset_bottom = 118

	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_END
	_row.add_theme_constant_override("separation", 8)
	_row.anchor_right = 1.0
	_row.anchor_bottom = 1.0
	add_child(_row)

	_clock_pill = _make_pill("🕗 00:00", CLOCK_COLOR)
	_clock_pill.visible = true   # always shown
	_row.add_child(_clock_pill)

	_cold_pill = _make_pill("❄ COLD", COLD_COLOR)
	_wet_pill = _make_pill("💧 WET", WET_COLOR)
	_weather_pill = _make_pill("", RAIN_COLOR)
	_row.add_child(_weather_pill)
	_row.add_child(_wet_pill)
	_row.add_child(_cold_pill)

	# Buff pills — one per known food buff, all hidden until applied.
	# The row sits left of the env pills so the env state is the visual
	# anchor a returning player expects.
	for id in BUFF_GLYPHS.keys():
		var pill: Label = _make_pill(String(BUFF_GLYPHS[id]), BUFF_COLOR)
		_buff_pills[id] = pill
		_row.add_child(pill)

	if PlayerStatus:
		PlayerStatus.cold_changed.connect(_on_cold)
		PlayerStatus.wet_changed.connect(_on_wet)
	if Weather:
		Weather.weather_changed.connect(_on_weather)
	if BuffManager:
		BuffManager.buff_applied.connect(_on_buff_applied)
		BuffManager.buff_expired.connect(_on_buff_expired)
	_refresh()


func _make_pill(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.visible = false
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func _on_cold(is_cold: bool) -> void:
	_cold_pill.visible = is_cold


func _on_wet(is_wet: bool) -> void:
	_wet_pill.visible = is_wet


func _on_weather(state: String) -> void:
	match state:
		"rain":
			_weather_pill.text = "☔ RAIN"
			_weather_pill.add_theme_color_override("font_color", RAIN_COLOR)
			_weather_pill.visible = true
		"storm":
			_weather_pill.text = "⛈ STORM"
			_weather_pill.add_theme_color_override("font_color", RAIN_COLOR)
			_weather_pill.visible = true
		"snow":
			_weather_pill.text = "❄ SNOW"
			_weather_pill.add_theme_color_override("font_color", SNOW_COLOR)
			_weather_pill.visible = true
		_:
			_weather_pill.visible = false


func _process(delta: float) -> void:
	# Tick the clock label at ~5 Hz — much cheaper than redrawing each
	# frame, and the player can't read sub-second changes anyway.
	_clock_accum += delta
	if _clock_accum < 0.2:
		return
	_clock_accum = 0.0
	if TimeOfDay == null or _clock_pill == null:
		return
	var minutes_of_day: int = int(TimeOfDay.t * 24.0 * 60.0)
	var hh: int = (minutes_of_day / 60) % 24
	var mm: int = minutes_of_day % 60
	_clock_pill.text = "🕗 %02d:%02d" % [hh, mm]


func _on_buff_applied(id: String, _duration: float) -> void:
	var pill: Label = _buff_pills.get(id)
	if pill:
		pill.visible = true


func _on_buff_expired(id: String) -> void:
	var pill: Label = _buff_pills.get(id)
	if pill:
		pill.visible = false


# Apply current state in case signals haven't fired yet on first frame.
func _refresh() -> void:
	if PlayerStatus:
		_on_cold(PlayerStatus.is_cold())
		_on_wet(PlayerStatus.is_wet())
	if Weather:
		_on_weather(Weather.get_state_name())
	if BuffManager:
		for id in _buff_pills.keys():
			_buff_pills[id].visible = BuffManager.has_buff(id)
