extends CharacterBody3D

# Player controller: ties together input, the action state machine
# (tux_state.gd), the procedural animator (tux_anim.gd), the rig, the
# sword + shield, and the trail FX. The state machine owns the action
# logic; this script is the integration layer.

const TuxState = preload("res://scripts/tux_state.gd")
const TuxAnim  = preload("res://scripts/tux_anim.gd")
const BoomerangScene = preload("res://scenes/boomerang.tscn")

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
	GameState.reset()


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


func _try_use_active_item() -> void:
	var item: String = GameState.active_b_item
	if item == "":
		return
	# Don't fire mid-attack/charge/spin/roll/flip — those need to finish.
	var act: int = state.action
	if act in [TuxState.ACT_ATTACK, TuxState.ACT_JAB, TuxState.ACT_JUMP_ATTACK,
			   TuxState.ACT_SPIN, TuxState.ACT_CHARGING, TuxState.ACT_ROLL,
			   TuxState.ACT_FLIP, TuxState.ACT_HURT, TuxState.ACT_DEAD]:
		return
	match item:
		"boomerang":
			_throw_boomerang()


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


func get_face_yaw() -> float:
	return state.face_yaw if state else rotation.y


# ---- Damage in / out --------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
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
