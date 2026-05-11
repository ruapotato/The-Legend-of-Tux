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
    # Preserve the caller's full 3D direction — first-person aim mode
    # passes a pitched camera-forward so the arrow can angle up at high
    # archery targets. Non-aim callers pass a flat (y=0) facing vector,
    # so the old behaviour is preserved by the caller, not the wrapper.
    var dir: Vector3 = direction
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
    _push_terminal_cmd(owner)
    return true


# Terminal-corner narration. Mirrors the bow's lore-canon pipeline:
# `ps aux | grep <target> | kill`. If the player has a Z-target locked
# we use that enemy's name as the grep argument; otherwise we fall back
# to the literal `$RETICLE` placeholder so it reads as "whatever's at
# the crosshair." Guarded so headless/test contexts without the autoload
# don't crash.
static func _push_terminal_cmd(owner: Node3D) -> void:
    if owner == null or not is_instance_valid(owner):
        return
    var tl: Node = owner.get_node_or_null("/root/TerminalLog")
    if tl == null:
        return
    var grep_arg: String = "$RETICLE"
    if owner.has_method("get_lock_target"):
        var t: Object = owner.call("get_lock_target")
        if t and "name" in t and String(t.get("name")) != "":
            grep_arg = String(t.get("name"))
    tl.cmd("ps aux | grep %s | kill" % grep_arg)
