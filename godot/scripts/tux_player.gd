extends CharacterBody3D

# Player controller: ties together input, the action state machine
# (tux_state.gd), the procedural animator (tux_anim.gd), the rig, the
# sword + shield, and the trail FX. The state machine owns the action
# logic; this script is the integration layer.

const TuxState = preload("res://scripts/tux_state.gd")
const TuxAnim  = preload("res://scripts/tux_anim.gd")
const WorldGen = preload("res://scripts/world_gen.gd")
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

# Mirror state of GameState.anchor_boots_active so we can fire a
# terminal-corner cmd on the rising/falling edge. The toggle itself
# lives in pause_menu.gd; we observe the value here so the corner
# picks up on/off transitions whether they came from the menu, a
# save load, or any future hotkey.
var _prev_anchor_boots_active: bool = false

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

# Fractional HP / stamina accumulators for the swim systems —
# GameState.damage and spend_stamina take ints, so we accumulate
# fractional drain and dispatch when a whole point is ready. Without
# this the per-frame swim stamina cost (8/sec * 0.0166s = 0.13/tick)
# truncated to int 0 every frame and stamina never moved.
var _swim_drown_remainder: float = 0.0
var _swim_stamina_remainder: float = 0.0
# Post-swim regen lockout. Starts at SWIM_REGEN_LOCKOUT_S whenever
# state.action == ACT_SWIM and ticks down. Stamina regen is suppressed
# while > 0. Stops the cheese where the player jumped out of the water
# for a frame each cycle to harvest a tick of regen mid-air before
# splashing back in.
const SWIM_REGEN_LOCKOUT_S: float = 1.5
var _swim_regen_lockout: float = 0.0


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
	GameState.sword_upgraded.connect(_on_sword_upgraded)
	# NOTE: we used to call GameState.reset() here. That wiped the
	# inventory/resources that the main menu's Load button had JUST
	# loaded (load_game writes state then change_scene_to_file —
	# tux_player._ready runs after the scene swap, AFTER the load). The
	# correct lifecycle: main_menu.gd handles reset on New Game; load
	# fills state on Load Game; this script just consumes whatever is
	# already in GameState. Don't reset here.
	_refresh_shield_skin()
	# Apply the current sword tier — covers the title→load path where
	# load_game emits sword_upgraded before this scene is built. Also
	# (re)applies tier 0 cleanly on reset.
	_apply_sword_tier(GameState.sword_tier)
	# Gate starter equipment on the inventory. Fresh games begin
	# unarmed (fists only); the sword/shield become visible the
	# moment the player crafts sapling_blade / bark_round at a
	# workbench. _on_item_acquired flips them on.
	_apply_equipment_visibility()


func _apply_equipment_visibility() -> void:
	if sword:
		sword.visible = bool(GameState.inventory.get("sapling_blade", false))
	if shield:
		shield.visible = bool(GameState.inventory.get("bark_round", false))
	_refresh_weapon_damage()


# Per-weapon-tier base damage. Best owned weapon wins. Bare fists do 1
# (so the punch is meaningful but slow), Sapling Blade doubles it,
# Stone Axe and Stone Sword triple it. Future metal/glim tiers will
# slot in here. The receiver (tree_prop, animal, bush) reads
# `take_damage(amount, …)` so this scaling propagates everywhere.
const WEAPON_DAMAGE: Dictionary = {
	"sapling_blade": 2,
	"stone_axe":     3,
	"stone_sword":   3,
}

func _refresh_weapon_damage() -> void:
	var dmg: int = 1    # bare fists
	for id in WEAPON_DAMAGE.keys():
		if bool(GameState.inventory.get(String(id), false)):
			dmg = max(dmg, int(WEAPON_DAMAGE[id]))
	if sword_hitbox:
		sword_hitbox.damage = dmg
	if spin_hitbox:
		# Spin keeps the legacy 2× ratio — wider radial, costs stamina,
		# should hit harder than a single swing.
		spin_hitbox.damage = dmg * 2


func _physics_process(delta: float) -> void:
	# Lock maintenance runs BEFORE input read so the strafe-remap and
	# face-yaw override see this tick's lock state. Drops the lock if
	# the target died/despawned/wandered out of range.
	_update_lock_target()
	_read_inputs()

	state.is_on_floor = is_on_floor()
	state.pos = global_position
	# Mirror equipment state into the action machine so it can gate
	# combos/charge/spin (sword) and parry/full-block (shield) at the
	# source of truth — GameState.inventory. Cheap dict lookup, fine to
	# do every tick; no signal-fan-out plumbing required.
	state.armed = bool(GameState.inventory.get("sapling_blade", false))
	state.has_shield = bool(GameState.inventory.get("bark_round", false))
	# Water feedback. Sea level is a single source of truth in WorldGen
	# (anything below 0 is ocean floor); pass it through so ACT_SWIM
	# doesn't have to import the world script. in_water is the trigger
	# for the swim transition; anchor_boots flips buoyancy to sink-mode
	# so the player can walk along the seabed in those boots.
	state.water_level = WorldGen.SEA_LEVEL
	# Hysteresis on the swim gate. ENTER at waist-deep
	# (SWIM_ENTER_DEPTH); EXIT only once the feet have actually crested
	# the surface by SWIM_EXIT_DEPTH (a small negative number — the
	# threshold sits ABOVE the water line so swim ends promptly when
	# climbing out). Otherwise the swim animation persists for a beat
	# after stepping onto the beach.
	var depth: float = WorldGen.SEA_LEVEL - global_position.y
	if state.action == TuxState.ACT_SWIM:
		state.in_water = depth > TuxState.SWIM_EXIT_DEPTH
	else:
		state.in_water = depth > TuxState.SWIM_ENTER_DEPTH
	state.anchor_boots = GameState.anchor_boots_active

	# Swim stamina drain. The state machine couldn't do this itself
	# because spend_stamina takes int and the per-frame drain is < 1 —
	# we accumulate the fractional cost here and dispatch whole spends.
	# Only counts while the player is actively propelling (input held);
	# floating in place is free.
	if state.action == TuxState.ACT_SWIM and state.input_stick.length() > 0.001 \
			and GameState.stamina > 0:
		_swim_stamina_remainder += TuxState.SWIM_STAMINA_PER_SEC * delta
		var stam_whole: int = int(_swim_stamina_remainder)
		if stam_whole > 0:
			_swim_stamina_remainder -= stam_whole
			GameState.spend_stamina(stam_whole)
	else:
		_swim_stamina_remainder = 0.0

	# Tux-can't-swim penalty: once stamina is gone and we're still
	# swimming, the cold ocean starts taking life. ~1 hp/sec — fast
	# enough to feel real but slow enough that a determined player can
	# still scramble to shore. Each HP tick fires the "hurt" SFX so the
	# player gets audio feedback that they're actively losing health.
	if state.action == TuxState.ACT_SWIM and GameState.stamina <= 0:
		_swim_drown_remainder += TuxState.SWIM_HP_DRAIN_PER_SEC * delta
		var whole: int = int(_swim_drown_remainder)
		if whole > 0:
			_swim_drown_remainder -= whole
			GameState.damage(whole)
			SoundBank.play_3d("hurt", global_position)
			# Brief camera shake — same intensity as a regular hit so
			# the player's eye snaps to the HP bar.
			if camera and camera.has_method("shake"):
				camera.shake(0.10, 0.18)
	else:
		_swim_drown_remainder = 0.0
	# Wetness pops to 1.0 the moment Tux is submerged. PlayerStatus
	# normally chases rain/snow at WET_RISE_RATE, but a literal dunk
	# should be instantaneous so the wet pill flips on right away.
	if state.in_water and PlayerStatus:
		PlayerStatus.wetness = 1.0
	state.step(delta)
	# Hide sword/shield while swimming (hands free for treading water).
	# Suspends the inventory-driven visibility for the duration of the
	# swim; _apply_equipment_visibility() restores it on the next item
	# event, and the state-driven check below re-evaluates each tick.
	_apply_swim_equipment_hide()
	# Underwater HUD tint — overlay alpha tracks state.in_water so the
	# scrim fades on the moment Tux submerges and clears the moment he
	# climbs out. Cheap, no asset, uses the HUD's existing CanvasLayer.
	_apply_underwater_tint(state.in_water)

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

	# Stamina regen — paused while blocking, while actually swimming, and
	# during a short post-swim lockout. The lockout closes the cheese
	# where pressing jump from the water briefly puts Tux above the
	# surface (out of ACT_SWIM) — without it that 0.1s of "not swim"
	# would harvest a tick of regen each cycle.
	var is_blocking: bool = state.action == TuxState.ACT_BLOCK and state.action_time >= TuxState.BLOCK_RAISE_DURATION
	var is_swimming: bool = state.action == TuxState.ACT_SWIM
	if is_swimming:
		_swim_regen_lockout = SWIM_REGEN_LOCKOUT_S
	elif _swim_regen_lockout > 0.0:
		_swim_regen_lockout = max(_swim_regen_lockout - delta, 0.0)
	if not is_blocking and not is_swimming and _swim_regen_lockout <= 0.0:
		# Cold halves stamina regen (PlayerStatus reads weather + time
		# of day; 1.0 when comfy, 0.5 when chilled). BuffManager
		# stacks food buffs on top — satiated bumps regen 1.5x.
		var regen_mul: float = PlayerStatus.stamina_regen_multiplier() if PlayerStatus else 1.0
		if BuffManager:
			regen_mul *= BuffManager.stamina_regen_multiplier()
		GameState.regen_stamina(30.0 * regen_mul, delta)

	_apply_passive_movement_mods(delta)
	# Cold + wet trim horizontal movement (Y preserved so gravity/jump
	# aren't muted). PlayerStatus.speed_multiplier() returns 1.0 when
	# unaffected. BuffManager stacks food buffs — Energized (raspberry)
	# bumps to 1.2x.
	var move_mul: float = PlayerStatus.speed_multiplier() if PlayerStatus else 1.0
	if BuffManager:
		move_mul *= BuffManager.speed_multiplier()
	velocity = Vector3(state.vel.x * move_mul, state.vel.y, state.vel.z * move_mul)
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
	_observe_anchor_boots_toggle()


func _read_inputs() -> void:
	# Multiplayer puppets have no input authority — their pose is
	# overwritten by net_player_sync each tick, so reading the local
	# keyboard would just fight the sync. Zero everything and bail.
	if not is_multiplayer_authority():
		state.input_stick = Vector2.ZERO
		state.input_attack_pressed = false
		state.input_attack_held    = false
		state.input_shield_held    = false
		state.input_jump_pressed   = false
		state.input_roll_pressed   = false
		state.input_sprint_held    = false
		state.input_camera_yaw     = 0.0
		return
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

	# BuildMode hijacks attack/shield while running — its _process polls
	# the same actions itself for place/cancel. Feeding the presses into
	# the action state machine would also trigger a sword swing or shield
	# raise, which we don't want during placement. Zero them out for the
	# state machine but let the rest (movement, jump, sprint, camera yaw)
	# stay live so the player can still walk the ghost around.
	var bm_node: Node = get_node_or_null("/root/BuildMode")
	var bm_active: bool = false
	if bm_node != null and "active" in bm_node:
		bm_active = bool(bm_node.get("active"))

	state.input_stick = stick
	state.input_attack_pressed = false if bm_active else Input.is_action_just_pressed("attack")
	state.input_attack_held    = false if bm_active else Input.is_action_pressed("attack")
	state.input_shield_held    = false if bm_active else Input.is_action_pressed("shield")
	state.input_jump_pressed   = Input.is_action_just_pressed("jump")
	state.input_roll_pressed   = Input.is_action_just_pressed("roll")
	state.input_sprint_held    = Input.is_action_pressed("sprint")
	state.input_camera_yaw     = lock_yaw

	if Input.is_action_just_pressed("item_use"):
		# F toggles BuildMode while it's active; otherwise route through
		# the normal dispatch (which itself ENTERS BuildMode for the
		# hammer — see _try_use_active_item's "hammer" branch).
		if bm_active and bm_node != null and bm_node.has_method("toggle"):
			bm_node.call("toggle", self)
		else:
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
			# The Builder's Hammer is the build-mode toggle, not a melee
			# weapon — ItemHammer.try_swing stays in the tree for the
			# eventual "wreck a placed piece" tool but the F-press path
			# now drops Tux straight into placement mode.
			var bm: Node = get_node_or_null("/root/BuildMode")
			if bm != null and bm.has_method("toggle"):
				bm.call("toggle", self)
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
		# Terminal-corner narration. Lore-canon command for a Mirror
		# Shield reflect: open every bit and tee the result back to
		# the source. Fires per-reflect (each laser hit is its own
		# event), matching the SFX cadence above.
		_push_terminal_cmd("chmod 777 . | tee")
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
	# Re-evaluate sword/shield visibility AND per-weapon hitbox damage
	# on every inventory acquisition. Cheap dict lookups — fine to run
	# on any pickup, and keeps stone_sword / future metal tiers in sync
	# without per-weapon match arms.
	_apply_equipment_visibility()


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


# ---- Sword tier (visual + damage) -------------------------------------
#
# Three tiers — Twigblade (brown handle, base damage), Brightsteel
# (silver handle, 2x damage), Glimblade (gold handle, glowing edge,
# 3x damage). Damage is multiplied on the SwordHitbox + SpinHitbox
# `damage` exports each time the tier changes; that way the per-swing
# code in sword_hitbox.gd (which reads `damage` at hit time) doesn't
# need to know about tiers.

const SWORD_TIER_DAMAGE_MULT: Array[int] = [1, 2, 3]

# Per-tier visual lookups. Blade colour leans cool→warm with the gold
# tier picking up a little emission so it reads as "magical" against
# a darker dungeon backdrop. Handle colour matches the tier's identity
# (brown twig, silver steel, gold glim).
const SWORD_BLADE_TINTS: Array[Color] = [
	Color(0.78, 0.82, 0.88, 1.0),    # tier 0 — base steel-ish
	Color(0.88, 0.92, 0.97, 1.0),    # tier 1 — bright steel
	Color(1.00, 0.92, 0.55, 1.0),    # tier 2 — glim gold
]
const SWORD_HANDLE_TINTS: Array[Color] = [
	Color(0.55, 0.32, 0.12, 1.0),    # tier 0 — brown twig
	Color(0.62, 0.66, 0.72, 1.0),    # tier 1 — silver-grey
	Color(0.85, 0.68, 0.20, 1.0),    # tier 2 — gold
]
# Per-tier base damage. Authored in tux.tscn the SwordHitbox starts at
# damage = 1 and SpinHitbox at damage = 2. We re-derive the live damage
# from these baselines * the multiplier, so the spin-attack stays at
# its 2x ratio after upgrades.
const SWORD_BASE_DAMAGE: int = 1
const SPIN_BASE_DAMAGE: int = 2


func _on_sword_upgraded(tier: int) -> void:
	_apply_sword_tier(tier)
	# Audible cue on actual upgrades. Using "pebble_get" as a stand-in
	# pickup chime — there's no dedicated upgrade jingle yet and SoundBank
	# silent-fallbacks if the name is missing.
	if tier > 0:
		SoundBank.play_2d("pebble_get")


func _apply_sword_tier(tier: int) -> void:
	var t: int = clamp(tier, 0, SWORD_TIER_DAMAGE_MULT.size() - 1)
	var mult: int = SWORD_TIER_DAMAGE_MULT[t]
	if sword_hitbox:
		sword_hitbox.damage = SWORD_BASE_DAMAGE * mult
	if spin_hitbox:
		spin_hitbox.damage = SPIN_BASE_DAMAGE * mult
	_retint_sword(t)


func _retint_sword(tier: int) -> void:
	if sword == null or not is_instance_valid(sword):
		return
	var t: int = clamp(tier, 0, SWORD_BLADE_TINTS.size() - 1)
	var blade: MeshInstance3D = sword.get_node_or_null("Blade") as MeshInstance3D
	var guard: MeshInstance3D = sword.get_node_or_null("Guard") as MeshInstance3D
	var handle: MeshInstance3D = sword.get_node_or_null("Handle") as MeshInstance3D
	if blade:
		var bm := StandardMaterial3D.new()
		bm.albedo_color = SWORD_BLADE_TINTS[t]
		bm.metallic = 0.7
		bm.roughness = 0.20
		# Glimblade glows along the edge — emission is the cheapest way
		# to fake "edge glow" with a primitive box mesh.
		if t >= 2:
			bm.emission_enabled = true
			bm.emission = Color(1.0, 0.85, 0.45)
			bm.emission_energy_multiplier = 0.8
		blade.material_override = bm
	# Tint the guard + handle together so the silhouette reads as one
	# weapon rather than a tinted blade on a brown stick.
	var hilt_mat := StandardMaterial3D.new()
	hilt_mat.albedo_color = SWORD_HANDLE_TINTS[t]
	hilt_mat.roughness = 0.7 if t == 0 else 0.45
	if t >= 1:
		hilt_mat.metallic = 0.6
	if guard:
		guard.material_override = hilt_mat
	if handle:
		handle.material_override = hilt_mat


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
		# Terminal-corner narration. Same trigger points as the SFX
		# above so the corner only narrates the *initial* transition,
		# not every frame the action is sustained.
		_dispatch_terminal_for_action(act, _prev_action)
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


# ---- Terminal-corner narration ----------------------------------------
#
# Per LORE.md §v2.2–v2.3 the bottom-left HUD terminal narrates Tux's
# actions as live shell commands. The autoload `TerminalLog` is the
# pub/sub buffer; we push from the same trigger points the SFX system
# uses (entry into a new ACT_*) so the corner only narrates the initial
# event, not every frame the action is sustained.
#
# All push helpers are guarded against a missing autoload so headless
# unit-test contexts (no scene tree) don't crash the call.

func _push_terminal_cmd(text: String) -> void:
	var tl: Node = get_node_or_null("/root/TerminalLog")
	if tl:
		tl.cmd(text)


# Translate a state-machine action transition into the matching shell
# command per the LORE table:
#   ACT_SPIN     → kill -9 *      (force-kill across the spin radius)
#   ACT_BLOCK    → chmod 000 .    (self-perms = none, attacks fail)
# Charge release into spin is captured by the SPIN entry above; the
# brightsteel `kill -TERM <PID>` line fires when the player has an
# active lock target so the pid arg can name a real process.
func _dispatch_terminal_for_action(act: int, prev_act: int) -> void:
	var TS := TuxState
	match act:
		TS.ACT_SPIN:
			# If the spin came directly out of a charge release, the
			# lore variant is `kill -TERM <PID>` against the locked
			# target (Brightsteel's flag-grant). Without a lock target
			# we still narrate the radial sweep as `kill -9 *` so the
			# corner has something to render either way.
			if prev_act == TS.ACT_CHARGING and _lock_target \
					and is_instance_valid(_lock_target):
				_push_terminal_cmd("kill -TERM PID%d"
						% _lock_target.get_instance_id())
			else:
				_push_terminal_cmd("kill -9 *")
		TS.ACT_BLOCK:
			_push_terminal_cmd("chmod 000 .")


# Watch GameState.anchor_boots_active for transitions and push the
# matching `chroot /lower` (on) / `cd /` (off) cmd to the corner. The
# toggle itself lives in pause_menu.gd (which we don't own); polling
# here means the corner narrates the change regardless of who flipped
# the bit.
func _observe_anchor_boots_toggle() -> void:
	var cur: bool = GameState.anchor_boots_active
	if cur == _prev_anchor_boots_active:
		return
	_prev_anchor_boots_active = cur
	if cur:
		_push_terminal_cmd("chroot /lower")
	else:
		_push_terminal_cmd("cd /")


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


# ---- Swim visuals -----------------------------------------------------
#
# Swimming hides the sword + shield (Tux needs his hands to tread water)
# and tints the HUD a soft blue while submerged. The tint is built once
# on first use and parented under the HUD CanvasLayer so it sits over
# the 3D viewport but under the existing death/aim overlays.

# Cached blue tint overlay; spawned lazily so a fresh scene doesn't pay
# for it upfront and so we don't depend on the HUD existing at _ready.
var _underwater_tint: ColorRect = null
const UNDERWATER_TINT_COLOR := Color(0.15, 0.45, 0.70, 0.18)


func _apply_swim_equipment_hide() -> void:
	# Force props off while in ACT_SWIM; restore the inventory-driven
	# visibility otherwise. Reading inventory each tick is cheap and
	# keeps the visibility correct after exiting water without needing
	# an explicit transition signal.
	var swimming: bool = state and state.action == TuxState.ACT_SWIM
	if sword:
		if swimming:
			sword.visible = false
		else:
			sword.visible = bool(GameState.inventory.get("sapling_blade", false))
	if shield:
		if swimming:
			shield.visible = false
		else:
			shield.visible = bool(GameState.inventory.get("bark_round", false))


func _apply_underwater_tint(submerged: bool) -> void:
	# HUD lookup is deferred — find the autoload-style HUD in the scene
	# tree the first time we need it. The HUD is a CanvasLayer parented
	# under the world scene; if it isn't present (headless/test contexts)
	# we just skip silently.
	if _underwater_tint == null:
		var hud: CanvasLayer = _find_hud_layer()
		if hud == null:
			return
		_underwater_tint = ColorRect.new()
		_underwater_tint.name = "UnderwaterTint"
		_underwater_tint.color = UNDERWATER_TINT_COLOR
		_underwater_tint.anchor_right = 1.0
		_underwater_tint.anchor_bottom = 1.0
		_underwater_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_underwater_tint.visible = false
		# Insert at the bottom of the layer so any death/aim overlays
		# still draw above us.
		hud.add_child(_underwater_tint)
		hud.move_child(_underwater_tint, 0)
	if _underwater_tint.visible != submerged:
		_underwater_tint.visible = submerged


func _find_hud_layer() -> CanvasLayer:
	# Walk the scene root for a node named "HUD" (the world_disc + dungeon
	# scenes both add it under the scene root). Falls back to a recursive
	# search by group name for resilience to future scene reshuffling.
	var root: Node = get_tree().current_scene if get_tree() else null
	if root == null:
		return null
	var n: Node = root.get_node_or_null("HUD")
	if n is CanvasLayer:
		return n
	for child in root.get_children():
		if child is CanvasLayer and child.name == "HUD":
			return child
	return null
