extends Node

# Global time-of-day clock. Advances `t` (0..1, where 0 = midnight,
# 0.5 = noon) on a configurable real-time period. Provides sun
# direction, sun colour, ambient colour and ambient energy that
# dungeon_root applies to the scene's DirectionalLight3D and
# WorldEnvironment each frame for a smooth day/night cycle.
#
# Designed so callers can also force time of day:
#   - `set_t(0.5)` on entering an overworld at "noon"
#   - `advance_to(0.0)` to fast-forward to midnight (warp song stub)
#   - `pause()` / `resume()` while a cinematic plays
#
# Defaults to 10 minutes real-time per game day, starting at morning.

signal hour_passed(t: float)

const DAY_LENGTH_SEC: float = 600.0

var t: float = 0.30                 # 0..1, normalized day cycle
var paused: bool = false
var _last_hour_idx: int = -1
# Cached scene-level nodes so we don't walk the tree every frame.
var _cached_scene: Node = null
var _cached_sun: DirectionalLight3D = null
var _cached_env: WorldEnvironment = null


func _process(delta: float) -> void:
    if not paused:
        t = fposmod(t + delta / DAY_LENGTH_SEC, 1.0)
        var hour_idx: int = int(t * 24.0)
        if hour_idx != _last_hour_idx:
            _last_hour_idx = hour_idx
            hour_passed.emit(t)
    _apply_to_scene()


func _apply_to_scene() -> void:
    var scene: Node = get_tree().current_scene if get_tree() else null
    if scene == null:
        return
    if scene != _cached_scene:
        _cached_scene = scene
        _cached_sun = _find(scene, "DirectionalLight3D") as DirectionalLight3D
        _cached_env = _find(scene, "WorldEnvironment") as WorldEnvironment
    if _cached_sun and is_instance_valid(_cached_sun):
        _cached_sun.rotation = sun_rotation()
        _cached_sun.light_color = sun_color()
        _cached_sun.light_energy = sun_energy()
    if _cached_env and is_instance_valid(_cached_env) and _cached_env.environment:
        _cached_env.environment.ambient_light_color = ambient_color()
        _cached_env.environment.ambient_light_energy = ambient_energy()


# Recursive find-by-class. Linear in node count but only runs on scene
# change (cached afterwards).
func _find(root: Node, type_name: String) -> Node:
    if root.get_class() == type_name:
        return root
    for child in root.get_children():
        var hit: Node = _find(child, type_name)
        if hit != null:
            return hit
    return null


func set_t(new_t: float) -> void:
    t = clamp(new_t, 0.0, 1.0)


func pause() -> void:
    paused = true


func resume() -> void:
    paused = false


# Returns the sun's direction vector (the direction sunlight is
# shining INTO — i.e. pointing from the sun toward the ground).
# At noon this is (0, -1, ~0); at sunrise/sunset it's near horizontal.
func sun_dir() -> Vector3:
    var angle: float = t * TAU - PI * 0.5    # -π/2 at midnight, +π/2 at noon
    return Vector3(0.30, -sin(angle), -cos(angle)).normalized()


# Pitch + yaw angles for setting a DirectionalLight3D.rotation.
func sun_rotation() -> Vector3:
    var angle: float = t * TAU - PI * 0.5
    # rotation.x rotates the light's -Z down. Want -π/2 at noon
    # (light pointing straight down) and -π at midnight (light
    # pointing up — but we cap energy so it's effectively off).
    return Vector3(-angle, 0.0, 0.0)


func sun_color() -> Color:
    # Day vs golden hour vs night palette.
    if t < 0.20 or t > 0.80:    # night
        return Color(0.45, 0.55, 0.85)
    if t < 0.32 or t > 0.68:    # sunrise / sunset
        return Color(1.0, 0.62, 0.38)
    return Color(1.0, 0.96, 0.85)


func sun_energy() -> float:
    var s: float = sin(t * TAU - PI * 0.5)
    return clamp(lerp(0.05, 1.40, (s + 1.0) * 0.5), 0.05, 1.40)


func ambient_color() -> Color:
    if t < 0.20 or t > 0.80:
        return Color(0.20, 0.25, 0.45)
    if t < 0.32 or t > 0.68:
        return Color(0.85, 0.65, 0.50)
    return Color(0.85, 0.90, 0.95)


func ambient_energy() -> float:
    var s: float = sin(t * TAU - PI * 0.5)
    return clamp(lerp(0.18, 0.55, (s + 1.0) * 0.5), 0.18, 0.55)


# Convenience flag for code that wants to trigger night-only events.
func is_night() -> bool:
    return t < 0.20 or t > 0.80
