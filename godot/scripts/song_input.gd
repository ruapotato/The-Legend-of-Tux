extends CanvasLayer

# OoT-ocarina-style 5-glyph picker. Built procedurally so the matching
# .tscn only needs to instance the script. On open the tree is paused
# (so the player can hum without the world ticking); the picker hovers
# above any pause-menu underneath at layer 95.
#
# Inputs:
#   ui_up / ui_down / ui_left / ui_right      → push that glyph
#   ui_select (Space)                          → push center diamond
#   ui_cancel (Esc)                            → close without playing
#   ui_accept (Enter) / on the 5th pick        → submit
#   Backspace                                  → undo last pick
#
# Submission rules:
#   - Exact 5-glyph match → if the song is unknown, fire the "learned"
#     animation + GameState.learn_song + the song's effect. If known,
#     just play the effect with the gentler "song_play" sting.
#   - No match → close with a soft "no melody recognized" message.
#
# Open it from anywhere with:
#   var picker := load("res://scenes/song_input.tscn").instantiate()
#   get_tree().current_scene.add_child(picker)

const BACKDROP_COLOR := Color(0.05, 0.04, 0.10, 0.92)
const PANEL_COLOR    := Color(0.10, 0.09, 0.16, 0.98)
const TITLE_COLOR    := Color(0.98, 0.93, 0.55, 1.0)
const LABEL_COLOR    := Color(0.92, 0.90, 0.85, 1.0)
const HINT_COLOR     := Color(0.72, 0.70, 0.65, 1.0)
const SLOT_EMPTY     := Color(0.20, 0.18, 0.26, 1.0)
const SLOT_FILLED    := Color(0.45, 0.38, 0.18, 1.0)
const FLASH_LEARNED  := Color(1.00, 0.85, 0.30, 1.0)
const FLASH_KNOWN    := Color(0.55, 0.85, 1.00, 1.0)

# Order matches SongBook.GLYPH_* constants — used by the on-screen
# button strip so picker[0] is always "up", picker[1] "down", etc.
const PICKER_ORDER: Array[String] = ["up", "down", "left", "right", "center"]

var _was_mouse_captured: bool = false
var _was_paused: bool = false

var _root: Control
var _slots: Array[ColorRect] = []     # 5 visual slots
var _slot_labels: Array[Label] = []   # glyph text inside each slot
var _status_label: Label
var _flash_panel: ColorRect
var _sequence: Array = []
var _closed: bool = false


func _ready() -> void:
    layer = 95
    process_mode = Node.PROCESS_MODE_ALWAYS
    _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
    _was_paused = get_tree().paused
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().paused = true
    _build_ui()


func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right  = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter  = Control.MOUSE_FILTER_STOP
    add_child(_root)

    var bg := ColorRect.new()
    bg.color = BACKDROP_COLOR
    bg.anchor_right  = 1.0
    bg.anchor_bottom = 1.0
    _root.add_child(bg)

    # Centered panel.
    var panel := ColorRect.new()
    panel.color = PANEL_COLOR
    panel.anchor_left  = 0.5
    panel.anchor_top   = 0.5
    panel.anchor_right = 0.5
    panel.anchor_bottom = 0.5
    panel.offset_left   = -360.0
    panel.offset_right  =  360.0
    panel.offset_top    = -180.0
    panel.offset_bottom =  180.0
    _root.add_child(panel)

    # Flash overlay used to colorize the panel briefly on submit.
    _flash_panel = ColorRect.new()
    _flash_panel.color = Color(1, 1, 1, 0)
    _flash_panel.anchor_right  = 1.0
    _flash_panel.anchor_bottom = 1.0
    _flash_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
    panel.add_child(_flash_panel)

    var title := Label.new()
    title.text = "Hum a Song"
    title.anchor_left  = 0.0
    title.anchor_right = 1.0
    title.offset_top    = 12.0
    title.offset_bottom = 56.0
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 28)
    title.add_theme_color_override("font_color", TITLE_COLOR)
    panel.add_child(title)

    # The 5 slot indicator squares — one per glyph the player will pick.
    var slot_strip := HBoxContainer.new()
    slot_strip.alignment = BoxContainer.ALIGNMENT_CENTER
    slot_strip.add_theme_constant_override("separation", 12)
    slot_strip.anchor_left  = 0.0
    slot_strip.anchor_right = 1.0
    slot_strip.offset_top    = 60.0
    slot_strip.offset_bottom = 120.0
    panel.add_child(slot_strip)
    for i in SongBook.SONG_LENGTH:
        var slot_holder := Control.new()
        slot_holder.custom_minimum_size = Vector2(56, 56)
        slot_strip.add_child(slot_holder)
        var rect := ColorRect.new()
        rect.color = SLOT_EMPTY
        rect.anchor_right  = 1.0
        rect.anchor_bottom = 1.0
        slot_holder.add_child(rect)
        _slots.append(rect)
        var lbl := Label.new()
        lbl.text = ""
        lbl.anchor_right  = 1.0
        lbl.anchor_bottom = 1.0
        lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
        lbl.add_theme_font_size_override("font_size", 32)
        lbl.add_theme_color_override("font_color", LABEL_COLOR)
        lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
        slot_holder.add_child(lbl)
        _slot_labels.append(lbl)

    # 5-button glyph picker. Each button presses a single glyph.
    var picker_strip := HBoxContainer.new()
    picker_strip.alignment = BoxContainer.ALIGNMENT_CENTER
    picker_strip.add_theme_constant_override("separation", 8)
    picker_strip.anchor_left  = 0.0
    picker_strip.anchor_right = 1.0
    picker_strip.offset_top    = 140.0
    picker_strip.offset_bottom = 210.0
    panel.add_child(picker_strip)
    for g in PICKER_ORDER:
        var b := Button.new()
        b.text = String(SongBook.GLYPH_GLYPH.get(g, g))
        b.custom_minimum_size = Vector2(64, 64)
        b.add_theme_font_size_override("font_size", 28)
        b.focus_mode = Control.FOCUS_NONE
        b.pressed.connect(_on_pick_button.bind(String(g)))
        picker_strip.add_child(b)

    # Status / hint area.
    _status_label = Label.new()
    _status_label.text = ""
    _status_label.anchor_left  = 0.0
    _status_label.anchor_right = 1.0
    _status_label.offset_top    = 220.0
    _status_label.offset_bottom = 250.0
    _status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _status_label.add_theme_color_override("font_color", LABEL_COLOR)
    panel.add_child(_status_label)

    var hint := Label.new()
    hint.text = "[↑ ↓ ← →] glyph    [Space] ◇    [Enter] hum    [Backspace] undo    [Esc] close"
    hint.anchor_left  = 0.0
    hint.anchor_right = 1.0
    hint.offset_top    = 280.0
    hint.offset_bottom = 310.0
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.add_theme_font_size_override("font_size", 13)
    hint.add_theme_color_override("font_color", HINT_COLOR)
    panel.add_child(hint)


# ---- Input --------------------------------------------------------------

func _input(event: InputEvent) -> void:
    if _closed:
        return
    if event.is_action_pressed("ui_cancel"):
        get_viewport().set_input_as_handled()
        _close()
        return
    if event.is_action_pressed("ui_up"):
        get_viewport().set_input_as_handled()
        _push_glyph(SongBook.GLYPH_UP)
        return
    if event.is_action_pressed("ui_down"):
        get_viewport().set_input_as_handled()
        _push_glyph(SongBook.GLYPH_DOWN)
        return
    if event.is_action_pressed("ui_left"):
        get_viewport().set_input_as_handled()
        _push_glyph(SongBook.GLYPH_LEFT)
        return
    if event.is_action_pressed("ui_right"):
        get_viewport().set_input_as_handled()
        _push_glyph(SongBook.GLYPH_RIGHT)
        return
    if event.is_action_pressed("ui_select"):
        # ui_select = Space. Used for the diamond (reserved future use).
        get_viewport().set_input_as_handled()
        _push_glyph(SongBook.GLYPH_CENTER)
        return
    if event.is_action_pressed("ui_accept"):
        # Manual submit. Most flows auto-submit when the 5th glyph lands;
        # this is here for the "close before 5" safety hatch (which today
        # just submits the partial sequence, which can never match → soft
        # dismiss). Keeps the keyboard contract obvious.
        get_viewport().set_input_as_handled()
        _submit()
        return
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_BACKSPACE:
            get_viewport().set_input_as_handled()
            _pop_glyph()


func _on_pick_button(glyph: String) -> void:
    _push_glyph(glyph)


# ---- Sequence ----------------------------------------------------------

func _push_glyph(glyph: String) -> void:
    if _sequence.size() >= SongBook.SONG_LENGTH:
        return
    _sequence.append(glyph)
    var idx: int = _sequence.size() - 1
    if idx < _slots.size():
        _slots[idx].color = SLOT_FILLED
        _slot_labels[idx].text = String(SongBook.GLYPH_GLYPH.get(glyph, "?"))
    # Per-glyph blip — cycles through the 4 numbered glyph SFX so a
    # 5-note song doesn't sound monotone. If the WAV is missing,
    # SoundBank silently no-ops.
    var blip_idx: int = (idx % 4) + 1
    SoundBank.play_2d("song_glyph_%d" % blip_idx)
    if _sequence.size() >= SongBook.SONG_LENGTH:
        # Slight defer so the final glyph visibly snaps in before the
        # match flash overwrites the panel.
        call_deferred("_submit")


func _pop_glyph() -> void:
    if _sequence.is_empty():
        return
    var idx: int = _sequence.size() - 1
    _sequence.pop_back()
    if idx < _slots.size():
        _slots[idx].color = SLOT_EMPTY
        _slot_labels[idx].text = ""


func _submit() -> void:
    if _closed:
        return
    var match_song: Dictionary = SongBook.match_sequence(_sequence)
    if match_song.is_empty():
        _status_label.text = "(no melody recognized)"
        _flash(Color(0.6, 0.2, 0.2, 0.4))
        # Brief pause so the player sees the rejection before the
        # picker dismisses itself.
        await _wait(0.55)
        _close()
        return
    var song_id: String = String(match_song.get("id", ""))
    var was_unknown: bool = not GameState.has_song(song_id)
    if was_unknown:
        GameState.learn_song(song_id)
        _status_label.text = "Learned: %s" % String(match_song.get("name", song_id))
        SoundBank.play_2d("song_learned")
        _flash(FLASH_LEARNED)
    else:
        _status_label.text = "♪ %s" % String(match_song.get("name", song_id))
        SoundBank.play_2d("song_play")
        _flash(FLASH_KNOWN)
    # Run the song's effect after the visual flash starts so the player
    # gets feedback that *something* happened even if the effect's own
    # signal fires off-screen.
    var effect: Variant = match_song.get("effect", null)
    if effect is Callable and (effect as Callable).is_valid():
        (effect as Callable).call()
    await _wait(0.85 if was_unknown else 0.55)
    _close()


func _flash(color: Color) -> void:
    if _flash_panel == null:
        return
    _flash_panel.color = Color(color.r, color.g, color.b, 0.55)
    var tw := create_tween()
    tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    tw.tween_property(_flash_panel, "color",
        Color(color.r, color.g, color.b, 0.0), 0.6)


func _wait(seconds: float) -> void:
    # Tree's create_timer respects paused state when given the second
    # arg; we want it to tick because the picker pauses the tree.
    await get_tree().create_timer(seconds, true, true).timeout


# ---- Close --------------------------------------------------------------

func _close() -> void:
    if _closed:
        return
    _closed = true
    if not _was_paused:
        get_tree().paused = false
    if _was_mouse_captured:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    queue_free()
