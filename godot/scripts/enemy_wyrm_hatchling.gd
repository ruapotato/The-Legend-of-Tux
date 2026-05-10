extends CharacterBody3D

# Wyrm Hatchling — a juvenile dragonling mini-boss. Small, aggressive,
# fast in straight lines but dumb. Takes the player's "wait for the
# crash" rhythm: lines up, charges in a straight line, slams into walls,
# stuns itself on the rebound.
#
# Combat rhythm:
#   IDLE        — light hover-bob, scanning.
#   APPROACH    — drift toward the player at a slow walk (1.5 m/s); on
#                 contact distance it commits to a CHARGE.
#   AIM         — brief 0.4s wind-up: locks the player's current position
#                 as the charge target so the player can sidestep.
#   CHARGE      — straight-line dash at 4 m/s. Locked direction. Hitting
#                 ANY wall (move_and_slide blocked) trips STUN.
#   STUN        — 1.5s recovery on the floor. The damage window. Player
#                 swings or arrows freely; both deal full damage.
#   SPIT        — every spit_interval (3s) while in IDLE/APPROACH/AIM,
#                 launches a small bouncing fireball at the player's
#                 current position. The fireball is implemented inline
#                 so we don't need a separate scene file.
#   HURT        — knockback after a damaging hit lands.
#   DEAD        — flatten + despawn.
#
# Drop: 1 heart pickup ("fairy spirit"-style heal) + 5 pebbles.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 25
@export var detect_range: float = 12.0
@export var attack_range: float = 4.0
@export var move_speed: float = 1.5
@export var charge_speed: float = 4.0
@export var contact_damage: int = 2
@export var pebble_reward: int = 5
@export var spit_interval: float = 3.0

const GRAVITY: float = 22.0
const AIM_TIME: float = 0.40
const CHARGE_MAX_TIME: float = 1.6
const STUN_TIME: float = 1.5
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.0
const FIREBALL_SPEED: float = 6.0
const FIREBALL_DAMAGE: int = 2
const FIREBALL_LIFETIME: float = 3.5
const FIREBALL_RADIUS: float = 0.30
const FIREBALL_BOUNCES: int = 3
const CHARGE_BLOCKED_SPEED_THRESHOLD: float = 0.8

enum State { IDLE, APPROACH, AIM, CHARGE, STUN, HURT, DEAD }

var hp: int = 25
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _spit_t: float = 1.5
var _charge_dir: Vector3 = Vector3.ZERO

@onready var visual: Node3D = $Visual
@onready var body_mesh: MeshInstance3D = $Visual/Body
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
	_spit_t -= delta

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

	# Spit can fire from any non-committed state.
	if _spit_t <= 0.0 and state in [State.IDLE, State.APPROACH, State.AIM] \
			and dist < detect_range and player and is_instance_valid(player):
		_spit_fireball()
		_spit_t = spit_interval

	match state:
		State.IDLE:     _do_idle(delta, dist)
		State.APPROACH: _do_approach(delta, to_player, dist)
		State.AIM:      _do_aim(delta, to_player)
		State.CHARGE:   _do_charge(delta)
		State.STUN:     _do_stun(delta)
		State.HURT:     _do_hurt(delta, dist)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()
	# Idle bob — only in non-committed states.
	if visual and state in [State.IDLE, State.APPROACH, State.AIM]:
		visual.position.y = 0.05 + sin(Time.get_ticks_msec() * 0.005) * 0.05


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
		_set_state(State.AIM)
		return
	var dir: Vector3 = to_player.normalized() if to_player.length_squared() > 1e-6 else Vector3.FORWARD
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	rotation.y = atan2(-dir.x, -dir.z)


func _do_aim(delta: float, to_player: Vector3) -> void:
	# Hold position, lock onto the player's CURRENT position. The charge
	# uses this locked direction — so the player can sidestep.
	velocity.x = move_toward(velocity.x, 0.0, 16.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 16.0 * delta)
	if to_player.length_squared() > 1e-6:
		var dir: Vector3 = to_player.normalized()
		rotation.y = atan2(-dir.x, -dir.z)
		_charge_dir = dir
	if state_time >= AIM_TIME:
		_set_state(State.CHARGE)


func _do_charge(_delta: float) -> void:
	if _charge_dir.length_squared() < 1e-6:
		_charge_dir = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	velocity.x = _charge_dir.x * charge_speed
	velocity.z = _charge_dir.z * charge_speed
	# After at least 0.15s of run, check if move_and_slide is failing to
	# carry us forward — that's "we hit a wall".
	if state_time > 0.15:
		var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
		if horiz_speed < CHARGE_BLOCKED_SPEED_THRESHOLD or get_slide_collision_count() > 0:
			# Confirm we're actually obstructed (move_and_slide collisions).
			var blocked: bool = false
			for i in range(get_slide_collision_count()):
				var c: KinematicCollision3D = get_slide_collision(i)
				if c and abs(c.get_normal().y) < 0.5:
					blocked = true
					break
			if blocked:
				_set_state(State.STUN)
				return
	if state_time >= CHARGE_MAX_TIME:
		# Ran the full charge without hitting anything — wind down to AIM
		# again so we don't strand ourselves charging across an empty room.
		_set_state(State.APPROACH)


func _do_stun(delta: float) -> void:
	# On the floor, dazed. Visible "circling stars" approximated by a
	# slow visual rotation so the player reads the window.
	velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
	if visual:
		visual.rotation.y += 4.0 * delta
	if state_time >= STUN_TIME:
		if visual:
			visual.rotation.y = 0.0
		_set_state(State.APPROACH)


func _do_hurt(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
	if state_time >= HURT_TIME:
		if dist < detect_range:
			_set_state(State.APPROACH)
		else:
			_set_state(State.IDLE)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
	if hp <= 0:
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
		# Don't break out of STUN early just because we got hit — the
		# stun is the player's earned window.
		if state != State.STUN:
			_set_state(State.HURT)


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)


func _on_contact_player(_body: Node) -> void:
	if state != State.CHARGE:
		return
	if player and is_instance_valid(player) and player.has_method("take_damage"):
		player.take_damage(contact_damage, global_position, self)


func _hit_punch() -> void:
	if not visual:
		return
	var base_scale: Vector3 = visual.scale
	visual.scale = base_scale * Vector3(1.20, 0.80, 1.20)
	var t := create_tween()
	t.tween_property(visual, "scale", base_scale, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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
	t.tween_property(visual, "scale", visual.scale * Vector3(1.4, 0.05, 1.4), 0.40)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var here: Vector3 = global_position
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		p.position = here + Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		parent.call_deferred("add_child", p)
	# Fairy-spirit heal: drop one heart pickup (the spec calls this a
	# "fairy spirit" but uses a heart pickup).
	var h := HeartPickup.instantiate()
	h.position = here + Vector3(0.0, 0.2, 0.4)
	parent.call_deferred("add_child", h)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
	var prev := state
	state = new_state
	state_time = 0.0
	if state != State.CHARGE:
		_charge_dir = Vector3.ZERO
	if state == State.APPROACH and prev == State.IDLE:
		SoundBank.play_3d("blob_alert", global_position)
	elif state == State.AIM:
		SoundBank.play_3d("sword_charge", global_position)
	elif state == State.CHARGE:
		SoundBank.play_3d("blob_attack", global_position)
	elif state == State.STUN:
		SoundBank.play_3d("hurt", global_position)


# ---- Inline fireball ---------------------------------------------------

# Self-hosted "spit" projectile: small glowing sphere that travels
# toward the player's current position, bounces a few times off the
# ground, and damages the player on Area3D contact. Implemented in
# script so we don't need a separate scene file.
func _spit_fireball() -> void:
	var parent := get_parent()
	if parent == null or player == null or not is_instance_valid(player):
		return

	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 2 | 1     # player + world (for bounce surface detect)
	area.monitoring = true
	area.monitorable = false

	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = FIREBALL_RADIUS
	cs.shape = sh
	area.add_child(cs)

	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = FIREBALL_RADIUS
	sm.height = FIREBALL_RADIUS * 2.0
	sm.radial_segments = 10
	sm.rings = 6
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.20, 1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.40, 0.15, 1)
	mat.emission_energy_multiplier = 2.6
	mesh.material_override = mat
	area.add_child(mesh)

	# Spawn a meter in front of the wyrm at chest height.
	var spawn_pos: Vector3 = global_position + Vector3(0.0, 0.6, 0.0)
	var to_p: Vector3 = player.global_position - spawn_pos
	to_p.y *= 0.3   # keep horizontal-ish trajectory
	if to_p.length_squared() < 1e-6:
		to_p = Vector3.FORWARD
	var dir: Vector3 = to_p.normalized()
	area.position = spawn_pos
	parent.call_deferred("add_child", area)

	# Fireball state, captured in the lambdas.
	var vel: Array = [dir * FIREBALL_SPEED]
	var life: Array = [0.0]
	var bounces_left: Array = [FIREBALL_BOUNCES]
	var hit: Array = [false]

	# Damage on player overlap (one-shot per fireball).
	area.body_entered.connect(func (body):
		if hit[0]:
			return
		if body.is_in_group("player") and body.has_method("take_damage"):
			hit[0] = true
			body.take_damage(FIREBALL_DAMAGE, area.global_position, self)
			area.queue_free())

	# Per-frame motion / bounce / lifetime via a child Node tick.
	var ticker := Node.new()
	area.add_child(ticker)
	ticker.set_process(true)
	# We can't @tool a callback here, so wire via process_callable.
	var fire_gravity: float = 8.0
	ticker.set_meta("tick_owner", area)
	# Use a Timer to drive motion at a fixed step (avoids needing a
	# script on `ticker`). 60Hz is enough for a slow fireball.
	var tm := Timer.new()
	tm.wait_time = 1.0 / 60.0
	tm.autostart = true
	tm.one_shot = false
	area.add_child(tm)
	tm.timeout.connect(func ():
		if hit[0] or not is_instance_valid(area):
			return
		var dt: float = tm.wait_time
		life[0] += dt
		if life[0] >= FIREBALL_LIFETIME:
			area.queue_free()
			return
		vel[0].y -= fire_gravity * dt
		var next_pos: Vector3 = area.global_position + vel[0] * dt
		# Cheap floor bounce: never let it sink below 0.2m.
		if next_pos.y < 0.2:
			next_pos.y = 0.2
			if bounces_left[0] > 0 and vel[0].y < 0.0:
				bounces_left[0] -= 1
				vel[0].y = -vel[0].y * 0.6
				vel[0].x *= 0.85
				vel[0].z *= 0.85
			else:
				area.queue_free()
				return
		area.global_position = next_pos)
