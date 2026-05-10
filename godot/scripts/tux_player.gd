extends CharacterBody3D

# Player controller: ties together input, the action state machine
# (tux_state.gd), the procedural animator (tux_anim.gd), the rig, the
# sword + shield, and the trail FX. The state machine owns the action
# logic; this script is the integration layer.

const TuxState = preload("res://scripts/tux_state.gd")
const TuxAnim  = preload("res://scripts/tux_anim.gd")
const BoomerangScene = preload("res://scenes/boomerang.tscn")
const BombScene      = preload("res://scenes/bomb.tscn")
const Bow       = preload("res://scripts/bow.gd")
const Slingshot = preload("res://scripts/slingshot.gd")
const Hookshot  = preload("res://scripts/hookshot.gd")
const ItemHammer    = preload("res://scripts/item_hammer.gd")
const ItemGlimSight = preload("res://scripts/item_glim_sight.gd")

@export var camera_path: NodePath

@onready var rig: Node3D = $Rig
@onready var sword: Node3D = $Sword
@onready var shield: Node3D = $Shield
@onready var sword_hitbox: Area3D = $Sword/SwordHitbox
@onready var spin_hitbox: Area3D = $SpinHitbox

var state: RefCounted
var anim: RefCounted
var camera: Node = null
var bones: Dictionary = {}

# Cached references for the trail FX so we don't traverse the scene
# tree every frame.
var _blade_node: MeshInstance3D = null
var _trail_cooldown: float = 0.0
const TRAIL_INTERVAL: float = 0.025

# Sound dispatch state — tracks transitions in the action machine and
# the swing index so combo continuations also fire a swing whoosh.
var _prev_action: int = -1
var _prev_swing_idx: int = -1
var _charge_ready_played: bool = false

# Only one boomerang can be in flight at a time. Track via tree_exited
# so the flag clears when the projectile despawns.
var _boomerang_in_flight: bool = false

# Hookshot has a small post-fire cooldown so the player can't carpet-
# bomb the chain. Counts down in _physics_process.
var _hookshot_cooldown: float = 0.0
const HOOKSHOT_COOLDOWN: float = 1.0

# A bomb the player picked from a bomb_flower (or any "live" bomb in
# their hand). Mirrors the rock-carry pattern: while carried, we pin
# the bomb above the player and ignore its physics; on item_use we
# launch it with the standard throw arc.
var _carried_bomb: RigidBody3D = null
const BOMB_CARRY_OFFSET: Vector3 = Vector3(0, 1.6, -0.1)
const BOMB_THROW_FWD: float = 6.0
const BOMB_THROW_UP: float = 4.0

# ---- Z-targeting / lock-on -------------------------------------------
#
# Tap `target_lock` (Q or RMB) to grab the nearest in-front-of-camera
# enemy. While locked: movement remaps to strafe-around-target, the
# capsule faces the target each tick, and the camera tracks the
# midpoint. The lock auto-releases when the target dies, despawns, or
# drifts past UNLOCK_RANGE.
const LOCK_ACQUIRE_RANGE: float = 12.0
const UNLOCK_RANGE: float = 15.0
# Dot threshold against camera-forward (XZ) for the front-of-camera
# filter. 0.4 ≈ 66° half-cone — wide enough to grab a flanking enemy
# you're already looking toward, narrow enough that an off-screen one
# behind you doesn't get picked.
const LOCK_FRONT_DOT: float = 0.4
# Acquisition score weights: small dist from screen center wins, but
# tie-breaks by world distance so two enemies overlapping the reticle
# are disambiguated by who's closer. Lower is better.
const LOCK_SCORE_SCREEN_W: float = 1.0
const LOCK_SCORE_WORLD_W: float = 0.3
var _lock_target: Node3D = null
var _locked: bool = false

# ---- First-person aim (OoT bow/slingshot) -----------------------------
#
# When the active B-item is the bow or slingshot AND the `aim` action is
# held, the camera shifts to first-person and the player's rig is
# hidden so the camera isn't framed by the back of Tux's head. Other
# code (arrow.gd, seed.gd, the HUD crosshair) reads `aim_mode` to know
# whether to use the camera-forward for projectile direction or to
# render the crosshair.
#
# The body's own facing yaw is realigned to the camera yaw each tick
# while aiming, so when aim is released and the player throws (or just
# moves), the capsule is already pointing where they were looking. The
# arrow/seed direction itself is taken from the camera 3D forward (with
# pitch), so high targets are reachable without needing the body to
# tilt up.
const AIM_HEAD_OFFSET: Vector3 = Vector3(0, 1.6, 0)
var aim_mode: bool = false


func _ready() -> void:
	add_to_group("player")
	state = TuxState.new()
	anim  = TuxAnim.new()

	# Wire stamina callbacks into the autoload so the state machine can
	# gate roll/spin/sprint without knowing about GameState directly.
	state.get_stamina = func() -> int: return GameState.stamina
	state.spend_stamina = func(amount: int) -> void: GameState.spend_stamina(amount)

	bones = {
		"pelvis": rig.get_node("pelvis"),
		"torso":  rig.get_node("pelvis/torso"),
		"head":   rig.get_node("pelvis/torso/head"),
		"arm_l":  rig.get_node("pelvis/torso/arm_l"),
		"arm_r":  rig.get_node("pelvis/torso/arm_r"),
		"leg_l":  rig.get_node("pelvis/leg_l"),
		"leg_r":  rig.get_node("pelvis/leg_r"),
	}
	anim.setup(bones)

	# Reparent sword + shield so they track the wing animations. The
	# local transforms below pin each prop to its wing tip; tweak the
	# offsets if anything clips or floats during tuning.
	var arm_r: Node3D = bones["arm_r"]
	var arm_l: Node3D = bones["arm_l"]
	var SWORD_LOCAL := Transform3D(Basis.IDENTITY, Vector3(-0.07, -0.32, 0))
	# Shield rotated +90° around X. With arm_l lifted forward (Rx ≈ -π/2)
	# in the block pose, this makes the boss-decorated FRONT of the
	# shield point at the enemy (body -Z) and the 0.50m dimension stand
	# vertical. Earlier the rotation sign was flipped, which had the
	# back of the shield facing the enemy.
	var SHIELD_LOCAL := Transform3D(Basis(Vector3(1, 0, 0), PI / 2), Vector3(0.07, -0.30, 0))
	remove_child(sword)
	arm_r.add_child(sword)
	sword.transform = SWORD_LOCAL
	remove_child(shield)
	arm_l.add_child(shield)
	shield.transform = SHIELD_LOCAL

	_blade_node = sword.get_node_or_null("Blade") as MeshInstance3D

	if camera_path:
		camera = get_node_or_null(camera_path)
		if camera and camera.has_method("set"):
			camera.target_node = self

	sword_hitbox.target_hit.connect(_on_sword_hit)
	spin_hitbox.target_hit.connect(_on_sword_hit)
	sword_hitbox.disarm()
	spin_hitbox.disarm()

	GameState.player_died.connect(_on_player_died)
	GameState.item_acquired.connect(_on_item_acquired)
	GameState.reset()
	# Apply the mirror skin if a save reload landed us with glim_mirror
	# already owned (the connect-then-reset above wipes inventory; in
	# practice load_game runs after _ready completes, so this catches a
	# fresh-game-with-cheat-inventory path more than anything).
	_refresh_shield_skin()


func _physics_process(delta: float) -> void:
	# Lock maintenance runs BEFORE input read so the strafe-remap and
	# face-yaw override see this tick's lock state. Drops the lock if
	# the target died/despawned/wandered out of range.
	_update_lock_target()
	_read_inputs()

	state.is_on_floor = is_on_floor()
	state.pos = global_position
	state.step(delta)

	# While locked, override face_yaw to point at the target so the
	# capsule (and the sword + shield rigged to it) tracks the enemy
	# regardless of stick direction. The state machine still owns yaw
	# during attacks/jabs (it snaps face_yaw on action start), so this
	# only takes effect for free movement / blocking.
	if _locked and _lock_target and is_instance_valid(_lock_target):
		var to_t: Vector3 = _lock_target.global_position - global_position
		to_t.y = 0.0
		if to_t.length() > 0.001:
			state.face_yaw = atan2(-to_t.x, -to_t.z)

	# While aiming (FP), the body faces wherever the camera is looking.
	# Even though the rig is hidden, the capsule's facing matters for
	# the carry slot (held bomb above the head) and so the player is
	# left pointed in the right spot when aim releases.
	if aim_mode and camera and camera.has_method("get_yaw"):
		state.face_yaw = camera.get_yaw()

	# Stamina regen — paused while blocking so big blocks read as a
	# serious cost.
	var is_blocking: bool = state.action == TuxState.ACT_BLOCK and state.action_time >= TuxState.BLOCK_RAISE_DURATION
	if not is_blocking:
		GameState.regen_stamina(30.0, delta)

	_apply_passive_movement_mods(delta)
	velocity = state.vel
	move_and_slide()
	rotation.y = state.face_yaw

	anim.play(state.requested_anim, state.requested_anim_speed, state.requested_anim_reset)
	anim.tick(delta)

	# Hitbox gating.
	if state.spin_hit_active:
		spin_hitbox.arm()
	else:
		spin_hitbox.disarm()
	if state.hit_window_active:
		sword_hitbox.arm()
	else:
		sword_hitbox.disarm()

	_emit_trail_if_active(delta)
	_dispatch_action_sounds()

	if _hookshot_cooldown > 0.0:
		_hookshot_cooldown -= delta
	_update_carried_bomb()


func _read_inputs() -> void:
	# Camera yaw still tracked (so the camera continues to follow even
	# mid-dialog), but everything else zeros out while a textbox is up.
	var cam_yaw: float = camera.get_yaw() if camera and camera.has_method("get_yaw") else 0.0
	if Dialog.is_active():
		state.input_stick = Vector2.ZERO
		state.input_attack_pressed = false
		state.input_attack_held    = false
		state.input_shield_held    = false
		state.input_jump_pressed   = false
		state.input_roll_pressed   = false
		state.input_sprint_held    = false
		state.input_camera_yaw     = cam_yaw
		return

	# Aim handling — bow/slingshot only. While aim is held the camera
	# pops into first-person (handled by free_orbit_camera) and the rig
	# is hidden so the camera isn't looking at the back of Tux's head.
	# Any active lock is dropped on aim entry so the FP framing isn't
	# fighting the lock framing. Releasing aim restores the rig and
	# pulls the camera back to third-person.
	_update_aim_mode()

	# Lock toggle. Press = acquire if free, release if locked. Suppressed
	# during dialog (handled above) so a textbox press doesn't grab. Also
	# suppressed while aiming — the AIM action and target_lock could share
	# a binding (RMB) historically; aim wins when bow/slingshot is up.
	if not aim_mode and Input.is_action_just_pressed("target_lock"):
		if _locked:
			_unlock()
		else:
			_try_acquire_lock()

	var stick := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward")
	)
	if stick.length() > 1.0:
		stick = stick.normalized()

	# Strafe remap. While locked, the world-direction the stick produces
	# is built from the player→target axis instead of camera-forward,
	# so "forward" closes distance and "right" orbits clockwise around
	# the target. We achieve this by feeding state.input_camera_yaw the
	# yaw OF THAT AXIS — _stick_to_world_dir() then builds the same
	# vector it always builds, just rotated to lock-relative.
	var lock_yaw: float = cam_yaw
	if _locked and _lock_target and is_instance_valid(_lock_target):
		var to_t: Vector3 = _lock_target.global_position - global_position
		to_t.y = 0.0
		if to_t.length() > 0.001:
			# Same convention as face_yaw: atan2(-x, -z) so forward = -Z.
			lock_yaw = atan2(-to_t.x, -to_t.z)

	state.input_stick = stick
	state.input_attack_pressed = Input.is_action_just_pressed("attack")
	state.input_attack_held    = Input.is_action_pressed("attack")
	state.input_shield_held    = Input.is_action_pressed("shield")
	state.input_jump_pressed   = Input.is_action_just_pressed("jump")
	state.input_roll_pressed   = Input.is_action_just_pressed("roll")
	state.input_sprint_held    = Input.is_action_pressed("sprint")
	state.input_camera_yaw     = lock_yaw

	if Input.is_action_just_pressed("item_use"):
		_try_use_active_item()
	# Glim Sight is the one held-item — it stays open while B is held
	# and dismisses the moment the button is released. The static helper
	# tracks its own state, so a no-op release (sight wasn't open) is
	# fine to call every release.
	if Input.is_action_just_released("item_use"):
		if GameState.active_b_item == "glim_sight":
			ItemGlimSight.close(self)


func _update_aim_mode() -> void:
	# AIM is held + bow/slingshot equipped → first-person.
	# Released or item swapped → third-person. Suppressed during dialog
	# (the early-return in _read_inputs catches that path).
	var item: String = GameState.active_b_item
	var weapon_ok: bool = (item == "bow" or item == "slingshot")
	# Don't allow entering aim mid-attack/charge/spin/roll/flip — those
	# are committed actions; let them finish first. Same suppress list
	# as item-use to keep behaviour consistent.
	var act: int = state.action
	var act_blocks_aim: bool = act in [TuxState.ACT_ATTACK, TuxState.ACT_JAB,
			TuxState.ACT_JUMP_ATTACK, TuxState.ACT_SPIN, TuxState.ACT_CHARGING,
			TuxState.ACT_ROLL, TuxState.ACT_FLIP, TuxState.ACT_HURT,
			TuxState.ACT_DEAD]
	var want_aim: bool = weapon_ok and not act_blocks_aim \
			and Input.is_action_pressed("aim")
	if want_aim and not aim_mode:
		_enter_aim_mode()
	elif not want_aim and aim_mode:
		_exit_aim_mode()
	# While aiming, keep refreshing the head position so a moving /
	# jumping player's camera tracks the body.
	if aim_mode and camera and camera.has_method("enter_first_person"):
		camera.enter_first_person(global_position + AIM_HEAD_OFFSET)


func _enter_aim_mode() -> void:
	aim_mode = true
	# Drop any active lock — FP framing wins.
	if _locked:
		_unlock()
	if camera and camera.has_method("enter_first_person"):
		camera.enter_first_person(global_position + AIM_HEAD_OFFSET)
	# Hide the rig so the camera isn't framed by the back of Tux's
	# head. Sword + shield are reparented under the rig's wing nodes
	# (see _ready), so hiding the rig hides them too — which is what
	# we want; the bow/slingshot is what's "active".
	if rig and is_instance_valid(rig):
		rig.visible = false


func _exit_aim_mode() -> void:
	aim_mode = false
	if camera and camera.has_method("exit_first_person"):
		camera.exit_first_person()
	if rig and is_instance_valid(rig):
		rig.visible = true


func _try_use_active_item() -> void:
	# Don't fire mid-attack/charge/spin/roll/flip — those need to finish.
	var act: int = state.action
	if act in [TuxState.ACT_ATTACK, TuxState.ACT_JAB, TuxState.ACT_JUMP_ATTACK,
			   TuxState.ACT_SPIN, TuxState.ACT_CHARGING, TuxState.ACT_ROLL,
			   TuxState.ACT_FLIP, TuxState.ACT_HURT, TuxState.ACT_DEAD]:
		return
	var fwd: Vector3 = Vector3(-sin(state.face_yaw), 0, -cos(state.face_yaw))
	# A live carried bomb (from a bomb_flower) consumes the use input —
	# checked BEFORE the active-item dispatch so the player can still
	# throw a flower-bomb even with no inventory item equipped.
	if _carried_bomb and is_instance_valid(_carried_bomb):
		_throw_carried_bomb(fwd)
		return
	var item: String = GameState.active_b_item
	if item == "":
		return
	# In aim mode, the bow/slingshot fire along the camera 3D forward
	# (which includes pitch) rather than the player's flat facing. This
	# is the whole reason FP aim exists — angled shots at high archery
	# targets, plinking at fliers, etc. The camera-forward already
	# matches what the player sees through the crosshair.
	var aim_dir: Vector3 = fwd
	if aim_mode and camera and camera.has_method("get_aim_forward"):
		aim_dir = camera.get_aim_forward()
	match item:
		"boomerang":
			_throw_boomerang()
		"bow":
			Bow.try_fire(self, aim_dir)
		"slingshot":
			Slingshot.try_fire(self, aim_dir)
		"bomb":
			_throw_bomb_from_inventory(fwd)
		"hookshot":
			_fire_hookshot(fwd)
		"hammer":
			ItemHammer.try_swing(self, fwd)
		"glim_sight":
			# Held-item: opening on press, _read_inputs handles release.
			ItemGlimSight.open(self)


func _throw_boomerang() -> void:
	if _boomerang_in_flight:
		return
	var b: Area3D = BoomerangScene.instantiate()
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return
	scene_root.add_child(b)
	b.global_position = global_position + Vector3(0, 0.8, 0)
	var fwd: Vector3 = Vector3(-sin(state.face_yaw), 0, -cos(state.face_yaw))
	b.set_direction(fwd)
	b.set_owner_player(self)
	_boomerang_in_flight = true
	b.tree_exited.connect(func() -> void: _boomerang_in_flight = false)


# ---- Bomb / hookshot ---------------------------------------------------

# Spawn a fresh bomb in front of the player and launch it with the
# standard throw arc. Decrements GameState.bombs; no-op if empty.
func _throw_bomb_from_inventory(fwd: Vector3) -> void:
	if GameState.bombs <= 0:
		return
	if not GameState.use_bomb():
		return
	var bomb: RigidBody3D = BombScene.instantiate()
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return
	scene_root.add_child(bomb)
	bomb.global_position = global_position + Vector3(0, 1.0, 0) + fwd * 0.5
	bomb.linear_velocity = fwd * BOMB_THROW_FWD + Vector3(0, BOMB_THROW_UP, 0)


# Bomb-flower → player handoff. Pins the bomb to the carry slot and
# blocks the body's collisions so it doesn't shove the player around.
# Tux can throw it via item_use; if he hangs onto it past the fuse it
# detonates in place (bomb.gd handles its own fuse).
func attach_carried_bomb(bomb: RigidBody3D) -> void:
	if not bomb or not is_instance_valid(bomb):
		return
	# Drop any prior carry; prefer the new one.
	if _carried_bomb and is_instance_valid(_carried_bomb):
		_carried_bomb.linear_velocity = Vector3.ZERO
	_carried_bomb = bomb
	bomb.freeze = true
	bomb.collision_layer = 0
	bomb.collision_mask = 0
	bomb.tree_exited.connect(func() -> void:
		if _carried_bomb == bomb:
			_carried_bomb = null)


func _update_carried_bomb() -> void:
	if not _carried_bomb or not is_instance_valid(_carried_bomb):
		return
	var t: Transform3D = global_transform
	_carried_bomb.global_position = t.origin + t.basis * BOMB_CARRY_OFFSET
	_carried_bomb.linear_velocity = Vector3.ZERO
	_carried_bomb.angular_velocity = Vector3.ZERO


func _throw_carried_bomb(fwd: Vector3) -> void:
	var bomb: RigidBody3D = _carried_bomb
	if not bomb or not is_instance_valid(bomb):
		_carried_bomb = null
		return
	_carried_bomb = null
	bomb.freeze = false
	bomb.collision_layer = 1
	bomb.collision_mask = 1
	bomb.linear_velocity = fwd * BOMB_THROW_FWD + Vector3(0, BOMB_THROW_UP, 0)


func _fire_hookshot(fwd: Vector3) -> void:
	if _hookshot_cooldown > 0.0:
		return
	_hookshot_cooldown = HOOKSHOT_COOLDOWN
	Hookshot.try_fire(self, fwd)


# ---- Passive movement modifiers ---------------------------------------
#
# Anchor Boots (passive toggle, GameState.anchor_boots_active): scale
# horizontal velocity to 60% and add an extra +GRAVITY to vel.y this
# frame so the effective gravity is ~2x. Lets Tux sink in water and
# walk along the under-water floor.
#
# Glim Sight (held-item active): scale horizontal velocity to 30%.
# We multiply state.vel directly because state.step() already wrote it
# this tick — modifying state.vel here is read by `velocity = state.vel`
# on the very next line of _physics_process.
const ANCHOR_BOOTS_SPEED_MULT: float = 0.60
const ANCHOR_BOOTS_GRAVITY_BONUS: float = 28.0    # = TuxState.GRAVITY (2x total)
const GLIM_SIGHT_SPEED_MULT: float = 0.30

func _apply_passive_movement_mods(delta: float) -> void:
	var hmult: float = 1.0
	if GameState.anchor_boots_active:
		hmult *= ANCHOR_BOOTS_SPEED_MULT
		# Add a flat extra gravity tick so the effective fall rate is
		# ~2x and Tux sinks in water (or off ledges) noticeably faster.
		# Skip if the state is doing a deliberate vertical impulse
		# (jump/flip) — those should still feel like jumps, just heavier.
		state.vel.y -= ANCHOR_BOOTS_GRAVITY_BONUS * delta
	if ItemGlimSight.is_open_on(self):
		hmult *= GLIM_SIGHT_SPEED_MULT
	if hmult < 1.0:
		state.vel.x *= hmult
		state.vel.z *= hmult


func get_face_yaw() -> float:
	return state.face_yaw if state else rotation.y


# ---- Lock-on (Z-targeting) --------------------------------------------
#
# Acquisition rules:
#   * candidate must be in the "enemy" group
#   * within LOCK_ACQUIRE_RANGE on the XZ plane
#   * in front of the camera (dot(camera_fwd, to_enemy) > LOCK_FRONT_DOT)
#   * minimises (screen_dist_from_center * 1.0 + world_dist * 0.3) so the
#     enemy nearest the reticle wins, with world distance as tie-break
#
# Maintenance (each tick): drop the lock if the target was freed, fell
# out of the tree, drifted past UNLOCK_RANGE, or entered a `dead`/`DEAD`
# state. Enemies don't share a base class, so we duck-type — first try
# `state` against the enemy's `State.DEAD` enum (most enemies use this
# pattern), then fall back to checking `hp <= 0` if `state` isn't set.

func _try_acquire_lock() -> void:
	if camera == null:
		return
	var cam_node: Camera3D = _get_camera3d()
	if cam_node == null:
		return
	var cam_fwd: Vector3 = -cam_node.global_transform.basis.z
	cam_fwd.y = 0.0
	if cam_fwd.length() < 0.001:
		return
	cam_fwd = cam_fwd.normalized()

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var screen_center: Vector2 = viewport_size * 0.5

	var best: Node3D = null
	var best_score: float = INF
	for n in get_tree().get_nodes_in_group("enemy"):
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		var enemy: Node3D = n
		# Skip already-dead enemies so a tap doesn't grab a corpse.
		if _is_target_dead(enemy):
			continue
		var to_e: Vector3 = enemy.global_position - global_position
		to_e.y = 0.0
		var dist: float = to_e.length()
		if dist > LOCK_ACQUIRE_RANGE or dist < 0.001:
			continue
		var to_e_dir: Vector3 = to_e.normalized()
		if cam_fwd.dot(to_e_dir) < LOCK_FRONT_DOT:
			continue
		# `unproject_position` returns NaN/garbage when the point is
		# behind the camera; the dot-product gate above already filters
		# those out (enemy is in the front half-plane of camera-yaw).
		var screen_pos: Vector2 = cam_node.unproject_position(enemy.global_position)
		var screen_dist: float = screen_pos.distance_to(screen_center)
		var score: float = screen_dist * LOCK_SCORE_SCREEN_W + dist * LOCK_SCORE_WORLD_W
		if score < best_score:
			best_score = score
			best = enemy

	if best:
		_lock_target = best
		_locked = true
		if camera and camera.has_method("lock_to"):
			camera.lock_to(best)


func _unlock() -> void:
	_locked = false
	_lock_target = null
	if camera and camera.has_method("unlock"):
		camera.unlock()


func _update_lock_target() -> void:
	if not _locked:
		return
	if _lock_target == null or not is_instance_valid(_lock_target) \
			or not _lock_target.is_inside_tree():
		_unlock()
		return
	if _is_target_dead(_lock_target):
		_unlock()
		return
	var to_t: Vector3 = _lock_target.global_position - global_position
	to_t.y = 0.0
	if to_t.length() > UNLOCK_RANGE:
		_unlock()
		return
	# Keep the camera fed every frame in case its lerp target needs to
	# track a moving enemy (also lets a fresh free_orbit_camera pick up
	# the lock if it was reloaded mid-scene).
	if camera and camera.has_method("lock_to"):
		camera.lock_to(_lock_target)


# Duck-typed death check: many enemies expose a `state` int compared
# against an enum-style DEAD value. We can't import every enemy's enum,
# so check the integer state against the value Enemy.State.DEAD would
# resolve to via `get(...)`. Falls back to `hp <= 0` for enemies that
# don't expose `state`.
func _is_target_dead(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return true
	# Try `state` first — most enemies expose an int state with an enum
	# whose DEAD entry is the LAST member. Comparing against the literal
	# integer would couple us to enum order, so we read the script's
	# constant_map for "DEAD" via duck-typing.
	if "state" in target:
		var st = target.get("state")
		# Most enemy scripts have an enum exposed as a const dict via
		# their script constants. Try to find a "DEAD" value to compare.
		var dead_val = _enum_dead_value(target)
		if dead_val != null and st == dead_val:
			return true
	if "hp" in target:
		var hp = target.get("hp")
		if hp != null and hp <= 0:
			return true
	return false


func _enum_dead_value(target: Node) -> Variant:
	# Walk script constants for an enum-style dictionary containing a
	# "DEAD" key (e.g. State, AIState). Returns the int or null if none.
	var scr: Script = target.get_script() as Script
	if scr == null:
		return null
	var consts: Dictionary = scr.get_script_constant_map()
	for key in consts.keys():
		var val = consts[key]
		if typeof(val) == TYPE_DICTIONARY and val.has("DEAD"):
			return val["DEAD"]
	return null


func _get_camera3d() -> Camera3D:
	if camera == null:
		return null
	# free_orbit_camera scene shape: Camera (Node3D) → SpringArm → Camera (Camera3D).
	var cam3d: Node = camera.get_node_or_null("SpringArm/Camera")
	if cam3d is Camera3D:
		return cam3d
	# Fallback: pick the active viewport camera.
	var vp := get_viewport()
	if vp:
		return vp.get_camera_3d()
	return null


func get_lock_target() -> Node3D:
	if _locked and _lock_target and is_instance_valid(_lock_target):
		return _lock_target
	return null


func is_locked() -> bool:
	return _locked and _lock_target != null and is_instance_valid(_lock_target)


# ---- Damage in / out --------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
	# Glim Mirror reflect: passive shield upgrade. If the incoming hit
	# is from anything in the `final_laser` group AND Tux carries the
	# Mirror, the laser is fully blocked and 25 damage is reflected to
	# the source. The shield doesn't have to be raised — the Mirror is
	# always-on by design (DESIGN.md §3 boss-8 hook).
	if attacker and attacker.is_in_group("final_laser") \
			and GameState.has_glim_mirror():
		SoundBank.play_3d("mirror_reflect", global_position)
		if attacker.has_method("take_damage"):
			attacker.take_damage(25, global_position, self)
		if camera and camera.has_method("shake"):
			camera.shake(0.10, 0.18)
		return
	var was_blocking: bool = state.action == TuxState.ACT_BLOCK
	var was_parry: bool = state.parry_active
	if state.take_hit(source_pos, amount):
		GameState.damage(amount)
		if camera and camera.has_method("shake"):
			camera.shake(0.18, 0.22)
		# ACT_HURT will fire its sound via _dispatch_action_sounds.
	else:
		if was_parry:
			SoundBank.play_3d("parry", global_position)
			_shove_attacker(attacker, TuxState.PARRY_PUSH_FORCE)
			if camera and camera.has_method("shake"):
				camera.shake(0.08, 0.14)
		elif was_blocking:
			SoundBank.play_3d("shield_block", global_position)
			_shove_attacker(attacker, TuxState.BLOCK_PUSH_FORCE)
			if camera and camera.has_method("shake"):
				camera.shake(0.06, 0.12)
		# i-frames during a roll/flip are intentionally silent.


# Knock the attacker backward when their hit lands on a raised shield.
# `attacker` is whichever node passed itself as the source — usually
# the enemy CharacterBody3D. Falls back silently if the attacker can't
# accept knockback.
func _shove_attacker(attacker: Node, force: float) -> void:
	if not attacker or not is_instance_valid(attacker):
		return
	if not attacker.has_method("get_knockback"):
		return
	var dir: Vector3 = attacker.global_position - global_position
	dir.y = 0.0
	if dir.length() < 0.001:
		return
	attacker.get_knockback(dir.normalized(), force)


func _on_sword_hit(_target: Node) -> void:
	SoundBank.play_3d("sword_hit", global_position)
	if camera and camera.has_method("shake"):
		camera.shake(0.05, 0.10)


func _on_player_died() -> void:
	state.kill()


# ---- Shield skin (Wood / Iron / Glim Mirror) --------------------------
#
# The shield mesh is authored as the wood-and-boss starter shield. When
# Tux acquires the Glim Mirror we retint the board and boss to mirror-
# silver / mirror-blue; this is the only visual cue today (no separate
# shield meshes). Called from _ready and on every item_acquired so
# late-loads pick up the skin.

func _on_item_acquired(item_name: String) -> void:
	if item_name == "glim_mirror":
		_refresh_shield_skin()


func _refresh_shield_skin() -> void:
	if shield == null or not is_instance_valid(shield):
		return
	if not GameState.has_glim_mirror():
		return
	var board: MeshInstance3D = shield.get_node_or_null("Board") as MeshInstance3D
	var boss:  MeshInstance3D = shield.get_node_or_null("Boss")  as MeshInstance3D
	if board:
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(0.85, 0.92, 0.98, 1.0)
		bm.metallic = 1.0
		bm.roughness = 0.05
		bm.emission_enabled = true
		bm.emission = Color(0.85, 0.95, 1.0)
		bm.emission_energy_multiplier = 0.45
		board.material_override = bm
	if boss:
		var bsm := StandardMaterial3D.new()
		bsm.albedo_color = Color(0.92, 0.95, 1.0, 1.0)
		bsm.metallic = 1.0
		bsm.roughness = 0.05
		boss.material_override = bsm


# ---- Sound dispatch ----------------------------------------------------

# Translates state-machine events into one-shot SFX. Watches both the
# action enum and the swing_index so combo continuations (which stay
# in ACT_ATTACK but bump swing_index) get their own whoosh.
func _dispatch_action_sounds() -> void:
	var TS := TuxState
	var act: int = state.action
	var swing_idx: int = state.swing_index
	var changed: bool = act != _prev_action

	# Combo step inside ACT_ATTACK — same action, new swing index.
	if act == TS.ACT_ATTACK and (changed or swing_idx != _prev_swing_idx):
		SoundBank.play_3d("sword_swing", global_position)

	if changed:
		match act:
			TS.ACT_JAB:         SoundBank.play_3d("sword_jab", global_position)
			TS.ACT_JUMP_ATTACK: SoundBank.play_3d("jump_strike", global_position)
			TS.ACT_SPIN:        SoundBank.play_3d("spin_attack", global_position)
			TS.ACT_BLOCK:       SoundBank.play_3d("shield_raise", global_position)
			TS.ACT_ROLL:        SoundBank.play_3d("roll", global_position)
			TS.ACT_FLIP:        SoundBank.play_3d("jump", global_position)
			TS.ACT_JUMP:        SoundBank.play_3d("jump", global_position)
			TS.ACT_LAND:        SoundBank.play_3d("land", global_position)
			TS.ACT_HURT:        SoundBank.play_3d("hurt", global_position)
			TS.ACT_DEAD:        SoundBank.play_3d("death", global_position)
			TS.ACT_CHARGING:    SoundBank.play_3d("sword_charge", global_position)
		if act == TS.ACT_CHARGING:
			_charge_ready_played = false

	# Charge crosses the spin threshold — play the "fully charged" cue
	# exactly once per charge.
	if act == TS.ACT_CHARGING and not _charge_ready_played \
			and state.charge_time >= TS.CHARGE_TIME_FOR_SPIN:
		SoundBank.play_3d("sword_charge_ready", global_position)
		_charge_ready_played = true

	_prev_action = act
	_prev_swing_idx = swing_idx


# ---- Sword trail FX ---------------------------------------------------

# Spawns fading ghost copies of the blade during JUMP_ATTACK and SPIN.
# Each ghost is parented under the player but flagged top_level so its
# world transform is captured at spawn and stays fixed — it doesn't
# follow Tux as he moves through the trail.
func _emit_trail_if_active(delta: float) -> void:
	var emitting: bool = state.action == TuxState.ACT_JUMP_ATTACK \
					  or state.action == TuxState.ACT_SPIN
	if not emitting:
		_trail_cooldown = 0.0
		return
	_trail_cooldown -= delta
	if _trail_cooldown > 0.0:
		return
	_trail_cooldown = TRAIL_INTERVAL
	_spawn_ghost_blade()


func _spawn_ghost_blade() -> void:
	if not _blade_node or not _blade_node.mesh:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = _blade_node.mesh
	ghost.top_level = true
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.65, 0.85, 1.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.95, 1.2)
	mat.emission_energy_multiplier = 1.6
	ghost.material_override = mat
	add_child(ghost)
	ghost.global_transform = _blade_node.global_transform
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(mat, "albedo_color:a", 0.0, 0.22)
	t.tween_property(ghost, "scale", Vector3(0.45, 0.45, 0.45), 0.22)
	t.chain().tween_callback(ghost.queue_free)
