extends Node3D

# Archery-range target for the Old Plays Sharpshooter minigame.
#
# A small painted disc on a stake. The TargetPractice autoload spawns
# ten of these inside a radius around the barker, varying their height
# so the player has to aim. The disc lives on the Hittable layer (32)
# so the bow's arrow detection picks it up the same way the eye-target
# puzzle target does (see eye_target.gd) — the arrow's body / area
# scan finds our Hitbox area, walks up to the script root, and calls
# `take_damage`, which fires the `hit` signal and queues us free.
#
# Note on the name: the existing `practice_target` files in this repo
# are sword-training dummies used by combat_arena.tscn and live on a
# different collision layer. To avoid breaking that, the archery
# target uses its own name (and own scene/script) even though the
# build spec called it `practice_target`. Functionally identical.

signal hit(target: Node3D)

@onready var visual: Node3D  = $Visual
@onready var disc:   MeshInstance3D = $Visual/Disc
@onready var stake:  MeshInstance3D = $Visual/Stake
@onready var hitbox: Area3D  = $Hitbox

var _hit: bool = false
var _t: float = 0.0


func _ready() -> void:
    # Layer 32 == Hittable. Arrows scan layers 1 + 32; making us
    # monitorable on 32 means the arrow's `_on_area_entered` finds the
    # Hitbox area, asks our script root for `take_damage`, and the
    # call lands here. (Same trick eye_target uses.)
    hitbox.collision_layer = 32
    hitbox.collision_mask  = 0
    hitbox.monitorable     = true
    hitbox.monitoring      = false
    add_to_group("archery_target")


func _process(delta: float) -> void:
    if _hit:
        return
    # A barely-perceptible bob so a stationary target still draws the eye.
    _t += delta
    if visual:
        visual.position.y = sin(_t * 2.4) * 0.04


# Arrow → arrow.gd → take_damage on the script root. Signature matches
# the rest of the take_damage receivers in the project so the arrow
# code path is uniform.
func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
                 _attacker: Node = null) -> void:
    if _hit:
        return
    _hit = true
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_3d("crystal_hit", global_position, 0.10)
    hit.emit(self)
    # Hide the visual immediately so the player gets clean feedback,
    # then queue_free at end-of-frame so listeners can still read
    # `global_position` if needed.
    if visual:
        visual.visible = false
    hitbox.set_deferred("monitorable", false)
    queue_free()
