extends Label3D

# A small floating name label that fades in above an NPC when the
# player is within `proximity` metres. Owned and instantiated by
# npc.gd in _ready() — kept as its own node so npc.gd doesn't need to
# carry the proximity / fade state machine inline.
#
# Implementation choice: Label3D over a screen-space Control. Label3D
# inherits the camera's billboard projection for free, plus the
# pixel_size knob keeps the label legible at any camera distance
# without us having to do per-frame project_to_screen math. Set
# `billboard = BaseMaterial3D.BILLBOARD_ENABLED` so the label always
# faces the active camera.
#
# The owning NPC sets `display_name` and `target_player` after
# instantiation. _process polls the squared-distance every frame
# (cheap) and crossfades modulate.a between 0 and 1 over `fade_time`
# seconds.

@export var display_name: String = ""
# Distance under which the nameplate fades to fully opaque. Above
# this threshold it fades back out. Squared internally to avoid the
# sqrt per frame.
@export var proximity: float = 4.0
# Wall-clock seconds to fully crossfade in or out.
@export var fade_time: float = 0.35
# Optional offset above the parent's origin. The default sits the
# label about a head's height above the NPC's existing 1.85m hint
# so the prompt and the nameplate don't overlap.
@export var height_offset: float = 1.5

# Set by the owning NPC after instantiation. We don't use a
# `get_tree().get_first_node_in_group("player")` lookup here because
# the lookup would happen on every frame and Player isn't always in
# the tree on early frames (loading screens, fades, etc.).
var target_player: Node3D = null

# Current alpha state, in [0, 1]. _process tweens this manually so we
# don't pay tween allocation costs each fade cycle.
var _alpha: float = 0.0


func _ready() -> void:
    # Visual defaults — billboard so it always faces the active camera,
    # no_depth_test so it renders above the NPC body even when the
    # camera clips into the head, and a small pixel_size so it stays
    # readable without dominating the view.
    billboard = BaseMaterial3D.BILLBOARD_ENABLED
    no_depth_test = true
    pixel_size = 0.005
    font_size = 28
    outline_size = 6
    outline_modulate = Color(0, 0, 0, 0.85)
    horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    text = display_name
    position.y = height_offset
    modulate.a = 0.0
    visible = (display_name != "")


func set_display_name(name: String) -> void:
    display_name = name
    text = name
    visible = (name != "")


func _process(delta: float) -> void:
    if not visible:
        return
    # No player bound yet — find one by group and remember it. This
    # runs at most once per nameplate per scene since target_player
    # sticks once set. If the player never appears (editor preview,
    # main menu) we'll just keep the label invisible.
    if target_player == null:
        var p: Node = get_tree().get_first_node_in_group("player")
        if p is Node3D:
            target_player = p as Node3D
        else:
            return
    if not is_instance_valid(target_player):
        target_player = null
        return
    # Squared distance vs squared threshold — avoids sqrt per frame.
    var d2: float = global_position.distance_squared_to(target_player.global_position)
    var threshold2: float = proximity * proximity
    var want_visible: bool = d2 <= threshold2
    var step: float = (delta / maxf(fade_time, 0.0001))
    if want_visible:
        _alpha = minf(_alpha + step, 1.0)
    else:
        _alpha = maxf(_alpha - step, 0.0)
    modulate.a = _alpha
