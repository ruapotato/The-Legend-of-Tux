extends CharacterBody3D

# cache_wraith — slow, fat ghost with a pickup tucked inside its core.
# When it dies, the held pickup spawns at its position. HP 14.
#
# `held_pickup_scene` is exported so a level designer (or future
# dungeon JSON wiring) can pin a heart_piece, fairy bottle, or any
# other PackedScene to drop. Default is a heart pickup so the wraith
# is at least mildly rewarding even if no specific drop was set.
#
# Lore note: caches in /var/cache that hoard wisp-light. Their core
# is always something the player needs.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")
const HeartPiece   := preload("res://scenes/heart_piece.tscn")

signal died

@export var max_hp: int = 14
@export var contact_damage: int = 2
@export var detect_range: float = 7.0
@export var move_speed: float = 1.6
@export var pebble_reward: int = 3
@export var held_pickup_scene: PackedScene = HeartPiece

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 4.0
const HURT_TIME: float = 0.30
const CONTACT_COOLDOWN: float = 1.0

enum State { IDLE, CHASE, HURT, DEAD }

var hp: int = 14
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
	add_to_group("cache_wraith")
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

	# Slow bob — looks heavy.
	if visual:
		visual.position.y = sin(state_time * 1.0) * 0.08

	match state:
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0.0, 4.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 4.0 * delta)
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
	_drop_held_pickup()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", Vector3(1.4, 0.10, 1.4), 0.25)
	t.tween_callback(queue_free)


# Drop the held PackedScene at our current position (small +Y offset so
# it doesn't spawn inside the floor). Parented to the dungeon root so
# it persists past our queue_free.
func _drop_held_pickup() -> void:
	if held_pickup_scene == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var inst: Node = held_pickup_scene.instantiate()
	parent.call_deferred("add_child", inst)
	if inst is Node3D:
		(inst as Node3D).global_position = global_position + Vector3(0, 0.3, 0)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		parent.call_deferred("add_child", p)
		p.global_position = global_position + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)
