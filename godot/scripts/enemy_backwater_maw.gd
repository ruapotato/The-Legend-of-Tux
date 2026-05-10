extends Node3D

# Backwater Maw — boss of Mirelake (Dungeon 6). A submerged squid
# anchored above the arena floor by long, drifting tendrils. Its core
# floats 4m up, well out of sword reach. The only way to engage it is
# to wear the Anchor Boots (GameState.inventory has "anchor_boots" AND
# GameState.anchor_boots_active) — those drag Tux DOWN onto the lower
# floor plane (the actual lakebed) where the Maw's core dangles low
# enough to strike.
#
# We don't actually move the player; we just check both the inventory
# flag and the active flag, and require the player's vertical position
# is on the lower plane (we pick `core_y - 1.0` as the threshold). If
# either gate is missing, sword damage is rejected — exactly the same
# bounce as the Codex Knight's armor.
#
# Boss attack: tendrils periodically lash a target spot on the floor;
# anyone in the splash zone takes contact damage. Tendrils ignore depth.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")

signal died

@export var max_hp: int = 70
@export var core_height: float = 4.0
@export var detect_range: float = 14.0
@export var contact_damage: int = 4
@export var pebble_reward: int = 10
@export var lash_radius: float = 1.8
@export var lash_cooldown: float = 2.6

const HURT_TIME: float = 0.30

enum State { IDLE, AGGRO, LASH, HURT, DEAD }

var hp: int = 70
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _lash_t: float = 0.0
var _lash_target: Vector3 = Vector3.ZERO
var _lash_armed: bool = false
const LASH_WINDUP: float = 0.7
const LASH_HIT: float = 0.05

@onready var visual: Node3D = $Visual
@onready var core: MeshInstance3D = $Visual/Core
@onready var hitbox: Area3D = $Hitbox
@onready var tendril_a: Node3D = $Visual/TendrilA
@onready var tendril_b: Node3D = $Visual/TendrilB
@onready var tendril_c: Node3D = $Visual/TendrilC


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    # The hitbox lives at the core's height — sword has to literally be
    # standing low enough that the swing reaches up to it from below.
    visual.position.y = core_height
    hitbox.position.y = core_height


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

    var dist: float = 1e9
    if player and is_instance_valid(player):
        dist = player.global_position.distance_to(global_position)

    # Drift the core in a slow horizontal float.
    visual.position.x = sin(state_time * 0.6) * 0.6
    visual.position.z = cos(state_time * 0.6) * 0.6
    hitbox.position.x = visual.position.x
    hitbox.position.z = visual.position.z
    # Tendrils sway.
    if tendril_a:
        tendril_a.rotation.z = sin(state_time * 1.2) * 0.20
    if tendril_b:
        tendril_b.rotation.z = sin(state_time * 1.2 + 2.1) * 0.20
    if tendril_c:
        tendril_c.rotation.z = sin(state_time * 1.2 + 4.2) * 0.20

    _lash_t -= delta

    match state:
        State.IDLE:
            if dist < detect_range:
                _set_state(State.AGGRO)
        State.AGGRO:
            if dist > detect_range * 1.6:
                _set_state(State.IDLE)
            elif _lash_t <= 0.0 and player:
                _begin_lash()
        State.LASH:
            if not _lash_armed and state_time >= LASH_WINDUP:
                _lash_armed = true
                _resolve_lash()
            if state_time >= LASH_WINDUP + LASH_HIT + 0.4:
                _lash_t = lash_cooldown
                _lash_armed = false
                _set_state(State.AGGRO)
        State.HURT:
            if state_time >= HURT_TIME:
                _set_state(State.AGGRO)


func _begin_lash() -> void:
    if player and is_instance_valid(player):
        _lash_target = player.global_position
    _set_state(State.LASH)
    SoundBank.play_3d("blob_attack", global_position)


func _resolve_lash() -> void:
    if player == null or not is_instance_valid(player):
        return
    var d: float = player.global_position.distance_to(_lash_target)
    if d <= lash_radius:
        if player.has_method("take_damage"):
            player.take_damage(contact_damage, _lash_target, self)


# Sword damage routing. Sword reaches the core only if BOTH:
#   1. Anchor Boots are equipped AND active, AND
#   2. The player is on the lower floor plane (their global_position.y
#      is below `core_y - 1.0`).
# Otherwise the hit bounces.
func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    if not _player_can_strike():
        SoundBank.play_3d("shield_block", global_position)
        return
    hp -= amount
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func _player_can_strike() -> bool:
    var gs := get_node_or_null("/root/GameState")
    if gs == null:
        return false
    var inv: Variant = gs.get("inventory") if "inventory" in gs else null
    if inv == null:
        return false
    var has_boots: bool = false
    if inv is Dictionary:
        has_boots = (inv as Dictionary).has("anchor_boots") and bool((inv as Dictionary).get("anchor_boots", false))
    elif inv.has_method("has"):
        has_boots = bool(inv.call("has", "anchor_boots"))
    if not has_boots:
        return false
    var active: bool = false
    if "anchor_boots_active" in gs:
        active = bool(gs.get("anchor_boots_active"))
    if not active:
        return false
    # Vertical-plane check: the player's feet must be below the underwater
    # threshold so we know they walked DOWN to the lakebed.
    if player and is_instance_valid(player):
        var threshold_y: float = global_position.y + core_height - 1.0
        if player.global_position.y > threshold_y:
            return false
    return true


func get_knockback(_direction: Vector3, _force: float) -> void:
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    # Sink the visual to the floor.
    var down_pos: Vector3 = Vector3(visual.position.x, 0.2, visual.position.z)
    var t := create_tween()
    t.set_parallel(true)
    t.tween_property(visual, "position", down_pos, 1.0)
    t.tween_property(visual, "scale", visual.scale * Vector3(1.1, 0.2, 1.1), 1.0)
    t.chain().tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    here.y = 0.2
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
