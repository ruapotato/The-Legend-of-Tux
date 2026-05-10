extends CharacterBody3D

# Process Ghost — a half-lucid wanderer of the Murk. Drifts in slow
# circles when alone; if the player crosses 5m it locks on and drifts
# toward them at 1 m/s. It dies easily (HP 2), and on death just fades
# out — no dramatic punctuation. Drops a single pebble.
#
# State machine is small enough to keep inline (cf. enemy_blob.gd).
#
# Lore lineage: Murk-bound /proc dweller. The signs do not say so.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 2
@export var contact_damage: int = 1
@export var aggro_range: float = 5.0
@export var aggro_speed: float = 1.0
@export var wander_speed: float = 0.6
@export var pebble_reward: int = 1

const GRAVITY: float = 18.0
const HURT_TIME: float = 0.25
const KNOCKBACK_SPEED: float = 4.0
const BOB_HZ: float = 1.0
const BOB_AMP: float = 0.10
# Wander is a slow circle — radius drives how far it drifts and the
# slow angular speed keeps it readable as "lost" rather than "patrolling."
const WANDER_RADIUS: float = 1.6
const WANDER_OMEGA: float = 0.45
const CONTACT_COOLDOWN: float = 1.0

enum State { WANDER, AGGRO, HURT, DEAD }

var hp: int = 2
var state: int = State.WANDER
var state_time: float = 0.0
var player: Node3D = null
var _wander_phase: float = 0.0
var _last_contact_t: float = -1000.0
var _origin: Vector3 = Vector3.ZERO

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	_origin = global_position
	_wander_phase = randf() * TAU
	contact_area.body_entered.connect(_on_contact_player)


# Enemies enter the tree before Tux in our generated dungeons; lazy-fetch
# the player each frame until the "player" group is populated.
func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


func _physics_process(delta: float) -> void:
	state_time += delta

	if state == State.DEAD:
		# Already despawning via the fade tween; just let physics settle.
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
			move_and_slide()
		return
	_ensure_player()

	# Slow vertical bob keeps the figure ghostly even when standing still.
	var bob: float = sin(state_time * BOB_HZ * TAU) * BOB_AMP
	visual.position.y = bob

	var dist: float = 1e9
	var to_player: Vector3 = Vector3.ZERO
	if player and is_instance_valid(player):
		to_player = player.global_position - global_position
		to_player.y = 0.0
		dist = to_player.length()

	match state:
		State.WANDER:
			_wander_phase += WANDER_OMEGA * delta
			# Sample a target along a small circle around the spawn
			# origin and steer toward it; drifts smoothly without a
			# real path-planner.
			var target: Vector3 = _origin + Vector3(
				cos(_wander_phase) * WANDER_RADIUS,
				0.0,
				sin(_wander_phase) * WANDER_RADIUS,
			)
			var to_target: Vector3 = target - global_position
			to_target.y = 0.0
			if to_target.length() > 0.05:
				var dir: Vector3 = to_target.normalized()
				velocity.x = dir.x * wander_speed
				velocity.z = dir.z * wander_speed
				rotation.y = atan2(-dir.x, -dir.z)
			else:
				velocity.x = move_toward(velocity.x, 0.0, 4.0 * delta)
				velocity.z = move_toward(velocity.z, 0.0, 4.0 * delta)
			if dist < aggro_range:
				_set_state(State.AGGRO)
		State.AGGRO:
			if dist > aggro_range * 1.6:
				_set_state(State.WANDER)
			elif to_player.length() > 0.05:
				var dir: Vector3 = to_player.normalized()
				velocity.x = dir.x * aggro_speed
				velocity.z = dir.z * aggro_speed
				rotation.y = atan2(-dir.x, -dir.z)
		State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= HURT_TIME:
				_set_state(State.AGGRO if dist < aggro_range else State.WANDER)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


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
		velocity.y = 2.0
	if hp <= 0:
		_die()
	else:
		_set_state(State.HURT)


# Direct-touch contact damage with a cooldown — same pattern as the
# blade overlap on enemy_tomato.gd.
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


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	# Deferred — _die may run inside an Area3D signal where Godot
	# blocks direct monitoring writes.
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	SoundBank.play_3d("enemy_squish", global_position)
	_drop_loot()
	died.emit()
	# Soft fade-and-shrink — no death sting, just a passing.
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(visual, "scale", Vector3(0.4, 0.4, 0.4), 0.55)
	# Tween the body's transparent_albedo via per-mesh material_override
	# would require knowing every mesh; the simpler win is just the
	# scale-down. The ghost is already half-transparent in its material.
	t.chain().tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var here: Vector3 = global_position
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		p.position = here + Vector3(randf_range(-0.4, 0.4), 0.0,
								   randf_range(-0.4, 0.4))
		parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0
