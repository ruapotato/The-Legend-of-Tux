extends CharacterBody3D

# Bone Ogre — a heavy, slow mini-boss. The defining hook is the
# GROUND POUND: every pound_interval (4s) the ogre commits to a
# 1.0s telegraph (raises arms, pauses), then SLAMS the ground,
# spawning a 4m-radius shockwave that knocks the player back hard
# unless they roll through it.
#
# Combat rhythm:
#   IDLE        — initial scan.
#   APPROACH    — heavy march toward the player at 1.4 m/s.
#   POUND_TELL  — 1.0s wind-up. Arms up, body tense, FX flashes.
#   POUND_SLAM  — 0.25s slam: spawns the shockwave Area3D, deals
#                 heavy contact damage in a 4m radius, knocks the
#                 player back hard.
#   POUND_REC   — 1.0s recover. Damage window for sword + bombs.
#   HURT        — knockback after a damaging hit.
#   DEAD        — flatten + despawn.
#
# Damage rules:
#   - Sword: normal damage.
#   - Bombs: x3 damage (attacker == null heuristic, same as
#     enemy_cinder_tomato.gd).
#
# Drop: 2 hearts + 12 pebbles.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 40
@export var detect_range: float = 14.0
@export var attack_range: float = 3.5
@export var move_speed: float = 1.4
@export var contact_damage: int = 3
@export var pound_damage: int = 4
@export var pebble_reward: int = 12
@export var heart_drops: int = 2
@export var pound_interval: float = 4.0
@export var bomb_damage_multiplier: int = 3

const GRAVITY: float = 24.0
const POUND_TELL_TIME: float = 1.00
const POUND_SLAM_TIME: float = 0.25
const POUND_REC_TIME: float = 1.00
const SHOCKWAVE_RADIUS: float = 4.0
const SHOCKWAVE_LIFETIME: float = 0.30
const POUND_KNOCKBACK: float = 9.0
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.0

enum State { IDLE, APPROACH, POUND_TELL, POUND_SLAM, POUND_REC, HURT, DEAD }

var hp: int = 40
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _pound_t: float = 2.5
var _slam_spawned: bool = false

@onready var visual: Node3D = $Visual
@onready var body_mesh: MeshInstance3D = $Visual/Body
@onready var arm_l: Node3D = $Visual/ArmL
@onready var arm_r: Node3D = $Visual/ArmR
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
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

	var to_player := Vector3.ZERO
	var dist: float = 1e9
	if player and is_instance_valid(player):
		to_player = player.global_position - global_position
		to_player.y = 0.0
		dist = to_player.length()

	# Pound timer ticks any time we're aware of the player. Triggers
	# the pound from APPROACH (or interrupts it) when ready.
	if state in [State.APPROACH, State.IDLE]:
		_pound_t -= delta
		if _pound_t <= 0.0 and dist < detect_range:
			_pound_t = pound_interval
			_set_state(State.POUND_TELL)

	match state:
		State.IDLE:        _do_idle(delta, dist)
		State.APPROACH:    _do_approach(delta, to_player, dist)
		State.POUND_TELL:  _do_pound_tell(delta, to_player)
		State.POUND_SLAM:  _do_pound_slam(delta)
		State.POUND_REC:   _do_pound_rec(delta, dist)
		State.HURT:        _do_hurt(delta, dist)

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
	var dir: Vector3 = to_player.normalized() if to_player.length_squared() > 1e-6 else Vector3.FORWARD
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	rotation.y = atan2(-dir.x, -dir.z)


func _do_pound_tell(delta: float, to_player: Vector3) -> void:
	# Stop, face, raise arms over the wind-up.
	velocity.x = move_toward(velocity.x, 0.0, 18.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 18.0 * delta)
	if to_player.length_squared() > 1e-6:
		var dir: Vector3 = to_player.normalized()
		rotation.y = atan2(-dir.x, -dir.z)
	var t: float = clamp(state_time / POUND_TELL_TIME, 0.0, 1.0)
	if arm_l:
		arm_l.rotation.x = lerp(0.0, -2.4, t)
	if arm_r:
		arm_r.rotation.x = lerp(0.0, -2.4, t)
	# Body tenses (slight scale up) to telegraph the slam.
	if visual:
		visual.scale = Vector3.ONE * (1.0 + 0.08 * t)
	if state_time >= POUND_TELL_TIME:
		_set_state(State.POUND_SLAM)


func _do_pound_slam(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	# Arms drop.
	if arm_l:
		arm_l.rotation.x = 0.6
	if arm_r:
		arm_r.rotation.x = 0.6
	# Body squashes on impact.
	if visual:
		visual.scale = Vector3(1.20, 0.80, 1.20)
	if not _slam_spawned:
		_slam_spawned = true
		_spawn_shockwave(global_position)
		SoundBank.play_3d("ground_pound", global_position)
	if state_time >= POUND_SLAM_TIME:
		_set_state(State.POUND_REC)


func _do_pound_rec(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
	# Arms slowly return; body slowly returns to normal scale.
	var t: float = clamp(state_time / POUND_REC_TIME, 0.0, 1.0)
	if arm_l:
		arm_l.rotation.x = lerp(0.6, 0.0, t)
	if arm_r:
		arm_r.rotation.x = lerp(0.6, 0.0, t)
	if visual:
		visual.scale = Vector3.ONE.lerp(Vector3(1.20, 0.80, 1.20), 1.0 - t)
	if state_time >= POUND_REC_TIME:
		if visual:
			visual.scale = Vector3.ONE
		if dist < detect_range:
			_set_state(State.APPROACH)
		else:
			_set_state(State.IDLE)


func _do_hurt(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
	if state_time >= HURT_TIME:
		if dist < detect_range:
			_set_state(State.APPROACH)
		else:
			_set_state(State.IDLE)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
	if hp <= 0:
		return
	var actual: int = amount
	# Bomb detection: bombs call take_damage with attacker == null
	# (same contract as enemy_cinder_tomato.gd uses).
	if attacker == null:
		actual = amount * bomb_damage_multiplier
	hp -= actual
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		velocity.x = away.x * KNOCKBACK_SPEED
		velocity.z = away.z * KNOCKBACK_SPEED
		velocity.y = 1.5
	_hit_punch()
	SoundBank.play_3d("hurt", global_position)
	if hp <= 0:
		_die()
	else:
		# Don't interrupt the pound commit — once committed the slam lands.
		if state in [State.APPROACH, State.IDLE, State.POUND_REC]:
			_set_state(State.HURT)


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 2.0
	_set_state(State.HURT)


func _on_contact_player(_body: Node) -> void:
	# Touching the ogre body (outside of the slam) is a body-check tick.
	if state in [State.DEAD, State.HURT]:
		return
	if player and is_instance_valid(player) and player.has_method("take_damage"):
		player.take_damage(contact_damage, global_position, self)
		# Knock the player out of the ogre's footprint.
		if "velocity" in player:
			var away: Vector3 = player.global_position - global_position
			away.y = 0.0
			if away.length() > 0.01:
				away = away.normalized()
				player.velocity.x = away.x * 5.0
				player.velocity.z = away.z * 5.0
				player.velocity.y = 3.0


func _hit_punch() -> void:
	if not visual:
		return
	# Subtle — visual scale is being driven by the pound state, so we
	# tween a quick squish on top via material flash instead.
	pass


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	SoundBank.play_3d("death", global_position)
	_drop_loot()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", visual.scale * Vector3(1.4, 0.05, 1.4), 0.55)
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
	for i in range(heart_drops):
		var h := HeartPickup.instantiate()
		var off: float = float(i) - (float(heart_drops) - 1.0) * 0.5
		h.position = here + Vector3(off * 0.5, 0.2, 0.4)
		parent.call_deferred("add_child", h)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
	var prev := state
	state = new_state
	state_time = 0.0
	if state != State.POUND_SLAM:
		_slam_spawned = false
	if state == State.APPROACH and prev == State.IDLE:
		SoundBank.play_3d("blob_alert", global_position)
	elif state == State.POUND_TELL:
		SoundBank.play_3d("sword_charge", global_position)


# Spawn a transient Area3D shockwave at `center` that damages and
# knocks back the player on contact. Self-hosted so the script doesn't
# need an extra companion scene. Mirrors the wyrdking's shockwave
# pattern at a larger radius.
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

	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = SHOCKWAVE_RADIUS * 0.5
	ring_mesh.outer_radius = SHOCKWAVE_RADIUS
	ring_mesh.rings = 3
	ring_mesh.ring_segments = 18
	ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.78, 0.74, 0.66, 0.85)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.95, 0.85, 0.65, 1)
	ring_mat.emission_energy_multiplier = 1.8
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = ring_mat
	ring.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.05, 0.0))
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
			body.take_damage(pound_damage, area.global_position, self)
		if "velocity" in body:
			var away: Vector3 = body.global_position - area.global_position
			away.y = 0.0
			if away.length() > 0.01:
				away = away.normalized()
				body.velocity.x = away.x * POUND_KNOCKBACK
				body.velocity.z = away.z * POUND_KNOCKBACK
				body.velocity.y = 5.0)

	# Swell + fade, then remove.
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(ring, "scale", Vector3(1.4, 1.0, 1.4), SHOCKWAVE_LIFETIME)
	t.tween_property(ring_mat, "albedo_color:a", 0.0, SHOCKWAVE_LIFETIME)
	t.chain().tween_callback(area.queue_free)
