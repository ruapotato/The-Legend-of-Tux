extends CharacterBody3D

# Armored Knight — a mini-boss tier melee tank. Two-handed sword,
# heavy plate, deliberate movements. The defining hook is the SHIELD:
# a forward-facing plate that wholly negates incoming sword damage
# while raised. Shield comes down only after the knight commits to its
# own swing — a 1.0s telegraph + 0.5s strike + 1.2s shield-down recovery
# window where the player's sword finally lands.
#
# Combat rhythm:
#   APPROACH        — slow march toward the player (1.5 m/s), shield up.
#   READY           — at attack range, holds shield, scans for opening.
#   TELEGRAPH       — winds up the two-hander overhead. 1.0s tell, shield
#                     STILL up (the shield only drops on the strike itself
#                     so a player who attacks during the telegraph gets
#                     their hit deflected — punishes pre-emptive swings).
#   STRIKE          — 0.5s downward chop. Shield is down for the duration
#                     of this state and the following RECOVER. Deals
#                     contact damage in a forward cone on impact.
#   RECOVER         — 1.2s windless follow-through. Shield still down.
#                     This is the sole damage window for the player.
#                     After recovery, snaps back to READY (shield up).
#   HURT            — knockback after a successful sword hit.
#   DEAD            — flatten + despawn.
#
# Shield mechanic details:
#   - The Shield is a child Area3D on collision_layer 32 (Hittable). The
#     sword_hitbox already scans layer 32, so a swing that overlaps the
#     shield first deals damage to the SHIELD's take_damage stub
#     (return-no-op) instead of the knight's body Hitbox. Because the
#     shield sits in front of the knight, any frontal swing intersects
#     it before reaching the body hitbox.
#   - We additionally honor a guard check inside take_damage: if the
#     shield is up AND the hit came from the front arc, swallow the
#     hit. This is the load-bearing path; the layered hitbox is the
#     visual cue.
#
# Drop: 8 pebbles + 50% chance of a small key.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const KeyPickup    := preload("res://scenes/pickup_key.tscn")

signal died

@export var max_hp: int = 30
@export var detect_range: float = 14.0
@export var attack_range: float = 2.6
@export var move_speed: float = 1.5
@export var contact_damage: int = 3
@export var pebble_reward: int = 8
@export var key_drop_chance: float = 0.5

const GRAVITY: float = 22.0
const TELEGRAPH_TIME: float = 1.00
const STRIKE_DURATION: float = 0.50
const STRIKE_HIT_WINDOW: Vector2 = Vector2(0.10, 0.32)
const RECOVER_TIME: float = 1.20
const READY_TIME_MIN: float = 0.6
const READY_TIME_MAX: float = 1.2
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.5
const STRIKE_REACH: float = 2.4
const STRIKE_CONE_DOT: float = 0.30
const GUARD_FACE_DOT: float = 0.20

enum State { IDLE, APPROACH, READY, TELEGRAPH, STRIKE, RECOVER, HURT, DEAD }

var hp: int = 30
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _strike_landed: bool = false
var _ready_for: float = 0.8

@onready var visual: Node3D = $Visual
@onready var body_mesh: MeshInstance3D = $Visual/BodyMesh
@onready var shield_mesh: MeshInstance3D = $Visual/ShieldPivot/ShieldMesh
@onready var shield_pivot: Node3D = $Visual/ShieldPivot
@onready var sword_mesh: MeshInstance3D = $Visual/SwordPivot/SwordMesh
@onready var sword_pivot: Node3D = $Visual/SwordPivot
@onready var hitbox: Area3D = $Hitbox
@onready var shield_area: Area3D = $ShieldArea
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	contact_area.body_entered.connect(_on_contact_player)
	# Stub take_damage on the shield so the sword hits it but no
	# damage routes through. The sword hitbox uses receiver.has_method
	# ("take_damage") to pick a target — adding the method here makes
	# the shield "absorb" the swing visually before the body Hitbox
	# can be hit. The script-level guard in our take_damage is the
	# load-bearing block; the area is a visual / routing cue.
	shield_area.set_script(_make_shield_stub())
	_set_shield_up(true)


# Build a tiny inline GDScript that exposes take_damage(amount, pos,
# attacker?) as a no-op. Used as the shield Area3D's script so the
# sword's `receiver.take_damage(...)` call lands here when the shield
# is the closer area, without hurting the knight.
func _make_shield_stub() -> Script:
	var s := GDScript.new()
	s.source_code = (
		"extends Area3D\n"
		+ "func take_damage(_amount: int = 0, _src: Vector3 = Vector3.ZERO, _att: Node = null) -> void:\n"
		+ "    if get_tree() and get_tree().root.has_node(\"SoundBank\"):\n"
		+ "        SoundBank.play_3d(\"shield_block\", global_position)\n"
	)
	s.reload()
	return s


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

	match state:
		State.IDLE:      _do_idle(delta, dist)
		State.APPROACH:  _do_approach(delta, to_player, dist)
		State.READY:     _do_ready(delta, to_player, dist)
		State.TELEGRAPH: _do_telegraph(delta, to_player)
		State.STRIKE:    _do_strike(delta)
		State.RECOVER:   _do_recover(delta, dist)
		State.HURT:      _do_hurt(delta, dist)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


# ---- Per-state handlers ------------------------------------------------

func _do_idle(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
	if dist < detect_range:
		_set_state(State.APPROACH)


func _do_approach(delta: float, to_player: Vector3, dist: float) -> void:
	if dist > detect_range * 1.6:
		_set_state(State.IDLE)
		return
	if dist < attack_range:
		_set_state(State.READY)
		return
	var dir: Vector3 = to_player.normalized() if to_player.length_squared() > 1e-6 else Vector3.FORWARD
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	rotation.y = atan2(-dir.x, -dir.z)


func _do_ready(delta: float, to_player: Vector3, dist: float) -> void:
	# Hold position, face the player. Shield is up. After a short
	# pause, commit to the swing.
	velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
	if to_player.length_squared() > 1e-6:
		var dir: Vector3 = to_player.normalized()
		rotation.y = atan2(-dir.x, -dir.z)
	if dist > attack_range * 1.4:
		_set_state(State.APPROACH)
		return
	if state_time >= _ready_for:
		_set_state(State.TELEGRAPH)


func _do_telegraph(delta: float, to_player: Vector3) -> void:
	# Wind up. Sword raises, body crouches slightly, shield STILL up.
	velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
	if to_player.length_squared() > 1e-6:
		var dir: Vector3 = to_player.normalized()
		rotation.y = atan2(-dir.x, -dir.z)
	# Visual: rotate sword pivot back over the head as the wind-up
	# progresses; pulse the blade tint redder.
	var t: float = clamp(state_time / TELEGRAPH_TIME, 0.0, 1.0)
	if sword_pivot:
		sword_pivot.rotation.x = lerp(0.0, -2.4, t)
	if state_time >= TELEGRAPH_TIME:
		_set_state(State.STRIKE)


func _do_strike(delta: float) -> void:
	# Shield is DOWN for the entire STRIKE + RECOVER window.
	# Lunge forward briefly during the active hit window.
	var fwd: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	if state_time >= STRIKE_HIT_WINDOW.x and state_time <= STRIKE_HIT_WINDOW.y:
		velocity.x = fwd.x * 2.5
		velocity.z = fwd.z * 2.5
		# Front-cone hit check (one-shot per strike).
		if not _strike_landed and player and is_instance_valid(player):
			var to_p: Vector3 = player.global_position - global_position
			to_p.y = 0.0
			var d: float = to_p.length()
			if d > 0.05 and d < STRIKE_REACH:
				var to_p_n: Vector3 = to_p / d
				if fwd.dot(to_p_n) > STRIKE_CONE_DOT:
					_strike_landed = true
					if player.has_method("take_damage"):
						SoundBank.play_3d("sword_hit", global_position)
						player.take_damage(contact_damage, global_position, self)
	else:
		velocity.x = move_toward(velocity.x, 0.0, 18.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 18.0 * delta)
	# Sword swings down through the strike.
	var t: float = clamp(state_time / STRIKE_DURATION, 0.0, 1.0)
	if sword_pivot:
		sword_pivot.rotation.x = lerp(-2.4, 0.6, t)
	if state_time >= STRIKE_DURATION:
		_set_state(State.RECOVER)


func _do_recover(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
	# Sword slowly returns to neutral; shield still down.
	var t: float = clamp(state_time / RECOVER_TIME, 0.0, 1.0)
	if sword_pivot:
		sword_pivot.rotation.x = lerp(0.6, 0.0, t)
	if state_time >= RECOVER_TIME:
		if dist < detect_range:
			_set_state(State.READY)
		else:
			_set_state(State.IDLE)


func _do_hurt(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
	if state_time >= HURT_TIME:
		# After getting hit, raise the shield again on resume.
		if dist < detect_range:
			_set_state(State.READY)
		else:
			_set_state(State.IDLE)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
	if hp <= 0:
		return
	# Guard check: shield up + frontal hit = no damage.
	if _is_shield_up():
		var to_src: Vector3 = source_pos - global_position
		to_src.y = 0.0
		if to_src.length() > 0.001:
			var to_src_dir: Vector3 = to_src.normalized()
			var fwd: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
			if fwd.dot(to_src_dir) > GUARD_FACE_DOT:
				SoundBank.play_3d("shield_block", global_position)
				return
	hp -= amount
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
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


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)


func _on_contact_player(_body: Node) -> void:
	# Body-contact tick for very-close standoffs (the cone strike already
	# covers the swing window). Cheap shove damage so the player can't
	# permanently hug the knight's shoulder.
	if state == State.DEAD or state == State.HURT:
		return
	if player and is_instance_valid(player) and player.has_method("take_damage"):
		# Only proc on contact if shield is down (we're in commit window)
		# OR if the player is BEHIND the shield. Otherwise the shield
		# absorbs the bump.
		if not _is_shield_up():
			player.take_damage(1, global_position, self)


func _hit_punch() -> void:
	if not visual:
		return
	var base_scale: Vector3 = visual.scale
	visual.scale = base_scale * Vector3(1.10, 0.90, 1.10)
	var t := create_tween()
	t.tween_property(visual, "scale", base_scale, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	shield_area.set_deferred("monitoring", false)
	shield_area.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	SoundBank.play_3d("death", global_position)
	_drop_loot()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", visual.scale * Vector3(1.0, 0.05, 1.0), 0.50)
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
	if randf() < key_drop_chance:
		var k := KeyPickup.instantiate()
		k.position = here + Vector3(0.0, 0.2, 0.4)
		parent.call_deferred("add_child", k)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
	var prev := state
	state = new_state
	state_time = 0.0
	if state == State.STRIKE or state == State.RECOVER:
		_set_shield_up(false)
	else:
		_set_shield_up(true)
	if state != State.STRIKE:
		_strike_landed = false
	if state == State.READY:
		_ready_for = randf_range(READY_TIME_MIN, READY_TIME_MAX)
	# Audio cues.
	if state == State.APPROACH and prev == State.IDLE:
		SoundBank.play_3d("blob_alert", global_position)
	elif state == State.TELEGRAPH:
		SoundBank.play_3d("sword_charge", global_position)
	elif state == State.STRIKE:
		SoundBank.play_3d("sword_swing", global_position)


func _is_shield_up() -> bool:
	return state in [State.IDLE, State.APPROACH, State.READY,
					 State.TELEGRAPH, State.HURT]


# Move the shield in/out and toggle its hittable area. Shield-up keeps
# the shield Area3D monitorable so the sword's layer-32 scan finds it
# before reaching the body Hitbox.
func _set_shield_up(up: bool) -> void:
	if not shield_area or not shield_pivot:
		return
	if up:
		shield_pivot.rotation.x = 0.0
		shield_pivot.position = Vector3(0.0, 1.0, -0.55)
		shield_area.set_deferred("monitorable", true)
	else:
		shield_pivot.rotation.x = -0.7
		shield_pivot.position = Vector3(0.35, 0.7, -0.20)
		shield_area.set_deferred("monitorable", false)
