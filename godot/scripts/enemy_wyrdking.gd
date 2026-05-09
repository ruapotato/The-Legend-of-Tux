extends CharacterBody3D

# Wyrdking Bonelord — the boss of the Hollow of the Last Wyrd. A
# bigger, slower, meaner cousin of the Bone Knight. Self-contained:
# does NOT extend or instance enemy_bone_knight.gd; this is the only
# script the boss runs. It uses the same shared tux_rig.tscn as a
# visual base, scaled up, with bone palette + crown + ember eye-glow.
#
# State machine:
#   IDLE          — waiting for the player; turn slowly.
#   APPROACH      — close the gap on foot, shield down.
#   TELEGRAPH     — overhead wind-up: arm raised, sword glowing brighter,
#                   0.8s. Player has time to dodge or interrupt.
#   OVERHEAD_SLAM — slam forward + spawn a radial shockwave Area3D for
#                   ~0.18s. The player gets damaged either by the sword
#                   reach OR by being near the impact when it lands.
#   RECOVER       — long post-slam pause; vulnerable.
#   DEFEND        — turtle: shield raised; counts player blocks. After
#                   3 blocked swings he commits to SHIELD_CHARGE.
#   SHIELD_CHARGE — bull-rush forward 0.6s with shield up. Touching him
#                   deals contact_damage and knocks the player back.
#   HURT          — knockback after a hit lands.
#   DEAD          — flatten + despawn.
#
# Counter-play:
#   - OVERHEAD_SLAM has the longest tell in the game (0.8s) but the AoE
#     means you can't just hug his side; you have to dodge OUT.
#   - SHIELD_CHARGE is unblockable but the path is straight; dodge-roll
#     past his shoulder.
#   - DEFEND breaks if he commits to a charge — so spamming attack
#     PROVOKES the worse attack. Players have to pause and read.
#
# Drops 8 pebbles on death and sets GameState.inventory.wyrdking_defeated
# so the wider world can react (NPC dialogue, gate states, etc.). The
# heart container is dropped by the surrounding boss_arena framework
# via the `died` signal — we don't drop it ourselves.

const TuxAnim = preload("res://scripts/tux_anim.gd")
const TuxState = preload("res://scripts/tux_state.gd")
const PebblePickup = preload("res://scenes/pickup_pebble.tscn")

signal died

@export var max_hp: int = 24
@export var detect_range: float = 16.0
@export var attack_range: float = 3.2
@export var move_speed: float = 1.7
@export var charge_speed: float = 8.5
@export var contact_damage: int = 3
@export var attack_damage: int = 4
@export var pebble_reward: int = 8

const GRAVITY: float = 24.0
const TELEGRAPH_TIME: float = 0.80
const SLAM_DURATION: float = 0.45
const SLAM_HIT_WINDOW: Vector2 = Vector2(0.05, 0.22)
const SHOCKWAVE_LIFETIME: float = 0.20
const SHOCKWAVE_RADIUS: float = 2.6
const RECOVER_TIME: float = 0.85
const DEFEND_TIME: float = 1.4
const SHIELD_CHARGE_TIME: float = 0.6
const SHIELD_CHARGE_COOLDOWN: float = 1.6
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 5.0
const CHARGE_KNOCKBACK: float = 8.0
# Direct hit cone for the slam. The Area3D shockwave covers AoE; the
# direct sword reach is a separate front-arc check that lands an extra
# tick of damage if the player is right in front of him on impact.
const SLAM_REACH: float = 3.6
const SLAM_CONE_DOT: float = 0.30
# Front-arc threshold for blocking incoming hits (matches bone knight's
# 70-degree cone) — blocks from behind always go through.
const DEFEND_FACE_DOT: float = 0.30
# Number of CONSECUTIVE successful blocks required to commit to a
# shield charge. Decays after STREAK_DECAY_TIME with no new attacks.
const CHARGE_BLOCK_THRESHOLD: int = 3
# Two blocks worth of player pressure also extends the shield duration
# (turtle behavior, like the bone knight, but the threshold is higher
# and the duration longer because we ALSO trigger a charge after 3).
const STREAK_TURTLE_AT: int = 2
const STREAK_DECAY_TIME: float = 2.4
const DEFEND_TIME_TURTLE: float = 2.2

enum State { IDLE, APPROACH, TELEGRAPH, OVERHEAD_SLAM, RECOVER,
             DEFEND, SHIELD_CHARGE, HURT, DEAD }

var hp: int = 24
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var anim: RefCounted
var bones: Dictionary = {}

# Player-pressure / block tracking.
var _player_was_attacking: bool = false
var _p_attack_streak: int = 0
var _p_streak_decay: float = 0.0
var _blocks_in_a_row: int = 0
var _last_charge_t: float = -1000.0

# Slam state.
var _slam_landed: bool = false
var _shockwave_spawned: bool = false
var _charge_dir: Vector3 = Vector3.ZERO

@onready var rig: Node3D = $Rig
@onready var sword: Node3D = $Sword
@onready var shield_node: Node3D = $Shield
@onready var hitbox: Area3D = $Hitbox
@onready var crown: Node3D = $Crown
@onready var blade_mesh: MeshInstance3D = $Sword/Blade
@onready var eye_glow: OmniLight3D = $EyeGlow


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")

    anim = TuxAnim.new()
    bones = {
        "pelvis": rig.get_node("pelvis"),
        "torso":  rig.get_node("pelvis/torso"),
        "head":   rig.get_node("pelvis/torso/head"),
        "arm_l":  rig.get_node("pelvis/torso/arm_l"),
        "arm_r":  rig.get_node("pelvis/torso/arm_r"),
        "leg_l":  rig.get_node("pelvis/leg_l"),
        "leg_r":  rig.get_node("pelvis/leg_r"),
    }
    anim.setup(bones)

    # Reparent weapons under the wing pivots so they ride the animation.
    var arm_r: Node3D = bones["arm_r"]
    var arm_l: Node3D = bones["arm_l"]
    remove_child(sword)
    arm_r.add_child(sword)
    sword.transform = Transform3D(Basis.IDENTITY, Vector3(-0.07, -0.42, 0))
    remove_child(shield_node)
    arm_l.add_child(shield_node)
    shield_node.transform = Transform3D(
        Basis(Vector3(1, 0, 0), PI / 2), Vector3(0.07, -0.40, 0))
    # Also parent the crown atop the head so it follows the bob/turn.
    var head: Node3D = bones["head"]
    remove_child(crown)
    head.add_child(crown)
    crown.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.20, 0))

    _apply_bone_materials()


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

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    # Track player attack edges for the block-streak / turtle logic.
    var p_attack: bool = _player_is_attacking()
    var p_attack_started: bool = p_attack and not _player_was_attacking
    _player_was_attacking = p_attack
    if p_attack_started:
        _p_attack_streak += 1
        _p_streak_decay = 0.0
    else:
        _p_streak_decay += delta
        if _p_streak_decay > STREAK_DECAY_TIME:
            _p_attack_streak = 0
            _blocks_in_a_row = 0
            _p_streak_decay = 0.0

    # Reactive shield raise. Only from non-committed states; the slam
    # window has to commit through and shield_charge has its own posture.
    if p_attack_started and dist < attack_range * 1.7 and _facing_player(to_player):
        if state in [State.IDLE, State.APPROACH, State.RECOVER]:
            _set_state(State.DEFEND)
        elif state == State.DEFEND:
            state_time = 0.0   # refresh — chain pressure keeps shield up

    match state:
        State.IDLE:           _do_idle(delta, to_player, dist)
        State.APPROACH:       _do_approach(delta, to_player, dist)
        State.TELEGRAPH:      _do_telegraph(delta, to_player)
        State.OVERHEAD_SLAM:  _do_slam(delta)
        State.RECOVER:        _do_recover(delta, dist)
        State.DEFEND:         _do_defend(delta, to_player, dist)
        State.SHIELD_CHARGE:  _do_shield_charge(delta)
        State.HURT:           _do_hurt(delta, dist)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()
    anim.tick(delta)


# ---- Per-state handlers ------------------------------------------------

func _do_idle(delta: float, _to_player: Vector3, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 8.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 8.0 * delta)
    anim.play("idle")
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
    anim.play("walk")


func _do_telegraph(delta: float, to_player: Vector3) -> void:
    velocity.x = move_toward(velocity.x, 0, 12.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 12.0 * delta)
    if to_player.length_squared() > 1e-6:
        var dir: Vector3 = to_player.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    anim.play("swing_3")     # overhead chop wind-up
    # Pulse the sword's emission to telegraph the slam — read by
    # _telegraph_glow each frame.
    _telegraph_glow(state_time / TELEGRAPH_TIME)
    if state_time >= TELEGRAPH_TIME:
        _set_state(State.OVERHEAD_SLAM)


func _do_slam(delta: float) -> void:
    var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
    if state_time >= SLAM_HIT_WINDOW.x and state_time <= SLAM_HIT_WINDOW.y:
        # Lunge forward briefly; otherwise the slam is too stationary.
        velocity.x = fwd.x * (charge_speed * 0.55)
        velocity.z = fwd.z * (charge_speed * 0.55)
        if not _shockwave_spawned:
            _shockwave_spawned = true
            _spawn_shockwave(global_position + fwd * 1.4)
        # Direct front-cone bite during the active window. One-shot.
        if not _slam_landed and player and is_instance_valid(player):
            var to_p: Vector3 = player.global_position - global_position
            to_p.y = 0
            var d: float = to_p.length()
            if d > 0.05 and d < SLAM_REACH:
                var to_p_n: Vector3 = to_p / d
                if fwd.dot(to_p_n) > SLAM_CONE_DOT:
                    _slam_landed = true
                    if player.has_method("take_damage"):
                        SoundBank.play_3d("sword_hit", global_position)
                        player.take_damage(attack_damage, global_position, self)
    else:
        velocity.x = move_toward(velocity.x, 0, 18.0 * delta)
        velocity.z = move_toward(velocity.z, 0, 18.0 * delta)
    anim.play("swing_1")
    if state_time >= SLAM_DURATION:
        _set_state(State.RECOVER)


func _do_recover(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 12.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 12.0 * delta)
    anim.play("idle")
    if state_time >= RECOVER_TIME:
        if dist < detect_range:
            _set_state(State.APPROACH)
        else:
            _set_state(State.IDLE)


func _do_defend(delta: float, to_player: Vector3, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 14.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 14.0 * delta)
    if to_player.length_squared() > 1e-6:
        var dir: Vector3 = to_player.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    anim.play("block_hold")

    # Block streak triggers a shield charge — the punishing answer to
    # the player blindly chaining swings into a turtled boss. Cooldown
    # so back-to-back charges can't lock the player out.
    var now: float = Time.get_ticks_msec() / 1000.0
    if _blocks_in_a_row >= CHARGE_BLOCK_THRESHOLD \
            and now - _last_charge_t > SHIELD_CHARGE_COOLDOWN \
            and dist < detect_range:
        _last_charge_t = now
        _blocks_in_a_row = 0
        _set_state(State.SHIELD_CHARGE)
        return

    var hold_for: float = DEFEND_TIME
    if _p_attack_streak >= STREAK_TURTLE_AT:
        hold_for = DEFEND_TIME_TURTLE
    if state_time >= hold_for:
        if dist < attack_range * 1.5:
            _set_state(State.TELEGRAPH)
        elif dist < detect_range:
            _set_state(State.APPROACH)
        else:
            _set_state(State.IDLE)


func _do_shield_charge(delta: float) -> void:
    # Lock the rush direction once on entry so the player can dodge
    # past a predictable line.
    if _charge_dir.length_squared() < 1e-6:
        var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
        _charge_dir = fwd
    velocity.x = _charge_dir.x * charge_speed
    velocity.z = _charge_dir.z * charge_speed
    anim.play("block_hold")
    # Body-contact check: damages + knocks back any time the boss
    # touches the player while charging. Re-armed each entry so a
    # single charge can re-hit if the player slides back into him.
    if player and is_instance_valid(player):
        var to_p: Vector3 = player.global_position - global_position
        to_p.y = 0
        var d: float = to_p.length()
        if d < 1.6 and d > 0.05:
            if player.has_method("take_damage"):
                player.take_damage(contact_damage, global_position, self)
            if "velocity" in player:
                var dir: Vector3 = _charge_dir if _charge_dir.length() > 0.001 \
                                                 else (player.global_position - global_position).normalized()
                player.velocity.x = dir.x * CHARGE_KNOCKBACK
                player.velocity.z = dir.z * CHARGE_KNOCKBACK
                player.velocity.y = 4.0
            # End the charge early so the same overlap doesn't keep
            # hammering the player with knockback ticks.
            _set_state(State.RECOVER)
            return
    if state_time >= SHIELD_CHARGE_TIME:
        _set_state(State.RECOVER)


func _do_hurt(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 6.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 6.0 * delta)
    anim.play("hurt")
    if state_time >= HURT_TIME:
        _set_state(State.APPROACH if dist < detect_range else State.IDLE)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    # Block: front-arc + DEFEND. Bumps the block streak that drives
    # the eventual SHIELD_CHARGE response.
    if state == State.DEFEND:
        var to_src: Vector3 = source_pos - global_position
        to_src.y = 0
        if to_src.length() > 0.001:
            var to_src_dir: Vector3 = to_src.normalized()
            var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
            if fwd.dot(to_src_dir) > DEFEND_FACE_DOT:
                _blocks_in_a_row += 1
                SoundBank.play_3d("shield_block", global_position)
                return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
        velocity.y = 2.5
    _hit_punch()
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


# Player parry — same response as a heavy hit, no damage. Cancels
# whatever the boss was committing to.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 3.0
    _set_state(State.HURT)


func _hit_punch() -> void:
    if not rig:
        return
    var base_scale: Vector3 = rig.scale
    rig.scale = base_scale * Vector3(1.10, 0.90, 1.10)
    var t := create_tween()
    t.tween_property(rig, "scale", base_scale, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    SoundBank.play_3d("death", global_position)
    # Persistent world flag — other systems can react to "the wyrdking
    # is gone" (NPC dialogue lines, gates, etc.).
    var gs := get_node_or_null("/root/GameState")
    if gs and "inventory" in gs:
        gs.inventory["wyrdking_defeated"] = true
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(rig, "scale", rig.scale * Vector3(1.0, 0.05, 1.0), 0.55)
    t.tween_callback(queue_free)


# Capture global_position before queue_free; set local position on each
# pickup BEFORE add_child (deferred). Boss arena drops the heart
# container via the `died` signal — we only drop pebbles here.
func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.4, 1.4), 0.0, randf_range(-1.4, 1.4))
        parent.call_deferred("add_child", p)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    # Per-state cleanup / setup.
    if state != State.OVERHEAD_SLAM:
        _slam_landed = false
        _shockwave_spawned = false
    if state != State.SHIELD_CHARGE:
        _charge_dir = Vector3.ZERO
    if state != State.TELEGRAPH:
        _telegraph_glow(0.0)   # reset the sword glow

    if state == State.APPROACH and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
    elif state == State.TELEGRAPH:
        SoundBank.play_3d("sword_charge", global_position)
    elif state == State.OVERHEAD_SLAM:
        SoundBank.play_3d("sword_swing", global_position)
    elif state == State.DEFEND:
        SoundBank.play_3d("shield_raise", global_position)
    elif state == State.SHIELD_CHARGE:
        SoundBank.play_3d("blob_attack", global_position)


# Spawn a transient Area3D shockwave at `center` that damages the
# player on contact during its short lifetime. Self-hosted so the
# script doesn't need an extra companion scene.
func _spawn_shockwave(center: Vector3) -> void:
    var parent := get_parent()
    if parent == null:
        return
    var area := Area3D.new()
    area.collision_layer = 0
    area.collision_mask = 2     # player layer
    area.monitoring = true
    area.monitorable = false
    var cs := CollisionShape3D.new()
    var sh := SphereShape3D.new()
    sh.radius = SHOCKWAVE_RADIUS
    cs.shape = sh
    area.add_child(cs)
    # Visual: low-poly ring of glowing dust on the ground. Doesn't
    # block anything — purely cosmetic so the player can read the AoE.
    var ring := MeshInstance3D.new()
    var ring_mesh := TorusMesh.new()
    ring_mesh.inner_radius = SHOCKWAVE_RADIUS * 0.55
    ring_mesh.outer_radius = SHOCKWAVE_RADIUS
    ring_mesh.rings = 3
    ring_mesh.ring_segments = 16
    ring.mesh = ring_mesh
    var ring_mat := StandardMaterial3D.new()
    ring_mat.albedo_color = Color(1.0, 0.55, 0.30, 0.85)
    ring_mat.emission_enabled = true
    ring_mat.emission = Color(1.0, 0.45, 0.20, 1)
    ring_mat.emission_energy_multiplier = 2.2
    ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    ring.material_override = ring_mat
    # TorusMesh lies in XZ already; raise it just above the ground.
    ring.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 0))
    area.add_child(ring)
    area.position = Vector3(center.x, 0.15, center.z)
    parent.call_deferred("add_child", area)

    # Damage on overlap (one-shot per spawn).
    var damaged: Array = [false]
    area.body_entered.connect(func (body):
        if damaged[0]:
            return
        if not body.is_in_group("player"):
            return
        damaged[0] = true
        if body.has_method("take_damage"):
            body.take_damage(contact_damage, area.global_position, self)
        if "velocity" in body:
            var away: Vector3 = body.global_position - area.global_position
            away.y = 0
            if away.length() > 0.01:
                away = away.normalized()
                body.velocity.x = away.x * 5.0
                body.velocity.z = away.z * 5.0
                body.velocity.y = 3.0)

    # Swell + fade, then remove. Tween targets are constructed here so
    # the area cleans itself up without a separate timer node.
    var t := create_tween()
    t.set_parallel(true)
    t.tween_property(ring, "scale", Vector3(1.4, 1.0, 1.4), SHOCKWAVE_LIFETIME)
    t.tween_property(ring_mat, "albedo_color:a", 0.0,         SHOCKWAVE_LIFETIME)
    t.chain().tween_callback(area.queue_free)


# Pulse the sword blade's emission so the wind-up is visually obvious.
# `t` is normalized 0..1 (state_time / TELEGRAPH_TIME).
func _telegraph_glow(t: float) -> void:
    if not blade_mesh:
        return
    var mat := blade_mesh.get_surface_override_material(0) as StandardMaterial3D
    if mat == null:
        return
    var glow: float = clamp(t, 0.0, 1.0) * 1.8 + 0.2
    mat.emission_energy_multiplier = glow
    if eye_glow:
        # Eye-glow tracks the wind-up too; resting glow is ~1.0, peaks ~3.0.
        eye_glow.light_energy = lerp(1.0, 3.2, clamp(t, 0.0, 1.0))


func _player_is_attacking() -> bool:
    if not player or not is_instance_valid(player):
        return false
    if not "state" in player or player.state == null:
        return false
    var act: int = player.state.action
    return act == TuxState.ACT_ATTACK or act == TuxState.ACT_JAB \
            or act == TuxState.ACT_JUMP_ATTACK or act == TuxState.ACT_SPIN


func _facing_player(to_player: Vector3) -> bool:
    if to_player.length_squared() < 1e-6:
        return true
    var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
    return fwd.dot(to_player.normalized()) > -0.3


# Replace the rig's penguin colors with bone tones + ember eyes.
func _apply_bone_materials() -> void:
    var bone := StandardMaterial3D.new()
    bone.albedo_color = Color(0.82, 0.79, 0.70, 1)
    bone.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    bone.roughness = 0.85
    var bone_dark := StandardMaterial3D.new()
    bone_dark.albedo_color = Color(0.45, 0.42, 0.36, 1)
    bone_dark.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    bone_dark.roughness = 0.85
    var eye := StandardMaterial3D.new()
    eye.albedo_color = Color(1.0, 0.30, 0.10, 1)
    eye.emission_enabled = true
    eye.emission = Color(1.0, 0.40, 0.18)
    eye.emission_energy_multiplier = 2.4
    var pupil := StandardMaterial3D.new()
    pupil.albedo_color = Color(0.05, 0.0, 0.0, 1)

    for n in _all_meshes(rig):
        var nm: String = n.name
        if nm in ["EyeL", "EyeR"]:
            n.material_override = eye
        elif nm in ["PupilL", "PupilR"]:
            n.material_override = pupil
        elif nm in ["Beak", "Beak2", "Foot", "LegMesh"]:
            n.material_override = bone_dark
        else:
            n.material_override = bone


func _all_meshes(root: Node) -> Array:
    var out: Array = []
    if root is MeshInstance3D:
        out.append(root)
    for child in root.get_children():
        out.append_array(_all_meshes(child))
    return out
