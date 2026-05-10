extends Control

# First-person aim crosshair. Mounted as a child of the HUD CanvasLayer
# (see hud.gd._ensure_aim_crosshair). Polls the player's `aim_mode`
# flag and paints a small four-tick + center-dot reticle in the screen
# centre while it's true. Fades in/out smoothly so toggling aim doesn't
# pop visually.
#
# Owner contract: this is added as a child of HUD. It finds the player
# via the `player` group on _process so it survives scene swaps and
# works even when the HUD is instantiated before the player.
#
# Visual: 4 short rectangles at N/S/E/W from screen center plus a
# small 2x2 center pixel. Yellow tint to read against most foliage /
# stone backdrops; alpha animates to/from 1.0 over FADE_TIME.

const TICK_LENGTH: float = 10.0     # pixels — N/S/E/W tick length
const TICK_THICK: float = 2.0       # pixels — tick width
const TICK_GAP: float = 4.0         # pixels from centre before the tick starts
const DOT_SIZE: float = 2.0         # 2x2 centre pixel
const COLOR_AIM := Color(1.0, 0.9, 0.4, 1.0)
const FADE_TIME: float = 0.15

var _player: Node = null
var _alpha: float = 0.0
var _target_alpha: float = 0.0


func _ready() -> void:
	# Cover the full viewport so we can draw at the centre regardless of
	# resolution; ignore mouse events so the reticle never eats clicks.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 11


func _process(delta: float) -> void:
	_ensure_player()
	var aiming: bool = false
	if _player and is_instance_valid(_player):
		# `aim_mode` is a plain bool member on tux_player.gd. Use `in`
		# so a player without the flag (e.g. a future remote-controlled
		# variant) doesn't error out.
		if "aim_mode" in _player:
			aiming = bool(_player.get("aim_mode"))
	_target_alpha = 1.0 if aiming else 0.0
	var fade_rate: float = 1.0 / FADE_TIME
	_alpha = move_toward(_alpha, _target_alpha, fade_rate * delta)
	queue_redraw()


func _ensure_player() -> void:
	if _player and is_instance_valid(_player):
		return
	var ps := get_tree().get_nodes_in_group("player")
	if ps.size() > 0:
		_player = ps[0]


func _draw() -> void:
	if _alpha <= 0.001:
		return
	var col := COLOR_AIM
	col.a = _alpha
	var c: Vector2 = size * 0.5
	# N tick: from (cx - thick/2, cy - GAP - LENGTH) size (thick, LENGTH).
	var t: float = TICK_THICK
	var l: float = TICK_LENGTH
	var g: float = TICK_GAP
	# Verticals (N + S)
	draw_rect(Rect2(c + Vector2(-t * 0.5, -g - l), Vector2(t, l)), col, true)
	draw_rect(Rect2(c + Vector2(-t * 0.5,  g),     Vector2(t, l)), col, true)
	# Horizontals (E + W)
	draw_rect(Rect2(c + Vector2(-g - l, -t * 0.5), Vector2(l, t)), col, true)
	draw_rect(Rect2(c + Vector2( g,     -t * 0.5), Vector2(l, t)), col, true)
	# Centre 2x2 dot.
	draw_rect(Rect2(c + Vector2(-DOT_SIZE * 0.5, -DOT_SIZE * 0.5),
			Vector2(DOT_SIZE, DOT_SIZE)), col, true)
