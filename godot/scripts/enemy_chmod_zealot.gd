extends CharacterBody3D

# Chmod Zealot — a hooded minor cultist of Khorgaul. It walks a slow
# patrol; if the player approaches, it tries to maintain a 4m gap and
# repeatedly performs a "sealing" gesture that locks any nearby chest,
# door, or pickup for a few seconds.
#
# The seal is implemented as a metadata flag (`set_meta("sealed", true)`)
# plus a Timer that clears it. chest.gd / door.gd / pickup scripts
# don't need to honor it yet — the flag is the deliverable. Consumers
# can later branch on `node.has_meta("sealed") and node.get_meta(...)`.
#
# Lore lineage: a minor Khorgaul-aligned cultist. Tries to lock down
# anything it touches.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 5
@export var contact_damage: int = 2
@export var detect_range: float = 6.0
@export var keep_distance: float = 4.0
@export var move_speed: float = 1.6
@export var seal_radius: float = 6.0
@export var seal_duration: float = 4.0
@export var seal_cooldown: float = 4.0
@export var pebble_reward: int = 3
@export var heart_drop_chance: float = 0.5

const GRAVITY: float = 18.0
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 5.0
const SEAL_WINDUP: float = 0.45
const SEAL_RECOVER: float = 0.30
const CONTACT_COOLDOWN: float = 1.0
# Patrol drift is a sin-based oscillation around the spawn point; we
# don't want pathfinding for this minor enemy.
const PATROL_RADIUS: float = 2.4
const PATROL_OMEGA: float = 0.6

enum State { PATROL, SEAL, AGGRO, HURT, DEAD }

var hp: int = 5
var state: int = State.PATROL
var state_time: float = 0.0
var player: Node3D = null
var _origin: Vector3 = Vector3.ZERO
var _patrol_phase: float = 0.0
var _seal_cooldown_t: float = 0.0
var _last_contact_t: float = -1000.0
# Track sealed nodes so we can clear them when the timer expires
# (rather than relying on the timer being fired on the right object).
var _sealed: Array = []

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	_origin = global_position
	_patrol_phase = randf() * TAU
	contact_area.body_entered.connect(_on_contact_player)


func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


func _physics_process(delta: float) -> void:
	state_time += delta
	_seal_cooldown_t = max(0.0, _seal_cooldown_t - delta)

	if state == State.DEAD:
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
			move_and_slide()
		return
	_ensure_player()

	var dist: float = 1e9
	var to_player: Vector3 = Vector3.ZERO
	if player and is_instance_valid(player):
		to_player = player.global_position - global_position
		to_player.y = 0.0
		dist = to_player.length()

	match state:
		State.PATROL:
			_patrol_phase += PATROL_OMEGA * delta
			var target: Vector3 = _origin + Vector3(
				cos(_patrol_phase) * PATROL_RADIUS,
				0.0,
				sin(_patrol_phase) * PATROL_RADIUS,
			)
			var to_target: Vector3 = target - global_position
			to_target.y = 0.0
			if to_target.length() > 0.05:
				var dir: Vector3 = to_target.normalized()
				velocity.x = dir.x * move_speed * 0.6
				velocity.z = dir.z * move_speed * 0.6
				rotation.y = atan2(-dir.x, -dir.z)
			if dist < detect_range:
				_set_state(State.AGGRO)
		State.AGGRO:
			# Hold position at keep_distance — strafe-equivalent: if
			# too close, back away; if too far, close in.
			if dist > detect_range * 1.6:
				_set_state(State.PATROL)
			elif to_player.length() > 0.01:
				var dir: Vector3 = to_player.normalized()
				rotation.y = atan2(-dir.x, -dir.z)
				var radial_err: float = dist - keep_distance
				var sgn: float = 1.0 if radial_err > 0.0 else -1.0
				if abs(radial_err) > 0.3:
					velocity.x = dir.x * move_speed * sgn
					velocity.z = dir.z * move_speed * sgn
				else:
					velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
					velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
				if _seal_cooldown_t <= 0.0:
					_set_state(State.SEAL)
		State.SEAL:
			# Stop, raise the hand, then on commit-time perform the seal.
			velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
			# Visual: arm pose is faked with a brief scale-up of the
			# upper portion. Cheap but reads as a gesture.
			var sq: float = clamp(state_time / SEAL_WINDUP, 0.0, 1.0)
			visual.scale = Vector3(1.0 + sq * 0.05, 1.0 + sq * 0.10, 1.0 + sq * 0.05)
			if state_time >= SEAL_WINDUP and state_time < SEAL_WINDUP + 0.05:
				_perform_seal()
			if state_time >= SEAL_WINDUP + SEAL_RECOVER:
				visual.scale = Vector3.ONE
				_seal_cooldown_t = seal_cooldown
				_set_state(State.AGGRO if dist < detect_range else State.PATROL)
		State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= HURT_TIME:
				_set_state(State.AGGRO if dist < detect_range else State.PATROL)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


# The seal: scan for any chest/door/pickup-group node within seal_radius
# and stamp it with `sealed = true` for seal_duration. A scene-tree
# Timer clears the flag.
func _perform_seal() -> void:
	SoundBank.play_3d("crystal_hit", global_position)
	var here: Vector3 = global_position
	var groups := ["chest", "door", "pickup"]
	var hits: Array = []
	for g in groups:
		for n in get_tree().get_nodes_in_group(g):
			if not (n is Node3D):
				continue
			var d: float = n.global_position.distance_to(here)
			if d <= seal_radius:
				hits.append(n)
	for n in hits:
		n.set_meta("sealed", true)
		_sealed.append(n)
	if hits.is_empty():
		return
	# Single-shot timer to clear the just-sealed nodes after the window.
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = seal_duration
	add_child(t)
	t.timeout.connect(func() -> void:
		for n in hits:
			if is_instance_valid(n):
				n.set_meta("sealed", false)
				_sealed.erase(n)
		t.queue_free()
	)
	t.start()


func _on_contact_player(body: Node) -> void:
	if state == State.DEAD or state == State.HURT:
		return
	if not body.is_in_group("player"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_contact_t < CONTACT_COOLDOWN:
		return
	_last_contact_t = now
	if body.has_method("take_damage"):
		body.take_damage(contact_damage, global_position, self)


func take_damage(amount: int, source_pos: Vector3, _attacker: Node3D = null) -> void:
	if hp <= 0:
		return
	hp -= amount
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		velocity.x = away.x * KNOCKBACK_SPEED
		velocity.z = away.z * KNOCKBACK_SPEED
		velocity.y = 3.0
	if hp <= 0:
		_die()
	else:
		_set_state(State.HURT)


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	# Free any seals we still hold so the world doesn't stay locked.
	for n in _sealed:
		if is_instance_valid(n):
			n.set_meta("sealed", false)
	_sealed.clear()
	SoundBank.play_3d("death", global_position)
	_drop_loot()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", Vector3(1.2, 0.10, 1.2), 0.30)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var here: Vector3 = global_position
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		p.position = here + Vector3(randf_range(-0.6, 0.6), 0.0,
								   randf_range(-0.6, 0.6))
		parent.call_deferred("add_child", p)
	if randf() < heart_drop_chance:
		var h := HeartPickup.instantiate()
		h.position = here + Vector3(0, 0, 0.4)
		parent.call_deferred("add_child", h)


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0
