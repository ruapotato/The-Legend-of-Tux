extends RefCounted

# Action-based state machine for Tux. Free-camera combat (no lock-on);
# inspired by stamina-gated melee like Valheim — light attack, hold-to-
# block with a parry window, roll-dodge with i-frames, sprint.
#
# The owning CharacterBody3D feeds inputs each tick, calls step(delta),
# then reads vel, face_yaw, and the requested anim tag. The state
# machine itself never touches the scene tree.

# ---- Actions -----------------------------------------------------------
enum {
    ACT_IDLE,
    ACT_MOVE,
    ACT_ATTACK,
    ACT_JAB,
    ACT_JUMP_ATTACK,
    ACT_CHARGING,
    ACT_SPIN,
    ACT_BLOCK,
    ACT_ROLL,
    ACT_FLIP,
    ACT_JUMP,
    ACT_FALL,
    ACT_LAND,
    ACT_HURT,
    ACT_DEAD,
}

# Flip variants — set when ACT_FLIP starts; the animator uses it to pick
# the right pose (front/back/side).
enum FlipKind { FRONT, BACK, SIDE_LEFT, SIDE_RIGHT }

# Animation tags consumed by tux_anim.gd. String-typed so the animator
# doesn't have to import this file's enum.
const ANIM_IDLE          := "idle"
const ANIM_WALK          := "walk"
const ANIM_RUN           := "run"
const ANIM_SPRINT        := "sprint"
const ANIM_SWING_1       := "swing_1"
const ANIM_SWING_2       := "swing_2"
const ANIM_SWING_3       := "swing_3"
const ANIM_JAB           := "jab"
const ANIM_JUMP_ATTACK   := "jump_attack"
const ANIM_CHARGING      := "charging"
const ANIM_CHARGING_FULL := "charging_full"
const ANIM_SPIN          := "spin"
const ANIM_BLOCK_RAISE   := "block_raise"
const ANIM_BLOCK_HOLD    := "block_hold"
const ANIM_BLOCK_WALK    := "block_walk"
const ANIM_PARRY         := "parry"
const ANIM_ROLL          := "roll"
const ANIM_FRONT_FLIP    := "front_flip"
const ANIM_BACK_FLIP     := "back_flip"
const ANIM_SIDE_FLIP_L   := "side_flip_left"
const ANIM_SIDE_FLIP_R   := "side_flip_right"
const ANIM_JUMP          := "jump"
const ANIM_FALL          := "fall"
const ANIM_LAND          := "land"
const ANIM_HURT          := "hurt"
const ANIM_DEAD          := "dead"

# ---- Tuning (Godot units; m, m/s, s) -----------------------------------
const WALK_MAX_VEL         := 4.0
const RUN_MAX_VEL          := 6.5
const SPRINT_MAX_VEL       := 9.5
const RUN_ANIM_THRESHOLD   := 4.5
const ACCEL                := 26.0
# 24 rad/s = ~1370°/s — turning is essentially instant for human-sized
# stick flicks. Combined with the snap-on-action-start in idle/move,
# Tux pivots without the U-shaped arc the old slower rate produced.
const TURN_RATE            := 24.0
const GRAVITY              := 28.0
const TERMINAL_VEL         := -22.0
const JUMP_IMPULSE         := 9.0

const SWING_DURATION       := 0.32
# Active hitbox window: starts a few frames into the swing, closes as the
# arm passes through. Contact-time outside this is whiff/recovery.
const SWING_HIT_WINDOW     := Vector2(0.07, 0.22)
# Combo chain window: pressing attack inside this slice of the current
# swing queues the next combo step. Outside it, the press is buffered
# only briefly so spam doesn't auto-chain forever.
const SWING_COMBO_WINDOW   := Vector2(0.14, SWING_DURATION)
# After the active hitbox closes, movement input cancels the recovery
# tail so the player isn't stuck mid-anim. Combo press still wins if it
# came earlier (combo_queued was set during SWING_COMBO_WINDOW).
const SWING_MOVE_CANCEL    := 0.22

# Forward thrust ("jab") triggered by stick-forward + attack press. Quick,
# narrow hit window, lower stamina cost than a full swing.
const JAB_DURATION         := 0.30
const JAB_HIT_WINDOW       := Vector2(0.08, 0.20)

# Down-strike: pressing attack while airborne. Drives Tux down at a
# controlled speed (slower than terminal so the strike reads), commits
# to the facing direction at strike-start (no side steering), and
# continues with a small forward push so you land further than you
# jumped from.
const JUMP_ATTACK_DURATION   := 0.7
const JUMP_ATTACK_FALL_VEL   := -8.5
const JUMP_ATTACK_FWD_SPEED  := 4.5

# Charge → spin. CHARGING starts at the end of a swing (or jab) if the
# player is still holding the attack button and didn't queue a combo.
# Once charge_time crosses CHARGE_TIME_FOR_SPIN the visual switches to
# "fully charged" and releasing the button fires the spin attack.
const CHARGE_TIME_FOR_SPIN := 1.0
const CHARGE_DRAIN_PER_SEC := 5.0    # stamina cost while holding charge
const SPIN_DURATION        := 0.45
const SPIN_HIT_WINDOW      := Vector2(0.05, 0.40)

const ROLL_SPEED           := 8.5
const ROLL_DURATION        := 0.45
const ROLL_IFRAME_END      := 0.38        # i-frames cover most of the roll

# Flip dodge from shield: short hop in the stick's direction, full
# rotation of the rig around the appropriate axis. I-frames cover most
# of the move so it works as an evasive option, not just a stunt.
const FLIP_DURATION        := 0.55
const FLIP_IFRAME_END      := 0.45
const FLIP_SPEED           := 7.0
const FLIP_IMPULSE         := 7.0

# Block locomotion + face-tracking. The shield doesn't lock you in
# place — you can walk slowly while raising it, and your facing slowly
# rotates to follow camera-forward so you can keep the shield pointed
# at a circling enemy by aiming the camera.
const BLOCK_WALK_SPEED     := 2.2
const BLOCK_FACE_TURN      := 6.0     # rad/s — slower than free turn

# Knockback applied to the attacker when their hit is parried/blocked.
# tux_player passes these to attacker.get_knockback() if available.
const BLOCK_PUSH_FORCE     := 7.0
const PARRY_PUSH_FORCE     := 11.0

# Block is hold-to-raise; the first PARRY_WINDOW seconds count as a
# parry (deflects with no stamina cost). After that, regular block —
# costs stamina on each hit, holds position.
const BLOCK_RAISE_DURATION := 0.12
const PARRY_WINDOW         := 0.20

const HURT_DURATION        := 0.40
const HURT_KNOCKBACK       := 5.0

# Stamina costs (consumed via the `stamina_*` callbacks set by the owner).
const COST_ROLL            := 25
const COST_BLOCK_HIT       := 30
const COST_SPRINT_PER_SEC  := 10
const COST_SWING           := 8
const COST_JAB             := 6
const COST_JUMP_ATTACK     := 12
const COST_SPIN            := 30

# ---- Inputs (set by owner each tick) -----------------------------------
var input_stick: Vector2 = Vector2.ZERO
var input_attack_pressed: bool = false
var input_attack_held: bool = false
var input_shield_held: bool = false
var input_jump_pressed: bool = false
var input_roll_pressed: bool = false
var input_sprint_held: bool = false
var input_camera_yaw: float = 0.0

# Stamina is owned by the host (game_state autoload); the state machine
# only reads it via these callbacks. Default no-ops let the file run in
# isolation for tests.
var get_stamina: Callable = func() -> int: return 100
var spend_stamina: Callable = func(_amount: int) -> void: pass

# Physics-world feedback (set by owner each tick).
var is_on_floor: bool = false
var pos: Vector3 = Vector3.ZERO

# ---- State -------------------------------------------------------------
var action: int = ACT_IDLE
var prev_action: int = ACT_IDLE
var action_time: float = 0.0
var vel: Vector3 = Vector3.ZERO
var face_yaw: float = 0.0

# Mid-attack flags read by the owner each tick.
var hit_window_active: bool = false
var spin_hit_active: bool = false      # true while spin attack hitbox open
var swing_index: int = 0       # rotates 0/1/2 across consecutive swings
var combo_queued: bool = false
var parry_active: bool = false   # true during PARRY_WINDOW after raising shield
var charge_time: float = 0.0    # accumulated while in ACT_CHARGING
var flip_kind: int = FlipKind.BACK    # set by _begin_shield_flip()

# ---- Animation request -------------------------------------------------
var requested_anim: String = ANIM_IDLE
var requested_anim_speed: float = 1.0
var requested_anim_reset: bool = false
var _last_requested_anim: String = ""

var _step_delta: float = 0.0


func set_action(new_action: int) -> bool:
    prev_action = action
    action = new_action
    action_time = 0.0
    return true


func step(delta: float) -> void:
    _step_delta = delta
    hit_window_active = false
    spin_hit_active = false
    parry_active = false
    requested_anim_reset = false

    var safety := 6
    while safety > 0:
        var changed := false
        match action:
            ACT_IDLE:        changed = _act_idle(delta)
            ACT_MOVE:        changed = _act_move(delta)
            ACT_ATTACK:      changed = _act_attack(delta)
            ACT_JAB:         changed = _act_jab(delta)
            ACT_JUMP_ATTACK: changed = _act_jump_attack(delta)
            ACT_CHARGING:    changed = _act_charging(delta)
            ACT_SPIN:        changed = _act_spin(delta)
            ACT_BLOCK:       changed = _act_block(delta)
            ACT_ROLL:        changed = _act_roll(delta)
            ACT_FLIP:        changed = _act_flip(delta)
            ACT_JUMP:        changed = _act_jump(delta)
            ACT_FALL:        changed = _act_fall(delta)
            ACT_LAND:        changed = _act_land(delta)
            ACT_HURT:        changed = _act_hurt(delta)
            ACT_DEAD:        changed = _act_dead(delta)
            _:               changed = set_action(ACT_IDLE)
        if not changed:
            break
        safety -= 1
    action_time += delta


# ---- Actions -----------------------------------------------------------

func _act_idle(_delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FALL)
    if input_shield_held:
        return set_action(ACT_BLOCK)
    if input_attack_pressed and _can_swing():
        return _begin_attack_or_jab()
    if input_roll_pressed and _can_roll():
        return _begin_roll()
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_MOVE)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    _request_anim(ANIM_IDLE, 1.0)
    return false


func _act_move(delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FALL)
    if input_shield_held:
        return set_action(ACT_BLOCK)
    if input_attack_pressed and _can_swing():
        return _begin_attack_or_jab()
    if input_roll_pressed and _can_roll():
        return _begin_roll()
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() <= 0.1:
        return set_action(ACT_IDLE)

    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.001:
        var target_yaw := atan2(-stick_dir.x, -stick_dir.z)
        face_yaw = _approach_angle(face_yaw, target_yaw, TURN_RATE * delta)

    var top_speed: float = RUN_MAX_VEL
    var anim := ANIM_RUN
    if input_sprint_held and get_stamina.call() > 0:
        top_speed = SPRINT_MAX_VEL
        anim = ANIM_SPRINT
        spend_stamina.call(int(COST_SPRINT_PER_SEC * delta + 0.5))
    var target_speed: float = input_stick.length() * top_speed
    var current_speed: float = Vector2(vel.x, vel.z).length()
    var new_speed: float = move_toward(current_speed, target_speed, ACCEL * delta)
    vel.x = -sin(face_yaw) * new_speed
    vel.z = -cos(face_yaw) * new_speed
    vel.y = -1.0

    if anim == ANIM_SPRINT:
        _request_anim(ANIM_SPRINT, _speed_scale(new_speed, SPRINT_MAX_VEL))
    elif new_speed >= RUN_ANIM_THRESHOLD:
        _request_anim(ANIM_RUN, _speed_scale(new_speed, RUN_MAX_VEL))
    else:
        _request_anim(ANIM_WALK, _speed_scale(new_speed, WALK_MAX_VEL))
    return false


func _act_attack(_delta: float) -> bool:
    # Active hitbox window.
    if action_time >= SWING_HIT_WINDOW.x and action_time <= SWING_HIT_WINDOW.y:
        hit_window_active = true

    # Combo input buffering: a press inside the combo window queues the
    # next swing, which fires when the current one ends.
    if input_attack_pressed and action_time >= SWING_COMBO_WINDOW.x \
            and action_time <= SWING_COMBO_WINDOW.y and _can_swing():
        combo_queued = true

    # Recovery cancel: once the active hit window closes, movement input
    # is allowed to break out of the recovery tail. Without this the
    # player feels glued to the ground after every swing.
    if action_time >= SWING_MOVE_CANCEL and not combo_queued and input_stick.length() > 0.1:
        return set_action(ACT_MOVE)

    # Damp horizontal velocity, but gently — full hard-stop dampening
    # made the recovery feel even sluggier than the anim would suggest.
    vel.x = move_toward(vel.x, 0.0, 12.0 * _step_delta)
    vel.z = move_toward(vel.z, 0.0, 12.0 * _step_delta)
    vel.y = -1.0

    var tag := ANIM_SWING_1
    if swing_index == 1:
        tag = ANIM_SWING_2
    elif swing_index == 2:
        tag = ANIM_SWING_3
    _request_anim(tag, 1.0)

    if action_time >= SWING_DURATION:
        if combo_queued and _can_swing():
            combo_queued = false
            swing_index = (swing_index + 1) % 3
            spend_stamina.call(COST_SWING)
            return set_action(ACT_ATTACK)
        # End-of-combo: reset index so the next attack starts with the
        # opening swing pose.
        if swing_index == 2:
            swing_index = 0
        # If the player is still holding attack (with no combo press),
        # roll into a charge wind-up. Otherwise drop to idle.
        if input_attack_held:
            charge_time = 0.0
            return set_action(ACT_CHARGING)
        return set_action(ACT_IDLE)
    return false


func _act_jab(_delta: float) -> bool:
    if action_time >= JAB_HIT_WINDOW.x and action_time <= JAB_HIT_WINDOW.y:
        hit_window_active = true
    # Slight forward lunge during the thrust.
    var lunge: float = 4.0 if action_time < JAB_HIT_WINDOW.y else 0.0
    vel.x = -sin(face_yaw) * lunge
    vel.z = -cos(face_yaw) * lunge
    vel.y = -1.0
    _request_anim(ANIM_JAB, 1.0)
    if action_time >= JAB_DURATION:
        if input_attack_held:
            charge_time = 0.0
            return set_action(ACT_CHARGING)
        return set_action(ACT_IDLE)
    return false


# Aerial down-strike. On entry we snap face_yaw to the player's current
# camera-relative input (or current facing) so the strike commits to a
# direction. Lateral input is ignored — only forward/back stick adjusts
# the constant forward push, so you can't slide sideways mid-strike.
# Vertical motion uses normal gravity but caps the descent speed at
# JUMP_ATTACK_FALL_VEL — this lets initial upward momentum (the small
# hop from shield→attack) carry through as a natural arc instead of
# getting squashed flat by a forced constant downward velocity.
func _act_jump_attack(_delta: float) -> bool:
    hit_window_active = true

    if action_time == 0.0:
        var stick_dir := _stick_to_world_dir()
        if stick_dir.length() > 0.1:
            face_yaw = atan2(-stick_dir.x, -stick_dir.z)

    var fwd := Vector3(-sin(face_yaw), 0.0, -cos(face_yaw))
    var fwd_speed: float = JUMP_ATTACK_FWD_SPEED
    if input_stick.y < -0.2:
        fwd_speed *= 1.5
    elif input_stick.y > 0.2:
        fwd_speed *= 0.5
    vel.x = fwd.x * fwd_speed
    vel.z = fwd.z * fwd_speed
    # Apply gravity with a descent cap so the strike still reads as
    # "committed downward" once you crest, but a hop into the strike
    # actually rises first.
    vel.y -= GRAVITY * _step_delta
    if vel.y < JUMP_ATTACK_FALL_VEL:
        vel.y = JUMP_ATTACK_FALL_VEL

    _request_anim(ANIM_JUMP_ATTACK, 1.0)
    if is_on_floor and action_time > 0.05:
        return set_action(ACT_LAND)
    if action_time >= JUMP_ATTACK_DURATION:
        return set_action(ACT_FALL)
    return false


# Hold-charge wind-up. Stamina drains slowly while charging. After
# CHARGE_TIME_FOR_SPIN seconds the visual switches to "fully charged".
# Releasing the button at any time exits — to ACT_SPIN if fully charged
# (and stamina available), else back to IDLE.
func _act_charging(delta: float) -> bool:
    charge_time += delta
    spend_stamina.call(int(CHARGE_DRAIN_PER_SEC * delta + 0.5))
    vel.x = move_toward(vel.x, 0.0, 16.0 * _step_delta)
    vel.z = move_toward(vel.z, 0.0, 16.0 * _step_delta)
    vel.y = -1.0

    if charge_time < CHARGE_TIME_FOR_SPIN:
        _request_anim(ANIM_CHARGING, 1.0)
    else:
        _request_anim(ANIM_CHARGING_FULL, 1.0)

    # Released — decide between spin and bail.
    if not input_attack_held:
        if charge_time >= CHARGE_TIME_FOR_SPIN and get_stamina.call() >= COST_SPIN:
            spend_stamina.call(COST_SPIN)
            return set_action(ACT_SPIN)
        return set_action(ACT_IDLE)

    # Stamina ran out → can't sustain charge.
    if get_stamina.call() <= 0:
        return set_action(ACT_IDLE)

    # Allow normal cancel options that should override charging.
    if input_roll_pressed and _can_roll():
        return _begin_roll()
    if input_shield_held:
        return set_action(ACT_BLOCK)
    return false


# 360 spin attack. Hitbox is active across most of the duration; the
# owner reads spin_hit_active and uses a wider radial hitbox shape.
func _act_spin(_delta: float) -> bool:
    if action_time >= SPIN_HIT_WINDOW.x and action_time <= SPIN_HIT_WINDOW.y:
        spin_hit_active = true
    vel.x = move_toward(vel.x, 0.0, 14.0 * _step_delta)
    vel.z = move_toward(vel.z, 0.0, 14.0 * _step_delta)
    vel.y = -1.0
    _request_anim(ANIM_SPIN, 1.0)
    if action_time >= SPIN_DURATION:
        return set_action(ACT_IDLE)
    return false


func _act_block(_delta: float) -> bool:
    # Parry window covers the very start of the block raise.
    if action_time < PARRY_WINDOW:
        parry_active = true

    if not input_shield_held:
        return set_action(ACT_IDLE)
    # Shield + attack → small jump-strike that commits forward with the
    # swipe-down animation. Lets the shield pressure into a counter.
    if input_attack_pressed and _can_swing():
        return _begin_shield_jump_slash()
    # Shield + jump → directional flip dodge.
    if input_jump_pressed and _can_roll():
        return _begin_shield_flip()
    if input_roll_pressed and _can_roll():
        return _begin_roll()

    # Slow walk while shielded so the player can reposition without
    # dropping the guard. Speed is capped at BLOCK_WALK_SPEED — well
    # under WALK_MAX_VEL — and accelerates more slowly than free walk.
    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.1:
        vel.x = stick_dir.x * BLOCK_WALK_SPEED * input_stick.length()
        vel.z = stick_dir.z * BLOCK_WALK_SPEED * input_stick.length()
    else:
        vel.x = move_toward(vel.x, 0.0, 16.0 * _step_delta)
        vel.z = move_toward(vel.z, 0.0, 16.0 * _step_delta)
    vel.y = -1.0

    # Slowly rotate facing toward camera-forward so the shield tracks
    # where the player is aiming. The slow turn lets the player keep an
    # enemy framed by the shield via small mouse adjustments.
    face_yaw = _approach_angle(face_yaw, input_camera_yaw, BLOCK_FACE_TURN * _step_delta)

    var moving: bool = stick_dir.length() > 0.1
    if action_time < BLOCK_RAISE_DURATION:
        _request_anim(ANIM_BLOCK_RAISE, 1.0)
    elif parry_active:
        _request_anim(ANIM_PARRY, 1.0)
    elif moving:
        _request_anim(ANIM_BLOCK_WALK, 1.0)
    else:
        _request_anim(ANIM_BLOCK_HOLD, 1.0)
    return false


# Aerial flip dodge from a shielded jump. The flip kind is picked from
# the stick: forward = front flip, backward = back flip, sideways = side
# flip. Movement is committed for the whole jump; air control is locked.
func _act_flip(_delta: float) -> bool:
    _apply_gravity()
    var tag := ANIM_BACK_FLIP
    match flip_kind:
        FlipKind.FRONT:      tag = ANIM_FRONT_FLIP
        FlipKind.BACK:       tag = ANIM_BACK_FLIP
        FlipKind.SIDE_LEFT:  tag = ANIM_SIDE_FLIP_L
        FlipKind.SIDE_RIGHT: tag = ANIM_SIDE_FLIP_R
    _request_anim(tag, 1.0)
    if is_on_floor and action_time > 0.10:
        return set_action(ACT_LAND)
    if action_time >= FLIP_DURATION:
        return set_action(ACT_FALL)
    return false


func _act_roll(_delta: float) -> bool:
    var t: float = action_time / ROLL_DURATION
    var speed := lerpf(ROLL_SPEED, ROLL_SPEED * 0.4, t)
    vel.x = -sin(face_yaw) * speed
    vel.z = -cos(face_yaw) * speed
    vel.y = -1.0
    _request_anim(ANIM_ROLL, 1.0)
    if action_time >= ROLL_DURATION:
        return set_action(ACT_IDLE)
    return false


func _act_jump(_delta: float) -> bool:
    if action_time == 0.0:
        vel.y = JUMP_IMPULSE
    if input_attack_pressed and get_stamina.call() >= COST_JUMP_ATTACK:
        spend_stamina.call(COST_JUMP_ATTACK)
        return set_action(ACT_JUMP_ATTACK)
    _air_steer()
    _apply_gravity()
    _request_anim(ANIM_JUMP, 1.0)
    if vel.y < 0.0:
        return set_action(ACT_FALL)
    if is_on_floor and action_time > 0.05:
        return set_action(ACT_LAND)
    return false


func _act_fall(_delta: float) -> bool:
    if input_attack_pressed and get_stamina.call() >= COST_JUMP_ATTACK:
        spend_stamina.call(COST_JUMP_ATTACK)
        return set_action(ACT_JUMP_ATTACK)
    _air_steer()
    _apply_gravity()
    _request_anim(ANIM_FALL, 1.0)
    if is_on_floor and action_time > 0.02:
        return set_action(ACT_LAND)
    return false


func _act_land(_delta: float) -> bool:
    vel.x = move_toward(vel.x, 0.0, 30.0 * _step_delta)
    vel.z = move_toward(vel.z, 0.0, 30.0 * _step_delta)
    vel.y = -1.0
    _request_anim(ANIM_LAND, 1.0)
    if action_time >= 0.18:
        return set_action(ACT_IDLE)
    return false


func _act_hurt(_delta: float) -> bool:
    _apply_gravity()
    vel.x = move_toward(vel.x, 0.0, 8.0 * _step_delta)
    vel.z = move_toward(vel.z, 0.0, 8.0 * _step_delta)
    _request_anim(ANIM_HURT, 1.0)
    if action_time >= HURT_DURATION:
        return set_action(ACT_IDLE)
    return false


func _act_dead(_delta: float) -> bool:
    vel = Vector3.ZERO
    _request_anim(ANIM_DEAD, 1.0)
    return false


# ---- Externally-driven transitions -------------------------------------

# Called by the owner when a hit lands on the player. Returns true if the
# damage should actually be applied (i.e. wasn't absorbed by parry/block/
# i-frames).
func take_hit(source_pos: Vector3, _damage: int) -> bool:
    if action == ACT_DEAD:
        return false
    # Full-roll invulnerability — Tux is bowling-pin tight from the
    # moment the roll starts until it resolves into IDLE/MOVE. (Was
    # gated on ROLL_IFRAME_END; the user wanted the whole roll to be
    # an escape move, not just a window.)
    if action == ACT_ROLL:
        return false
    if action == ACT_FLIP and action_time <= FLIP_IFRAME_END:
        return false
    # Already-hurt i-frames: the entire HURT state is invulnerable so a
    # bat can't chain-stun by re-hitting on every swoop, and the
    # player has time to recover position before the next blow.
    if action == ACT_HURT:
        return false

    # Directional shield: only blocks hits that come from roughly in
    # front of the player. Sources behind/to-the-side punch through
    # the guard so an enemy that flanks you while you turtle gets
    # rewarded. Cone is dot(forward, to_source) > 0 — anything in
    # the front half-plane.
    var shielded_front: bool = false
    if action == ACT_BLOCK:
        var fwd: Vector3 = Vector3(-sin(face_yaw), 0.0, -cos(face_yaw))
        var to_src: Vector3 = source_pos - pos
        to_src.y = 0.0
        if to_src.length() > 0.001:
            shielded_front = fwd.dot(to_src.normalized()) > 0.0
        else:
            shielded_front = true   # source-on-top edge case

    # Parry: free deflect inside the parry window — but only if the
    # attack came from in front. Side/back hits ignore parry too.
    if action == ACT_BLOCK and parry_active and shielded_front:
        return false
    # Regular block: absorb if facing the source AND have stamina.
    if action == ACT_BLOCK and shielded_front \
            and get_stamina.call() >= COST_BLOCK_HIT:
        spend_stamina.call(COST_BLOCK_HIT)
        # Light shove on a successful block.
        var away := pos - source_pos
        away.y = 0.0
        if away.length() > 0.001:
            away = away.normalized()
            vel.x = away.x * 2.0
            vel.z = away.z * 2.0
        return false

    # Hit landed (block missed direction or stamina ran out).
    var knock := pos - source_pos
    knock.y = 0.0
    if knock.length() > 0.001:
        knock = knock.normalized()
        vel.x = knock.x * HURT_KNOCKBACK
        vel.z = knock.z * HURT_KNOCKBACK
    set_action(ACT_HURT)
    return true


func kill() -> void:
    set_action(ACT_DEAD)


# ---- Helpers -----------------------------------------------------------

func _can_swing() -> bool:
    return get_stamina.call() >= COST_SWING


func _can_roll() -> bool:
    return is_on_floor and get_stamina.call() >= COST_ROLL


func _begin_shield_jump_slash() -> bool:
    if get_stamina.call() < COST_JUMP_ATTACK:
        return false
    spend_stamina.call(COST_JUMP_ATTACK)
    # Real hop now that JUMP_ATTACK applies gravity instead of pinning
    # vel.y; 90% of a full jump impulse gives a satisfying leap into
    # the strike without overshooting.
    vel.y = JUMP_IMPULSE * 0.9
    return set_action(ACT_JUMP_ATTACK)


func _begin_shield_flip() -> bool:
    if get_stamina.call() < COST_ROLL:
        return false
    spend_stamina.call(COST_ROLL)
    # Pick the flip kind from stick. Defaults to a back flip when the
    # stick is neutral so a held-shield + jump still does something
    # readable.
    if abs(input_stick.x) > 0.3 and abs(input_stick.x) > abs(input_stick.y):
        flip_kind = FlipKind.SIDE_RIGHT if input_stick.x > 0 else FlipKind.SIDE_LEFT
    elif input_stick.y < -0.3:
        flip_kind = FlipKind.FRONT
    else:
        flip_kind = FlipKind.BACK

    # `right` is forward × up; previous version had both signs flipped,
    # which is why pushing right launched the side-flip leftward.
    var fwd := Vector3(-sin(face_yaw), 0.0, -cos(face_yaw))
    var right := Vector3(cos(face_yaw), 0.0, -sin(face_yaw))
    var move_dir := Vector3.ZERO
    match flip_kind:
        FlipKind.FRONT:      move_dir = fwd
        FlipKind.BACK:       move_dir = -fwd
        FlipKind.SIDE_RIGHT: move_dir = right
        FlipKind.SIDE_LEFT:  move_dir = -right
    vel.y = FLIP_IMPULSE
    vel.x = move_dir.x * FLIP_SPEED
    vel.z = move_dir.z * FLIP_SPEED
    return set_action(ACT_FLIP)


func _begin_attack_or_jab() -> bool:
    combo_queued = false
    # Forward thrust if the player is leaning hard into the stick. The
    # facing also snaps to the stick direction so the jab actually goes
    # where they're aiming, not where they happened to be turned.
    var stick_dir := _stick_to_world_dir()
    if input_stick.length() > 0.6 and stick_dir.length() > 0.001:
        face_yaw = atan2(-stick_dir.x, -stick_dir.z)
        if get_stamina.call() >= COST_JAB:
            spend_stamina.call(COST_JAB)
            return set_action(ACT_JAB)
    spend_stamina.call(COST_SWING)
    return set_action(ACT_ATTACK)


func _begin_roll() -> bool:
    spend_stamina.call(COST_ROLL)
    # Roll direction: toward the stick if held, else along current facing.
    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.1:
        face_yaw = atan2(-stick_dir.x, -stick_dir.z)
    return set_action(ACT_ROLL)


func _air_steer() -> void:
    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.01:
        var target_x: float = stick_dir.x * RUN_MAX_VEL * 0.7
        var target_z: float = stick_dir.z * RUN_MAX_VEL * 0.7
        vel.x = move_toward(vel.x, target_x, 8.0 * _step_delta)
        vel.z = move_toward(vel.z, target_z, 8.0 * _step_delta)


func _apply_gravity() -> void:
    vel.y -= GRAVITY * _step_delta
    if vel.y < TERMINAL_VEL:
        vel.y = TERMINAL_VEL


func _stick_to_world_dir() -> Vector3:
    if input_stick.length() < 0.001:
        return Vector3.ZERO
    var cy := cos(input_camera_yaw)
    var sy := sin(input_camera_yaw)
    var forward := Vector3(-sy, 0.0, -cy)
    var right := Vector3(cy, 0.0, -sy)
    return (right * input_stick.x + forward * (-input_stick.y)).normalized()


func _speed_scale(current: float, max_speed: float) -> float:
    return clamp(0.5 + (current / max_speed) * 0.7, 0.5, 1.6)


func _approach_angle(current: float, target: float, max_step: float) -> float:
    var diff := wrapf(target - current, -PI, PI)
    if abs(diff) <= max_step:
        return target
    return current + sign(diff) * max_step


func _request_anim(name: String, speed: float) -> void:
    requested_anim = name
    requested_anim_speed = speed
    requested_anim_reset = (name != _last_requested_anim)
    _last_requested_anim = name
