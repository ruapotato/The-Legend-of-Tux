extends CharacterBody3D

# find_hawk — flying scout that hovers above its perch. When it gets
# line-of-sight on the player (range 8m AND a forward dot-product
# above the LOS_DOT threshold so it has to be looking that way), it
# emits an "aggro ping": every other enemy in the scene is poked via
# `_aggro_now()` if they expose it.
#
# HP 5; one decent sword swing kills it. The threat isn't the bird's
# damage — it's that the bird makes everything ELSE around the player
# notice them all at once.
#
# We don't tank the player ourselves; touching us deals minor contact
# damage but the mainline use is "scout that announces you."

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 5
@export var contact_damage: int = 1
@export var sight_range: float = 8.0
@export var hover_height: float = 3.0
@export var move_speed: float = 2.6
@export var ping_cooldown: float = 6.0
@export var pebble_reward: int = 1

const GRAVITY: float = 0.0   # we self-stabilize altitude
const HOVER_K: float = 4.0
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 4.0
const CONTACT_COOLDOWN: float = 1.0
# Dot-product threshold for "facing the player." 0.5 = within ~60° cone.
const LOS_DOT: float = 0.50

enum State { HOVER, ALERT, HURT, DEAD }

var hp: int = 5
var state: int = State.HOVER
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var _last_ping_t: float = -1000.0
var _spawn_y: float = 0.0
var _drift_phase: float = 0.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("find_hawk")
	contact_area.body_entered.connect(_on_contact_player)
	# Lift up to hover_height above wherever we were placed.
	_spawn_y = global_position.y + hover_height
	global_position.y = _spawn_y
	_drift_phase = randf() * TAU


func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


func _physics_process(delta: float) -> void:
	state_time += delta

	if state == State.DEAD:
		velocity.y -= 24.0 * delta
		move_and_slide()
		return
	_ensure_player()

	# Lazy figure-eight drift while alive — gives the scout some air.
	_drift_phase += delta
	var drift_x: float = sin(_drift_phase * 0.6) * 0.6
	var drift_z: float = cos(_drift_phase * 0.4) * 0.6

	# Vertical PD toward _spawn_y so altitude self-stabilizes after
	# any disturbance (knockback drops us a bit, etc.).
	var dy: float = _spawn_y - global_position.y
	velocity.y = dy * HOVER_K

	match state:
		State.HOVER:
			# Slow lazy drift in XZ.
			velocity.x = move_toward(velocity.x, drift_x, 4.0 * delta)
			velocity.z = move_toward(velocity.z, drift_z, 4.0 * delta)
			# Look around slowly so the LOS dot-product check makes sense.
			rotation.y += delta * 0.6
			if _check_los():
				_aggro_ping()
		State.ALERT:
			# Lock facing on player and orbit-strafe a bit.
			if player and is_instance_valid(player):
				var to_p: Vector3 = player.global_position - global_position
				to_p.y = 0.0
				if to_p.length() > 0.01:
					var n: Vector3 = to_p.normalized()
					rotation.y = atan2(-n.x, -n.z)
					# Orbit perpendicular.
					var perp: Vector3 = Vector3(-n.z, 0.0, n.x)
					velocity.x = perp.x * move_speed
					velocity.z = perp.z * move_speed
			if state_time >= 1.5:
				_set_state(State.HOVER)
		State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= HURT_TIME:
				_set_state(State.HOVER)

	move_and_slide()


# Line-of-sight gate: within sight_range AND we're roughly facing the
# player (dot product against -Z forward, since that's what
# atan2(-x,-z) puts forward at). If both pass, also gate on
# ping_cooldown so we don't re-announce constantly.
func _check_los() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	var to_p: Vector3 = player.global_position - global_position
	to_p.y = 0.0
	var d: float = to_p.length()
	if d > sight_range or d < 0.01:
		return false
	var fwd: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var dot: float = fwd.dot(to_p.normalized())
	if dot < LOS_DOT:
		return false
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_ping_t < ping_cooldown:
		return false
	return true


# Walk every node in the "enemy" group; if it has _aggro_now(), call
# it. We swallow exceptions silently — most other enemies won't expose
# this method and that's fine; the spec is "ping anyone who listens."
func _aggro_ping() -> void:
	_last_ping_t = Time.get_ticks_msec() / 1000.0
	_set_state(State.ALERT)
	SoundBank.play_3d("crystal_hit", global_position)
	for n in get_tree().get_nodes_in_group("enemy"):
		if n == self:
			continue
		if n.has_method("_aggro_now"):
			n.call_deferred("_aggro_now")


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
	if visual:
		visual.scale = Vector3(1.20, 0.85, 1.20)
		var t := create_tween()
		t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
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
	SoundBank.play_3d("blob_die", global_position)
	_drop_loot()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", Vector3.ZERO, 0.30)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		parent.call_deferred("add_child", p)
		p.global_position = global_position + Vector3(randf_range(-0.4, 0.4), -0.5, randf_range(-0.4, 0.4))


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	_set_state(State.HURT)
