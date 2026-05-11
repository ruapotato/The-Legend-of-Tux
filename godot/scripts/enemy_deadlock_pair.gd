extends CharacterBody3D

# deadlock_pair — two enemies that mutually-protect each other. Each
# is invulnerable to damage UNLESS its partner is currently in a 3s
# stagger window. The "stagger" is opened by attempting to hit a
# protected member: the hit deflects, but the attempted-victim flips
# its partner's `_partner_staggered` flag for 3s, and the partner
# becomes vulnerable for that window.
#
# Result: the player has to alternate — hit A (no damage but staggers
# B), then hit B (now vulnerable), then hit A (now vulnerable through
# B's stagger reaction), etc.
#
# Pairing — same auto-pair-up pattern as race_condition: the two
# closest unpaired members within `pair_pickup_radius` bind on the
# next idle frame. If we end up unpaired, we behave like a regular
# enemy WITHOUT invulnerability (the lock requires both halves) — see
# the report header for context.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 12
@export var contact_damage: int = 1
@export var detect_range: float = 8.0
@export var move_speed: float = 2.2
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.30
@export var pair_pickup_radius: float = 8.0
@export var stagger_window: float = 3.0

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 6.0
const HURT_TIME: float = 0.30
const STAGGER_TIME: float = 0.60
const CONTACT_COOLDOWN: float = 1.0

enum State { IDLE, CHASE, HURT, STAGGER, DEAD }

var hp: int = 12
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var pair_partner: Node = null
var _partner_staggered_until: float = -1.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("deadlock_pair")
	contact_area.body_entered.connect(_on_contact_player)
	call_deferred("_try_pair_up")


func _try_pair_up() -> void:
	if pair_partner != null and is_instance_valid(pair_partner):
		return
	var here: Vector3 = global_position
	var best: Node = null
	var best_d: float = pair_pickup_radius
	for n in get_tree().get_nodes_in_group("deadlock_pair"):
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

	# Vulnerability tell — pulse harder while exposed.
	if visual:
		if _is_vulnerable():
			var pulse: float = 1.0 + sin(state_time * 12.0) * 0.10
			visual.scale = Vector3(pulse, 1.0, pulse)
		else:
			visual.scale = Vector3.ONE

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
		State.STAGGER:
			velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
			if state_time >= STAGGER_TIME:
				_set_state(State.CHASE if dist < detect_range else State.IDLE)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


func _on_contact_player(body: Node) -> void:
	if state == State.DEAD or state == State.HURT or state == State.STAGGER:
		return
	if not body.is_in_group("player"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_contact_t < CONTACT_COOLDOWN:
		return
	_last_contact_t = now
	if body.has_method("take_damage"):
		body.take_damage(contact_damage, global_position, self)


# Vulnerability rule: we take damage iff EITHER the partner is currently
# inside their stagger window OR we have no partner (the lonely-spawn
# fallback — without a partner, the lock is meaningless).
func _is_vulnerable() -> bool:
	if pair_partner == null or not is_instance_valid(pair_partner):
		return true
	return Time.get_ticks_msec() / 1000.0 < _partner_staggered_until


# Called by our partner to open our stagger window. Also flips us into
# the visible STAGGER state as feedback so the player knows the
# protection is open.
func notify_partner_stagger(duration: float) -> void:
	if state == State.DEAD:
		return
	_partner_staggered_until = Time.get_ticks_msec() / 1000.0 + duration
	_set_state(State.STAGGER)


func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
	if hp <= 0:
		return
	# Protected — don't lose HP, but stagger our partner so the player
	# can chip through them now.
	if not _is_vulnerable():
		# Spark + audio so the player reads "deflected, partner exposed."
		if visual:
			visual.scale = Vector3(1.10, 0.95, 1.10)
			var t := create_tween()
			t.tween_property(visual, "scale", Vector3.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		SoundBank.play_3d("crystal_hit", global_position)
		if pair_partner != null and is_instance_valid(pair_partner) \
				and pair_partner.has_method("notify_partner_stagger"):
			pair_partner.notify_partner_stagger(stagger_window)
		return
	# Vulnerable — full damage.
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
	# Cascade: surviving partner loses their lock and is now killable
	# without alternation. Detach the binding so they don't try to
	# stagger a freed node.
	if pair_partner != null and is_instance_valid(pair_partner):
		pair_partner.set("pair_partner", null)
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
