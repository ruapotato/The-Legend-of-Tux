extends CanvasLayer

# Opening cutscene. Plays once when the player picks "New Game" on the
# main menu, before wyrdkin_glade loads. Skippable with any input —
# pressing anything fast-forwards to the final fade so the player still
# gets a clean transition into the game world (rather than a hard cut).
#
# Storyboard (~30s total, designed for OoT-style title-card pacing):
#   1. 0.5s   Black fade-in.
#   2. 3.0s   Title card "THE LEGEND OF TUX" (gold).
#   3. 2.0s   Subtitle "in the realm of the Wyrdmark" fades in beneath.
#   4. 4 x 3s Narrator lines over a dark glade silhouette.
#   5. 3.0s   Glim — a small bright dot — drifts in from screen-right
#             and pulses once before settling at the center.
#   6. 1.5s   "Press any key" prompt.
#   7. 0.8s   Fade to black, then change_scene_to_file → wyrdkin_glade.
#
# Visual primitives only: ColorRect for backgrounds / overlays / Glim,
# Label for narrator + title text. No 3D, no models. The glade silhouette
# is a stack of low-saturation green/grey ColorRects suggesting tree
# shapes against a near-black sky — enough to read as "forest at dusk."
#
# If GameState.show_intro is false on _ready (i.e. someone routed here
# without setting the flag — a Loaded save shouldn't), we hop straight
# to the destination so we never strand the player on a black screen.

const DEST_SCENE: String = "res://scenes/level_00.tscn"
const DEST_TRACK: String = "level_00"

const NARRATION: Array[String] = [
    "The Source moved through the realm,",
    "and through one Wyrdkin, sleeping.",
    "Then the wisp came.",
    "And the realm asked something of him.",
]

const TITLE_GOLD := Color(0.96, 0.83, 0.36, 1)
const SUBTITLE_DIM := Color(0.78, 0.74, 0.55, 1)
const NARRATOR_PALE := Color(0.92, 0.92, 0.86, 1)
const PROMPT_DIM := Color(0.70, 0.70, 0.62, 1)
const GLIM_GOLD := Color(1.0, 0.92, 0.55, 1)

var _root: Control
var _bg: ColorRect           # base black/sky background
var _silhouette: Control     # holds the glade silhouette rectangles
var _title_label: Label
var _subtitle_label: Label
var _narrator_label: Label
var _prompt_label: Label
var _glim: ColorRect
var _fade: ColorRect         # full-screen overlay used for in/out fades

var _skipped: bool = false
var _finished: bool = false


func _ready() -> void:
    layer = 50
    process_mode = Node.PROCESS_MODE_ALWAYS

    # Bypass: if the flag isn't set we shouldn't be here. Hop to the
    # destination on the next frame so the engine has a chance to finish
    # standing this scene up before we tear it down.
    if not GameState.show_intro:
        call_deferred("_hop_to_destination")
        return
    GameState.show_intro = false

    _build_ui()
    MusicBank.play("title", 0.5)
    _run_storyboard()


# ---- UI construction ---------------------------------------------------

func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _bg = ColorRect.new()
    _bg.color = Color(0.04, 0.05, 0.07, 1)
    _bg.anchor_right = 1.0
    _bg.anchor_bottom = 1.0
    _bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_bg)

    # Glade silhouette: a stack of darker shapes hinting at trees and a
    # ground line. Built once and shown later (modulate.a = 0 until the
    # narration scene begins).
    _silhouette = Control.new()
    _silhouette.anchor_right = 1.0
    _silhouette.anchor_bottom = 1.0
    _silhouette.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _silhouette.modulate = Color(1, 1, 1, 0)
    _root.add_child(_silhouette)
    _build_silhouette()

    # Title.
    _title_label = Label.new()
    _title_label.text = "THE LEGEND OF TUX"
    _title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _title_label.anchor_right = 1.0
    _title_label.anchor_bottom = 1.0
    _title_label.offset_top = 240
    _title_label.offset_bottom = 320
    _title_label.add_theme_font_size_override("font_size", 64)
    _title_label.add_theme_color_override("font_color", TITLE_GOLD)
    _title_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_title_label)

    _subtitle_label = Label.new()
    _subtitle_label.text = "in the realm of the Wyrdmark"
    _subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _subtitle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _subtitle_label.anchor_right = 1.0
    _subtitle_label.anchor_bottom = 1.0
    _subtitle_label.offset_top = 330
    _subtitle_label.offset_bottom = 380
    _subtitle_label.add_theme_font_size_override("font_size", 22)
    _subtitle_label.add_theme_color_override("font_color", SUBTITLE_DIM)
    _subtitle_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_subtitle_label)

    # Narrator caption — single Label re-used line-to-line.
    _narrator_label = Label.new()
    _narrator_label.text = ""
    _narrator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _narrator_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _narrator_label.anchor_right = 1.0
    _narrator_label.anchor_bottom = 1.0
    _narrator_label.offset_top = 540
    _narrator_label.offset_bottom = 620
    _narrator_label.add_theme_font_size_override("font_size", 26)
    _narrator_label.add_theme_color_override("font_color", NARRATOR_PALE)
    _narrator_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_narrator_label)

    # Glim — 32x32 gold dot. Drifts in from screen-right.
    _glim = ColorRect.new()
    _glim.color = GLIM_GOLD
    _glim.size = Vector2(32, 32)
    _glim.position = Vector2(1320, 360 - 16)   # off-screen right
    _glim.modulate = Color(1, 1, 1, 0)
    _glim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_glim)

    _prompt_label = Label.new()
    _prompt_label.text = "Press any key"
    _prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _prompt_label.anchor_right = 1.0
    _prompt_label.anchor_bottom = 1.0
    _prompt_label.offset_top = 660
    _prompt_label.offset_bottom = 700
    _prompt_label.add_theme_font_size_override("font_size", 18)
    _prompt_label.add_theme_color_override("font_color", PROMPT_DIM)
    _prompt_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_prompt_label)

    # Top-level fade overlay (drawn last so it sits over everything).
    _fade = ColorRect.new()
    _fade.color = Color(0, 0, 0, 1)   # starts opaque for the fade-in
    _fade.anchor_right = 1.0
    _fade.anchor_bottom = 1.0
    _fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_fade)


func _build_silhouette() -> void:
    # Ground line.
    var ground := ColorRect.new()
    ground.color = Color(0.06, 0.10, 0.07, 1)
    ground.position = Vector2(0, 520)
    ground.size = Vector2(1280, 200)
    _silhouette.add_child(ground)
    # Tree clumps — dark greens, slightly varied widths and heights so
    # the skyline doesn't read as a single block.
    var trees := [
        Vector2(80, 360), Vector2(220, 300), Vector2(360, 380),
        Vector2(540, 280), Vector2(720, 360), Vector2(880, 320),
        Vector2(1040, 360), Vector2(1180, 300),
    ]
    for i in trees.size():
        var pos: Vector2 = trees[i]
        var trunk := ColorRect.new()
        var w: float = 90.0 + float(i % 3) * 18.0
        var h: float = 520.0 - pos.y
        trunk.color = Color(0.05, 0.09, 0.06, 1)
        trunk.position = Vector2(pos.x - w * 0.5, pos.y)
        trunk.size = Vector2(w, h)
        _silhouette.add_child(trunk)


# ---- Storyboard --------------------------------------------------------

func _run_storyboard() -> void:
    # Each beat is gated by `_skipped`; if the player presses input
    # during the run we bail out into the final fade.
    await _beat_fade_in()
    if _skipped: await _beat_finish(); return
    await _beat_title()
    if _skipped: await _beat_finish(); return
    await _beat_subtitle()
    if _skipped: await _beat_finish(); return
    await _beat_glade_in()
    if _skipped: await _beat_finish(); return
    await _beat_narration()
    if _skipped: await _beat_finish(); return
    await _beat_glim()
    if _skipped: await _beat_finish(); return
    await _beat_prompt()
    await _beat_finish()


func _beat_fade_in() -> void:
    # Background is already drawn under the opaque fade overlay; just
    # tween the overlay's alpha to 0 to reveal it.
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_fade, "color:a", 0.0, 0.5)
    await t.finished


func _beat_title() -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_title_label, "modulate:a", 1.0, 0.6)
    await t.finished
    # Hold.
    await _wait(2.4)


func _beat_subtitle() -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_subtitle_label, "modulate:a", 1.0, 0.7)
    await t.finished
    await _wait(1.3)


func _beat_glade_in() -> void:
    # Push the title up and out, fade in the glade silhouette.
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.set_parallel(true)
    t.tween_property(_title_label, "modulate:a", 0.0, 0.6)
    t.tween_property(_subtitle_label, "modulate:a", 0.0, 0.6)
    t.tween_property(_silhouette, "modulate:a", 1.0, 0.8)
    await t.finished


func _beat_narration() -> void:
    for line in NARRATION:
        if _skipped: return
        _narrator_label.text = line
        _narrator_label.modulate.a = 0.0
        var t_in := create_tween()
        t_in.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t_in.tween_property(_narrator_label, "modulate:a", 1.0, 0.5)
        await t_in.finished
        if _skipped: return
        await _wait(2.0)
        if _skipped: return
        var t_out := create_tween()
        t_out.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t_out.tween_property(_narrator_label, "modulate:a", 0.0, 0.5)
        await t_out.finished


func _beat_glim() -> void:
    # Drift Glim in from off-screen-right to center, then pulse once.
    _glim.modulate.a = 1.0
    var center := Vector2(640 - 16, 360 - 16)
    var t_in := create_tween()
    t_in.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t_in.tween_property(_glim, "position", center, 2.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
    await t_in.finished
    if _skipped: return
    # Pulse: scale up briefly then back down. ColorRect doesn't have a
    # native scale but we can grow/shrink the size around its center.
    var pulse_size := Vector2(64, 64)
    var pulse_pos := center - Vector2(16, 16)
    var t_p := create_tween()
    t_p.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t_p.set_parallel(true)
    t_p.tween_property(_glim, "size", pulse_size, 0.25)
    t_p.tween_property(_glim, "position", pulse_pos, 0.25)
    await t_p.finished
    if _skipped: return
    var t_p2 := create_tween()
    t_p2.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t_p2.set_parallel(true)
    t_p2.tween_property(_glim, "size", Vector2(32, 32), 0.25)
    t_p2.tween_property(_glim, "position", center, 0.25)
    await t_p2.finished


func _beat_prompt() -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_prompt_label, "modulate:a", 1.0, 0.4)
    await t.finished
    await _wait(1.1)


func _beat_finish() -> void:
    if _finished:
        return
    _finished = true
    # Fade to black + crossfade music to the destination track. On a
    # skipped run we keep the fade short so the cut still feels intentional.
    var fade_dur: float = 0.8 if not _skipped else 1.0
    MusicBank.play(DEST_TRACK, fade_dur)
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_fade, "color:a", 1.0, fade_dur)
    await t.finished
    _hop_to_destination()


func _hop_to_destination() -> void:
    get_tree().change_scene_to_file(DEST_SCENE)


# ---- Helpers -----------------------------------------------------------

func _wait(seconds: float) -> void:
    # Skip-aware sleep: returns early if the player skips, so the
    # storyboard can bail to its final fade without waiting out the
    # remaining beat duration.
    var elapsed: float = 0.0
    while elapsed < seconds and not _skipped:
        await get_tree().process_frame
        elapsed += get_process_delta_time()


# ---- Skip-on-input -----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
    if _skipped or _finished:
        return
    # Any key, mouse button, or pad button counts. We deliberately
    # ignore mouse motion so a stray cursor twitch doesn't skip.
    var is_skip: bool = event is InputEventKey and event.pressed \
        or event is InputEventMouseButton and event.pressed \
        or event is InputEventJoypadButton and event.pressed
    if not is_skip:
        return
    _skipped = true
    get_viewport().set_input_as_handled()
