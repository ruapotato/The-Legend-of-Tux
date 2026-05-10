extends Node3D

# Gale Roost — boss of Stoneroost (Dungeon 3). A vast pterodactyl that
# circles 8m overhead. The player can never reach it on foot. Three
# `hookshot_target` nodes ride on the creature's underside; firing the
# hookshot at one yanks Tux up onto its back, where they have a 3-second
# window of free sword strikes before the Roost throws them off.
#
# Implementation contract:
#   - The boss is a Node3D (not CharacterBody3D) — it doesn't need
#     gravity / collision; it just rides a circular orbit.
#   - Each hookshot target node is added to group "hookshot_target" in
#     its own scene script; we just position them on our underside.
#   - When the player's `global_position.y` rises above us by ~0.5m AND
#     we are within 2m XZ, we treat them as "mounted." The mount window
#     runs for MOUNT_TIME, after which we boost them off (set their
#     velocity).
#   - During mount the player can sword-strike our Hitbox normally. The
#     Hitbox is large and easy to hit when they're standing on us.
#
# Lore: a sentinel of Stoneroost's high ledges; older than the keep
# itself. Carries scraps of bone trophies from past climbers.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HookshotTargetScene: PackedScene = preload("res://scenes/hookshot_target.tscn")

signal died

@export var max_hp: int = 70
@export var perch_height: float = 8.0
@export var orbit_radius: float = 6.0
@export var orbit_speed: float = 0.45     # rad/sec
@export var contact_damage: int = 4
@export var mount_time: float = 3.0
@export var pebble_reward: int = 10

const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 5.0
const THROW_SPEED: float = 8.0
const MOUNT_RADIUS_XZ: float = 2.5
const MOUNT_HEIGHT_TOL: float = 1.6
# Wing flap visual
const FLAP_OMEGA: float = 4.0

enum State { CIRCLE, MOUNTED, HURT, DEAD }

var hp: int = 70
var state: int = State.CIRCLE
var state_time: float = 0.0
var player: Node3D = null
var _origin: Vector3 = Vector3.ZERO
var _orbit_phase: float = 0.0
var _mount_t: float = 0.0
# Three hookshot anchor points. Spawned into our underside on _ready.
var _hooks: Array = []

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea
@onready var wing_l: Node3D = $Visual/WingL
@onready var wing_r: Node3D = $Visual/WingR
@onready var hook_anchor_a: Node3D = $HookA
@onready var hook_anchor_b: Node3D = $HookB
@onready var hook_anchor_c: Node3D = $HookC


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    _origin = global_position
    # Lift the visual up to the perch.
    visual.position = Vector3(orbit_radius, perch_height, 0)
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)
    _spawn_hookshot_targets()


# Plant a hookshot_target instance under each of the three anchor nodes.
# The targets parent themselves to the anchors so they ride the orbit.
func _spawn_hookshot_targets() -> void:
    for anchor in [hook_anchor_a, hook_anchor_b, hook_anchor_c]:
        if anchor == null:
            continue
        var t := HookshotTargetScene.instantiate()
        anchor.add_child(t)
        _hooks.append(t)


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta

    if state == State.DEAD:
        return
    _ensure_player()

    # Drift the visual + hitbox along the orbit.
    _orbit_phase += orbit_speed * delta
    var ox: float = cos(_orbit_phase) * orbit_radius
    var oz: float = sin(_orbit_phase) * orbit_radius
    visual.position = Vector3(ox, perch_height, oz)
    hitbox.position = Vector3(ox, perch_height, oz)
    contact_area.position = Vector3(ox, perch_height, oz)
    # Hookshot anchors hang under the body.
    var anchor_y: float = perch_height - 0.6
    if hook_anchor_a:
        hook_anchor_a.position = Vector3(ox + 0.0, anchor_y, oz + 0.5)
    if hook_anchor_b:
        hook_anchor_b.position = Vector3(ox + 0.5, anchor_y, oz - 0.4)
    if hook_anchor_c:
        hook_anchor_c.position = Vector3(ox - 0.5, anchor_y, oz - 0.4)

    # Wing flap.
    var flap: float = sin(state_time * FLAP_OMEGA) * 0.45
    if wing_l:
        wing_l.rotation.z = flap
    if wing_r:
        wing_r.rotation.z = -flap

    # Face along orbit direction.
    var fwd_xz: Vector3 = Vector3(-sin(_orbit_phase), 0.0, cos(_orbit_phase))
    visual.rotation.y = atan2(-fwd_xz.x, -fwd_xz.z)

    match state:
        State.CIRCLE:
            _check_for_mount()
        State.MOUNTED:
            _mount_t -= delta
            # Keep the player glued to the back during mount.
            if player and is_instance_valid(player):
                var back: Vector3 = visual.global_position + Vector3(0, 0.6, 0)
                player.global_position = back
                if "velocity" in player:
                    player.velocity = Vector3.ZERO
            if _mount_t <= 0.0:
                _throw_player_off()
                _set_state(State.CIRCLE)
        State.HURT:
            if state_time >= HURT_TIME:
                _set_state(State.CIRCLE)


# Detect a hookshot connection. The hookshot scenes don't expose an
# event we can hook directly, so we infer it: if the player is suddenly
# very close to one of our three hookshot_target instances AND vertically
# near our perch, treat that as a successful mount.
func _check_for_mount() -> void:
    if player == null or not is_instance_valid(player):
        return
    var pp: Vector3 = player.global_position
    var here: Vector3 = visual.global_position
    var dxz: float = Vector2(pp.x - here.x, pp.z - here.z).length()
    var dy: float = abs(pp.y - here.y)
    if dxz < MOUNT_RADIUS_XZ and dy < MOUNT_HEIGHT_TOL:
        _begin_mount()


func _begin_mount() -> void:
    _mount_t = mount_time
    _set_state(State.MOUNTED)
    SoundBank.play_3d("hookshot_hit", visual.global_position)


func _throw_player_off() -> void:
    if player == null or not is_instance_valid(player):
        return
    if "velocity" in player:
        # Punch them off backwards along the orbit tangent.
        var fwd_xz: Vector3 = Vector3(-sin(_orbit_phase), 0.0, cos(_orbit_phase))
        var away: Vector3 = -fwd_xz
        player.velocity = Vector3(away.x * THROW_SPEED, 6.0, away.z * THROW_SPEED)
    SoundBank.play_3d("blob_attack", visual.global_position)


func _on_contact_player(body: Node) -> void:
    if state == State.DEAD or state == State.MOUNTED:
        return
    if not body.is_in_group("player"):
        return
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, visual.global_position, self)


func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    SoundBank.play_3d("hurt", visual.global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func get_knockback(_direction: Vector3, _force: float) -> void:
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    if contact_area:
        contact_area.set_deferred("monitoring", false)
    SoundBank.play_3d("death", visual.global_position)
    _drop_loot()
    died.emit()
    # Drop the visual to the ground in a graceful arc.
    var down_pos: Vector3 = Vector3(visual.position.x, 0.2, visual.position.z)
    var t := create_tween()
    t.set_parallel(true)
    t.tween_property(visual, "position", down_pos, 1.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    t.tween_property(visual, "scale", visual.scale * Vector3(1.1, 0.2, 1.1), 1.0)
    t.chain().tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = visual.global_position
    here.y = 0.2
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
