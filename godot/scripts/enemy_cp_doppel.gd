extends CharacterBody3D

# cp_doppel — a "doppel" that splits ONCE on first hit. HP 16; the
# instant it takes any damage, it spawns two copies of itself at
# +1m / -1m from its current position (each at half HP) and queue_frees
# the original. Subsequent generations have `_has_split = true` baked
# from spawn so they take damage normally.
#
# Lore note: the duplicating shell command, given form. Lirien-aligned
# trickster — copies of copies; the second hit kills.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 16
@export var contact_damage: int = 1
@export var detect_range: float = 8.0
@export var attack_range: float = 1.6
@export var move_speed: float = 2.6
@export var pebble_reward: int = 1
@export var heart_drop_chance: float = 0.10
# Set by the parent doppel when it splits — children skip the split
# branch and behave like a normal enemy (one and done).
@export var has_split: bool = false

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 6.0
const HURT_TIME: float = 0.28
const CONTACT_COOLDOWN: float = 1.0

enum State { IDLE, CHASE, HURT, DEAD }

var hp: int = 16
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var _has_split: bool = false

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	_has_split = has_split
	add_to_group("enemy")
	add_to_group("cp_doppel")
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
	# First-ever hit on the original splits it. Children (spawned with
	# has_split=true) skip this branch entirely.
	if not _has_split:
		_split()
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


# Spawn two children at +1m / -1m offset from the player axis (or
# world axis if the player isn't found yet) and queue_free self.
# Each child gets half max_hp, has_split=true, and starts in HURT.
func _split() -> void:
	state = State.DEAD   # block re-entry while we spawn the copies
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	SoundBank.play_3d("blob_attack", global_position)
	var parent: Node = get_parent()
	if parent == null:
		queue_free()
		return
	var packed: PackedScene = load(scene_file_path) as PackedScene
	if packed == null:
		queue_free()
		return
	var child_hp: int = max(1, max_hp / 2)
	var here: Vector3 = global_position
	var off_axis: Vector3 = Vector3(1, 0, 0)
	if player and is_instance_valid(player):
		var to_p: Vector3 = player.global_position - here
		to_p.y = 0.0
		if to_p.length() > 0.01:
			# Perpendicular in the XZ plane to the player axis.
			off_axis = Vector3(-to_p.z, 0.0, to_p.x).normalized()
	for sgn in [1.0, -1.0]:
		var inst: Node = packed.instantiate()
		parent.call_deferred("add_child", inst)
		if inst is Node3D:
			(inst as Node3D).global_position = here + off_axis * sgn
		# Configure exports BEFORE _ready runs by setting them post-add
		# is fine because call_deferred queues the add to the next idle
		# frame; the set below executes immediately on the not-yet-tree
		# instance and the values stick into _ready.
		inst.set("max_hp", child_hp)
		inst.set("has_split", true)
	queue_free()


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
	t.tween_property(visual, "scale", Vector3(1.4, 0.10, 1.4), 0.22)
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
