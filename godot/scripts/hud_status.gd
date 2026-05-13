extends Control

# Top-right environmental status row. Three pill labels (cold / wet /
# rain) that fade in and out as PlayerStatus + Weather state flips.
# Built procedurally — no external icon assets needed.

const COLD_COLOR := Color(0.55, 0.75, 1.0, 1.0)
const WET_COLOR  := Color(0.55, 0.85, 1.0, 1.0)
const RAIN_COLOR := Color(0.70, 0.80, 0.95, 1.0)
const SNOW_COLOR := Color(0.95, 0.95, 1.0, 1.0)

var _row: HBoxContainer
var _cold_pill: Label
var _wet_pill: Label
var _weather_pill: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -440
	offset_top = 32
	offset_right = -8
	offset_bottom = 60

	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_END
	_row.add_theme_constant_override("separation", 8)
	_row.anchor_right = 1.0
	_row.anchor_bottom = 1.0
	add_child(_row)

	_cold_pill = _make_pill("❄ COLD", COLD_COLOR)
	_wet_pill = _make_pill("💧 WET", WET_COLOR)
	_weather_pill = _make_pill("", RAIN_COLOR)
	_row.add_child(_weather_pill)
	_row.add_child(_wet_pill)
	_row.add_child(_cold_pill)

	if PlayerStatus:
		PlayerStatus.cold_changed.connect(_on_cold)
		PlayerStatus.wet_changed.connect(_on_wet)
	if Weather:
		Weather.weather_changed.connect(_on_weather)
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


# Apply current state in case signals haven't fired yet on first frame.
func _refresh() -> void:
	if PlayerStatus:
		_on_cold(PlayerStatus.is_cold())
		_on_wet(PlayerStatus.is_wet())
	if Weather:
		_on_weather(Weather.get_state_name())
