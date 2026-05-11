extends CharacterBody3D

# race_condition — designed to spawn in pairs (two siblings placed
# near each other in the dungeon JSON). Killing one buffs the survivor
# for 3s: faster, harder hits.
#
# Pairing — placement is JSON-driven (the dungeon writer drops two
# of these near each other), so pair-up is auto-discovered at _ready
# rather than passed explicitly:
#   - Walk the "race_condition" group on the next idle frame (so all
#     siblings are in the tree first).
#   - The two closest unpaired members within `pair_pickup_radius`
#     bind to each other via `pair_partner`.
#   - If we end up unpaired (lonely spawn — the level writer placed
#     a single one), the buff branch simply never fires; we behave
#     like a standard mid-difficulty enemy. This is the deliberate
#     fallback — see the report header for context.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 10
@export var contact_damage: int = 1
@export var detect_range: float = 8.0
@export var attack_range: float = 1.5
@export var move_speed: float = 2.6
@export var lunge_speed: float = 6.5
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.20
@export var pair_pickup_radius: float = 8.0
@export var buff_duration: float = 3.0
@export var buff_speed_mult: float = 1.6
@export var buff_damage_bonus: int = 1

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 6.0
const HURT_TIME: float = 0.28
const CONTACT_COOLDOWN: float = 0.8
const WIND_UP_TIME: float = 0.30
const ATTACK_LUNGE_TIME: float = 0.20
const RECOVER_TIME: float = 0.30

enum State { IDLE, CHASE, WIND_UP, ATTACK, RECOVER, HURT, DEAD }

var hp: int = 10
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var pair_partner: Node = null
var _buffed: bool = false
var _buff_until: float = -1.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var attack_hitbox: Area3D = $AttackHitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("race_condition")
	contact_area.body_entered.connect(_on_contact_player)
	attack_hitbox.body_entered.connect(_on_attack_overlap)
	attack_hitbox.monitoring = false
	# Defer pairing one frame so all siblings are spawned first.
	call_deferred("_try_pair_up")


# Auto-pair: find the closest unpaired race_condition within radius.
# The two-way binding goes both ways so killing either side buffs the
# other regardless of order.
func _try_pair_up() -> void:
	if pair_partner != null and is_instance_valid(pair_partner):
		return
	var here: Vector3 = global_position
	var best: Node = null
	var best_d: float = pair_pickup_radius
	for n in get_tree().get_nodes_in_group("race_condition"):
		if n == self or not (n is Node3D):
			continue
		if n.get("pair_partner") != null and is_instance_valid(n.get("pair_partner")):
			continue
		var d: float = (n as Node3D).global_position.distance_to(here)
		if d <= best_d:
			best = n
			best_d = d
	if best != null:
		pair_partner = best
		best.set("pair_partner", self)


func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


func _physics_process(delta: float) -> void:
	state_time += delta

	# Buff timer.
	if _buffed and Time.get_ticks_msec() / 1000.0 >= _buff_until:
		_buffed = false
		if visual:
			visual.scale = Vector3.ONE

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

	var spd: float = move_speed * (buff_speed_mult if _buffed else 1.0)
	var lunge: float = lunge_speed * (buff_speed_mult if _buffed else 1.0)

	match state:
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
			if dist < detect_range:
				_set_state(State.CHASE)
		State.CHASE:
			if dist < attack_range:
				_set_state(State.WIND_UP)
			elif dist > detect_range * 1.6:
				_set_state(State.IDLE)
			else:
				var dir: Vector3 = to_player.normalized()
				velocity.x = dir.x * spd
				velocity.z = dir.z * spd
				rotation.y = atan2(-dir.x, -dir.z)
		State.WIND_UP:
			velocity.x = move_toward(velocity.x, 0.0, 18.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 18.0 * delta)
			if state_time >= WIND_UP_TIME:
				_set_state(State.ATTACK)
		State.ATTACK:
			if state_time < ATTACK_LUNGE_TIME:
				attack_hitbox.monitoring = true
				var fwd: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
				velocity.x = fwd.x * lunge
				velocity.z = fwd.z * lunge
			else:
				attack_hitbox.set_deferred("monitoring", false)
				_set_state(State.RECOVER)
		State.RECOVER:
			velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
			if state_time >= RECOVER_TIME:
				_set_state(State.CHASE if dist < detect_range else State.IDLE)
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
		var dmg: int = contact_damage + (buff_damage_bonus if _buffed else 0)
		body.take_damage(dmg, global_position, self)


func _on_attack_overlap(body: Node) -> void:
	if body.is_in_group("player") and body.has_method("take_damage"):
		var dmg: int = contact_damage + (buff_damage_bonus if _buffed else 0)
		body.take_damage(dmg, global_position, self)


# Called by our partner when they die. Buff for buff_duration.
func apply_buff(duration: float) -> void:
	if state == State.DEAD:
		return
	_buffed = true
	_buff_until = Time.get_ticks_msec() / 1000.0 + duration
	# Visible tell: scale up + tint shift via emission boost. We don't
	# rebuild the material; just bump scale so the player reads the buff.
	if visual:
		visual.scale = Vector3(1.20, 1.20, 1.20)
	SoundBank.play_3d("crystal_hit", global_position)


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
		var rest: Vector3 = Vector3(1.20, 1.20, 1.20) if _buffed else Vector3.ONE
		t.tween_property(visual, "scale", rest, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
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
	attack_hitbox.set_deferred("monitoring", false)
	# Notify partner BEFORE we tear down — they buff for buff_duration.
	if pair_partner != null and is_instance_valid(pair_partner):
		if pair_partner.has_method("apply_buff"):
			pair_partner.apply_buff(buff_duration)
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
	if state != State.ATTACK:
		attack_hitbox.set_deferred("monitoring", false)


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)
