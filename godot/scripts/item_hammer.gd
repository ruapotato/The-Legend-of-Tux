extends Node

# Striker's Maul — heavy two-handed mallet. B-item utility shaped like
# bow.gd / slingshot.gd: a stateless class with a single try_swing entry
# point. The actual swing is a tiny short-lived helper Node parented
# under the player so we can run a 0.4 s wind-up tween, then open a
# transient damage Area3D in front of Tux. The helper queue_frees once
# the strike resolves.
#
# Behavior:
#   - 0.4s wind-up before the impact lands — telegraphs the hit, lets
#     the player commit (no cancel) and matches the sluggish feel that
#     differentiates the maul from the sword.
#   - Strike radius: 1.8m sphere centered ~1.6m in front of the player.
#   - Damage 4 to anything in groups: enemy, fork_hydra, destructible_wall.
#   - fork_hydra heads are one-shot: the script bypasses the fork chain
#     by writing `hp = 0` directly before calling take_damage, so the
#     enemy's own _die path runs without the split branch.
#   - Smashes "crystal_lock" + "hard_rock" group nodes (queue_free + sfx).
#
# A swing already-in-progress no-ops a fresh try_swing call.

const SWING_WIND_UP: float = 0.4
const STRIKE_RADIUS: float = 1.8
const STRIKE_FORWARD: float = 1.6
const STRIKE_HEIGHT: float = 0.6
const STRIKE_DAMAGE: int = 4
# fork_hydra heads die outright on a maul strike. We write hp to 0
# before delegating to the enemy's take_damage so its existing _die
# branch runs unmodified — no need to add a new path inside the boss.
const HYDRA_ONESHOT_HP: int = 0

const HammerScene: PackedScene = preload("res://scenes/hammer.tscn")


# Entry point. Returns true if a swing started, false if one was already
# in progress (the player can't double-swing while the maul is in motion).
static func try_swing(player: Node3D, direction: Vector3) -> bool:
    if player == null or not is_instance_valid(player):
        return false
    # One swing at a time — the helper node tags itself so we can detect
    # a live swing without bothering the player script with extra state.
    for child in player.get_children():
        if child.has_meta("hammer_swing_active"):
            return false
    var dir: Vector3 = direction
    dir.y = 0.0
    if dir.length_squared() < 1e-6:
        dir = Vector3(0, 0, -1)
    dir = dir.normalized()
    var helper: Node3D = Node3D.new()
    helper.set_meta("hammer_swing_active", true)
    helper.set_script(load("res://scripts/item_hammer.gd"))
    player.add_child(helper)
    helper.set("_dir", dir)
    helper.set("_player", player)
    helper.call_deferred("_begin_swing")
    return true


# ---- Helper-instance behaviour -----------------------------------------
#
# The same script runs a swing-state when an instance is parented under
# the player. The static path above kicks the instance off; everything
# below is the per-swing controller.

var _dir: Vector3 = Vector3(0, 0, -1)
var _player: Node3D = null
var _t: float = 0.0
var _impacted: bool = false
var _hammer_visual: Node3D = null


func _begin_swing() -> void:
    SoundBank.play_3d("hammer_swing", _player.global_position)
    # Brief cosmetic mallet that hangs off the player's silhouette while
    # the wind-up plays. Uses the dedicated hammer.tscn so the visual
    # stays consistent with the equipped-weapon look.
    var packed: PackedScene = HammerScene
    if packed != null:
        var v: Node3D = packed.instantiate() as Node3D
        if v != null:
            _player.add_child(v)
            # Pin the mallet just above and slightly forward of Tux,
            # tilted overhead during the wind-up. We rotate it on the
            # X axis to telegraph "raised over the head."
            var b: Basis = Basis(Vector3(1, 0, 0), -1.1)
            v.transform = Transform3D(b, Vector3(0, 1.4, -0.3))
            _hammer_visual = v
    set_process(true)


func _process(delta: float) -> void:
    if _impacted:
        return
    _t += delta
    # Tilt the visual forward over the wind-up so it reads as being
    # swung. At t=0 it's overhead (-1.1 rad), at t=SWING_WIND_UP it's
    # roughly horizontal in front (+0.5 rad).
    if _hammer_visual != null and is_instance_valid(_hammer_visual):
        var k: float = clamp(_t / SWING_WIND_UP, 0.0, 1.0)
        var ang: float = lerp(-1.1, 0.5, k)
        var b: Basis = Basis(Vector3(1, 0, 0), ang)
        _hammer_visual.transform = Transform3D(
            b, Vector3(0, 1.4 - k * 0.7, -0.3 - k * 0.3))
    if _t >= SWING_WIND_UP:
        _impacted = true
        _strike()


func _strike() -> void:
    if _player == null or not is_instance_valid(_player):
        _cleanup()
        return
    var here: Vector3 = _player.global_position + _dir * STRIKE_FORWARD \
        + Vector3(0, STRIKE_HEIGHT, 0)
    SoundBank.play_3d("hammer_strike", here)
    # Camera shake feedback if the player has a free-orbit camera with
    # the standard `shake(amplitude, duration)` API.
    var cam_path: NodePath = _player.get("camera_path") if "camera_path" in _player else NodePath()
    if cam_path != NodePath():
        var cam: Node = _player.get_node_or_null(cam_path)
        if cam and cam.has_method("shake"):
            cam.shake(0.18, 0.18)

    # Build a transient sphere Area3D for the strike volume — same shape
    # as bomb.gd's blast sweeper, smaller radius. layer=PlayerHitbox(8),
    # mask=Hittable(32) + Enemy(4) + World(1) so we catch enemies, props,
    # and any static destructible.
    var blast := Area3D.new()
    blast.collision_layer = 0
    blast.collision_mask = 1 | 4 | 32
    blast.monitoring = true
    blast.monitorable = false
    var shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = STRIKE_RADIUS
    shape.shape = sphere
    blast.add_child(shape)
    var scene_root: Node = _player.get_tree().current_scene
    if scene_root == null:
        _cleanup()
        return
    scene_root.add_child(blast)
    blast.global_position = here
    # Defer the overlap sweep one frame so physics can register, then
    # free the helper and the volume.
    var sweeper := Timer.new()
    sweeper.one_shot = true
    sweeper.wait_time = 0.05
    blast.add_child(sweeper)
    sweeper.timeout.connect(func() -> void:
        _apply_strike(blast, here)
        if is_instance_valid(blast):
            blast.queue_free()
        _cleanup())
    sweeper.start()


func _apply_strike(blast: Area3D, here: Vector3) -> void:
    if not is_instance_valid(blast):
        _cleanup()
        return
    var hit_set: Array = []
    var bodies: Array = blast.get_overlapping_bodies()
    var areas: Array = blast.get_overlapping_areas()
    for body in bodies:
        if body == _player or hit_set.has(body):
            continue
        _hit_target(body, here, hit_set)
    for area in areas:
        var receiver: Object = area if area.has_method("take_damage") \
            else area.get_parent()
        if not (receiver is Node) or hit_set.has(receiver):
            continue
        _hit_target(receiver as Node, here, hit_set)
    # Also walk the active scene for crystal_lock / hard_rock nodes
    # within the strike radius. Those don't necessarily have hitboxes
    # on the Hittable layer (they're solid props), so the area sweep
    # alone misses them.
    _smash_named_groups(here)


func _hit_target(node: Node, here: Vector3, hit_set: Array) -> void:
    if node == null or not is_instance_valid(node):
        return
    hit_set.append(node)
    # fork_hydra heads die outright on a maul strike (no split, per
    # design). Set hp = 0 first so the enemy's own take_damage takes
    # the death branch instead of the fork branch.
    if node.is_in_group("fork_hydra") and "hp" in node:
        node.set("hp", HYDRA_ONESHOT_HP)
        if node.has_method("take_damage"):
            node.take_damage(STRIKE_DAMAGE, here, _player)
        return
    if node.has_method("take_damage"):
        node.take_damage(STRIKE_DAMAGE, here, _player)


func _smash_named_groups(here: Vector3) -> void:
    if _player == null or not is_instance_valid(_player):
        return
    var tree: SceneTree = _player.get_tree()
    if tree == null:
        return
    for group_name in ["crystal_lock", "hard_rock"]:
        for n in tree.get_nodes_in_group(group_name):
            if not (n is Node3D):
                continue
            var d: Vector3 = (n as Node3D).global_position - here
            if d.length() > STRIKE_RADIUS + 0.4:
                continue
            SoundBank.play_3d("rock_break", (n as Node3D).global_position)
            (n as Node3D).queue_free()


func _cleanup() -> void:
    if _hammer_visual != null and is_instance_valid(_hammer_visual):
        _hammer_visual.queue_free()
    queue_free()
