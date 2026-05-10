extends StaticBody3D

# A prop gate that's solid until the global TimeOfDay clock enters a
# named phase window, then drops its collision and fades out so the
# player can walk through. Symmetric on the way back: when the phase
# expires the gate re-solidifies and fades back in.
#
# Phase windows (TimeOfDay.t in 0..1, 0 = midnight, 0.5 = noon):
#   "day"   = 0.25 <  t <  0.75
#   "night" = t > 0.85 or t < 0.15  (wraps midnight)
#   "dawn"  = 0.15 <= t <= 0.30
#   "dusk"  = 0.70 <= t <= 0.85
#   "any"   = always open (decorative — useful for level designers
#             who haven't picked a phase yet)
#
# The Sun Chord (SongBook) snaps TimeOfDay to noon, so any "day" gate
# opens roughly 1.5s after the chord plays. Moon Chord snaps to
# midnight and opens "night" gates the same way.

@export_enum("day", "night", "dawn", "dusk", "any") var time_phase: String = "any"

# Visual tuning. The slab is a translucent panel — alpha 0.6 when
# locked so the player can read it as "barrier you can see through",
# fully transparent when open. Tween length matches TimeOfDay's
# advance_to so the song-triggered transition lines up.
const FADE_DURATION: float = 1.5
const LOCKED_ALPHA: float = 0.6
const OPEN_ALPHA: float = 0.0

@onready var mesh: CSGBox3D = $Slab
@onready var shape: CollisionShape3D = $Shape

var _is_open: bool = false
var _slab_material: StandardMaterial3D = null
var _fade_tween: Tween = null
# Cached collision_layer for re-locking (we zero it when open so the
# player can walk through; restore from this on re-lock).
var _locked_layer: int = 1


func _ready() -> void:
    add_to_group("ground_snap")
    _locked_layer = collision_layer if collision_layer != 0 else 1
    # Build a unique material so two time_gates in the same scene
    # don't share an alpha tween. CSGBox3D exposes `material` directly.
    _slab_material = StandardMaterial3D.new()
    _slab_material.albedo_color = Color(0.55, 0.70, 1.00, LOCKED_ALPHA)
    _slab_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _slab_material.emission_enabled = true
    _slab_material.emission = Color(0.30, 0.55, 0.85)
    _slab_material.emission_energy_multiplier = 0.35
    if mesh:
        mesh.material = _slab_material
    # Apply initial state from the current TimeOfDay.t. "any" is a
    # decorative pass-through and skips the tween entirely.
    if time_phase == "any":
        _open_now(true)
    else:
        _refresh_state(true)


func _process(_delta: float) -> void:
    if time_phase == "any":
        return
    _refresh_state(false)


# Returns true when TimeOfDay.t falls inside this gate's phase window.
# "any" always returns true. Wraps midnight for "night".
func _phase_open() -> bool:
    if time_phase == "any":
        return true
    var t: float = TimeOfDay.t
    match time_phase:
        "day":
            return t > 0.25 and t < 0.75
        "night":
            return t > 0.85 or t < 0.15
        "dawn":
            return t >= 0.15 and t <= 0.30
        "dusk":
            return t >= 0.70 and t <= 0.85
    return false


# Reconcile current open/closed state against the phase window. On the
# initial pass (`snap` true) we skip the tween and just slam the alpha
# to its target so the gate is in its final state on scene load.
func _refresh_state(snap: bool) -> void:
    var should_be_open := _phase_open()
    if should_be_open and not _is_open:
        _open_now(snap)
    elif not should_be_open and _is_open:
        _lock_now(snap)


func _open_now(snap: bool) -> void:
    _is_open = true
    # Drop collision so the player walks through. Done as a one-shot
    # set_collision_layer per the file-header spec.
    set_collision_layer(0)
    if shape:
        shape.disabled = true
    _fade_alpha(OPEN_ALPHA, snap)


func _lock_now(snap: bool) -> void:
    _is_open = false
    set_collision_layer(_locked_layer)
    if shape:
        shape.disabled = false
    _fade_alpha(LOCKED_ALPHA, snap)


func _fade_alpha(target_a: float, snap: bool) -> void:
    if _slab_material == null:
        return
    if _fade_tween and _fade_tween.is_valid():
        _fade_tween.kill()
    var c: Color = _slab_material.albedo_color
    if snap:
        c.a = target_a
        _slab_material.albedo_color = c
        return
    _fade_tween = create_tween()
    _fade_tween.tween_method(
        Callable(self, "_set_alpha"), c.a, target_a, FADE_DURATION
    )


func _set_alpha(a: float) -> void:
    if _slab_material == null:
        return
    var c: Color = _slab_material.albedo_color
    c.a = a
    _slab_material.albedo_color = c
