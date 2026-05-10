extends CharacterBody3D

# Fork Hydra — when struck (and not killed), splits into two smaller
# children of the next tier outward. Three tiers max:
#   tier 0 (full)  → splits into 2 tier-1
#   tier 1 (mid)   → splits into 2 tier-2
#   tier 2 (small) → never splits, dies normally
#
# Visual: a clutch of small dark spheres on a stalk, with 2^(2-tier)
# pulsing red "heads." So the silhouette tells you how dangerous it
# still is at a glance: 4 heads = full, 2 = mid, 1 = small.
#
# Lore lineage: lifted from FILESYSTEM.md §7. The flavor name is the
# only joke; the enemy plays it straight.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var tier: int = 0
@export var aggro_range: float = 7.0
@export var move_speed: float = 1.4

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 3.5
const HURT_TIME: float = 0.20
const FORK_TIME: float = 0.18
const CONTACT_COOLDOWN: float = 1.0
# Per-tier scalar tables. Indices match `tier`.
const TIER_HP:        Array = [6, 3, 2]
const TIER_SCALE:     Array = [1.0, 0.7, 0.5]
const TIER_CONTACT:   Array = [2, 1, 1]
const TIER_HEADS:     Array = [4, 2, 1]
# Drops per tier — tier 0 gets a heart on top of pebbles, tier 1/2 just pebbles.
const TIER_PEBBLES:   Array = [4, 2, 1]
const TIER_HEART:     Array = [true, false, false]
# When a parent forks, children are nudged outward at this speed so
# they visibly separate instead of stacking on top of one another.
const SPLIT_SPEED:    float = 4.0

enum State { WANDER, AGGRO, HURT, FORK, DEAD }

var hp: int = 6
var state: int = State.WANDER
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var _split_dir: Vector3 = Vector3.ZERO
var _heads: Array = []     # MeshInstance3D refs for the per-tier head visuals.

@onready var visual: Node3D = $Visual
@onready var stalk: MeshInstance3D = $Visual/Stalk
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	add_to_group("enemy")
	tier = clamp(tier, 0, 2)
	hp = TIER_HP[tier]
	# Body scale telegraphs tier — smaller children are visibly weaker.
	visual.scale = Vector3.ONE * float(TIER_SCALE[tier])
	contact_area.body_entered.connect(_on_contact_player)
	_build_heads()


# Generate the head visuals procedurally from the tier so we don't
# author three different scenes. Heads are arranged in a small ring
# above the body and pulse on a slow sin wave.
func _build_heads() -> void:
	# Wipe any pre-existing children (relevant if the scene template
	# carried placeholder heads).
	for child in visual.get_children():
		if child.has_meta("hydra_head"):
			child.queue_free()
	var n: int = int(TIER_HEADS[tier])
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.45, 0.10, 0.15, 1)
	head_mat.emission_enabled = true
	head_mat.emission = Color(1.0, 0.20, 0.20, 1)
	head_mat.emission_energy_multiplier = 0.8
	head_mat.roughness = 0.5
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.18
	head_mesh.height = 0.36
	head_mesh.radial_segments = 10
	head_mesh.rings = 6
	for i in range(n):
		var m := MeshInstance3D.new()
		m.mesh = head_mesh
		m.material_override = head_mat
		m.set_meta("hydra_head", true)
		var ang: float = float(i) / max(1, n) * TAU
		var r: float = 0.0 if n == 1 else 0.30
		m.position = Vector3(cos(ang) * r, 0.95, sin(ang) * r)
		visual.add_child(m)
		_heads.append(m)


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

	# Head pulse — emission energy oscillation read as "alive."
	for h in _heads:
		if is_instance_valid(h) and h.material_override:
			var pulse: float = 0.6 + 0.4 * sin(state_time * 3.0 + h.position.x * 5.0)
			h.material_override.emission_energy_multiplier = pulse

	var dist: float = 1e9
	var to_player: Vector3 = Vector3.ZERO
	if player and is_instance_valid(player):
		to_player = player.global_position - global_position
		to_player.y = 0.0
		dist = to_player.length()

	match state:
		State.WANDER:
			velocity.x = move_toward(velocity.x, 0.0, 4.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 4.0 * delta)
			if dist < aggro_range:
				_set_state(State.AGGRO)
		State.AGGRO:
			if dist > aggro_range * 1.6:
				_set_state(State.WANDER)
			elif to_player.length() > 0.05:
				var dir: Vector3 = to_player.normalized()
				velocity.x = dir.x * move_speed
				velocity.z = dir.z * move_speed
				rotation.y = atan2(-dir.x, -dir.z)
		State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= HURT_TIME:
				_set_state(State.AGGRO if dist < aggro_range else State.WANDER)
		State.FORK:
			# Brief held pose before the actual split; the spawn happens
			# in take_damage() and we queue_free at the end of FORK.
			velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
			if state_time >= FORK_TIME:
				queue_free()

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


func _on_contact_player(body: Node) -> void:
	if state == State.DEAD or state == State.HURT or state == State.FORK:
		return
	if not body.is_in_group("player"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_contact_t < CONTACT_COOLDOWN:
		return
	_last_contact_t = now
	if body.has_method("take_damage"):
		body.take_damage(int(TIER_CONTACT[tier]), global_position, self)


func take_damage(amount: int, source_pos: Vector3, _attacker: Node3D = null) -> void:
	if hp <= 0 or state == State.FORK:
		return
	hp -= amount
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		velocity.x = away.x * KNOCKBACK_SPEED
		velocity.z = away.z * KNOCKBACK_SPEED
		velocity.y = 2.5
	if hp <= 0:
		_die()
		return
	# Surviving hits at tier < 2 fork instead of just hurting.
	if tier < 2:
		_split_dir = away if away.length() > 0.01 else Vector3(1, 0, 0)
		_fork_into_children()
	else:
		_set_state(State.HURT)


# Spawn two children of the next tier, push them outward perpendicular
# to the hit direction, then queue ourselves for free at FORK_TIME.
func _fork_into_children() -> void:
	var parent: Node = get_parent()
	if parent == null:
		queue_free()
		return
	var here: Vector3 = global_position
	# Perpendicular axis in XZ to the knockback direction.
	var perp: Vector3 = Vector3(-_split_dir.z, 0.0, _split_dir.x).normalized()
	for i in [-1, 1]:
		var child: CharacterBody3D = (load("res://scenes/enemy_fork_hydra.tscn")
									  as PackedScene).instantiate()
		child.tier = tier + 1
		# Place child slightly above ground; physics settles it on next tick.
		child.position = here + perp * float(i) * 0.6 + Vector3(0, 0.2, 0)
		child.velocity = perp * float(i) * SPLIT_SPEED
		parent.call_deferred("add_child", child)
	# Disable our own hit volumes so we can't be re-hit during the
	# tiny FORK window before queue_free.
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	contact_area.set_deferred("monitoring", false)
	SoundBank.play_3d("blob_die", global_position)
	_set_state(State.FORK)


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
	t.tween_property(visual, "scale", visual.scale * Vector3(1.2, 0.05, 1.2), 0.30)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var here: Vector3 = global_position
	for i in range(int(TIER_PEBBLES[tier])):
		var p := PebblePickup.instantiate()
		p.position = here + Vector3(randf_range(-0.5, 0.5), 0.0,
								   randf_range(-0.5, 0.5))
		parent.call_deferred("add_child", p)
	if bool(TIER_HEART[tier]):
		var h := HeartPickup.instantiate()
		h.position = here + Vector3(0, 0, 0.4)
		parent.call_deferred("add_child", h)


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0
