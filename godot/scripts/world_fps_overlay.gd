extends Label

# Tiny diagnostic overlay for the procedural world. Shows FPS, active
# chunk count, in-flight generation tasks, and pending queue depth.
# Polled four times a second so the label doesn't flicker.

const UPDATE_INTERVAL: float = 0.25

var _accum: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_size_override("font_size", 13)
	add_theme_color_override("font_color", Color(0.85, 1.0, 0.85, 1))
	add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	add_theme_constant_override("shadow_offset_x", 1)
	add_theme_constant_override("shadow_offset_y", 1)
	text = "—"


func _process(dt: float) -> void:
	_accum += dt
	if _accum < UPDATE_INTERVAL:
		return
	_accum = 0.0
	var fps: int = int(Engine.get_frames_per_second())
	var active: int = WorldStreamer.active_chunk_count()
	var inflight: int = WorldStreamer.inflight_count()
	var pending: int = WorldStreamer.pending_count()
	var apply_q: int = WorldStreamer.pending_apply_count()
	text = "%d FPS    chunks: %d    gen: %d in-flight, %d pending    apply-q: %d" % [
		fps, active, inflight, pending, apply_q]
