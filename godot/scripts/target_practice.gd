extends CanvasLayer

# Autoloaded singleton (`TargetPractice`) running the Old Plays
# Sharpshooter minigame — our equivalent of OoT's Hyrule Castle archery
# range. The Carnival Barker NPC dispatches into us via a dialog choice
# (see dialog.gd's `opens_minigame` field, value "target_practice").
#
# Public API
#   TargetPractice.start(npc_position, target_area_radius=12.0)
#       Pay 5 pebbles, spawn 10 archery targets in a ring around the
#       barker, run a 30s countdown, score arrows, hand out rewards.
#   TargetPractice.is_active() -> bool
#
# Reward tiers (committed):
#   <5 hits   "Walk well, walker." (no reward)
#    5-7 hits Heart piece — first time only, gated by the quest_flag
#             `target_practice_won_heart` so a replay can still pay
#             out the high-tier bonus but never re-grants the heart.
#    8+ hits  20 pebble bonus (every play)
#   10 hits   Same 20-pebble bonus, plus the heart on the first run
#             (the heart triggers at 5+, so a perfect game still grants
#             it). No special "perfect" sting beyond that.
#
# Game loop in plain English:
#   1. Intro overlay: "Hit 5 targets in 30 seconds. [E] to begin /
#      [Esc] to quit."
#   2. Spend 5 pebbles, top arrows up to a guaranteed 15 (so the
#      player always has enough ammo for the round).
#   3. Spawn 10 ArcheryTargets around `start_position` inside
#      `target_area_radius`, with y in [1.5, 4.0] so the player has to
#      look up. Each new target is rejected if it lands within 3m of
#      any prior pick (small attempts cap → fall back if it can't find
#      a clear slot).
#   4. Score HUD: top-right gold-tinted readout — score / time left.
#   5. Arrow hits a target → +1 score, target queue_frees with a
#      `crystal_hit` sting. Hitting the last target ends the round
#      early.
#   6. End overlay shows hits + reward; "[E] play again / [Esc] leave".
#   7. Cleanup any unkilled targets. The world is NOT paused — Tux
#      keeps moving and shooting — but we swallow ui_cancel so the
#      pause menu can't open mid-round.

# ---- Tunables (kept in one place so the JSON-side spec is readable) -----

const ENTRY_COST: int        = 5
const ROUND_DURATION: float  = 30.0
const TARGET_COUNT: int      = 10
const HEART_THRESHOLD: int   = 5
const PEBBLE_THRESHOLD: int  = 8
const PEBBLE_REWARD: int     = 20
const HEART_QUEST_FLAG: String = "target_practice_won_heart"

# Target placement.
const TARGET_Y_MIN: float    = 1.5
const TARGET_Y_MAX: float    = 4.0
const MIN_TARGET_GAP: float  = 3.0
const PLACEMENT_TRIES: int   = 24
# Don't place a target right on top of the player / barker.
const MIN_RADIUS_FRAC: float = 0.35

# Promised arrow floor at start so the player can actually play even
# if their quiver is empty. We don't take them back at end-of-round.
const ARROW_FLOOR: int       = 15

const TargetScene: PackedScene = preload("res://scenes/archery_target.tscn")

# ---- State --------------------------------------------------------------

enum Phase { IDLE, INTRO, RUNNING, OUTRO }

var _phase: int = Phase.IDLE
var _start_pos: Vector3 = Vector3.ZERO
var _radius: float = 12.0

var _live_targets: Array = []        # Array[ArcheryTarget Node3D]
var _time_left: float = 0.0
var _score: int = 0
var _round_seed: int = 0

# UI ----------------------------------------------------------------------

var _root: Control = null
var _score_label: Label = null
var _timer_label: Label = null

# Centered overlay (intro + outro share the same panel skeleton).
var _overlay: Control = null
var _overlay_title: Label = null
var _overlay_body: Label = null
var _overlay_hint: Label = null


func _ready() -> void:
    layer = 85    # under pause menu (which is 100/effective top), above HUD
    process_mode = Node.PROCESS_MODE_ALWAYS
    visible = false
    _build_ui()
    _hide_score_hud()
    _hide_overlay()


# ---- public API --------------------------------------------------------

func is_active() -> bool:
    return _phase != Phase.IDLE


func start(npc_position: Vector3, target_area_radius: float = 12.0) -> void:
    # Decline reentry — if a round is already up, ignore.
    if _phase != Phase.IDLE:
        return
    _start_pos = npc_position
    _radius = max(target_area_radius, 4.0)
    # Bow gating happens at the dialog layer (the `requires: bow`
    # choice is hidden if Tux doesn't own the bow), but a defensive
    # check here keeps a future caller honest.
    if not GameState.has_item("bow"):
        _show_overlay(
            "No bow on you.",
            "The Sharpshooter wants the recurve. Come back when you've found one.",
            "[E] / [Esc]  back"
        )
        _phase = Phase.OUTRO
        return
    if GameState.pebbles < ENTRY_COST:
        _show_overlay(
            "Not enough pebbles.",
            "The line costs %d pebbles. Come back with the toll." % ENTRY_COST,
            "[E] / [Esc]  back"
        )
        _phase = Phase.OUTRO
        return
    _enter_intro()


# ---- Intro -------------------------------------------------------------

func _enter_intro() -> void:
    _phase = Phase.INTRO
    visible = true
    _show_overlay(
        "Old Plays — Sharpshooter",
        "Hit %d targets in %d seconds for a piece of heart.\n%d hits earns a %d-pebble bonus." % [
            HEART_THRESHOLD, int(ROUND_DURATION), PEBBLE_THRESHOLD, PEBBLE_REWARD,
        ],
        "[E] begin    [Esc] back out"
    )


func _begin_round() -> void:
    # Charge the entry fee just before the round starts so a player who
    # backs out of the intro doesn't get charged for the look-around.
    if not GameState.spend_pebbles(ENTRY_COST):
        _phase = Phase.IDLE
        _hide_overlay()
        visible = false
        return
    # Top up arrows so the round is actually playable.
    if GameState.arrows < ARROW_FLOOR:
        GameState.add_arrows(ARROW_FLOOR - GameState.arrows)
    randomize()
    _round_seed = randi()
    _score = 0
    _time_left = ROUND_DURATION
    _spawn_targets()
    _hide_overlay()
    _show_score_hud()
    _phase = Phase.RUNNING
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("menu_confirm")


func _spawn_targets() -> void:
    _clear_targets()
    var placed: Array = []     # Array[Vector3]
    var rng := RandomNumberGenerator.new()
    rng.seed = _round_seed
    var scene_root: Node = get_tree().current_scene
    if scene_root == null:
        return
    for i in range(TARGET_COUNT):
        var pos: Vector3 = _pick_target_position(rng, placed)
        placed.append(pos)
        var t: Node3D = TargetScene.instantiate()
        scene_root.add_child(t)
        t.global_position = pos
        # Face roughly toward the player position so the disc reads
        # rather than presenting an edge-on profile.
        var to_center: Vector3 = (_start_pos - pos)
        to_center.y = 0.0
        if to_center.length_squared() > 0.001:
            var ang: float = atan2(to_center.x, to_center.z)
            t.rotation.y = ang
        # Hook the per-target hit signal so we can score and detect
        # round-end-by-clear without polling. queue_freed targets
        # tidy themselves up; we just remove the freed entry from
        # _live_targets in _process via is_instance_valid.
        if t.has_signal("hit"):
            t.connect("hit", Callable(self, "_on_target_hit"))
        _live_targets.append(t)


func _pick_target_position(rng: RandomNumberGenerator, placed: Array) -> Vector3:
    var min_r: float = _radius * MIN_RADIUS_FRAC
    var max_r: float = _radius
    for _attempt in range(PLACEMENT_TRIES):
        var ang: float = rng.randf_range(0.0, TAU)
        var r: float = rng.randf_range(min_r, max_r)
        var y: float = rng.randf_range(TARGET_Y_MIN, TARGET_Y_MAX)
        var pos := Vector3(
            _start_pos.x + cos(ang) * r,
            _start_pos.y + y,
            _start_pos.z + sin(ang) * r
        )
        var ok: bool = true
        for p_v in placed:
            var p: Vector3 = p_v
            if pos.distance_to(p) < MIN_TARGET_GAP:
                ok = false
                break
        if ok:
            return pos
    # Fall back: a clean slot couldn't be found. Drop the last attempted
    # position anyway so we still hit TARGET_COUNT — a minor cluster is
    # better than a missing target.
    var ang2: float = rng.randf_range(0.0, TAU)
    var r2: float = rng.randf_range(min_r, max_r)
    var y2: float = rng.randf_range(TARGET_Y_MIN, TARGET_Y_MAX)
    return Vector3(
        _start_pos.x + cos(ang2) * r2,
        _start_pos.y + y2,
        _start_pos.z + sin(ang2) * r2
    )


# ---- Round update / scoring --------------------------------------------

func _process(delta: float) -> void:
    if _phase != Phase.RUNNING:
        return
    _time_left = max(_time_left - delta, 0.0)
    _refresh_score_hud()
    # Reap any targets that vanished without firing the signal (defensive).
    for i in range(_live_targets.size() - 1, -1, -1):
        if not is_instance_valid(_live_targets[i]):
            _live_targets.remove_at(i)
    if _time_left <= 0.0 or _live_targets.is_empty():
        _end_round()


func _on_target_hit(target: Node) -> void:
    if _phase != Phase.RUNNING:
        return
    _score += 1
    if target in _live_targets:
        _live_targets.erase(target)
    _refresh_score_hud()
    if _live_targets.is_empty() or _score >= TARGET_COUNT:
        # Defer one frame so the hit sting / queue_free completes
        # before the outro overlay swaps in.
        call_deferred("_end_round")


func _end_round() -> void:
    if _phase != Phase.RUNNING:
        return
    _phase = Phase.OUTRO
    _hide_score_hud()
    _clear_targets()
    var awarded_heart: bool = false
    var awarded_pebbles: bool = false
    var lines: PackedStringArray = PackedStringArray()
    lines.append("You hit %d of %d." % [_score, TARGET_COUNT])
    if _score >= HEART_THRESHOLD:
        if not GameState.has_flag(HEART_QUEST_FLAG):
            GameState.add_heart_piece()
            GameState.set_flag(HEART_QUEST_FLAG, true)
            awarded_heart = true
            lines.append("A piece of heart, painted onto a wooden token.")
        else:
            lines.append("(The heart prize is already on your wall.)")
    if _score >= PEBBLE_THRESHOLD:
        GameState.add_pebbles(PEBBLE_REWARD)
        awarded_pebbles = true
        lines.append("Bonus: %d pebbles." % PEBBLE_REWARD)
    if not awarded_heart and not awarded_pebbles and _score < HEART_THRESHOLD:
        lines.append("Aim wants the practice. Try again?")
    var title: String
    if _score >= HEART_THRESHOLD:
        title = "A clean line."
        if get_tree().root.has_node("SoundBank"):
            SoundBank.play_2d("boss_clear")
    else:
        title = "Time."
        if get_tree().root.has_node("SoundBank"):
            SoundBank.play_2d("menu_back")
    _show_overlay(title, "\n".join(lines), "[E] play again    [Esc] leave")


# ---- Cleanup -----------------------------------------------------------

func _clear_targets() -> void:
    for t in _live_targets:
        if is_instance_valid(t):
            t.queue_free()
    _live_targets.clear()


func _quit() -> void:
    _phase = Phase.IDLE
    _hide_overlay()
    _hide_score_hud()
    _clear_targets()
    visible = false
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("menu_back")


# ---- Input -------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
    if _phase == Phase.IDLE:
        return
    # Swallow ui_cancel during the running round so the pause menu
    # can't pop while the player is mid-line. Esc still works in the
    # intro / outro overlays — there it's the "back out" verb.
    if _phase == Phase.RUNNING and event.is_action_pressed("ui_cancel"):
        get_viewport().set_input_as_handled()
        return
    if _phase == Phase.INTRO:
        if event.is_action_pressed("interact"):
            get_viewport().set_input_as_handled()
            _begin_round()
            return
        if event.is_action_pressed("ui_cancel"):
            get_viewport().set_input_as_handled()
            _quit()
            return
    elif _phase == Phase.OUTRO:
        if event.is_action_pressed("interact"):
            get_viewport().set_input_as_handled()
            # Re-attempt: must still be able to pay.
            if GameState.pebbles < ENTRY_COST:
                _show_overlay(
                    "Out of pebbles.",
                    "Come back with %d." % ENTRY_COST,
                    "[Esc] leave"
                )
                return
            _enter_intro()
            return
        if event.is_action_pressed("ui_cancel"):
            get_viewport().set_input_as_handled()
            _quit()
            return


# ---- UI plumbing -------------------------------------------------------

func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    # Score / timer HUD: small label top-right, gold-tinted, font 18.
    var hud_panel := PanelContainer.new()
    hud_panel.anchor_left  = 1.0
    hud_panel.anchor_right = 1.0
    hud_panel.anchor_top   = 0.0
    hud_panel.anchor_bottom = 0.0
    hud_panel.offset_left   = -240.0
    hud_panel.offset_right  = -16.0
    hud_panel.offset_top    = 16.0
    hud_panel.offset_bottom = 84.0
    hud_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
    var hud_sb := StyleBoxFlat.new()
    hud_sb.bg_color = Color(0.06, 0.05, 0.10, 0.78)
    hud_sb.border_color = Color(0.98, 0.85, 0.40, 1.0)
    hud_sb.border_width_left = 2
    hud_sb.border_width_top = 2
    hud_sb.border_width_right = 2
    hud_sb.border_width_bottom = 2
    hud_sb.corner_radius_top_left = 6
    hud_sb.corner_radius_top_right = 6
    hud_sb.corner_radius_bottom_left = 6
    hud_sb.corner_radius_bottom_right = 6
    hud_sb.content_margin_left  = 12
    hud_sb.content_margin_right = 12
    hud_sb.content_margin_top   = 6
    hud_sb.content_margin_bottom = 6
    hud_panel.add_theme_stylebox_override("panel", hud_sb)
    _root.add_child(hud_panel)

    var hud_box := VBoxContainer.new()
    hud_box.add_theme_constant_override("separation", 2)
    hud_panel.add_child(hud_box)

    _score_label = Label.new()
    _score_label.add_theme_font_size_override("font_size", 18)
    _score_label.add_theme_color_override("font_color", Color(0.98, 0.85, 0.40, 1.0))
    _score_label.text = "Score 0 / %d" % TARGET_COUNT
    hud_box.add_child(_score_label)

    _timer_label = Label.new()
    _timer_label.add_theme_font_size_override("font_size", 18)
    _timer_label.add_theme_color_override("font_color", Color(0.98, 0.93, 0.55, 1.0))
    _timer_label.text = "Time 30.0s"
    hud_box.add_child(_timer_label)

    # Centered overlay panel for intro / outro / "no money" notes.
    _overlay = Control.new()
    _overlay.anchor_right  = 1.0
    _overlay.anchor_bottom = 1.0
    _overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_overlay)

    var overlay_panel := PanelContainer.new()
    overlay_panel.anchor_left   = 0.5
    overlay_panel.anchor_right  = 0.5
    overlay_panel.anchor_top    = 0.5
    overlay_panel.anchor_bottom = 0.5
    overlay_panel.offset_left   = -300.0
    overlay_panel.offset_right  = 300.0
    overlay_panel.offset_top    = -120.0
    overlay_panel.offset_bottom = 120.0
    overlay_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
    var ov_sb := StyleBoxFlat.new()
    ov_sb.bg_color = Color(0.08, 0.07, 0.12, 0.94)
    ov_sb.border_color = Color(0.98, 0.85, 0.40, 1.0)
    ov_sb.border_width_left = 2
    ov_sb.border_width_top = 2
    ov_sb.border_width_right = 2
    ov_sb.border_width_bottom = 2
    ov_sb.corner_radius_top_left = 8
    ov_sb.corner_radius_top_right = 8
    ov_sb.corner_radius_bottom_left = 8
    ov_sb.corner_radius_bottom_right = 8
    ov_sb.content_margin_left  = 24
    ov_sb.content_margin_right = 24
    ov_sb.content_margin_top   = 18
    ov_sb.content_margin_bottom = 18
    overlay_panel.add_theme_stylebox_override("panel", ov_sb)
    _overlay.add_child(overlay_panel)

    var ov_box := VBoxContainer.new()
    ov_box.add_theme_constant_override("separation", 10)
    overlay_panel.add_child(ov_box)

    _overlay_title = Label.new()
    _overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _overlay_title.add_theme_font_size_override("font_size", 26)
    _overlay_title.add_theme_color_override("font_color", Color(0.98, 0.85, 0.40, 1.0))
    ov_box.add_child(_overlay_title)

    _overlay_body = Label.new()
    _overlay_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _overlay_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _overlay_body.add_theme_font_size_override("font_size", 18)
    _overlay_body.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85, 1.0))
    ov_box.add_child(_overlay_body)

    var spacer := Control.new()
    spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
    ov_box.add_child(spacer)

    _overlay_hint = Label.new()
    _overlay_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _overlay_hint.add_theme_font_size_override("font_size", 14)
    _overlay_hint.add_theme_color_override("font_color", Color(0.72, 0.70, 0.65, 1.0))
    ov_box.add_child(_overlay_hint)


func _show_score_hud() -> void:
    if _score_label:
        _score_label.get_parent().get_parent().visible = true
    _refresh_score_hud()


func _hide_score_hud() -> void:
    if _score_label:
        _score_label.get_parent().get_parent().visible = false


func _refresh_score_hud() -> void:
    if _score_label:
        _score_label.text = "Score %d / %d" % [_score, TARGET_COUNT]
    if _timer_label:
        _timer_label.text = "Time %.1fs" % _time_left


func _show_overlay(title: String, body: String, hint: String) -> void:
    if _overlay_title:
        _overlay_title.text = title
    if _overlay_body:
        _overlay_body.text = body
    if _overlay_hint:
        _overlay_hint.text = hint
    if _overlay:
        _overlay.visible = true
    visible = true


func _hide_overlay() -> void:
    if _overlay:
        _overlay.visible = false
