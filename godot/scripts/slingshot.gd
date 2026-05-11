extends Node

# Static utility wrapper for the slingshot. Same shape as bow.gd — fires
# a seed projectile, consumes one seed of ammo. Faster muzzle velocity,
# no arc, lower damage. The contrast with the bow is the design beat:
# the bow is your "real" ranged weapon, the slingshot is the snappy
# answer for the moments when something small and fast needs swatting.

const SeedScene: PackedScene = preload("res://scenes/seed.tscn")

const SPAWN_OFFSET: float = 0.6
const SPAWN_HEIGHT: float = 1.0
const SPEED: float = 24.0


static func try_fire(owner: Node3D, direction: Vector3) -> bool:
    if owner == null or not is_instance_valid(owner):
        return false
    if not GameState.use_seed():
        return false
    # Preserve the caller's full 3D direction — first-person aim mode
    # passes a pitched camera-forward so seeds can plink fliers above
    # the player. Non-aim callers pass a flat facing vector, so the
    # old behaviour is preserved by the caller, not the wrapper.
    var dir: Vector3 = direction
    if dir.length_squared() < 1e-6:
        dir = Vector3(0, 0, -1)
    dir = dir.normalized()
    var pellet: Area3D = SeedScene.instantiate()
    var scene_root: Node = owner.get_tree().current_scene
    if scene_root == null:
        pellet.queue_free()
        return false
    scene_root.add_child(pellet)
    pellet.global_position = owner.global_position + dir * SPAWN_OFFSET + Vector3(0, SPAWN_HEIGHT, 0)
    pellet.setup(dir * SPEED, owner)
    SoundBank.play_3d("sword_swing", pellet.global_position)
    _push_terminal_cmd(owner)
    return true


# Terminal-corner narration. The slingshot's lore-canon command is
# `ping <pid>` — a small response from a distant target. If the player
# has something Z-targeted we ping its instance id; otherwise we ping
# the reticle. Guarded so headless contexts without the autoload pass.
static func _push_terminal_cmd(owner: Node3D) -> void:
    if owner == null or not is_instance_valid(owner):
        return
    var tl: Node = owner.get_node_or_null("/root/TerminalLog")
    if tl == null:
        return
    var pid_arg: String = "$RETICLE"
    if owner.has_method("get_lock_target"):
        var t: Object = owner.call("get_lock_target")
        if t and t.has_method("get_instance_id"):
            pid_arg = "PID%d" % t.get_instance_id()
    tl.cmd("ping %s" % pid_arg)
