extends CharacterBody3D

# Player controller: ties together input, the action state machine
# (tux_state.gd), the procedural animator (tux_anim.gd), the rig, and
# the sword hitbox(es). The state machine owns the action logic; this
# script is the integration layer.

const TuxState = preload("res://scripts/tux_state.gd")
const TuxAnim  = preload("res://scripts/tux_anim.gd")

@export var camera_path: NodePath

@onready var rig: Node3D = $Rig
@onready var sword: Node3D = $Sword
@onready var sword_hitbox: Area3D = $Sword/SwordHitbox
@onready var spin_hitbox: Area3D = $SpinHitbox
@onready var shield_mesh: MeshInstance3D = null   # set after rig load if present

var state: RefCounted
var anim: RefCounted
var camera: Node = null
var bones: Dictionary = {}


func _ready() -> void:
    add_to_group("player")
    state = TuxState.new()
    anim  = TuxAnim.new()

    # Wire stamina callbacks into the autoload so the state machine can
    # gate roll/spin/sprint without knowing about GameState directly.
    state.get_stamina = func() -> int: return GameState.stamina
    state.spend_stamina = func(amount: int) -> void: GameState.spend_stamina(amount)

    # Locate the bones the animator drives. Path matches tux_rig.tscn.
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

    # Reparent the sword under arm_r so it tracks the wing's animation.
    # The sword is authored at the player root for editor convenience;
    # at runtime we move it under the wing pivot and pin its local
    # transform so the grip sits at the wing tip. Tweak SWORD_LOCAL if
    # the blade ends up clipping or floating.
    var arm_r: Node3D = bones["arm_r"]
    var SWORD_LOCAL := Transform3D(Basis.IDENTITY, Vector3(-0.07, -0.32, 0))
    remove_child(sword)
    arm_r.add_child(sword)
    sword.transform = SWORD_LOCAL

    # Camera is a sibling we point at this player.
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

    # Stamina regen: full rate when not blocking, none while blocking
    # (blocking holds the meter so big blocks read as a serious cost).
    var is_blocking: bool = state.action == TuxState.ACT_BLOCK and state.action_time >= TuxState.BLOCK_RAISE_DURATION
    if not is_blocking:
        GameState.regen_stamina(30.0, delta)

    velocity = state.vel
    move_and_slide()

    # Apply state's chosen face_yaw to the rig. The rig's root transform
    # has its own basis flip; we rotate the WHOLE CharacterBody3D so the
    # collision shape and sword rotate with the visuals.
    rotation.y = state.face_yaw

    # Drive animator from the state's request.
    anim.play(state.requested_anim, state.requested_anim_speed, state.requested_anim_reset)
    anim.tick(delta)

    # Sword hitbox gating. The spin uses a separate, larger radial
    # hitbox; regular swings/jab/jump-strike use the blade hitbox.
    if state.spin_hit_active:
        spin_hitbox.arm()
    else:
        spin_hitbox.disarm()
    if state.hit_window_active:
        sword_hitbox.arm()
    else:
        sword_hitbox.disarm()


func _read_inputs() -> void:
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
    state.input_camera_yaw     = camera.get_yaw() if camera and camera.has_method("get_yaw") else 0.0


func get_face_yaw() -> float:
    return state.face_yaw if state else rotation.y


# ---- Damage in / out --------------------------------------------------

func take_damage(amount: int, source_pos: Vector3) -> void:
    if state.take_hit(source_pos, amount):
        GameState.damage(amount)


func _on_sword_hit(_target: Node) -> void:
    # Hook for hit-stop, screen shake, sword sfx etc. No-op for now.
    pass


func _on_player_died() -> void:
    state.kill()
