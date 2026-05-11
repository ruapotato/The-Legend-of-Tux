extends CharacterBody3D

# cron_daemon — a stationary spike-pillar that picks a random tile in
# a small radius around itself, marks it with a red emissive decal for
# 3s, then strikes that tile with a 0.3s damage zone. Repeats forever.
#
# HP 12. Standard sword-knockback take_damage path.
#
# The decal is a very thin CSGCylinder3D placed at the chosen ground
# point. We use Node3D + plain MeshInstance3D + a flat CylinderMesh
# (no CSG dependency) so the scene is portable to headless boot tests.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 12
@export var detect_range: float = 12.0
@export var strike_radius: float = 0.75   # tile half-width (1.5m diameter)
@export var aim_radius: float = 4.0       # how far from the daemon a tile can be picked
@export var telegraph_time: float = 3.0
@export var strike_window: float = 0.30
@export var strike_damage: int = 3
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.20

const GRAVITY: float = 18.0

enum State { IDLE, AIM, STRIKE, RECOVER, DEAD }

var hp: int = 12
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _strike_target: Vector3 = Vector3.ZERO
var _decal: Node3D = null

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("cron_daemon")


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

	if visual:
		visual.rotation.y += delta * 0.4

	var dist: float = 1e9
	if player and is_instance_valid(player):
		dist = global_position.distance_to(player.global_position)

	match state:
		State.IDLE:
			if dist < detect_range:
				_pick_target()
				_set_state(State.AIM)
		State.AIM:
			# Telegraph the strike with the decal pulse.
			_pulse_decal()
			if state_time >= telegraph_time:
				_fire_strike()
				_set_state(State.STRIKE)
		State.STRIKE:
			if state_time >= strike_window:
				if _decal != null and is_instance_valid(_decal):
					_decal.queue_free()
					_decal = null
				_set_state(State.RECOVER)
		State.RECOVER:
			if state_time >= 0.3:
				if dist < detect_range:
					_pick_target()
					_set_state(State.AIM)
				else:
					_set_state(State.IDLE)

	# Stationary.
	velocity.x = 0.0
	velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


# Pick a random tile within aim_radius. If the player is in range, bias
# toward their current position so the daemon feels like it's hunting
# rather than rolling pure dice.
func _pick_target() -> void:
	var center: Vector3 = global_position
	if player and is_instance_valid(player):
		var to_p: Vector3 = player.global_position - center
		to_p.y = 0.0
		if to_p.length() <= aim_radius:
			center = player.global_position
		else:
			center += to_p.normalized() * aim_radius * 0.5
	var ang: float = randf() * TAU
	var r: float = randf() * aim_radius * 0.6
	_strike_target = Vector3(center.x + cos(ang) * r, global_position.y, center.z + sin(ang) * r)
	_spawn_decal()


# Decal: a flat low-profile cylinder mesh tinted red, parented to the
# scene root so it sits at the strike point instead of moving with us.
func _spawn_decal() -> void:
	if _decal != null and is_instance_valid(_decal):
		_decal.queue_free()
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_parent()
	if parent == null:
		return
	var d := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = strike_radius
	m.bottom_radius = strike_radius
	m.height = 0.04
	m.radial_segments = 16
	d.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.20, 0.15, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.15, 0.10, 1.0)
	mat.emission_energy_multiplier = 1.0
	d.material_override = mat
	parent.add_child(d)
	d.global_position = _strike_target + Vector3(0, 0.02, 0)
	_decal = d


func _pulse_decal() -> void:
	if _decal == null or not is_instance_valid(_decal):
		return
	var mat: StandardMaterial3D = _decal.material_override as StandardMaterial3D
	if mat == null:
		return
	# Stronger pulse as we approach strike — like a klaxon.
	var t: float = clamp(state_time / telegraph_time, 0.0, 1.0)
	var base: float = 0.40 + t * 0.40
	var beat: float = sin(state_time * (4.0 + t * 8.0)) * 0.20
	mat.albedo_color = Color(1.0, 0.20, 0.15, clamp(base + beat, 0.20, 0.95))


# Spawn the actual damage volume at the marked tile for strike_window.
# Layered like a normal enemy attack hitbox so the player's body
# overlaps it; we deal damage on overlap and let the volume self-free.
func _fire_strike() -> void:
	SoundBank.play_3d("crystal_hit", _strike_target)
	var area := Area3D.new()
	area.collision_layer = 16
	area.collision_mask = 2
	area.monitoring = true
	area.monitorable = false
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = strike_radius
	cs.shape = sphere
	area.add_child(cs)
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_parent()
	if parent == null:
		return
	parent.add_child(area)
	area.global_position = _strike_target + Vector3(0, 0.5, 0)
	# Sweep one frame later, then expire after strike_window total.
	var sweep := Timer.new()
	sweep.one_shot = true
	sweep.wait_time = 0.05
	area.add_child(sweep)
	sweep.timeout.connect(func() -> void:
		for body in area.get_overlapping_bodies():
			if body.is_in_group("player") and body.has_method("take_damage"):
				body.take_damage(strike_damage, area.global_position, self)
		var killer := Timer.new()
		killer.one_shot = true
		killer.wait_time = max(0.05, strike_window - 0.05)
		area.add_child(killer)
		killer.timeout.connect(func() -> void:
			if is_instance_valid(area):
				area.queue_free())
		killer.start())
	sweep.start()


func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
	if hp <= 0:
		return
	hp -= amount
	if visual:
		visual.scale = Vector3(1.20, 0.85, 1.20)
		var t := create_tween()
		t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# We don't move (stationary), so no knockback; record source for parity.
	if hp <= 0:
		_die()


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	if _decal != null and is_instance_valid(_decal):
		_decal.queue_free()
		_decal = null
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
