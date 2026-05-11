extends Node

# Autoloaded sink for the bottom-left terminal corner. Other systems
# (weapons, doors, chests, scene loaders) push lines into this log via
# `cmd()`, `output()`, or `err()`; `terminal_corner.gd` listens to the
# `line_added` signal and renders the rolling buffer.
#
# This autoload owns NO presentation. It is a pure pub/sub buffer:
#   - `lines` is the rolling history (newest at the end)
#   - `line_added` fires whenever a line is appended
#   - `cleared` fires when the buffer is wiped (rare; used on hard scene
#     resets so the corner doesn't carry stale text into a fresh load)
#
# Pipeline / weapon agents are expected to format their own pretty
# command text — e.g. the bow agent will push something like
#   TerminalLog.cmd("ps aux | grep bone_bat | kill")
# and a follow-up
#   TerminalLog.output("[ok]")
# This keeps shell-flavor decisions out of the HUD layer.

signal line_added(line: String, kind: String)
signal cleared()

# {text: String, kind: String, age: float}
# `age` starts at 0 and is bumped by terminal_corner.gd's per-frame
# tick. We keep it on the entry (rather than as a parallel array) so
# the corner can iterate the buffer once and decide alpha per line.
var lines: Array[Dictionary] = []

const MAX_LINES: int = 8

# Working directory shown in the prompt prefix. terminal_corner.gd
# rebuilds the prompt from `cwd` whenever a new line lands; weapon
# agents don't have to worry about formatting `tux@wyrdmark:...$`.
# Updated by `set_cwd()` (called from a scene-change watcher in the
# corner, via current_scene.scene_file_path).
var cwd: String = "/opt/wyrdmark/glade"


func cmd(text: String) -> void:
    _push(text, "cmd")


func output(text: String) -> void:
    _push(text, "output")


func err(text: String) -> void:
    _push(text, "err")


func clear() -> void:
    lines.clear()
    cleared.emit()


# Internal: append + trim + signal. Kept private so weapon agents
# can't accidentally invent a fourth `kind` value the corner has no
# color for.
func _push(text: String, kind: String) -> void:
    var entry: Dictionary = {
        "text": text,
        "kind": kind,
        "age": 0.0,
    }
    lines.append(entry)
    while lines.size() > MAX_LINES:
        lines.pop_front()
    line_added.emit(text, kind)


# Update the prompt path. terminal_corner.gd calls this when the
# current scene changes; we also expose it publicly so the dungeon
# loader can tighten the path (e.g. `/opt/wyrdmark/glade/cache_4`)
# at finer granularity than the scene file alone implies.
func set_cwd(path: String) -> void:
    if path == "" or path == cwd:
        return
    cwd = path


# Convenience for the corner: full prompt prefix as a string. Kept
# here so the formatting lives next to `cwd`, not in two places.
func prompt() -> String:
    return "tux@wyrdmark:%s$ " % cwd
