extends Node3D

# Early-game wood source — small bush you can punch barehanded for a
# wood drop. Two hits with fists, one with a sword/axe. This is the
# bridge from "spawned naked into the forest" to "I have enough wood
# to craft a sword at the workbench"; full trees are tool-gated.

# Early-game wood source. Bare fists chip 1 hp/swing → 2 hits to break.
# Swords chip 2 hp/swing → one-shot. We grant the resource directly on
# break (matching raspberry_bush's interact path) instead of spawning a
# ground pickup, because the Area3D-pickup loop was missing too many
# drops in practice — small collider plus chunk parenting meant
# `body_entered` rarely fired. Direct-grant is unambiguous.

@export var hp_full: int = 2
@export var wood_drops_on_break: int = 1
@export var bush_radius: float = 0.55
@export var leaf_color: Color = Color(0.22, 0.40, 0.18, 1)
@export var berry_chance: float = 0.0    # set >0 to mix in berry bushes

var hp: int = 2
var _hp_label: Label3D = null
var _hp_label_timer: float = 0.0


func _ready() -> void:
	add_to_group("ground_snap")
	add_to_group("bush")
	hp = hp_full
	# Three overlapping SphereMesh blobs for a clumpy bush silhouette,
	# all driven from bush_radius so the prop scales cleanly.
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = leaf_color
	leaf_mat.roughness = 0.85
	_add_blob(Vector3(0, bush_radius * 0.95, 0), bush_radius, leaf_mat)
	_add_blob(Vector3(bush_radius * 0.55, bush_radius * 0.6, bush_radius * 0.10),
			bush_radius * 0.75, leaf_mat)
	_add_blob(Vector3(-bush_radius * 0.50, bush_radius * 0.65, -bush_radius * 0.05),
			bush_radius * 0.7, leaf_mat)
	# Static collision so the player can't walk through; small height
	# (cylinder) since bushes shouldn't behave like a wall.
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.height = bush_radius * 1.8
	cyl.radius = bush_radius * 0.9
	shape.shape = cyl
	shape.position.y = bush_radius * 0.9
	body.add_child(shape)
	# Sword-detectable Area3D on layer 32 — same layer the player's
	# SwordHitbox masks. Parent-fallback in sword_hitbox._on_area_entered
	# dispatches the hit up to this Node3D's take_damage; no separate
	# forwarder script needed. Layer/monitorable are set DEFERRED — the
	# physics server is only aware of the area once it's in the tree, so
	# direct property writes in _ready can be lost on the first frame.
	var hitbox := Area3D.new()
	add_child(hitbox)
	var hit_shape := CollisionShape3D.new()
	var hit_sphere := SphereShape3D.new()
	hit_sphere.radius = bush_radius * 1.1
	hit_shape.shape = hit_sphere
	hit_shape.position.y = bush_radius * 0.9
	hitbox.add_child(hit_shape)
	hitbox.set_deferred("collision_layer", 32)
	hitbox.set_deferred("collision_mask", 0)
	hitbox.set_deferred("monitorable", true)
	hitbox.set_deferred("monitoring", false)


func _add_blob(pos: Vector3, radius: float, mat: StandardMaterial3D) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 1.9
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.position = pos
	m.material_override = mat
	add_child(m)


func _process(delta: float) -> void:
	if _hp_label_timer > 0.0:
		_hp_label_timer -= delta
		if _hp_label and is_instance_valid(_hp_label):
			_hp_label.modulate.a = clamp(_hp_label_timer / 0.5, 0.0, 1.0)
			if _hp_label_timer <= 0.0:
				_hp_label.queue_free()
				_hp_label = null


# Toggle when diagnosing — prints every hit and the destruction path so
# you can tell whether a one-shot kill came from the wood_bush code or
# from some other take_damage callsite (the dungeon bush.gd used to be
# spawned in the same biome and one-shot to pebble/heart with no wood).
const DEBUG: bool = true


# Same signature as tree_prop / animal so the sword_hitbox dispatches
# uniformly. Bushes accept any non-zero damage (fists included) so
# they're the bare-hand wood source.
func take_damage(amount: int, _source_pos: Vector3 = Vector3.ZERO,
		_attacker: Node = null) -> void:
	if hp <= 0 or amount <= 0:
		if DEBUG:
			print("[wood_bush %s] take_damage REJECTED — hp=%d amount=%d"
					% [name, hp, amount])
		return
	hp -= amount
	if DEBUG:
		print("[wood_bush %s] take_damage amount=%d → hp=%d/%d"
				% [name, amount, hp, hp_full])
	# Only flash the HP banner if the bush survived — otherwise the
	# break/drop runs and the bush is freed before the banner ever
	# draws. Showing "HP 0 / N" right before death also looks broken.
	if hp > 0:
		_show_hp_banner("HP %d / %d" % [hp, hp_full])
		return
	_break_and_drop()


func _break_and_drop() -> void:
	# Direct grant — bypasses the flaky Area3D pickup pipeline. Visual
	# feedback comes from the inventory slot count ticking up (the
	# pause-menu grid live-refreshes on resource_changed) plus the SFX.
	if GameState and GameState.has_method("add_resource"):
		GameState.add_resource("wood", wood_drops_on_break)
		if DEBUG:
			print("[wood_bush %s] BREAK — granted %d wood, total=%d"
					% [name, wood_drops_on_break,
							int(GameState.resources.get("wood", 0))])
	elif DEBUG:
		print("[wood_bush %s] BREAK — GameState/add_resource unavailable!" % name)
	_mark_destroyed()
	SoundBank.play_3d("bush_cut", global_position)
	queue_free()


# Procedural-world persistence hook. Records this prop's deterministic id
# in GameState so the chunk re-spawner skips it on reload. The id is
# stamped onto the instance via meta by world_chunk.apply_data; bushes
# placed by hand (no meta) silently no-op.
func _mark_destroyed() -> void:
	if not has_meta("prop_id"):
		return
	if GameState == null:
		return
	GameState.destroyed_props[String(get_meta("prop_id"))] = true


func _show_hp_banner(text: String) -> void:
	if _hp_label == null:
		_hp_label = Label3D.new()
		_hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_hp_label.fixed_size = true
		_hp_label.pixel_size = 0.0022
		# no_depth_test = true so the banner ALWAYS draws on top of the
		# bush mesh — otherwise the text gets clipped inside the leaves.
		_hp_label.no_depth_test = true
		_hp_label.modulate = Color(0.85, 1.0, 0.65, 1.0)
		_hp_label.outline_modulate = Color(0, 0, 0, 1)
		_hp_label.outline_size = 6
		add_child(_hp_label)
	_hp_label.text = text
	# Float well above the bush so it's easy to spot.
	_hp_label.position = Vector3(0, bush_radius * 3.0 + 0.4, 0)
	_hp_label.modulate.a = 1.0
	_hp_label_timer = 1.5
