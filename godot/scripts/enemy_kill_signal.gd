extends CharacterBody3D

# kill_signal — a stationary "rune" that telegraphs a 2s instakill cone
# (3m wide, 4m long) aimed at the player. The cone draws as a flat
# fan-shaped Area3D fading red over 2s. On expiry, the area deals
# max_fish * HP_PER_FISH damage to anyone overlapping.
#
# HP 1 — dies on first hit, BUT the player has to actually survive the
# telegraph window. If you panic-swing into it, you eat the cone.
#
# Quirk: the cone is "instakill" but we honor the standard take_damage
# pipeline so fairy bottles can revive, and so the enemy isn't a
# magical bypass of the player's HP system.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 1
@export var detect_range: float = 9.0
@export var cone_length: float = 4.0
@export var cone_width: float = 3.0
@export var telegraph_time: float = 2.0
@export var cone_cooldown: float = 3.0
@export var pebble_reward: int = 0

const GRAVITY: float = 18.0

enum State { IDLE, TELEGRAPH, RECOVER, DEAD }

var hp: int = 1
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _telegraph: Node3D = null
var _telegraph_dir: Vector3 = Vector3(0, 0, -1)
var _cooldown_t: float = 0.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("kill_signal")


func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


func _physics_process(delta: float) -> void:
	state_time += delta
	_cooldown_t = max(0.0, _cooldown_t - delta)

	if state == State.DEAD:
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
			move_and_slide()
		return
	_ensure_player()

	# Pulse the rune visual in IDLE so the player knows it's alive.
	if visual:
		var pulse: float = 1.0 + sin(state_time * 3.0) * 0.08
		visual.scale = Vector3(pulse, 1.0, pulse)

	match state:
		State.IDLE:
			velocity.x = 0.0
			velocity.z = 0.0
			if _cooldown_t <= 0.0 and player and is_instance_valid(player):
				var d: float = global_position.distance_to(player.global_position)
				if d < detect_range:
					_begin_telegraph()
		State.TELEGRAPH:
			velocity.x = 0.0
			velocity.z = 0.0
			_update_telegraph_visual()
			if state_time >= telegraph_time:
				_fire_cone()
				_set_state(State.RECOVER)
		State.RECOVER:
			velocity.x = 0.0
			velocity.z = 0.0
			if state_time >= 0.4:
				_cooldown_t = cone_cooldown
				_set_state(State.IDLE)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -1.0
	move_and_slide()


# Pick the cone direction from current player position; that direction
# is locked for the whole telegraph window so the player can dodge by
# rolling sideways.
func _begin_telegraph() -> void:
	if player == null or not is_instance_valid(player):
		return
	var to_p: Vector3 = player.global_position - global_position
	to_p.y = 0.0
	if to_p.length() < 0.01:
		_telegraph_dir = Vector3(0, 0, -1)
	else:
		_telegraph_dir = to_p.normalized()
	rotation.y = atan2(-_telegraph_dir.x, -_telegraph_dir.z)
	_spawn_telegraph_visual()
	SoundBank.play_3d("crystal_hit", global_position)
	_set_state(State.TELEGRAPH)


# Build the fan as a flat MeshInstance3D under our visual root, so it
# follows the rune. We use an ImmediateMesh for the wedge — cheap, no
# extra resource files needed.
func _spawn_telegraph_visual() -> void:
	if _telegraph != null and is_instance_valid(_telegraph):
		_telegraph.queue_free()
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.10, 0.10, 0.30)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Build a triangle fan in local space — apex at origin, opening
	# along -Z to match face_yaw=atan2(-x,-z).
	var segs: int = 16
	var half_w: float = cone_width * 0.5
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	for i in range(segs):
		var t0: float = float(i) / segs
		var t1: float = float(i + 1) / segs
		var x0: float = lerp(-half_w, half_w, t0)
		var x1: float = lerp(-half_w, half_w, t1)
		# Apex -> right edge -> left edge (CCW from above).
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3(x1, 0.02, -cone_length))
		im.surface_add_vertex(Vector3(x0, 0.02, -cone_length))
	im.surface_end()
	mi.mesh = im
	mi.material_override = mat
	add_child(mi)
	_telegraph = mi


func _update_telegraph_visual() -> void:
	if _telegraph == null or not is_instance_valid(_telegraph):
		return
	var t: float = clamp(state_time / telegraph_time, 0.0, 1.0)
	# Ramp alpha from 0.30 to 0.85 over the window — reads as "loading."
	var mat: StandardMaterial3D = _telegraph.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = Color(1.0, 0.10, 0.10, lerp(0.30, 0.85, t))


# Fire the cone: build a one-frame Area3D wedge collider, sweep for the
# player, deal max-HP damage. The visual cleans itself up via the same
# tween so the wedge "discharges" then fades.
func _fire_cone() -> void:
	SoundBank.play_3d("blob_attack", global_position)
	# Damage = full bar so the player loses everything if they're caught.
	var dmg: int = 12
	if has_node("/root/GameState"):
		var gs: Node = get_node("/root/GameState")
		var mf: int = int(gs.get("max_fish")) if "max_fish" in gs else 3
		var per: int = int(gs.get("HP_PER_FISH")) if "HP_PER_FISH" in gs else 4
		dmg = mf * per
	# Build the damage volume as a single ConvexPolygonShape3D wedge.
	var area := Area3D.new()
	area.collision_layer = 16
	area.collision_mask = 2
	area.monitoring = true
	area.monitorable = false
	var cs := CollisionShape3D.new()
	var convex := ConvexPolygonShape3D.new()
	var pts: PackedVector3Array = PackedVector3Array()
	var half_w: float = cone_width * 0.5
	# Six points: apex + far-edge corners, top and bottom (1m tall).
	pts.append(Vector3(0, 0, 0))
	pts.append(Vector3(0, 1.5, 0))
	pts.append(Vector3(-half_w, 0, -cone_length))
	pts.append(Vector3(half_w, 0, -cone_length))
	pts.append(Vector3(-half_w, 1.5, -cone_length))
	pts.append(Vector3(half_w, 1.5, -cone_length))
	convex.points = pts
	cs.shape = convex
	area.add_child(cs)
	add_child(area)
	# Defer one tick so physics registers, then sweep.
	var sweeper := Timer.new()
	sweeper.one_shot = true
	sweeper.wait_time = 0.05
	area.add_child(sweeper)
	sweeper.timeout.connect(func() -> void:
		for body in area.get_overlapping_bodies():
			if body.is_in_group("player") and body.has_method("take_damage"):
				body.take_damage(dmg, global_position, self)
		# Fade the telegraph then remove both volume and visual.
		if is_instance_valid(_telegraph):
			var t := _telegraph.create_tween()
			var mat: StandardMaterial3D = _telegraph.material_override as StandardMaterial3D
			if mat:
				t.tween_property(mat, "albedo_color", Color(1.0, 0.10, 0.10, 0.0), 0.30)
			t.tween_callback(_telegraph.queue_free)
			_telegraph = null
		if is_instance_valid(area):
			area.queue_free())
	sweeper.start()


func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
	if hp <= 0:
		return
	hp -= amount
	if visual:
		visual.scale = Vector3(1.20, 0.85, 1.20)
		var t := create_tween()
		t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Knockback is irrelevant — we're stationary — but record source_pos
	# for parity with the take_damage signature.
	if hp <= 0:
		_die()


func _die() -> void:
	state = State.DEAD
	state_time = 0.0
	hitbox.set_deferred("monitoring", false)
	hitbox.set_deferred("monitorable", false)
	# Cancel any in-flight telegraph — killing the rune defuses it.
	if _telegraph != null and is_instance_valid(_telegraph):
		_telegraph.queue_free()
	SoundBank.play_3d("blob_die", global_position)
	_drop_loot()
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", Vector3(1.6, 0.05, 1.6), 0.20)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		parent.call_deferred("add_child", p)
		p.global_position = global_position + Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0
