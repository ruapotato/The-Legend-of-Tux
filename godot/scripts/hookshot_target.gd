extends Node3D

# Marker prop a hookshot tip can latch onto. Adds itself to the
# "hookshot_target" group; the tip queries the group on contact.
# A subtle pulse on the inner ring sells the "grappable" affordance.

@onready var ring: MeshInstance3D = $Visual/Ring
@onready var glow: OmniLight3D = $Visual/Glow

var _t: float = 0.0


func _ready() -> void:
    add_to_group("hookshot_target")


func _process(delta: float) -> void:
    _t += delta
    if ring:
        var s: float = 1.0 + sin(_t * 2.5) * 0.06
        ring.scale = Vector3(s, 1.0, s)
    if glow:
        glow.light_energy = 0.9 + sin(_t * 3.0) * 0.25
