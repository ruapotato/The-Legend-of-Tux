extends CanvasLayer

# Procedural-world mini-map for world_disc.tscn. A separate widget from
# the dungeon mini_map.gd (which bakes per-cell tile colour from
# TerrainMesh nodes) — this one samples WorldGen.biome_at / height_at
# directly at sample-grid points and produces an ImageTexture per zoom
# level.
#
# Three zooms:
#   LOCAL    — ~100m radius around the player, 128×128 grid, rebakes
#              every ~0.25s while the player moves.
#   REGIONAL — ~2km radius around the player, 256×256 grid, rebakes
#              every ~1s.
#   WORLD    — full 30km world disc, 512×512 grid, baked ONCE on first
#              open and then cached as an ImageTexture forever. The
#              World bake is expensive (~262k samples × a few noise
#              lookups each) so it always runs on WorkerThreadPool;
#              we show a "Generating map…" label until it lands.
#
# Two visual states:
#   Corner widget — always-visible 128×128 frame in the top-LEFT
#                   (top-right is the hud_status pill cluster). Always
#                   shows LOCAL zoom. Click on it (or press M) to open
#                   the full-screen view.
#   Full-screen   — Valheim-style overlay. Mouse-wheel cycles
#                   LOCAL → REGIONAL → WORLD. M or Esc closes;
#                   `set_input_as_handled()` swallows the Esc so the
#                   pause menu doesn't also open.
#
# The player triangle uses Tux.get_face_yaw() so the orientation tracks
# the player's facing rather than the camera. North (world -Z) is up.

const CORNER_SIZE:    Vector2 = Vector2(176, 176)
const FULLSCREEN_SIZE: Vector2 = Vector2(720, 720)

# Sample-grid resolutions per zoom. Higher = finer, but each sample
# costs a height_at + biome_at, so we keep them modest.
const LOCAL_GRID:    int = 128
const REGIONAL_GRID: int = 256
const WORLD_GRID:    int = 512

# Visible-world radius (in metres) at each zoom level.
const LOCAL_RADIUS_M:    float =   100.0
const REGIONAL_RADIUS_M: float =  2000.0
const WORLD_RADIUS_M:    float = 30000.0

# How often each zoom level rebakes when the corner is visible / the
# fullscreen overlay sits on this zoom. World is once-only.
const LOCAL_REFRESH_S:    float = 0.25
const REGIONAL_REFRESH_S: float = 1.00

# Distance the player must travel (m) before a Local/Regional rebake
# is even considered. Keeps us from re-baking every tick while standing
# still or shuffling on the spot.
const LOCAL_MOVE_EPSILON_M:    float =  2.0
const REGIONAL_MOVE_EPSILON_M: float = 40.0

# Three baked textures cover the world at decreasing resolution; the
# user-facing zoom is a 15-step continuous slider that picks one of them
# as the source and crops it via AtlasTexture for the visible window.
# Step 0 = 50 m radius (max zoom in), step 14 = 30 km (full world).
enum Zoom { LOCAL, REGIONAL, WORLD }
const ZOOM_STEPS: int = 15
const ZOOM_RADIUS_MIN_M: float = 50.0
const ZOOM_RADIUS_MAX_M: float = 30000.0

const OCEAN_COLOR := Color(0.08, 0.20, 0.40, 1.0)
const FRAME_COLOR := Color(0.85, 0.78, 0.55, 1.0)
const BG_COLOR    := Color(0.05, 0.06, 0.10, 0.78)
const PLAYER_COLOR := Color(1.00, 0.92, 0.40, 1.0)
const LABEL_COLOR := Color(0.95, 0.92, 0.78, 1.0)
const BAKING_LABEL_COLOR := Color(0.95, 0.92, 0.78, 0.92)

# Sea-level ish — anything below this `height_at()` returns counts as ocean.
# WorldGen.SEA_LEVEL is 0.0; we use a small positive cushion so the very
# faint beach edges still read as land.
const OCEAN_HEIGHT_THRESHOLD: float = 0.0

# Layer high enough to draw over the HUD but below the pause menu (95).
const LAYER: int = 80

# Layout sub-nodes — built procedurally in _ready so we don't need a
# .tscn file dedicated to the widget.
var _root: Control = null            # full-screen container, hidden until M
var _corner_panel: Panel = null      # the always-visible top-left widget
var _corner_view: TextureRect = null
var _corner_overlay: Control = null  # draws the player triangle + frame on top of _corner_view
var _full_view: TextureRect = null   # the full-screen TextureRect (uses entire window)
var _full_overlay: Control = null    # draws triangle + frame on top of _full_view
var _zoom_label: Label = null
var _baking_label: Label = null

var _player: Node3D = null
var _is_open: bool = false
# Source-tier (which baked texture is currently the live source). Derived
# from _zoom_step in _apply_zoom; kept as a member so the bake/drain
# code can ask "is this tier the active source right now?".
var _current_zoom: int = Zoom.LOCAL
# User-facing 0..ZOOM_STEPS-1 step. Cycled by `,` / `.` keys + wheel.
var _zoom_step: int = 2
# Most recent target_radius (m) computed from _zoom_step. Cached so the
# per-frame atlas refresh in _process doesn't have to recompute.
var _last_target_radius_m: float = 0.0
# AtlasTextures wrapping the active source texture and cropped to the
# target-radius window centered on the player. One per view so the
# corner and the fullscreen overlay can show the same source but
# (in principle) different windows.
var _corner_atlas: AtlasTexture = null
var _full_atlas: AtlasTexture = null

# Cached textures per zoom. World is keyed off the seed so a future
# new-world (debug command) invalidates the cache.
var _local_tex: ImageTexture = null
var _regional_tex: ImageTexture = null
var _world_tex: ImageTexture = null
var _world_baked_seed: int = -1

# Centre-of-bake (world XZ) used to position the player blip relative to
# the texture. Updated when each level rebakes.
var _local_center: Vector2 = Vector2.ZERO
var _regional_center: Vector2 = Vector2.ZERO

# Time/movement accumulators per zoom — wakes the rebake only when the
# player has actually moved AND the timer elapsed.
var _local_accum: float = 0.0
var _regional_accum: float = 0.0

# In-flight bake tracking. We park bake results on a thread, then drain
# them in _process. Only one of each kind can be in flight at a time;
# requesting another while the first is still cooking is a no-op.
var _local_task_id: int = -1
var _regional_task_id: int = -1
var _world_task_id: int = -1
var _local_task_payload: Dictionary = {}
var _regional_task_payload: Dictionary = {}
var _world_task_payload: Dictionary = {}
var _bake_mtx: Mutex = Mutex.new()


func _ready() -> void:
	layer = LAYER
	_build_layout()
	_refresh_player()
	# Queue an initial local bake immediately so the corner widget isn't
	# empty for the first 0.25s of play, and apply the default zoom so
	# the AtlasTexture is wired up before the first _process tick.
	_request_local_bake(true)
	_apply_zoom()
	set_process(true)
	set_process_input(true)


func _build_layout() -> void:
	# ---- Corner widget --------------------------------------------------
	# A Panel anchored top-LEFT (hud_status owns the top-right).
	_corner_panel = Panel.new()
	# Bottom-left corner — keeps the top-left clear for the legacy
	# stamina/HP HUD and the top-right for the pills + control hints.
	_corner_panel.anchor_left = 0.0
	_corner_panel.anchor_right = 0.0
	_corner_panel.anchor_top = 1.0
	_corner_panel.anchor_bottom = 1.0
	_corner_panel.offset_left = 16
	_corner_panel.offset_right = 16 + CORNER_SIZE.x
	_corner_panel.offset_top = -(16 + CORNER_SIZE.y)
	_corner_panel.offset_bottom = -16
	_corner_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_COLOR
	sb.border_color = FRAME_COLOR
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	_corner_panel.add_theme_stylebox_override("panel", sb)
	add_child(_corner_panel)

	_corner_view = TextureRect.new()
	_corner_view.anchor_right = 1.0
	_corner_view.anchor_bottom = 1.0
	_corner_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_corner_view.stretch_mode = TextureRect.STRETCH_SCALE
	_corner_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_corner_panel.add_child(_corner_view)

	_corner_overlay = Control.new()
	_corner_overlay.anchor_right = 1.0
	_corner_overlay.anchor_bottom = 1.0
	_corner_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_corner_overlay.draw.connect(_draw_corner_overlay)
	_corner_panel.add_child(_corner_overlay)

	_corner_panel.gui_input.connect(_on_corner_clicked)

	# ---- Fullscreen overlay --------------------------------------------
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.70)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var frame := Panel.new()
	frame.custom_minimum_size = FULLSCREEN_SIZE
	var sb2 := StyleBoxFlat.new()
	sb2.bg_color = BG_COLOR
	sb2.border_color = FRAME_COLOR
	sb2.set_border_width_all(3)
	sb2.set_corner_radius_all(4)
	frame.add_theme_stylebox_override("panel", sb2)
	center.add_child(frame)

	_full_view = TextureRect.new()
	_full_view.anchor_right = 1.0
	_full_view.anchor_bottom = 1.0
	_full_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_full_view.stretch_mode = TextureRect.STRETCH_SCALE
	_full_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_full_view)

	_full_overlay = Control.new()
	_full_overlay.anchor_right = 1.0
	_full_overlay.anchor_bottom = 1.0
	_full_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_overlay.draw.connect(_draw_full_overlay)
	frame.add_child(_full_overlay)

	# Zoom label across the top of the panel.
	_zoom_label = Label.new()
	_zoom_label.text = "LOCAL"
	_zoom_label.add_theme_font_size_override("font_size", 18)
	_zoom_label.add_theme_color_override("font_color", LABEL_COLOR)
	_zoom_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_zoom_label.add_theme_constant_override("shadow_offset_x", 1)
	_zoom_label.add_theme_constant_override("shadow_offset_y", 1)
	_zoom_label.position = Vector2(12, 8)
	_zoom_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_zoom_label)

	# "Generating map…" — only shown while the WORLD bake is running.
	_baking_label = Label.new()
	_baking_label.text = "Generating map…"
	_baking_label.add_theme_font_size_override("font_size", 22)
	_baking_label.add_theme_color_override("font_color", BAKING_LABEL_COLOR)
	_baking_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_baking_label.add_theme_constant_override("shadow_offset_x", 1)
	_baking_label.add_theme_constant_override("shadow_offset_y", 1)
	_baking_label.anchor_left = 0.5
	_baking_label.anchor_top = 0.5
	_baking_label.anchor_right = 0.5
	_baking_label.anchor_bottom = 0.5
	_baking_label.offset_left = -120
	_baking_label.offset_top = -14
	_baking_label.offset_right = 120
	_baking_label.offset_bottom = 14
	_baking_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_baking_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_baking_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_baking_label.visible = false
	frame.add_child(_baking_label)

	# Hint at the bottom: zoom + close instructions.
	var hint := Label.new()
	hint.text = "Wheel / , . : zoom    •    M / Esc: close"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.78, 0.74, 0.62, 0.90))
	hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	hint.add_theme_constant_override("shadow_offset_x", 1)
	hint.add_theme_constant_override("shadow_offset_y", 1)
	hint.anchor_left = 0.0
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 12
	hint.offset_top = -28
	hint.offset_right = -12
	hint.offset_bottom = -6
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(hint)


func _refresh_player() -> void:
	if _player and is_instance_valid(_player):
		return
	var ps := get_tree().get_nodes_in_group("player")
	for p in ps:
		if p is Node3D:
			_player = p
			return


# ---- Input -----------------------------------------------------------

func _input(event: InputEvent) -> void:
	# M — toggle fullscreen. Always swallowed so a future re-bind to a
	# letter that means something else for the player doesn't double-fire.
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_M:
			get_viewport().set_input_as_handled()
			if _is_open:
				_close_full()
			else:
				_open_full()
			return
		# Esc closes the fullscreen view WITHOUT opening the pause menu.
		# We swallow the event in that case so game_pause_menu doesn't
		# also see this keypress (it checks the same key in _input).
		if k.keycode == KEY_ESCAPE and _is_open:
			get_viewport().set_input_as_handled()
			_close_full()
			return
		# Keyboard zoom — works whether the map is the corner thumb or
		# the fullscreen overlay. `.` / `>` zooms OUT (LOCAL → REGIONAL
		# → WORLD); `,` / `<` zooms IN. The shift-versions share the
		# same physical keycode in Godot so the modifier doesn't matter.
		if k.keycode == KEY_PERIOD or k.keycode == KEY_GREATER:
			get_viewport().set_input_as_handled()
			_cycle_zoom(+1)
			return
		if k.keycode == KEY_COMMA or k.keycode == KEY_LESS:
			get_viewport().set_input_as_handled()
			_cycle_zoom(-1)
			return

	# Mouse-wheel zoom while open (still supported; just one more way).
	if _is_open and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			get_viewport().set_input_as_handled()
			_cycle_zoom(-1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			get_viewport().set_input_as_handled()
			_cycle_zoom(+1)


func _on_corner_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_open_full()


func _open_full() -> void:
	_is_open = true
	_root.visible = true
	_apply_zoom()


func _close_full() -> void:
	_is_open = false
	_root.visible = false


# target_radius(m) for the current 0..14 step on a log scale between
# ZOOM_RADIUS_MIN_M and ZOOM_RADIUS_MAX_M. Log feels natural — small
# steps near the player, ever-wider sweeps near the world view.
func _target_radius_m() -> float:
	var t: float = float(_zoom_step) / float(max(ZOOM_STEPS - 1, 1))
	return ZOOM_RADIUS_MIN_M * pow(ZOOM_RADIUS_MAX_M / ZOOM_RADIUS_MIN_M, t)


# Which baked tier covers a given target radius. Uses a 0.95 margin so
# the source's edges aren't visible at the corner of the crop window —
# bake-center drift between rebakes would otherwise paint clamp-extend
# colour into the visible map.
func _tier_for_radius(r: float) -> int:
	if r <= LOCAL_RADIUS_M * 0.95:
		return Zoom.LOCAL
	if r <= REGIONAL_RADIUS_M * 0.95:
		return Zoom.REGIONAL
	return Zoom.WORLD


func _cycle_zoom(direction: int) -> void:
	# 15-step continuous zoom. `direction = +1` zooms out (wider radius),
	# `-1` zooms in. Clamped at the endpoints.
	var next: int = clampi(_zoom_step + direction, 0, ZOOM_STEPS - 1)
	if next == _zoom_step:
		return
	_zoom_step = next
	_apply_zoom()


func _apply_zoom() -> void:
	# Compute target radius, pick the smallest baked source that covers
	# it, trigger a bake if the source isn't ready, then crop via
	# AtlasTexture. Both views share the same crop so the corner thumb
	# tracks the fullscreen overlay one-to-one.
	var target: float = _target_radius_m()
	_last_target_radius_m = target
	var tier: int = _tier_for_radius(target)
	_current_zoom = tier
	var tex: Texture2D = null
	match tier:
		Zoom.LOCAL:
			if _local_tex == null:
				_request_local_bake(true)
			tex = _local_tex
			_baking_label.visible = false
		Zoom.REGIONAL:
			if _regional_tex == null:
				_request_regional_bake(true)
			tex = _regional_tex
			_baking_label.visible = false
		Zoom.WORLD:
			if _world_tex == null or _world_baked_seed != WorldGen.world_seed:
				_request_world_bake()
				_baking_label.visible = (_world_tex == null)
			else:
				_baking_label.visible = false
			tex = _world_tex
	_update_zoom_label(target)
	_update_views_for(tex, target, tier)
	if _full_overlay:
		_full_overlay.queue_redraw()
	if _corner_overlay:
		_corner_overlay.queue_redraw()


func _update_zoom_label(target_m: float) -> void:
	if _zoom_label == null:
		return
	var step_txt: String = "(%d/%d)" % [_zoom_step + 1, ZOOM_STEPS]
	if target_m < 1000.0:
		_zoom_label.text = "%.0f m  %s" % [target_m, step_txt]
	else:
		_zoom_label.text = "%.1f km  %s" % [target_m / 1000.0, step_txt]


# Build / refresh an AtlasTexture around `tex` whose `region` covers the
# target-radius window centered on the player's current XZ. Re-runs each
# frame from _process so the world view actually scrolls as the player
# moves at zoomed-out levels.
func _update_views_for(tex: Texture2D, target_radius: float, tier: int) -> void:
	if tex == null:
		if _corner_view: _corner_view.texture = null
		if _full_view:   _full_view.texture = null
		return
	if _corner_atlas == null:
		_corner_atlas = AtlasTexture.new()
	if _full_atlas == null:
		_full_atlas = AtlasTexture.new()
	var grid: int = LOCAL_GRID
	var src_radius: float = LOCAL_RADIUS_M
	var src_center: Vector2 = _local_center
	match tier:
		Zoom.LOCAL:
			grid = LOCAL_GRID
			src_radius = LOCAL_RADIUS_M
			src_center = _local_center
		Zoom.REGIONAL:
			grid = REGIONAL_GRID
			src_radius = REGIONAL_RADIUS_M
			src_center = _regional_center
		Zoom.WORLD:
			grid = WORLD_GRID
			src_radius = WORLD_RADIUS_M
			src_center = Vector2.ZERO
	var px_per_m: float = float(grid) / (2.0 * src_radius)
	var player_xz: Vector2 = _player_xz()
	# Centre of the crop, in source-texture pixel coordinates. The
	# source covers ±src_radius around src_center, mapped to a `grid`
	# square; player_xz lands at this pixel position inside the source.
	var center_px: Vector2 = (player_xz - src_center) * px_per_m \
			+ Vector2(grid, grid) * 0.5
	var half_px: float = target_radius * px_per_m
	var region := Rect2(
			center_px.x - half_px, center_px.y - half_px,
			half_px * 2.0, half_px * 2.0)
	_corner_atlas.atlas = tex
	_corner_atlas.region = region
	_full_atlas.atlas = tex
	_full_atlas.region = region
	if _corner_view:
		_corner_view.texture = _corner_atlas
	if _full_view:
		_full_view.texture = _full_atlas


# ---- Main loop --------------------------------------------------------

func _process(delta: float) -> void:
	_refresh_player()
	_drain_bakes()

	# Local rebake — runs whenever LOCAL is the active source tier,
	# throttled by timer + player-movement epsilon inside the bake fn.
	if _current_zoom == Zoom.LOCAL:
		_local_accum += delta
		if _local_accum >= LOCAL_REFRESH_S:
			_local_accum = 0.0
			_request_local_bake(false)
	else:
		_local_accum = 0.0

	# Regional rebake — same idea.
	if _current_zoom == Zoom.REGIONAL:
		_regional_accum += delta
		if _regional_accum >= REGIONAL_REFRESH_S:
			_regional_accum = 0.0
			_request_regional_bake(false)
	else:
		_regional_accum = 0.0

	# Re-crop the AtlasTexture each frame so the visible window scrolls
	# as the player moves — cheap (just two Rect2 writes). Skipped
	# before any zoom has been applied.
	if _last_target_radius_m > 0.0:
		var tex: Texture2D = null
		match _current_zoom:
			Zoom.LOCAL:    tex = _local_tex
			Zoom.REGIONAL: tex = _regional_tex
			Zoom.WORLD:    tex = _world_tex
		if tex != null:
			_update_views_for(tex, _last_target_radius_m, _current_zoom)

	# Player-blip motion — every frame the overlay redraws so the
	# triangle slides with the player even between rebakes.
	if _corner_overlay:
		_corner_overlay.queue_redraw()
	if _is_open and _full_overlay:
		_full_overlay.queue_redraw()


# ---- Bake requests ----------------------------------------------------

func _player_xz() -> Vector2:
	if _player and is_instance_valid(_player):
		return Vector2(_player.global_position.x, _player.global_position.z)
	return Vector2.ZERO


func _request_local_bake(force: bool) -> void:
	if _local_task_id != -1:
		return       # already in flight
	var c: Vector2 = _player_xz()
	if not force and _local_tex != null \
			and c.distance_to(_local_center) < LOCAL_MOVE_EPSILON_M:
		return
	var payload := {
		"grid":   LOCAL_GRID,
		"center": c,
		"radius": LOCAL_RADIUS_M,
		"seed":   WorldGen.world_seed,
		"out":    null,
	}
	_local_task_payload = payload
	_local_task_id = WorkerThreadPool.add_task(
			_bake_task.bind(payload), false, "mini_map_local_bake")


func _request_regional_bake(force: bool) -> void:
	if _regional_task_id != -1:
		return
	var c: Vector2 = _player_xz()
	if not force and _regional_tex != null \
			and c.distance_to(_regional_center) < REGIONAL_MOVE_EPSILON_M:
		return
	var payload := {
		"grid":   REGIONAL_GRID,
		"center": c,
		"radius": REGIONAL_RADIUS_M,
		"seed":   WorldGen.world_seed,
		"out":    null,
	}
	_regional_task_payload = payload
	_regional_task_id = WorkerThreadPool.add_task(
			_bake_task.bind(payload), false, "mini_map_regional_bake")


func _request_world_bake() -> void:
	if _world_task_id != -1:
		return
	var payload := {
		"grid":   WORLD_GRID,
		"center": Vector2.ZERO,
		"radius": WORLD_RADIUS_M,
		"seed":   WorldGen.world_seed,
		"out":    null,
	}
	_world_task_payload = payload
	_world_task_id = WorkerThreadPool.add_task(
			_bake_task.bind(payload), false, "mini_map_world_bake")


# Runs on a worker thread. Builds a square Image by sampling biome /
# height at evenly spaced world coordinates and parks the raw Image in
# the payload so the main thread can wrap it in an ImageTexture.
func _bake_task(payload: Dictionary) -> void:
	var grid: int = int(payload["grid"])
	var center: Vector2 = payload["center"]
	var radius: float = float(payload["radius"])
	var img := Image.create(grid, grid, false, Image.FORMAT_RGBA8)

	# step = how many world-metres each pixel covers. The visible window
	# spans [-radius, +radius] on both axes.
	var step: float = (radius * 2.0) / float(grid)
	var origin_x: float = center.x - radius
	var origin_z: float = center.y - radius

	# We hot-loop biome_at + height_at here. height_at is a few noise
	# lookups; cheap, but 262k of them at WORLD_GRID is the bulk of the
	# cost. Hence the off-main-thread bake.
	for py in grid:
		var wz: float = origin_z + (float(py) + 0.5) * step
		for px in grid:
			var wx: float = origin_x + (float(px) + 0.5) * step
			# Anything below sea level (continent_noise < threshold
			# OR past the disc edge) reads as ocean.
			var h: float = WorldGen.height_at(wx, wz)
			var col: Color
			if h <= OCEAN_HEIGHT_THRESHOLD:
				col = OCEAN_COLOR
			else:
				col = WorldGen.biome_color_at(wx, wz)
			img.set_pixel(px, py, col)

	_bake_mtx.lock()
	payload["out"] = img
	_bake_mtx.unlock()


# Main thread — turn each completed Image into an ImageTexture and
# clear the in-flight flag for that zoom. Called once per frame.
func _drain_bakes() -> void:
	# Bake completions just publish the new ImageTexture; the per-frame
	# _update_views_for() picks it up via the atlas swap on the very
	# next tick, so the drain no longer needs to assign TextureRect
	# textures directly.
	if _local_task_id != -1 and WorkerThreadPool.is_task_completed(_local_task_id):
		WorkerThreadPool.wait_for_task_completion(_local_task_id)
		_bake_mtx.lock()
		var img: Image = _local_task_payload.get("out")
		_bake_mtx.unlock()
		if img != null:
			_local_tex = ImageTexture.create_from_image(img)
			_local_center = _local_task_payload["center"]
		_local_task_id = -1
		_local_task_payload = {}

	if _regional_task_id != -1 and WorkerThreadPool.is_task_completed(_regional_task_id):
		WorkerThreadPool.wait_for_task_completion(_regional_task_id)
		_bake_mtx.lock()
		var img2: Image = _regional_task_payload.get("out")
		_bake_mtx.unlock()
		if img2 != null:
			_regional_tex = ImageTexture.create_from_image(img2)
			_regional_center = _regional_task_payload["center"]
		_regional_task_id = -1
		_regional_task_payload = {}

	if _world_task_id != -1 and WorkerThreadPool.is_task_completed(_world_task_id):
		WorkerThreadPool.wait_for_task_completion(_world_task_id)
		_bake_mtx.lock()
		var img3: Image = _world_task_payload.get("out")
		_bake_mtx.unlock()
		if img3 != null:
			_world_tex = ImageTexture.create_from_image(img3)
			_world_baked_seed = int(_world_task_payload["seed"])
			if _current_zoom == Zoom.WORLD:
				_baking_label.visible = false
		_world_task_id = -1
		_world_task_payload = {}


# ---- Overlay drawing --------------------------------------------------
#
# The TextureRect under each overlay shows the baked biome image; the
# Control on top of it draws the player triangle + an outline frame.
# Drawing the blip in a separate Control means we don't have to re-bake
# the texture every frame just to move the marker — only the overlay
# redraws, which is a single polygon call.

func _draw_corner_overlay() -> void:
	_draw_overlay(_corner_overlay, true, 6.0)


func _draw_full_overlay() -> void:
	if _full_overlay == null:
		return
	_draw_overlay(_full_overlay, false, 10.0)


# Shared draw helper. With the new AtlasTexture cropping the visible
# window is ALWAYS centered on the player (we pick the source's pixel
# rect around the player's current XZ each frame in _update_views_for).
# So the blip is just at the widget centre — no per-zoom projection math
# needed. The triangle still rotates with get_face_yaw().
func _draw_overlay(node: Control, draw_frame: bool, triangle_radius: float) -> void:
	if draw_frame:
		node.draw_rect(Rect2(Vector2.ZERO, node.size), FRAME_COLOR, false, 1.0)
	if _player == null or not is_instance_valid(_player):
		return
	var yaw: float = 0.0
	if _player.has_method("get_face_yaw"):
		yaw = float(_player.call("get_face_yaw"))
	else:
		yaw = _player.rotation.y
	var center := Vector2(node.size.x * 0.5, node.size.y * 0.5)
	_draw_player_triangle(node, center, yaw, triangle_radius)


func _draw_player_triangle(node: Control, at: Vector2, yaw: float, r: float) -> void:
	# At yaw=0 the player faces world -Z; on the map that's UP (screen
	# Y is +down). Matches mini_map.gd's convention exactly so an
	# experienced player doesn't have to relearn the marker.
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(fwd.y, -fwd.x)
	var tip := at + fwd * r
	var l   := at - fwd * (r * 0.6) + right * (r * 0.6)
	var rg  := at - fwd * (r * 0.6) - right * (r * 0.6)
	node.draw_colored_polygon(PackedVector2Array([tip, l, rg]), PLAYER_COLOR)
	node.draw_polyline(PackedVector2Array([tip, l, rg, tip]),
			PLAYER_COLOR.darkened(0.5), 1.5)
