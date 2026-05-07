extends CanvasLayer

# Autoloaded full-screen fade-to-black + scene transition. Survives
# scene changes (PROCESS_MODE_ALWAYS) so the curtain stays drawn while
# Godot swaps the tree underneath.
#
#   SceneFader.change_scene("res://scenes/foo.tscn")
#
# fades to black, calls change_scene_to_file, waits a frame, then
# fades back to clear. Anything else can call fade_to(alpha, dur) for
# UI moments.

const FADE_DURATION: float = 0.35

var _rect: ColorRect


func _ready() -> void:
    layer = 100
    process_mode = Node.PROCESS_MODE_ALWAYS
    _rect = ColorRect.new()
    _rect.color = Color(0, 0, 0, 0)
    _rect.anchor_right = 1.0
    _rect.anchor_bottom = 1.0
    _rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_rect)


func change_scene(target_path: String, fade_in: float = FADE_DURATION, fade_out: float = FADE_DURATION) -> void:
    var t1 := create_tween()
    t1.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t1.tween_property(_rect, "color:a", 1.0, fade_in)
    await t1.finished
    get_tree().change_scene_to_file(target_path)
    # Wait for the new scene to finish its first _ready cycle, then
    # fade the curtain back out.
    await get_tree().process_frame
    await get_tree().process_frame
    var t2 := create_tween()
    t2.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t2.tween_property(_rect, "color:a", 0.0, fade_out)


func fade_to(alpha: float, duration: float = FADE_DURATION) -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(_rect, "color:a", clamp(alpha, 0.0, 1.0), duration)
