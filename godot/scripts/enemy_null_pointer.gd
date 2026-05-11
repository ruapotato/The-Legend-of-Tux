extends CharacterBody3D

# null_pointer — a void-shadow that, when struck, dereferences the
# player to an undefined position 3-5m away. Doesn't damage on touch
# enough to matter; the threat is the disorientation. HP 6.
#
# The teleport is a flat +offset on the player's global_position. We
# don't try to validate the destination against geometry — it's a
# "null deref" in flavor; landing in a wall is on-theme.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 6
@export var contact_damage: int = 1
@export var detect_range: float = 8.0
@export var move_speed: float = 2.4
@export var teleport_min: float = 3.0
@export var teleport_max: float = 5.0
@export var pebble_reward: int = 1
@export var heart_drop_chance: float = 0.20

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 5.0
const HURT_TIME: float = 0.30
const CONTACT_COOLDOWN: float = 1.0

enum State { IDLE, CHASE, HURT, DEAD }

var hp: int = 6
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("null_pointer")
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

	if visual:
		visual.rotation.y += delta * 1.6

	match state:
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
			if dist < detect_range:
				_set_state(State.CHASE)
		State.CHASE:
			if dist > detect_range * 1.6:
				_set_state(State.IDLE)
			elif to_player.length() > 0.01:
				var dir: Vector3 = to_player.normalized()
				velocity.x = dir.x * move_speed
				velocity.z = dir.z * move_speed
				rotation.y = atan2(-dir.x, -dir.z)
		State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= HURT_TIME:
				_set_state(State.CHASE if dist < detect_range else State.IDLE)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


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
	# The signature move: yank the player to a random nearby tile.
	if player and is_instance_valid(player):
		var ang: float = randf() * TAU
		var r: float = randf_range(teleport_min, teleport_max)
		var off: Vector3 = Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		player.global_position += off
		SoundBank.play_3d("crystal_hit", player.global_position)
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		velocity.x = away.x * KNOCKBACK_SPEED
		velocity.z = away.z * KNOCKBACK_SPEED
		velocity.y = 3.0
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
	t.tween_property(visual, "scale", Vector3(1.4, 0.10, 1.4), 0.25)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		parent.call_deferred("add_child", p)
		p.global_position = global_position + Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
	if randf() < heart_drop_chance:
		var h := HeartPickup.instantiate()
		parent.call_deferred("add_child", h)
		h.global_position = global_position


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)
