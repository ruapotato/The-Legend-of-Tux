extends Node

# Static utility wrapper for the bow item. Spawns an arrow and consumes
# one arrow of ammo. Kept as a thin shell so tux_player only has to
# dispatch on the active_b_item string.

const ArrowScene: PackedScene = preload("res://scenes/arrow.tscn")

const SPAWN_OFFSET: float = 0.6
const SPAWN_HEIGHT: float = 1.0
const SPEED: float = 18.0
const ARC_LIFT: float = 1.5


# Spawn an arrow if there's ammo. Returns true if a shot fired, false if
# the player is dry and the call was a no-op.
static func try_fire(owner: Node3D, direction: Vector3) -> bool:
    if owner == null or not is_instance_valid(owner):
        return false
    if not GameState.use_arrow():
        return false
    var dir: Vector3 = direction
    dir.y = 0.0
    if dir.length_squared() < 1e-6:
        dir = Vector3(0, 0, -1)
    dir = dir.normalized()
    var arrow: Area3D = ArrowScene.instantiate()
    var scene_root: Node = owner.get_tree().current_scene
    if scene_root == null:
        arrow.queue_free()
        return false
    scene_root.add_child(arrow)
    arrow.global_position = owner.global_position + dir * SPAWN_OFFSET + Vector3(0, SPAWN_HEIGHT, 0)
    var velocity: Vector3 = dir * SPEED + Vector3(0, ARC_LIFT, 0)
    arrow.setup(velocity, owner)
    SoundBank.play_3d("sword_swing", arrow.global_position)
    return true
