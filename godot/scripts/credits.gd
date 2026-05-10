extends CanvasLayer

# End-of-game credits + lore epilogue. Reached only via
# game_end_watcher.gd when the Sleeper at the Null Door falls. Plays a
# title card, three lore paragraphs, the credit roll, then returns to
# main_menu.tscn.
#
# Built procedurally — same approach as intro.gd — so the .tscn is just
# a CanvasLayer host with this script attached.
#
# Storyboard (~49s total at full pacing):
#   1. 1.5s   Black fade-in.
#   2. 3.0s   Title card "THE WYRDMARK ANSWERS" (gold, 32pt) hold.
#   3. 3 x ~6s  Epilogue paragraphs, fade in / hold / fade out.
#   4. ~25s   Vertical credit roll, slow constant scroll.
#   5. 2.0s   Final fade to black.
#   6.        change_scene_to_file → main_menu.tscn.
#
# Skip-on-input: any key / mouse / pad button sets _skipped, which
# every storyboard beat checks via _wait(); on skip we jump straight to
# the final fade so the cut still feels intentional.

const DEST_SCENE: String = "res://scenes/main_menu.tscn"
const DEST_TRACK: String = "crown"   # calm reverent track; silent if missing.

const TITLE_TEXT: String = "THE WYRDMARK ANSWERS"
const TITLE_GOLD := Color(0.96, 0.83, 0.36, 1)
const PARAGRAPH_PALE := Color(0.92, 0.92, 0.86, 1)
const CREDIT_PALE := Color(0.88, 0.88, 0.82, 1)
const CREDIT_DIM := Color(0.70, 0.70, 0.62, 1)

# Beat durations. Kept as constants so adjusting pacing is a one-line
# change — the storyboard composes them rather than hard-coding numbers.
const FADE_IN_DUR: float = 1.5
const TITLE_HOLD_DUR: float = 3.0
const PARAGRAPH_FADE_DUR: float = 0.8     # in OR out
const PARAGRAPH_HOLD_DUR: float = 4.4     # 0.8 + 4.4 + 0.8 ≈ 6s per paragraph
const CREDIT_SCROLL_DUR: float = 25.0
const FINAL_FADE_DUR: float = 2.0

const PARAGRAPHS: Array[String] = [
    "Init turned in his long sleep, and the realm exhaled. The Source moved freely again. The Wyrdkin in the Glade woke a second time, with a dream he could not name.",
    "Lirien returned to her chamber. Khorgaul's hold stayed cold. And Glim, who had carried the Triglyph as far as a wisp can carry anything, pulsed once and was still.",
    "The realm continues. The chord persists. And the door at the end of the Forge remains closed -- by choice, this time, not by force.",
]

# Each entry is [text, font_size]. Headline first, then crew lines.
const CREDIT_ENTRIES: Array = [
    ["THE LEGEND OF TUX", 56],
    ["", 28],
    ["Game Direction", 22],
    ["David", 28],
    ["", 28],
    ["Code & Worldbuilding", 22],
    ["Claude (Anthropic)", 28],
    ["", 28],
    ["Built in Godot 4.5", 22],
    ["", 56],
    ["Tux is a trademark of Linus Torvalds", 18],
    ["", 12],
    ["The Wyrdmark is fictional.", 18],
    ["Any resemblance to real Unix filesystems is intentional.", 18],
]

var _root: Control
var _bg: ColorRect              # opaque black backdrop (always at the bottom)
var _title_label: Label
var _paragraph_label: Label
var _credit_box: VBoxContainer  # the scrolling stack
var _credit_clip: Control       # viewport-clip parent for the scrolling stack
var _fade: ColorRect            # full-screen overlay used for in/out fades

var _skipped: bool = false
var _finished: bool = false


func _ready() -> void:
    layer = 50
    process_mode = Node.PROCESS_MODE_ALWAYS

    _build_ui()
    MusicBank.play(DEST_TRACK, 1.0)
    _run_storyboard()


# ---- UI construction ---------------------------------------------------

func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    # Pure-black backdrop — ALWAYS present at the bottom so the credits
    # don't blend into whatever was on screen when the boss fanfare
    # ended.
    _bg = ColorRect.new()
    _bg.color = Color(0, 0, 0, 1)
    _bg.anchor_right = 1.0
    _bg.anchor_bottom = 1.0
    _bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_bg)

    # Title — centered, gold, 32pt as spec'd.
    _title_label = Label.new()
    _title_label.text = TITLE_TEXT
    _title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _title_label.anchor_right = 1.0
    _title_label.anchor_bottom = 1.0
    _title_label.offset_top = 320
    _title_label.offset_bottom = 400
    _title_label.add_theme_font_size_override("font_size", 32)
    _title_label.add_theme_color_override("font_color", TITLE_GOLD)
    _title_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_title_label)

    # Paragraph slot — re-used line-to-line. Wraps at the viewport
    # width with comfortable margins so long sentences don't run edge
    # to edge.
    _paragraph_label = Label.new()
    _paragraph_label.text = ""
    _paragraph_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _paragraph_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _paragraph_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _paragraph_label.anchor_right = 1.0
    _paragraph_label.anchor_bottom = 1.0
    _paragraph_label.offset_left = 160
    _paragraph_label.offset_right = -160
    _paragraph_label.offset_top = 240
    _paragraph_label.offset_bottom = 480
    _paragraph_label.add_theme_font_size_override("font_size", 24)
    _paragraph_label.add_theme_color_override("font_color", PARAGRAPH_PALE)
    _paragraph_label.modulate = Color(1, 1, 1, 0)
    _root.add_child(_paragraph_label)

    # Credit roll. The clip control keeps the scrolling box visually
    # bounded to the screen even though Godot's default Control already
    # doesn't draw outside its rect — the clip child explicitly
    # enables clip_contents so any tall VBox child still respects it.
    _credit_clip = Control.new()
    _credit_clip.anchor_right = 1.0
    _credit_clip.anchor_bottom = 1.0
    _credit_clip.clip_contents = true
    _credit_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _credit_clip.modulate = Color(1, 1, 1, 0)   # hidden until its beat
    _root.add_child(_credit_clip)

    _credit_box = VBoxContainer.new()
    _credit_box.alignment = BoxContainer.ALIGNMENT_CENTER
    _credit_box.add_theme_constant_override("separation", 14)
    # Use a fixed width via custom_minimum_size rather than anchors so
    # Godot doesn't warn about non-equal opposite anchors when we tween
    # position.y by hand. The box auto-sizes vertically to its labels.
    _credit_box.custom_minimum_size = Vector2(1280, 0)
    # Start the box just below the bottom of the screen so the first
    # line slides UP into view. The tween moves position.y upward.
    _credit_box.position = Vector2(0, 720)
    _credit_clip.add_child(_credit_box)
    _build_credit_entries()

    # Top-level fade overlay — drawn last so it covers everything else.
    _fade = ColorRect.new()
    _fade.color = Color(0, 0, 0, 1)   # starts opaque for the fade-in
    _fade.anchor_right = 1.0
    _fade.anchor_bottom = 1.0
    _fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_fade)


func _build_credit_entries() -> void:
    for entry in CREDIT_ENTRIES:
        var text: String = entry[0]
        var size: int = entry[1]
        var lbl := Label.new()
        lbl.text = text
        lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        lbl.add_theme_font_size_override("font_size", size)
        # Headline / large lines use the warm pale; smaller body lines
        # (the Tux trademark + Wyrdmark fiction notes) read in dimmer
        # grey to feel like a footer.
        var color: Color = CREDIT_PALE if size >= 22 else CREDIT_DIM
        lbl.add_theme_color_override("font_color", color)
        # Spacer rows (empty text) need a little vertical slot so the
        # gap actually shows; without a min size an empty Label collapses.
        if text == "":
            lbl.custom_minimum_size = Vector2(0, float(size))
        _credit_box.add_child(lbl)


# ---- Storyboard --------------------------------------------------------

func _run_storyboard() -> void:
    await _beat_fade_in()
    if _skipped: await _beat_finish(); return
    await _beat_title()
    if _skipped: await _beat_finish(); return
    await _beat_paragraphs()
    if _skipped: await _beat_finish(); return
    await _beat_credit_roll()
    await _beat_finish()


func _beat_fade_in() -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_fade, "color:a", 0.0, FADE_IN_DUR)
    await t.finished


func _beat_title() -> void:
    var t_in := create_tween()
    t_in.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t_in.tween_property(_title_label, "modulate:a", 1.0, 0.6)
    await t_in.finished
    if _skipped: return
    await _wait(TITLE_HOLD_DUR)
    if _skipped: return
    var t_out := create_tween()
    t_out.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t_out.tween_property(_title_label, "modulate:a", 0.0, 0.6)
    await t_out.finished


func _beat_paragraphs() -> void:
    for line in PARAGRAPHS:
        if _skipped: return
        _paragraph_label.text = line
        _paragraph_label.modulate.a = 0.0
        var t_in := create_tween()
        t_in.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t_in.tween_property(_paragraph_label, "modulate:a", 1.0, PARAGRAPH_FADE_DUR)
        await t_in.finished
        if _skipped: return
        await _wait(PARAGRAPH_HOLD_DUR)
        if _skipped: return
        var t_out := create_tween()
        t_out.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t_out.tween_property(_paragraph_label, "modulate:a", 0.0, PARAGRAPH_FADE_DUR)
        await t_out.finished


func _beat_credit_roll() -> void:
    # Reveal the credit clip, then tween its child VBox upward by an
    # amount that pushes the last line off the top. The VBox auto-sized
    # to its children when added; we read that size now.
    _credit_clip.modulate.a = 1.0
    # Force a layout pass so the VBox knows its real height.
    await get_tree().process_frame
    await get_tree().process_frame
    var stack_height: float = _credit_box.size.y
    # Travel: from y = 720 (start, fully below) to y = -(stack_height)
    # (last line just off the top). That way every line gets equal
    # screen time regardless of total content length.
    var end_y: float = -stack_height - 40.0
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_credit_box, "position:y", end_y, CREDIT_SCROLL_DUR).set_trans(Tween.TRANS_LINEAR)
    # Skip-aware: rather than awaiting the full tween, poll so a skip
    # press during the long roll bails immediately.
    var elapsed: float = 0.0
    while elapsed < CREDIT_SCROLL_DUR and not _skipped:
        await get_tree().process_frame
        elapsed += get_process_delta_time()
    if _skipped:
        t.kill()


func _beat_finish() -> void:
    if _finished:
        return
    _finished = true
    # Fade music down in parallel with the visual fade so we don't hand
    # off into the menu with the credits track still blaring.
    MusicBank.stop(FINAL_FADE_DUR)
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_fade, "color:a", 1.0, FINAL_FADE_DUR)
    await t.finished
    _hop_to_destination()


func _hop_to_destination() -> void:
    get_tree().change_scene_to_file(DEST_SCENE)


# ---- Helpers -----------------------------------------------------------

func _wait(seconds: float) -> void:
    # Skip-aware sleep — returns early so the storyboard can bail to
    # its final fade without waiting out the remaining beat duration.
    var elapsed: float = 0.0
    while elapsed < seconds and not _skipped:
        await get_tree().process_frame
        elapsed += get_process_delta_time()


# ---- Skip-on-input -----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
    if _skipped or _finished:
        return
    var is_skip: bool = event is InputEventKey and event.pressed \
        or event is InputEventMouseButton and event.pressed \
        or event is InputEventJoypadButton and event.pressed
    if not is_skip:
        return
    _skipped = true
    get_viewport().set_input_as_handled()
