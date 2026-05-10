extends Node3D

# Censor — boss of the Scriptorium (Dungeon 7). Default state is fully
# invisible (visibility = 0). The only way to see — and therefore aim
# at — the Censor is to hold Glim Sight in the B-slot AND be actively
# pressing the use-item input ("aiming" the lens). When both conditions
# are met AND the boss falls inside a 12m forward cone from the player,
# the visual fades in. Otherwise it ghosts back to invisible.
#
# Damage rules: take_damage works at any time (you CAN one-shot it from
# memory if you somehow remember where you left it). The visibility gate
# is purely a "you can see what you're aiming at" affordance.
#
# Boss attack: throws "censorship blocks" — small Area3D rectangles that
# fly along the ground. On player contact, a darkening overlay briefly
# appears on the floor under the impact (visual only; no real floor
# removal). The block is a sibling-spawned scene object that frees
# itself after the overlay's timer.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")

signal died

@export var max_hp: int = 80
@export var detect_range: float = 16.0
@export var orbit_radius: float = 5.0
@export var orbit_speed: float = 0.55
@export var contact_damage: int = 4
@export var pebble_reward: int = 12
@export var visibility_cone_deg: float = 38.0
@export var visibility_range: float = 12.0
@export var throw_cooldown: float = 2.4
@export var block_speed: float = 5.0
@export var block_lifetime: float = 4.0
@export var block_radius: float = 0.75
@export var darken_radius: float = 1.6
@export var darken_lifetime: float = 1.6

const HURT_TIME: float = 0.20

enum State { CIRCLE, HURT, DEAD }

var hp: int = 80
var state: int = State.CIRCLE
var state_time: float = 0.0
var player: Node3D = null
var _orbit_phase: float = 0.0
var _throw_t: float = 0.0
var _visible_alpha: float = 0.0     # 0..1 fade

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea
@onready var body_mesh: MeshInstance3D = $Visual/Body
@onready var halo_mesh: MeshInstance3D = $Visual/Halo


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)
    _orbit_phase = randf() * TAU
    _apply_visibility(0.0)


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

    # Drift along a circle around our origin.
    _orbit_phase += orbit_speed * delta
    var ox: float = cos(_orbit_phase) * orbit_radius
    var oz: float = sin(_orbit_phase) * orbit_radius
    visual.position = Vector3(ox, 1.4 + sin(state_time * 1.2) * 0.30, oz)
    hitbox.position = visual.position
    contact_area.position = visual.position

    # Visibility gate.
    var target_alpha: float = 0.0
    if _player_is_aiming_glim_sight():
        var fwd: Vector3 = _player_forward()
        var to_self: Vector3 = visual.global_position - player.global_position
        var d: float = to_self.length()
        if d <= visibility_range and d > 0.001:
            var to_self_n: Vector3 = to_self.normalized()
            var dot: float = fwd.dot(to_self_n)
            var cone_dot: float = cos(deg_to_rad(visibility_cone_deg))
            if dot >= cone_dot:
                target_alpha = 1.0
    _visible_alpha = move_toward(_visible_alpha, target_alpha, 4.0 * delta)
    _apply_visibility(_visible_alpha)

    match state:
        State.CIRCLE:
            _throw_t -= delta
            if _throw_t <= 0.0 and player and is_instance_valid(player):
                if visual.global_position.distance_to(player.global_position) < detect_range:
                    _throw_block()
                    _throw_t = throw_cooldown
        State.HURT:
            if state_time >= HURT_TIME:
                _set_state(State.CIRCLE)


func _player_is_aiming_glim_sight() -> bool:
    if player == null or not is_instance_valid(player):
        return false
    var gs := get_node_or_null("/root/GameState")
    if gs == null:
        return false
    var item: String = ""
    if "active_b_item" in gs:
        item = String(gs.get("active_b_item"))
    if item != "glim_sight":
        return false
    return Input.is_action_pressed("item_use")


func _player_forward() -> Vector3:
    if player == null or not is_instance_valid(player):
        return Vector3.FORWARD
    if "state" in player and player.state != null and "face_yaw" in player.state:
        var yaw: float = player.state.face_yaw
        return Vector3(-sin(yaw), 0, -cos(yaw))
    return Vector3(-sin(player.rotation.y), 0, -cos(player.rotation.y))


func _apply_visibility(a: float) -> void:
    var clamped: float = clamp(a, 0.0, 1.0)
    if body_mesh:
        var m := body_mesh.material_override as StandardMaterial3D
        if m:
            m.albedo_color.a = clamped
            m.emission_energy_multiplier = clamped * 1.2
    if halo_mesh:
        var m2 := halo_mesh.material_override as StandardMaterial3D
        if m2:
            m2.albedo_color.a = clamped * 0.7


# Spawn an Area3D "censorship block" that flies horizontally along the
# ground toward the player; on player contact, drops a darkening floor
# overlay (cosmetic) and despawns.
func _throw_block() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var area := Area3D.new()
    area.collision_layer = 0
    area.collision_mask = 2
    area.monitoring = true
    area.monitorable = false
    var cs := CollisionShape3D.new()
    var sh := BoxShape3D.new()
    sh.size = Vector3(block_radius, block_radius, block_radius)
    cs.shape = sh
    area.add_child(cs)
    # Visual: a small flat black slab.
    var mi := MeshInstance3D.new()
    var bm := BoxMesh.new()
    bm.size = Vector3(block_radius, block_radius * 0.6, block_radius)
    mi.mesh = bm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.05, 0.04, 0.07, 1)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mi.material_override = mat
    area.add_child(mi)

    var here: Vector3 = visual.global_position
    here.y = 0.6
    area.position = here
    parent.call_deferred("add_child", area)

    # Aim toward the player.
    var dir: Vector3 = Vector3.FORWARD
    if player and is_instance_valid(player):
        var to_p: Vector3 = player.global_position - here
        to_p.y = 0
        if to_p.length() > 0.05:
            dir = to_p.normalized()
    var vel: Vector3 = dir * block_speed

    # Drive the block forward via a frame timer attached to itself.
    # `area` is deferred-added to the parent above, so the timer isn't in
    # the tree until next frame; use autostart instead of t.start() to
    # avoid the "not inside scene tree" error.
    var t := Timer.new()
    t.wait_time = 0.016
    t.one_shot = false
    t.autostart = true
    area.add_child(t)
    var elapsed: Array = [0.0]
    t.timeout.connect(func() -> void:
        if not is_instance_valid(area):
            return
        area.position += vel * t.wait_time
        elapsed[0] += t.wait_time
        if elapsed[0] >= block_lifetime:
            area.queue_free())

    var darkened: Array = [false]
    area.body_entered.connect(func(body: Node) -> void:
        if darkened[0]:
            return
        if not body.is_in_group("player"):
            return
        darkened[0] = true
        if body.has_method("take_damage"):
            body.take_damage(contact_damage, area.global_position, self)
        _spawn_darken(area.global_position)
        area.queue_free())

    SoundBank.play_3d("blob_attack", visual.global_position)


# Cosmetic floor-darkening overlay. Lives `darken_lifetime` then fades.
# This is the "deletes a chunk of the floor" effect — visual only.
func _spawn_darken(at: Vector3) -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var disk := MeshInstance3D.new()
    var dm := CylinderMesh.new()
    dm.top_radius = darken_radius
    dm.bottom_radius = darken_radius
    dm.height = 0.04
    dm.radial_segments = 18
    disk.mesh = dm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.0, 0.0, 0.0, 0.95)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    disk.material_override = mat
    disk.position = Vector3(at.x, 0.04, at.z)
    parent.call_deferred("add_child", disk)
    var t := create_tween()
    t.tween_interval(darken_lifetime * 0.7)
    t.tween_property(mat, "albedo_color:a", 0.0, darken_lifetime * 0.3)
    t.tween_callback(disk.queue_free)


func _on_contact_player(body: Node) -> void:
    if state == State.DEAD:
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
    var t := create_tween()
    t.tween_property(visual, "scale", visual.scale * Vector3(0.05, 0.05, 0.05), 0.45)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = visual.global_position
    here.y = 0.2
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
