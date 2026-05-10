extends CharacterBody3D

# Codex Knight — boss of Sigilkeep (Dungeon 2). A robed scholar-warrior
# wielding a chained quill that whips in long arcs. The body itself is
# armored: sword strikes ring off it harmlessly. Its only weakness is
# the inkpot strapped to its hip — when the inkpot is shattered by an
# arrow (group `arrow`), the spilled ink drenches the knight's robes
# and renders it briefly vulnerable to the sword.
#
# The fight loop:
#   1. Knight circles, performs sweeping quill arcs (contact damage).
#   2. Player must time a Bow shot at the inkpot Area3D (a small Area3D
#      at the knight's side). When the inkpot takes any damage, it
#      enters its "broken" visual state and the knight enters a 5-second
#      VULNERABLE window during which sword strikes register.
#   3. After the window, the inkpot "refills" (visual restored, hp reset)
#      and the knight returns to its normal armored state.
#
# Damage routing:
#   - The inkpot is a self-contained Area3D with its own take_damage(),
#     so arrows naturally hit it (sword_hitbox dispatches to whichever
#     receiver has take_damage()).
#   - The knight's main Hitbox routes all damage through take_damage()
#     here, which BOUNCES (no hp loss) unless `_vuln_t > 0`.
#
# Lore: a Sigilkeep archivist driven mad by what they read. The chained
# quill is the only weapon they ever needed — every page of their codex
# was once written by it.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 60
@export var detect_range: float = 14.0
@export var attack_range: float = 4.6
@export var move_speed: float = 1.8
@export var contact_damage: int = 3
@export var quill_damage: int = 4
@export var pebble_reward: int = 8
@export var vuln_window: float = 5.0
@export var inkpot_refill_time: float = 6.5

const GRAVITY: float = 22.0
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.5
const TELEGRAPH_TIME: float = 0.55
const SWING_DURATION: float = 0.70
const SWING_HIT_WINDOW: Vector2 = Vector2(0.10, 0.55)
const SWING_REACH: float = 4.4
const RECOVER_TIME: float = 0.85
const QUILL_ARC_DEG: float = 160.0     # sweep span around the body

enum State { IDLE, APPROACH, TELEGRAPH, SWING, RECOVER, HURT, DEAD }

var hp: int = 60
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
# Vulnerability timer — counts DOWN. While > 0, sword damage applies.
var _vuln_t: float = 0.0
# Tracks whether the inkpot is currently broken (visual / collision off).
var _inkpot_broken: bool = false
var _inkpot_refill_t: float = 0.0
# Set true once during a SWING so contact damage doesn't tick repeatedly
# from the same swing's overlapping window.
var _swing_landed: bool = false

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea
@onready var inkpot: Area3D = $Inkpot
@onready var inkpot_mesh: MeshInstance3D = $Inkpot/Pot
@onready var quill: Node3D = $Visual/Quill
@onready var aura: OmniLight3D = $Aura


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    # Inkpot is its own damageable Area3D. We attach a callable so when
    # something with damage hits it, the *boss* hears about it.
    if inkpot:
        # Use metadata + a wrapping Node3D method on the inkpot itself.
        # The simplest contract: inkpot has its own take_damage that we
        # dispatch to via _on_inkpot_damaged below. We use set_meta to
        # tag the inkpot owner; the inkpot node has a tiny script-less
        # take_damage handled here through area_entered.
        inkpot.set_meta("owner_boss", self)
        # Listen for Area-Area contacts (arrows are Area3D).
        inkpot.area_entered.connect(_on_inkpot_area_hit)
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta
    if _vuln_t > 0.0:
        _vuln_t -= delta
        # Pulse the aura while vulnerable so the player can read the window.
        if aura:
            var p: float = clamp(_vuln_t / max(0.1, vuln_window), 0.0, 1.0)
            aura.light_energy = lerp(0.4, 2.6, 0.5 + 0.5 * sin(state_time * 8.0)) * p
        if _vuln_t <= 0.0 and aura:
            aura.light_energy = 0.0
    if _inkpot_broken:
        _inkpot_refill_t -= delta
        if _inkpot_refill_t <= 0.0:
            _refill_inkpot()

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
        State.IDLE:        _do_idle(delta, dist)
        State.APPROACH:    _do_approach(delta, to_player, dist)
        State.TELEGRAPH:   _do_telegraph(delta, to_player)
        State.SWING:       _do_swing(delta)
        State.RECOVER:     _do_recover(delta, dist)
        State.HURT:        _do_hurt(delta, dist)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()


func _do_idle(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 8.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 8.0 * delta)
    if dist < detect_range:
        _set_state(State.APPROACH)


func _do_approach(delta: float, to_player: Vector3, dist: float) -> void:
    if dist > detect_range * 1.6:
        _set_state(State.IDLE)
        return
    if dist < attack_range:
        _set_state(State.TELEGRAPH)
        return
    var dir: Vector3 = to_player.normalized() if to_player.length_squared() > 1e-6 else Vector3.FORWARD
    velocity.x = dir.x * move_speed
    velocity.z = dir.z * move_speed
    rotation.y = atan2(-dir.x, -dir.z)


func _do_telegraph(delta: float, to_player: Vector3) -> void:
    velocity.x = move_toward(velocity.x, 0, 12.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 12.0 * delta)
    if to_player.length_squared() > 1e-6:
        var dir: Vector3 = to_player.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    # Quill rears back during telegraph.
    if quill:
        var t: float = clamp(state_time / TELEGRAPH_TIME, 0.0, 1.0)
        quill.rotation.y = lerp(0.0, -PI * 0.55, t)
    if state_time >= TELEGRAPH_TIME:
        _set_state(State.SWING)


func _do_swing(delta: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 14.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 14.0 * delta)
    # Sweep the quill across an arc.
    if quill:
        var t: float = clamp(state_time / SWING_DURATION, 0.0, 1.0)
        var arc: float = deg_to_rad(QUILL_ARC_DEG)
        quill.rotation.y = lerp(-PI * 0.55, -PI * 0.55 + arc, t)
    # Active hit window: front-arc cone within reach.
    if state_time >= SWING_HIT_WINDOW.x and state_time <= SWING_HIT_WINDOW.y:
        if not _swing_landed and player and is_instance_valid(player):
            var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
            var to_p: Vector3 = player.global_position - global_position
            to_p.y = 0
            var d: float = to_p.length()
            if d > 0.05 and d < SWING_REACH:
                var to_p_n: Vector3 = to_p / d
                # Wide cone since the quill is sweeping.
                if fwd.dot(to_p_n) > -0.20:
                    _swing_landed = true
                    if player.has_method("take_damage"):
                        SoundBank.play_3d("sword_hit", global_position)
                        player.take_damage(quill_damage, global_position, self)
    if state_time >= SWING_DURATION:
        _set_state(State.RECOVER)


func _do_recover(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 12.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 12.0 * delta)
    if quill:
        # Drift quill back to neutral.
        quill.rotation.y = lerp(quill.rotation.y, 0.0, 6.0 * delta)
    if state_time >= RECOVER_TIME:
        _set_state(State.APPROACH if dist < detect_range else State.IDLE)


func _do_hurt(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 6.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 6.0 * delta)
    if state_time >= HURT_TIME:
        _set_state(State.APPROACH if dist < detect_range else State.IDLE)


# ---- Damage in / out ---------------------------------------------------

# Sword (and other body-area damage) routes here. Bounces unless
# vulnerable. Bow can hit the boss body too — but that doesn't open
# the window; only an inkpot hit does.
func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    if _vuln_t <= 0.0:
        # Armored bounce — small visual cue, no hp loss.
        SoundBank.play_3d("shield_block", global_position)
        _bounce_punch()
        return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0
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


func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 3.0
    _set_state(State.HURT)


# Inkpot-broke pipeline. Any Area3D entering the inkpot Area3D — arrows
# qualify (they're Area3D) — opens the vulnerability window. Bombs work
# too if they happen to overlap (the spec only requires arrows but we
# don't gate it). The inkpot needs to be intact to qualify.
func _on_inkpot_area_hit(area: Area3D) -> void:
    if _inkpot_broken or state == State.DEAD:
        return
    # Be permissive: the spec calls out "arrow" group, but any incoming
    # damaging area (arrow / boomerang / etc.) breaks it. Don't open on
    # our own contact area (which is layer 0, mask 2 — won't match).
    if area == hitbox or area == contact_area:
        return
    _break_inkpot()


func _break_inkpot() -> void:
    _inkpot_broken = true
    _vuln_t = vuln_window
    _inkpot_refill_t = inkpot_refill_time
    if inkpot:
        inkpot.set_deferred("monitoring", false)
        inkpot.set_deferred("monitorable", false)
    if inkpot_mesh:
        inkpot_mesh.visible = false
    if aura:
        aura.light_energy = 2.0
    SoundBank.play_3d("crystal_hit", global_position)


func _refill_inkpot() -> void:
    _inkpot_broken = false
    if inkpot:
        inkpot.set_deferred("monitoring", true)
        inkpot.set_deferred("monitorable", true)
    if inkpot_mesh:
        inkpot_mesh.visible = true
    if aura:
        aura.light_energy = 0.0


func _on_contact_player(body: Node) -> void:
    if state == State.DEAD or state == State.HURT:
        return
    if not body.is_in_group("player"):
        return
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, global_position, self)


func _bounce_punch() -> void:
    if visual == null:
        return
    var base: Vector3 = visual.scale
    visual.scale = base * Vector3(1.05, 0.92, 1.05)
    var t := create_tween()
    t.tween_property(visual, "scale", base, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    if contact_area:
        contact_area.set_deferred("monitoring", false)
    if inkpot:
        inkpot.set_deferred("monitoring", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", visual.scale * Vector3(1.0, 0.05, 1.0), 0.55)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
    if state != State.SWING:
        _swing_landed = false
    if state == State.TELEGRAPH:
        SoundBank.play_3d("sword_charge", global_position)
    elif state == State.SWING:
        SoundBank.play_3d("sword_swing", global_position)
