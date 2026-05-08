extends CharacterBody3D

# Tomato Peahat — a Peahat-style spinner that hovers above the ground
# with its rotor crown deflecting sword hits. Aggro: charge down, ram
# through the player, recover. Counter-play: hit the rotor while it's
# committing to a charge/ram and the tomato gets knocked off-balance,
# sinks to the ground, and exposes a soft red bulb on its underside —
# THAT is the only window where it can actually be damaged.
#
# State machine:
#   IDLE       — perched, slow rotor, no player in range
#   HOVER      — rotor at full speed, eyeing the player
#   CHARGE     — descending toward player, rotor faster (telegraph)
#   RAM        — straight-line lunge at the player's last known XZ
#   RECOVER    — brief float after the ram, before resuming HOVER
#   STUNNED    — knocked down to ground level, weakpoint exposed
#   HURT       — bounce after a successful weakpoint hit
#   DEAD       — sink + despawn
#
# Collision layout: TWO Area3Ds, both on layer 32 so the sword's mask
# (32) finds them. The ROTOR is always monitorable; its take_damage
# rejects damage with a clang + player shove unless weakpoint_exposed
# is true (in which case the underside is actually what got hit, just
# routed through the same script). The WEAKPOINT bulb only flips
# monitorable on while STUNNED — so during HOVER/CHARGE/RAM the sword
# physically only ever overlaps the rotor.

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 12
@export var aggro_range: float = 14.0
@export var charge_speed: float = 6.0
@export var ram_speed: float = 9.0
@export var contact_damage: int = 2
@export var pebble_reward: int = 5
@export var heart_drop_count: int = 2

const HOVER_HEIGHT: float = 4.0
const HOVER_AMP: float = 0.25
# The body oscillates between these heights every 3 s so the rotor
# isn't fixed at one altitude — gives the player a natural window
# where it's drifting low or high.
const HOVER_HEIGHT_MIN: float = 2.6
const HOVER_HEIGHT_MAX: float = 5.4
const HOVER_OSC_HZ:    float = 0.30
# Orbit around the player while in HOVER, so the tomato doesn't
# just hang above and dive — it actually flies AROUND you, deciding
# when to commit to a charge.
const ORBIT_RADIUS:    float = 7.0
const ORBIT_TANGENT:   float = 2.4
const ORBIT_RADIAL_K:  float = 1.5
# Body tilt while orbiting. The tilt direction faces AWAY from the
# player so the underside (weakpoint bulb) lifts toward the player —
# which is the OoT-style "you can see the weak spot when it tilts
# away" tell. While stunned the tilt resets to flat.
const TILT_MAX:        float = 0.30
const BLADE_SPIN:      float = 18.0
const BLADE_HIT_COOLDOWN: float = 0.8
const BLADE_PUSH:      float = 5.5
const SPIN_SPEED_HOVER: float = 6.0
const SPIN_SPEED_CHARGE: float = 12.0
const SPIN_SPEED_STUNNED: float = 1.2
const CHARGE_TIME_MAX: float = 0.7
const RAM_TIME: float = 0.6
const RECOVER_TIME: float = 0.4
const STUN_TIME: float = 1.0
const HURT_TIME: float = 0.25
const PLAYER_PUSH_SPEED: float = 5.0
const DEFLECT_PUSH_SPEED: float = 4.0
const RAM_KNOCKBACK: float = 5.0
const KNOCKBACK_SPEED: float = 4.5
const CHARGE_END_DROP: float = 1.6   # how low the body has dipped before RAM
const STUN_GROUND_Y: float = 0.6     # target body y while stunned

enum State { IDLE, HOVER, CHARGE, RAM, RECOVER, STUNNED, HURT, DEAD }

var hp: int = 12
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var weakpoint_exposed: bool = false

var _spin_speed: float = SPIN_SPEED_HOVER
var _hover_y: float = HOVER_HEIGHT       # current target y (ground-level when stunned)
var _ram_dir: Vector3 = Vector3.ZERO
var _ram_landed: bool = false

@onready var visual: Node3D = $Visual
@onready var blades: Node3D = $Visual/Blades
@onready var rotor_area: Area3D = $RotorArea
@onready var weakpoint_area: Area3D = $WeakpointArea
@onready var blade_hit_area: Area3D = $BladeHitArea
@onready var body_shape: CollisionShape3D = $BodyShape

var _last_blade_hit_t: float = -1000.0
var _orbit_dir: int = 1   # +1 = CCW around player, -1 = CW


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    # Make sure both hit volumes can route damage back through us.
    if not rotor_area.has_meta("tomato_role"):
        rotor_area.set_meta("tomato_role", "rotor")
    if not weakpoint_area.has_meta("tomato_role"):
        weakpoint_area.set_meta("tomato_role", "weakpoint")
    # Start with weakpoint hidden.
    weakpoint_exposed = false
    weakpoint_area.set_deferred("monitorable", false)
    blade_hit_area.body_entered.connect(_on_blade_hit_player)
    _orbit_dir = 1 if randf() < 0.5 else -1


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta

    if state == State.DEAD:
        # Sink to the ground after death.
        velocity.y = -2.0
        move_and_slide()
        return
    _ensure_player()

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    # Always spin the rotor crown on its Y axis at the current spin
    # speed; blades rotate at their own (always faster) rate so they
    # read as a separate, dangerous element from the body.
    visual.rotation.y += _spin_speed * delta
    blades.rotation.y += BLADE_SPIN * delta

    match state:
        State.IDLE:
            _spin_speed = SPIN_SPEED_HOVER * 0.4
            _hover_to(HOVER_HEIGHT, delta)
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            if dist < aggro_range:
                _set_state(State.HOVER)
        State.HOVER:
            _spin_speed = SPIN_SPEED_HOVER
            # Vertical oscillation between MIN and MAX so the rotor's
            # not pinned at one altitude.
            var phase: float = sin(state_time * HOVER_OSC_HZ * TAU) * 0.5 + 0.5
            var target_h: float = lerp(HOVER_HEIGHT_MIN, HOVER_HEIGHT_MAX, phase)
            _hover_to(target_h, delta, 3.5)
            # Orbit the player at ORBIT_RADIUS — tangent moves us
            # around them, radial term keeps us at the right distance.
            if dist > 0.3 and dist < aggro_range * 2.0:
                var n: Vector3 = to_player.normalized()
                var tangent: Vector3 = Vector3(-n.z, 0.0, n.x) * float(_orbit_dir)
                var radial_err: float = ORBIT_RADIUS - dist  # +ve if too close
                velocity.x = tangent.x * ORBIT_TANGENT - n.x * radial_err * ORBIT_RADIAL_K
                velocity.z = tangent.z * ORBIT_TANGENT - n.z * radial_err * ORBIT_RADIAL_K
                # Tilt body AWAY from player so the underside lifts
                # toward you — that's the "crawl under" tell. Tilt
                # axis is perpendicular to the to-player vector.
                visual.rotation.x = -n.z * TILT_MAX
                visual.rotation.z =  n.x * TILT_MAX
            else:
                velocity.x = move_toward(velocity.x, 0.0, 4.0 * delta)
                velocity.z = move_toward(velocity.z, 0.0, 4.0 * delta)
                visual.rotation.x = move_toward(visual.rotation.x, 0.0, delta)
                visual.rotation.z = move_toward(visual.rotation.z, 0.0, delta)
            # Commit to a charge after circling for a beat. Throw in a
            # 25% chance to flip orbit direction at each commit so the
            # next pass isn't predictable.
            if state_time > 2.0 and dist < aggro_range:
                if randf() < 0.25:
                    _orbit_dir = -_orbit_dir
                _set_state(State.CHARGE)
            elif dist > aggro_range * 1.8:
                _set_state(State.IDLE)
        State.CHARGE:
            _spin_speed = SPIN_SPEED_CHARGE
            # Descend partway; lock onto current XZ direction at end.
            var target_y: float = HOVER_HEIGHT - CHARGE_END_DROP
            velocity.y = (target_y - global_position.y) * 5.0
            if to_player.length_squared() > 1e-6:
                var n := to_player.normalized()
                velocity.x = n.x * charge_speed
                velocity.z = n.z * charge_speed
            if state_time >= CHARGE_TIME_MAX:
                _ram_landed = false
                _ram_dir = to_player
                _ram_dir.y = 0.0
                if _ram_dir.length() < 0.001:
                    _ram_dir = Vector3(0, 0, -1)
                _ram_dir = _ram_dir.normalized()
                _set_state(State.RAM)
        State.RAM:
            _spin_speed = SPIN_SPEED_CHARGE
            # Maintain the dipped altitude while ramming forward.
            var ram_y: float = HOVER_HEIGHT - CHARGE_END_DROP
            velocity.y = (ram_y - global_position.y) * 4.0
            velocity.x = _ram_dir.x * ram_speed
            velocity.z = _ram_dir.z * ram_speed
            _check_ram_contact()
            if state_time >= RAM_TIME:
                _set_state(State.RECOVER)
        State.RECOVER:
            _spin_speed = SPIN_SPEED_HOVER
            _hover_to(HOVER_HEIGHT, delta)
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            if state_time >= RECOVER_TIME:
                _set_state(State.HOVER)
        State.STUNNED:
            _spin_speed = SPIN_SPEED_STUNNED
            _hover_to(STUN_GROUND_Y, delta, 6.0)
            velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
            visual.rotation.x = move_toward(visual.rotation.x, 0.0, 4.0 * delta)
            visual.rotation.z = move_toward(visual.rotation.z, 0.0, 4.0 * delta)
            if state_time >= STUN_TIME:
                _set_state(State.HOVER)
        State.HURT:
            _spin_speed = SPIN_SPEED_STUNNED
            _hover_to(STUN_GROUND_Y, delta, 6.0)
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            if state_time >= HURT_TIME:
                # After a weakpoint hit it stays stunned for the rest of
                # the stun window; if the stun has expired, lift off.
                _set_state(State.STUNNED)

    move_and_slide()


# Smooth track to a target altitude with a small bob.
func _hover_to(target_y: float, _delta: float, gain: float = 4.0) -> void:
    var bob: float = sin(state_time * 1.6) * HOVER_AMP * (1.0 if target_y > 1.0 else 0.0)
    var goal: float = target_y + bob
    velocity.y = (goal - global_position.y) * gain


# Damage entry. The sword hits whichever Area3D is currently monitorable
# — both areas live under this body so they re-route here. We branch on
# weakpoint_exposed to decide whether the hit lands or pings off.
func take_damage(amount: int, source_pos: Vector3, attacker: Node3D = null) -> void:
    if hp <= 0:
        return
    if not weakpoint_exposed:
        # Rotor deflect — no HP loss, push the player back, clang.
        SoundBank.play_3d("shield_block", global_position)
        if attacker and attacker.is_in_group("player") and "velocity" in attacker:
            var away: Vector3 = attacker.global_position - global_position
            away.y = 0.0
            if away.length() > 0.01:
                away = away.normalized()
                attacker.velocity.x = away.x * DEFLECT_PUSH_SPEED
                attacker.velocity.z = away.z * DEFLECT_PUSH_SPEED
                attacker.velocity.y = 2.5
        # If the tomato is in the middle of a charge/ram when it gets
        # whacked, the impact rattles it loose and exposes the bulb.
        if state == State.CHARGE or state == State.RAM:
            _enter_stunned()
        return
    # Weakpoint hit — actually hurts.
    hp -= amount
    var bump: Vector3 = global_position - source_pos
    bump.y = 0.0
    if bump.length() > 0.01:
        bump = bump.normalized()
        velocity.x = bump.x * KNOCKBACK_SPEED
        velocity.z = bump.z * KNOCKBACK_SPEED
    _hit_punch()
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func _enter_stunned() -> void:
    weakpoint_exposed = true
    weakpoint_area.set_deferred("monitorable", true)
    # Blades go inert while it's grounded — sword hits the underside
    # safely and the player isn't punished for closing in.
    blade_hit_area.set_deferred("monitoring", false)
    SoundBank.play_3d("blob_die", global_position)
    _set_state(State.STUNNED)


# Player overlapping the spinning blade ring takes contact damage with
# a knockback shove. Cooldown so a brief touch doesn't chain-stun.
func _on_blade_hit_player(body: Node) -> void:
    if state == State.STUNNED or state == State.HURT or state == State.DEAD:
        return
    if not body.is_in_group("player"):
        return
    var now: float = Time.get_ticks_msec() / 1000.0
    if now - _last_blade_hit_t < BLADE_HIT_COOLDOWN:
        return
    _last_blade_hit_t = now
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, global_position, self)
    if "velocity" in body:
        var away: Vector3 = body.global_position - global_position
        away.y = 0.0
        if away.length() > 0.01:
            away = away.normalized()
            body.velocity.x = away.x * BLADE_PUSH
            body.velocity.z = away.z * BLADE_PUSH
            body.velocity.y = 3.0


func _hit_punch() -> void:
    if not visual:
        return
    visual.scale = Vector3(1.20, 0.85, 1.20)
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# RAM body-contact: damage + knockback the player along the ram dir.
func _check_ram_contact() -> void:
    if _ram_landed or not player or not is_instance_valid(player):
        return
    var to_p: Vector3 = player.global_position - global_position
    to_p.y = 0.0
    if to_p.length() > 1.6:
        return
    _ram_landed = true
    if player.has_method("take_damage"):
        player.take_damage(contact_damage, global_position, self)
    if "velocity" in player:
        var d: Vector3 = _ram_dir if _ram_dir.length() > 0.001 else Vector3(0, 0, -1)
        player.velocity.x = d.x * RAM_KNOCKBACK
        player.velocity.z = d.z * RAM_KNOCKBACK
        player.velocity.y = 3.5


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    rotor_area.set_deferred("monitoring", false)
    rotor_area.set_deferred("monitorable", false)
    weakpoint_area.set_deferred("monitoring", false)
    weakpoint_area.set_deferred("monitorable", false)
    blade_hit_area.set_deferred("monitoring", false)
    body_shape.set_deferred("disabled", true)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3(1.4, 0.10, 1.4), 0.40)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.0, 1.0), -here.y, randf_range(-1.0, 1.0))
        parent.call_deferred("add_child", p)
    for i in range(heart_drop_count):
        var h := HeartPickup.instantiate()
        h.position = here + Vector3(randf_range(-0.5, 0.5), -here.y, randf_range(-0.5, 0.5))
        parent.call_deferred("add_child", h)


func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    if state != State.STUNNED and state != State.HURT:
        weakpoint_exposed = false
        weakpoint_area.set_deferred("monitorable", false)
        # Spin back up: blades are dangerous again as soon as we leave
        # stunned/hurt. They were disabled when entering STUNNED so the
        # player could approach and hit the underside safely.
        blade_hit_area.set_deferred("monitoring", true)
    if state == State.HOVER and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
    elif state == State.RAM:
        SoundBank.play_3d("blob_attack", global_position)


# Block/parry routes here too — same response as a charge-stagger.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    if state == State.CHARGE or state == State.RAM:
        _enter_stunned()
    else:
        _set_state(State.HURT)
