extends CharacterBody3D

# Shade Archon — a robed mini-boss that doesn't engage in melee. Holds
# the player at distance via teleport + slow-tracking shadow projectile.
# The encounter rewards patience and ranged play.
#
# Combat rhythm:
#   IDLE        — initial scan, very brief.
#   STALK       — visible, hovering. Throws a tracking shadow bolt every
#                 throw_interval (3.0s). Cannot melee — keeps a buffer
#                 distance.
#   FADE        — 0.5s "fade-out" before teleporting (vulnerable to
#                 anything during this animation, but visually obvious).
#   GONE        — 0.4s untargetable hover at the new position.
#   MATERIALISE — 0.5s "fade-in" at the new position. SECOND vulnerable
#                 window: arrow can land for double damage here too.
#                 After this, returns to STALK.
#   HURT        — knockback after a damaging hit.
#   DEAD        — flatten + despawn.
#
# Teleport cycle: STALK ~5s → FADE 0.5s → GONE 0.4s → MATERIALISE 0.5s
#                 → STALK ~5s → ...
#
# Damage rules:
#   - Sword: normal damage.
#   - Arrow / ranged: x2 damage. Detection uses the same heuristic as
#     enemy_init.gd — "the source position is far from the attacker" =
#     ranged hit. Bombs (attacker == null) also count as ranged.
#   - In GONE state, all damage is rejected (untargetable).
#
# Drop: a small key + 10 pebbles.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const KeyPickup    := preload("res://scenes/pickup_key.tscn")

signal died

@export var max_hp: int = 35
@export var detect_range: float = 14.0
@export var keep_distance: float = 5.0
@export var throw_interval: float = 3.0
@export var teleport_interval: float = 5.0
@export var teleport_radius: float = 6.0
@export var contact_damage: int = 2
@export var pebble_reward: int = 10
@export var ranged_damage_multiplier: int = 2
@export var bolt_damage: int = 2
@export var bolt_speed: float = 5.0
@export var bolt_homing: float = 1.6
@export var bolt_lifetime: float = 4.0

const GRAVITY: float = 18.0
const FADE_TIME: float = 0.50
const GONE_TIME: float = 0.40
const MATERIALISE_TIME: float = 0.50
const HURT_TIME: float = 0.30
const KNOCKBACK_SPEED: float = 3.0
const RANGED_HIT_DISTANCE: float = 3.0   # source-to-attacker threshold
# Slow drift around `keep_distance` from the player so the shade
# doesn't stand perfectly still between teleports.
const STALK_DRIFT_SPEED: float = 1.4

enum State { IDLE, STALK, FADE, GONE, MATERIALISE, HURT, DEAD }

var hp: int = 35
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _origin: Vector3 = Vector3.ZERO
var _throw_t: float = 1.5
var _teleport_t: float = 0.0
var _stalk_dir_sign: float = 1.0
var _stalk_dir_t: float = 0.0

@onready var visual: Node3D = $Visual
@onready var body_mesh: MeshInstance3D = $Visual/Robe
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	_origin = global_position
	_stalk_dir_sign = 1.0 if randf() > 0.5 else -1.0
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

	# Throw / teleport timers tick in STALK only.
	if state == State.STALK:
		_throw_t -= delta
		_teleport_t += delta
		if _throw_t <= 0.0 and dist < detect_range and player and is_instance_valid(player):
			_throw_bolt()
			_throw_t = throw_interval
		if _teleport_t >= teleport_interval:
			_teleport_t = 0.0
			_set_state(State.FADE)

	match state:
		State.IDLE:        _do_idle(delta, dist)
		State.STALK:       _do_stalk(delta, to_player, dist)
		State.FADE:        _do_fade(delta)
		State.GONE:        _do_gone(delta)
		State.MATERIALISE: _do_materialise(delta)
		State.HURT:        _do_hurt(delta)

	# The shade hovers — apply a gentle gravity but clamp at hover height
	# so it doesn't stick to the floor. Hover via velocity dampening.
	if not is_on_floor():
		velocity.y -= GRAVITY * delta * 0.4
	else:
		velocity.y = max(velocity.y, 0.5)
	move_and_slide()


# ---- Per-state handlers ------------------------------------------------

func _do_idle(delta: float, dist: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
	if dist < detect_range and player and is_instance_valid(player):
		_set_state(State.STALK)


func _do_stalk(delta: float, to_player: Vector3, dist: float) -> void:
	# Face the player, drift sideways at keep_distance.
	if to_player.length_squared() > 1e-6:
		var face: Vector3 = to_player.normalized()
		rotation.y = atan2(-face.x, -face.z)
	# Drift direction flips every 1.5–2.5s.
	_stalk_dir_t -= delta
	if _stalk_dir_t <= 0.0:
		_stalk_dir_sign = -_stalk_dir_sign
		_stalk_dir_t = randf_range(1.5, 2.5)
	if dist > 0.01:
		var to_p_n: Vector3 = to_player.normalized()
		var radial_err: float = dist - keep_distance
		var radial: Vector3 = to_p_n * (1.0 if radial_err > 0.0 else -1.0)
		var strafe: Vector3 = Vector3(-to_p_n.z, 0.0, to_p_n.x) * _stalk_dir_sign
		var combined: Vector3 = radial * 0.6 + strafe
		if abs(radial_err) < 0.4:
			combined = strafe
		velocity.x = combined.x * STALK_DRIFT_SPEED
		velocity.z = combined.z * STALK_DRIFT_SPEED


func _do_fade(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
	# Visual fade-out.
	var t: float = clamp(state_time / FADE_TIME, 0.0, 1.0)
	if visual:
		visual.scale = Vector3.ONE * (1.0 - 0.7 * t)
		_set_alpha(1.0 - t)
	if state_time >= FADE_TIME:
		_teleport()
		_set_state(State.GONE)


func _do_gone(delta: float) -> void:
	velocity = Vector3.ZERO
	if visual:
		visual.scale = Vector3.ONE * 0.3
		_set_alpha(0.0)
	if state_time >= GONE_TIME:
		_set_state(State.MATERIALISE)


func _do_materialise(delta: float) -> void:
	velocity = Vector3.ZERO
	var t: float = clamp(state_time / MATERIALISE_TIME, 0.0, 1.0)
	if visual:
		visual.scale = Vector3.ONE * (0.3 + 0.7 * t)
		_set_alpha(t)
	if state_time >= MATERIALISE_TIME:
		if visual:
			visual.scale = Vector3.ONE
			_set_alpha(1.0)
		_set_state(State.STALK)


func _do_hurt(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
	if state_time >= HURT_TIME:
		_set_state(State.STALK)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
	if hp <= 0:
		return
	# Untargetable while gone.
	if state == State.GONE:
		return
	var actual: int = amount
	# Ranged check — attacker null (bomb) OR attacker far from source.
	if _looks_like_ranged_hit(source_pos, attacker):
		actual = amount * ranged_damage_multiplier
	hp -= actual
	var away: Vector3 = global_position - source_pos
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		velocity.x = away.x * KNOCKBACK_SPEED
		velocity.z = away.z * KNOCKBACK_SPEED
	_hit_punch()
	SoundBank.play_3d("hurt", global_position)
	if hp <= 0:
		_die()
	else:
		# Don't interrupt the teleport sequence — only HURT from STALK.
		if state == State.STALK:
			_set_state(State.HURT)


func _looks_like_ranged_hit(source_pos: Vector3, attacker: Node) -> bool:
	if attacker == null:
		return true
	if attacker is Node3D:
		var d: float = (attacker as Node3D).global_position.distance_to(source_pos)
		if d > RANGED_HIT_DISTANCE:
			return true
	return false


func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	_set_state(State.HURT)


func _on_contact_player(_body: Node) -> void:
	# Touching the shade in STALK is a small, low-frequency tick. The
	# shade isn't a melee unit but standing in its space stings.
	if state != State.STALK:
		return
	if player and is_instance_valid(player) and player.has_method("take_damage"):
		player.take_damage(contact_damage, global_position, self)


func _hit_punch() -> void:
	if not visual:
		return
	var base_scale: Vector3 = visual.scale
	visual.scale = base_scale * Vector3(1.20, 0.85, 1.20)
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
	t.tween_property(visual, "scale", visual.scale * Vector3(1.2, 0.05, 1.2), 0.45)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var here: Vector3 = global_position
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		p.position = here + Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
		parent.call_deferred("add_child", p)
	var k := KeyPickup.instantiate()
	k.position = here + Vector3(0.0, 0.2, 0.4)
	parent.call_deferred("add_child", k)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0
	if state == State.STALK:
		_throw_t = throw_interval * 0.5   # don't spam right after teleport
	if state == State.FADE:
		SoundBank.play_3d("crystal_hit", global_position)
	elif state == State.MATERIALISE:
		SoundBank.play_3d("crystal_hit", global_position)


# Pick a teleport landing point: somewhere within `teleport_radius` of
# the spawn origin, biased to be ~5m from the player (keep_distance).
func _teleport() -> void:
	var here: Vector3 = global_position
	for i in range(8):
		var ang: float = randf() * TAU
		var r: float = randf_range(2.0, teleport_radius)
		var cand: Vector3 = _origin + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		cand.y = here.y
		if player and is_instance_valid(player):
			var d: float = cand.distance_to(player.global_position)
			if d > 3.5 and d < teleport_radius * 1.5:
				global_position = cand
				return
	# Fallback: warp anywhere within radius.
	var ang2: float = randf() * TAU
	var cand2: Vector3 = _origin + Vector3(cos(ang2) * teleport_radius, 0.0, sin(ang2) * teleport_radius)
	cand2.y = here.y
	global_position = cand2


# Set transparency on the robe + hood meshes by tweaking each
# StandardMaterial3D's albedo alpha. Does nothing for non-standard mats.
func _set_alpha(a: float) -> void:
	for n in _all_meshes(visual):
		var mat: Material = n.material_override
		if mat is StandardMaterial3D:
			var sm: StandardMaterial3D = mat
			# Ensure transparent rendering once we've poked the alpha.
			if sm.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var c: Color = sm.albedo_color
			c.a = clamp(a, 0.0, 1.0)
			sm.albedo_color = c


func _all_meshes(root: Node) -> Array:
	var out: Array = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(_all_meshes(child))
	return out


# ---- Inline shadow bolt -----------------------------------------------

# Self-hosted homing projectile. Slow, weakly tracks the player. Single
# damage on contact. Tween-driven so the script stays self-contained.
func _throw_bolt() -> void:
	var parent := get_parent()
	if parent == null or player == null or not is_instance_valid(player):
		return

	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 2     # player
	area.monitoring = true
	area.monitorable = false

	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.30
	cs.shape = sh
	area.add_child(cs)

	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.30
	sm.height = 0.60
	sm.radial_segments = 10
	sm.rings = 6
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.18, 0.40, 1)
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.30, 0.70, 1)
	mat.emission_energy_multiplier = 2.0
	mesh.material_override = mat
	area.add_child(mesh)

	var spawn_pos: Vector3 = global_position + Vector3(0.0, 0.6, 0.0)
	area.position = spawn_pos
	parent.call_deferred("add_child", area)

	var to_p: Vector3 = player.global_position - spawn_pos
	if to_p.length_squared() < 1e-6:
		to_p = Vector3.FORWARD
	var vel: Array = [to_p.normalized() * bolt_speed]
	var life: Array = [0.0]
	var hit: Array = [false]

	area.body_entered.connect(func (body):
		if hit[0]:
			return
		if body.is_in_group("player") and body.has_method("take_damage"):
			hit[0] = true
			body.take_damage(bolt_damage, area.global_position, self)
			area.queue_free())

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
		if life[0] >= bolt_lifetime:
			area.queue_free()
			return
		# Weak homing: nudge velocity toward player each tick.
		if player and is_instance_valid(player):
			var to_target: Vector3 = (player.global_position + Vector3(0.0, 0.6, 0.0)) - area.global_position
			if to_target.length() > 0.01:
				var desired: Vector3 = to_target.normalized() * bolt_speed
				vel[0] = vel[0].lerp(desired, clamp(bolt_homing * dt, 0.0, 1.0))
		area.global_position += vel[0] * dt)
