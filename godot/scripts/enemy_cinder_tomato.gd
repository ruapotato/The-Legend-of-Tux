extends CharacterBody3D

# Cinder Tomato — boss of Burnt Hollow (Dungeon 4). A scorched, layered
# tomato. Three "rind" stages cake the soft core. The sword merely
# bounces off rind. Each Bomb (group `bomb`) detonating within 3m of the
# Tomato blasts off one rind layer. After all three are gone, the soft
# core takes sword damage normally.
#
# State / hp model:
#   rind_layers : 3 → 2 → 1 → 0
#   max_hp / hp : the inner core hp (this is the "official" HP the boss
#                 arena bar reads; we set it to max_hp from start so the
#                 bar visually shrinks ONLY once the core is exposed).
#                 During rind stages, take_damage from sword is rejected.
#
# We detect bomb damage via the contract that bombs call
# `take_damage(amount, source_pos, null)` — i.e. attacker is null. While
# rind layers remain, an attacker-less hit is treated as a bomb blast
# and strips one layer. The 3m proximity check on `source_pos` is
# implicit (we trust the bomb's blast radius).

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 80
@export var detect_range: float = 12.0
@export var roll_speed: float = 2.6
@export var contact_damage: int = 4
@export var pebble_reward: int = 12
@export var bomb_proximity: float = 3.0

const GRAVITY: float = 22.0
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.0
const ROLL_OMEGA: float = 2.5

enum State { IDLE, ROLL, HURT, DEAD }

var hp: int = 80
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var rind_layers: int = 3
var _roll_dir: Vector3 = Vector3.ZERO
var _last_contact_t: float = -1000.0

@onready var visual: Node3D = $Visual
@onready var rind_a: MeshInstance3D = $Visual/RindA
@onready var rind_b: MeshInstance3D = $Visual/RindB
@onready var rind_c: MeshInstance3D = $Visual/RindC
@onready var core: MeshInstance3D = $Visual/Core
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    _refresh_rind_visual()
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta

    if state == State.DEAD:
        if not is_on_floor():
            velocity.y -= GRAVITY * delta
            move_and_slide()
        return
    _ensure_player()

    var to_player: Vector3 = Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    match state:
        State.IDLE:
            velocity.x = move_toward(velocity.x, 0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0, 8.0 * delta)
            if dist < detect_range:
                _set_state(State.ROLL)
        State.ROLL:
            if dist > detect_range * 1.6:
                _set_state(State.IDLE)
            elif to_player.length_squared() > 1e-6:
                var dir: Vector3 = to_player.normalized()
                velocity.x = dir.x * roll_speed
                velocity.z = dir.z * roll_speed
                _roll_dir = dir
                # Roll the visual around its X-axis based on travel.
                if visual:
                    visual.rotation.x += ROLL_OMEGA * delta
        State.HURT:
            velocity.x = move_toward(velocity.x, 0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0, 8.0 * delta)
            if state_time >= HURT_TIME:
                _set_state(State.ROLL if dist < detect_range else State.IDLE)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()


func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
    if hp <= 0 or state == State.DEAD:
        return
    # Bomb routing: attacker == null is the bomb-blast contract.
    # Strip one rind layer, regardless of `amount`.
    if attacker == null:
        if rind_layers > 0:
            _strip_rind(source_pos)
            return
        # No rind left? Bomb damage flows to the core like any hit.
        hp -= amount
        SoundBank.play_3d("hurt", global_position)
        if hp <= 0:
            _die()
        else:
            _set_state(State.HURT)
        return
    # Sword / arrow / etc. (attacker != null) bounces while rind > 0.
    if rind_layers > 0:
        SoundBank.play_3d("shield_block", global_position)
        return
    # Core exposed — normal damage.
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
        velocity.y = 2.5
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func _strip_rind(source_pos: Vector3) -> void:
    rind_layers = max(0, rind_layers - 1)
    SoundBank.play_3d("crystal_hit", global_position)
    _refresh_rind_visual()
    # Small flinch on rind loss — same as a hurt, but no hp tick.
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED * 0.5
        velocity.z = away.z * KNOCKBACK_SPEED * 0.5
        velocity.y = 1.5
    _set_state(State.HURT)


# Show rind layers from the outside in. Each successive layer hidden
# reveals a slightly redder/glowier interior.
func _refresh_rind_visual() -> void:
    if rind_c:
        rind_c.visible = rind_layers >= 3
    if rind_b:
        rind_b.visible = rind_layers >= 2
    if rind_a:
        rind_a.visible = rind_layers >= 1
    if core:
        # Core is always rendered; emission rises as rinds peel away.
        var mat := core.material_override as StandardMaterial3D
        if mat:
            mat.emission_energy_multiplier = 0.3 + (3 - rind_layers) * 0.6


func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 3.0
    _set_state(State.HURT)


func _on_contact_player(body: Node) -> void:
    if state == State.DEAD or state == State.HURT:
        return
    if not body.is_in_group("player"):
        return
    var now: float = Time.get_ticks_msec() / 1000.0
    if now - _last_contact_t < 0.9:
        return
    _last_contact_t = now
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, global_position, self)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    if contact_area:
        contact_area.set_deferred("monitoring", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", visual.scale * Vector3(1.4, 0.10, 1.4), 0.45)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.4, 1.4), 0.0, randf_range(-1.4, 1.4))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
