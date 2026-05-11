extends Control

# Bottom-left HUD terminal. Subscribes to TerminalLog and renders the
# rolling buffer as a faded panel with monospace lines, plus a blinking
# cursor at the very bottom. Built procedurally so we can mount it from
# hud.gd without touching hud.tscn.
#
# Visual contract (per the v2.2 spec in LORE.md):
#   - 320x120 px panel, anchored bottom-left of the HUD CanvasLayer
#   - faded dark background, 0.65 alpha
#   - 6 visible lines, monospace 12pt
#   - lines fade alpha 1.0 → 0.55 as they age (2.5s settle); fully
#     invisible after 5s
#   - "_" cursor blinks at the end of the buffer
#   - never pauses; runs always-on (process_mode = ALWAYS)
#
# This Control is purely a sink — weapon-pipeline agents and other
# systems push into TerminalLog and we re-render. We do NOT push our
# own commands here.

const PANEL_WIDTH: float = 320.0
const PANEL_HEIGHT: float = 120.0
const PANEL_MARGIN: float = 8.0  # gap from screen edges

const PANEL_BG: Color = Color(0.05, 0.06, 0.10, 0.65)

const COLOR_CMD: Color = Color(0.85, 0.92, 0.85, 1.0)
const COLOR_OUTPUT: Color = Color(0.95, 0.85, 0.45, 1.0)
const COLOR_ERR: Color = Color(0.95, 0.40, 0.40, 1.0)

const FONT_SIZE: int = 12

# Age thresholds (seconds). settle = the time over which the alpha
# eases from 1.0 down to AGED_ALPHA. expire = total lifetime; past
# this, the line draws at alpha 0 (effectively gone).
const SETTLE_TIME: float = 2.5
const EXPIRE_TIME: float = 5.0
const AGED_ALPHA: float = 0.55

# Cursor blink — half-period.
const CURSOR_BLINK: float = 0.55

# Visible line count (top of panel = oldest visible, bottom = prompt).
const VISIBLE_LINES: int = 6

# Initial seed line so a fresh boot already looks like a live shell
# rather than an empty box. Per spec.
const SEED_PROMPT_TEXT: String = "tux@wyrdmark:/opt/wyrdmark/glade$ "

var _bg: ColorRect = null
var _text_root: Control = null
var _cursor_label: Label = null
var _cursor_visible: bool = true
var _cursor_t: float = 0.0
# Cached current scene path so we only push set_cwd() to the autoload
# when it actually changes (scene transitions). Watched in _process.
var _last_scene_path: String = ""


func _ready() -> void:
    # Always-on. Pause overlay should not freeze the corner, so the
    # player can still see the most recent command after pausing.
    process_mode = Node.PROCESS_MODE_ALWAYS
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    name = "TerminalCorner"

    # Anchor bottom-left of the parent CanvasLayer. Using anchors so
    # the panel stays glued to the corner across viewport resizes.
    anchor_left = 0.0
    anchor_top = 1.0
    anchor_right = 0.0
    anchor_bottom = 1.0
    offset_left = PANEL_MARGIN
    offset_top = -PANEL_HEIGHT - PANEL_MARGIN
    offset_right = PANEL_MARGIN + PANEL_WIDTH
    offset_bottom = -PANEL_MARGIN
    custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)

    _bg = ColorRect.new()
    _bg.name = "Bg"
    _bg.color = PANEL_BG
    _bg.anchor_right = 1.0
    _bg.anchor_bottom = 1.0
    _bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_bg)

    _text_root = Control.new()
    _text_root.name = "TextRoot"
    _text_root.anchor_right = 1.0
    _text_root.anchor_bottom = 1.0
    _text_root.offset_left = 6.0
    _text_root.offset_top = 4.0
    _text_root.offset_right = -6.0
    _text_root.offset_bottom = -4.0
    _text_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_text_root)

    # The blinking cursor lives in its own pinned label at the bottom.
    # We swap its text between "_" and " " in _process so the line
    # rebuild path doesn't have to think about it.
    _cursor_label = Label.new()
    _cursor_label.name = "Cursor"
    _cursor_label.add_theme_font_size_override("font_size", FONT_SIZE)
    _cursor_label.add_theme_color_override("font_color", COLOR_CMD)
    _cursor_label.text = SEED_PROMPT_TEXT + "_"
    _cursor_label.anchor_left = 0.0
    _cursor_label.anchor_top = 1.0
    _cursor_label.anchor_right = 1.0
    _cursor_label.anchor_bottom = 1.0
    _cursor_label.offset_left = 6.0
    _cursor_label.offset_top = -16.0
    _cursor_label.offset_right = -6.0
    _cursor_label.offset_bottom = -2.0
    _cursor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_cursor_label)

    # Wire signals from the autoload. Both hooks just trigger a
    # redraw; the autoload owns the buffer.
    if Engine.has_singleton("TerminalLog") or _has_terminal_log():
        TerminalLog.line_added.connect(_on_line_added)
        TerminalLog.cleared.connect(_redraw)

    _sync_cwd_from_scene()
    _redraw()


# Engine.has_singleton is for native singletons; autoloaded scripts
# show up as named globals instead. Defensive guard so headless boots
# without the autoload (test harnesses, etc.) don't crash.
func _has_terminal_log() -> bool:
    var root := get_tree().root if get_tree() != null else null
    return root != null and root.has_node("TerminalLog")


func _process(delta: float) -> void:
    _cursor_t += delta
    if _cursor_t >= CURSOR_BLINK:
        _cursor_t = 0.0
        _cursor_visible = not _cursor_visible
        _refresh_cursor_text()

    # Age every line in the autoload's buffer. We mutate the dict
    # in-place — `lines` is a typed Array[Dictionary], so the entries
    # are references and the autoload sees the bumped age too.
    if _has_terminal_log():
        var any_changed: bool = false
        for entry in TerminalLog.lines:
            entry["age"] = float(entry.get("age", 0.0)) + delta
            any_changed = true
        if any_changed:
            _redraw_lines_only()

    # Cheap scene-path watch. Done here (rather than via a signal)
    # because there is no global "scene changed" signal in Godot 4 —
    # we just sample current_scene.scene_file_path each frame.
    _sync_cwd_from_scene()


func _refresh_cursor_text() -> void:
    if _cursor_label == null:
        return
    var prompt_str: String = TerminalLog.prompt() if _has_terminal_log() else SEED_PROMPT_TEXT
    _cursor_label.text = prompt_str + ("_" if _cursor_visible else " ")


func _on_line_added(_text: String, _kind: String) -> void:
    _redraw()


# Full rebuild. Drops every label under _text_root and lays out the
# current buffer fresh. Called on line_added, cleared, and at boot.
# The per-frame age tick uses the lighter `_redraw_lines_only` to
# avoid teardown thrash.
func _redraw() -> void:
    _redraw_lines_only()
    _refresh_cursor_text()


# Light path: refresh the existing slot labels in place without
# tearing them down. Called every frame from _process so aging fades
# update smoothly; allocating + queue_free()ing 6 labels per frame
# would be silly. We pre-allocate VISIBLE_LINES slot labels lazily
# and just rewrite their text/color/visibility each tick.
func _redraw_lines_only() -> void:
    if _text_root == null:
        return
    _ensure_slot_labels()
    if not _has_terminal_log():
        for s in VISIBLE_LINES:
            (_text_root.get_child(s) as Label).visible = false
        return

    var buf: Array = TerminalLog.lines
    # Render from the newest VISIBLE_LINES, oldest first so the most
    # recent lands just above the cursor. The cursor itself is its
    # own pinned label below this stack.
    var start: int = max(0, buf.size() - VISIBLE_LINES)
    var visible_count: int = buf.size() - start
    for slot in VISIBLE_LINES:
        var lbl: Label = _text_root.get_child(slot) as Label
        if slot >= visible_count:
            lbl.visible = false
            continue
        var entry: Dictionary = buf[start + slot]
        var age: float = float(entry.get("age", 0.0))
        if age >= EXPIRE_TIME:
            lbl.visible = false
            continue
        # Alpha curve: full for 0..settle, then ease down to AGED_ALPHA
        # by EXPIRE_TIME. Linear is fine here — the eye doesn't read
        # the difference and the math is one less line.
        var a: float = 1.0
        if age >= SETTLE_TIME:
            var t: float = clampf((age - SETTLE_TIME) / (EXPIRE_TIME - SETTLE_TIME), 0.0, 1.0)
            a = lerp(1.0, AGED_ALPHA, t)
        var col: Color = _color_for(String(entry.get("kind", "cmd")))
        col.a *= a
        lbl.add_theme_color_override("font_color", col)
        lbl.text = _format_entry(entry)
        lbl.visible = true


# Pre-allocate the VISIBLE_LINES slot labels once. Each slot is
# pinned to its row position; _redraw_lines_only rewrites the text
# and color in-place and toggles visibility.
func _ensure_slot_labels() -> void:
    while _text_root.get_child_count() < VISIBLE_LINES:
        var slot: int = _text_root.get_child_count()
        var lbl := Label.new()
        lbl.add_theme_font_size_override("font_size", FONT_SIZE)
        lbl.add_theme_color_override("font_color", COLOR_CMD)
        lbl.anchor_left = 0.0
        lbl.anchor_top = 0.0
        lbl.anchor_right = 1.0
        lbl.anchor_bottom = 0.0
        lbl.offset_top = float(slot) * 16.0
        lbl.offset_bottom = lbl.offset_top + 16.0
        lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
        lbl.visible = false
        lbl.text = ""
        _text_root.add_child(lbl)


func _color_for(kind: String) -> Color:
    match kind:
        "output":
            return COLOR_OUTPUT
        "err":
            return COLOR_ERR
        _:
            return COLOR_CMD


# Pretty per-line format. Commands get a `$ ` prompt prefix so the
# scrollback looks like a real shell session; output and errors land
# bare. We deliberately do NOT pre-pend the full `tux@wyrdmark:cwd$`
# prompt to historical lines (only to the live cursor row) — that
# keeps the column readable inside 320px without the prompt eating
# the whole width.
func _format_entry(entry: Dictionary) -> String:
    var text: String = String(entry.get("text", ""))
    var kind: String = String(entry.get("kind", "cmd"))
    if kind == "cmd":
        return "$ " + text
    return text


# Walk the current scene name into a faux filesystem path. Most
# scenes live under /opt/wyrdmark; a few special ones (intro,
# main_menu, credits) we leave as the default since the player isn't
# really "in" the world there. The mapping is intentionally light —
# the corner is texture, not a game-state reflector.
func _sync_cwd_from_scene() -> void:
    if get_tree() == null:
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    var p: String = scene.scene_file_path
    if p == _last_scene_path:
        return
    _last_scene_path = p
    var leaf: String = p
    if leaf.begins_with("res://scenes/"):
        leaf = leaf.substr("res://scenes/".length())
    if leaf.ends_with(".tscn"):
        leaf = leaf.substr(0, leaf.length() - ".tscn".length())
    if leaf == "" or leaf == "main_menu" or leaf == "credits" or leaf == "intro":
        return  # leave the cwd alone for non-world scenes
    if _has_terminal_log():
        TerminalLog.set_cwd("/opt/wyrdmark/" + leaf)
