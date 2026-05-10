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
	_read_inputs()

	state.is_on_floor = is_on_floor()
	state.pos = global_position
	state.step(delta)

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

	var stick := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward")
	)
	if stick.length() > 1.0:
		stick = stick.normalized()

	state.input_stick = stick
	state.input_attack_pressed = Input.is_action_just_pressed("attack")
	state.input_attack_held    = Input.is_action_pressed("attack")
	state.input_shield_held    = Input.is_action_pressed("shield")
	state.input_jump_pressed   = Input.is_action_just_pressed("jump")
	state.input_roll_pressed   = Input.is_action_just_pressed("roll")
	state.input_sprint_held    = Input.is_action_pressed("sprint")
	state.input_camera_yaw     = cam_yaw

	if Input.is_action_just_pressed("item_use"):
		_try_use_active_item()
	# Glim Sight is the one held-item — it stays open while B is held
	# and dismisses the moment the button is released. The static helper
	# tracks its own state, so a no-op release (sight wasn't open) is
	# fine to call every release.
	if Input.is_action_just_released("item_use"):
		if GameState.active_b_item == "glim_sight":
			ItemGlimSight.close(self)


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
	match item:
		"boomerang":
			_throw_boomerang()
		"bow":
			Bow.try_fire(self, fwd)
		"slingshot":
			Slingshot.try_fire(self, fwd)
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
