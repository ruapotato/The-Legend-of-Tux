extends CharacterBody3D

# rm_phantom — a translucent grey wraith that "removes" pickups and
# props on touch. When the player gets close, it drifts toward the
# nearest pickup/chest within 3m, queue_free's it, and recreates the
# same scene at the same spot 5s later (the "rm -i" recovery window).
#
# HP 8. Standard sword-knockback / contact damage like the blob, but
# its real threat isn't dealing damage — it's deleting the player's
# loot if they linger near a chest or grass-dropped heart.
#
# Pickup discovery: spec says "groups: pickup, chest". Pickups in the
# current codebase don't add themselves to any group, so we ALSO walk
# the dungeon-root siblings looking for nodes whose script path ends
# in pickup.gd or treasure_chest.gd. The group lookup wins if it has
# results — that path is forward-compatible with future tagging.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 8
@export var contact_damage: int = 1
@export var detect_range: float = 8.0
@export var move_speed: float = 2.2
@export var rm_radius: float = 3.0
@export var respawn_delay: float = 5.0
@export var rm_cooldown: float = 4.0
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.25

const GRAVITY: float = 18.0
const KNOCKBACK_SPEED: float = 6.0
const HURT_TIME: float = 0.28
const CONTACT_COOLDOWN: float = 1.0

enum State { IDLE, CHASE, HURT, DEAD }

var hp: int = 8
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _last_contact_t: float = -1000.0
var _rm_ready_at: float = 0.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")
	add_to_group("rm_phantom")
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

	# Slow drift bob.
	if visual:
		visual.position.y = sin(state_time * 1.4) * 0.10

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
	if now >= _rm_ready_at:
		_perform_rm()
		_rm_ready_at = now + rm_cooldown


# Find a pickup/chest within rm_radius. Tries the canonical groups
# first (forward-compatible), then falls back to scanning sibling
# nodes whose script path looks like a pickup or chest.
func _perform_rm() -> void:
	var here: Vector3 = global_position
	var candidates: Array = []
	for g in ["pickup", "chest"]:
		for n in get_tree().get_nodes_in_group(g):
			if n is Node3D and n.global_position.distance_to(here) <= rm_radius:
				candidates.append(n)
	if candidates.is_empty():
		var parent: Node = get_parent()
		if parent:
			for child in parent.get_children():
				if not (child is Node3D):
					continue
				var s: Script = child.get_script() as Script
				if s == null:
					continue
				var p: String = s.resource_path
				if p.ends_with("pickup.gd") or p.ends_with("treasure_chest.gd"):
					if (child as Node3D).global_position.distance_to(here) <= rm_radius:
						candidates.append(child)
	if candidates.is_empty():
		return
	var target: Node3D = candidates[randi() % candidates.size()] as Node3D
	if target == null or not is_instance_valid(target):
		return
	# Capture enough state to recreate it. We reuse the same packed scene
	# the node was instantiated from when we can; otherwise we capture a
	# duplicate via Node.duplicate so the respawn carries its config.
	var spawn_pos: Vector3 = target.global_position
	var path: String = target.scene_file_path
	var parent_node: Node = target.get_parent()
	target.queue_free()
	SoundBank.play_3d("crystal_hit", spawn_pos)
	# Schedule the respawn. Detached timer parented to the dungeon root
	# so it survives if we (the phantom) die first.
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = respawn_delay
	var root: Node = get_tree().current_scene
	if root == null:
		root = parent_node
	if root == null:
		return
	root.add_child(t)
	t.timeout.connect(func() -> void:
		if path != "" and parent_node != null and is_instance_valid(parent_node):
			var ps: PackedScene = load(path) as PackedScene
			if ps != null:
				var inst: Node = ps.instantiate()
				parent_node.add_child(inst)
				if inst is Node3D:
					(inst as Node3D).global_position = spawn_pos
		t.queue_free())
	t.start()


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
	died.emit()
	var t := create_tween()
	t.tween_property(visual, "scale", Vector3(1.5, 0.10, 1.5), 0.25)
	t.tween_callback(queue_free)


func _drop_loot() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for i in range(pebble_reward):
		var p := PebblePickup.instantiate()
		parent.call_deferred("add_child", p)
		p.global_position = global_position + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	if randf() < heart_drop_chance:
		var h := HeartPickup.instantiate()
		parent.call_deferred("add_child", h)
		h.global_position = global_position


func _set_state(new_state: int) -> void:
	state = new_state
	state_time = 0.0


# Shield deflection.
func get_knockback(direction: Vector3, force: float) -> void:
	velocity.x = direction.x * force
	velocity.z = direction.z * force
	velocity.y = 3.0
	_set_state(State.HURT)
