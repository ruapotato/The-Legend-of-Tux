extends Node

# Player-side pull driver. Lives as a child of the Tux CharacterBody3D
# while the hookshot is reeling Tux toward its anchor point. Sets the
# parent body's velocity each physics tick so the existing
# move_and_slide() in tux_player.gd integrates the motion through the
# physics world (collisions still apply, so the player stops if a wall
# intervenes).
#
# Self-frees once Tux reaches the target or 1.0 s elapses, whichever
# comes first.

const PULL_SPEED: float = 14.0
const TIMEOUT: float = 1.0
const ARRIVE_DIST: float = 0.6

@export var target_pos: Vector3 = Vector3.ZERO

var _t: float = 0.0


func _physics_process(delta: float) -> void:
    var body: Node = get_parent()
    if body == null or not (body is CharacterBody3D):
        queue_free()
        return
    var character: CharacterBody3D = body
    _t += delta
    var to_target: Vector3 = target_pos - character.global_position
    if to_target.length() <= ARRIVE_DIST or _t >= TIMEOUT:
        # Stop the body cleanly before handing control back. Y stays at
        # a small downward bias so the next tick of tux_state grounds
        # naturally.
        character.velocity = Vector3(0, -1, 0)
        queue_free()
        return
    var dir: Vector3 = to_target.normalized()
    character.velocity = dir * PULL_SPEED
