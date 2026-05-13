extends Area3D

# Scene-transition trigger. Walking the player into the volume fires
# the change. The Hint label is a signpost; the prompt text is shown
# above the portal so the player knows where it leads.
#
# Visual note: the trigger itself is INVISIBLE — the level transition
# should read as "the player walks through a gap in the tree wall",
# not "a black box is sitting on the level edge". Build script (and
# tree_wall.gd's `gaps` export) carve the matching opening; this
# script just fires when the player enters and shows a soft ground
# glow when they're close, as a subtle waypoint cue.
#
# Spawn-overlap suppression: when the destination scene's "from_X"
# spawn marker sits next to the back-to-X portal, the player's
# capsule materializes already overlapping the trigger and
# body_entered fires on the very next physics tick — bouncing the
# player back to the source. The earlier "check overlapping_bodies on
# _ready" approach was racy because physics hadn't run yet by the
# time the deferred check ran. We just use a time-based grace window
# instead: ignore body entries for SPAWN_GRACE seconds after _ready.

const SPAWN_GRACE: float = 0.6
const GLOW_RADIUS: float = 6.0          # m; player must be within this to see the ring
const GLOW_RING_RADIUS: float = 1.8     # ring drawn on the ground at the trigger

@export_file("*.tscn") var target_scene: String = ""
@export var target_spawn: String = "default"
@export_multiline var prompt: String = ""
@export var auto_trigger: bool = true
@export var debug_visible: bool = false  # set true in editor to see the trigger box

# Gating: transition refuses to fire unless GameState satisfies these.
# Empty strings = no gate. `gate_message` is what we say to the player
# when they bounce off — leave blank to silently refuse.
@export var requires_flag: String = ""
@export var requires_item: String = ""
@export_multiline var gate_message: String = ""

@onready var hint: Label3D = $Hint if has_node("Hint") else null

var _firing: bool = false
var _ready_at: float = 0.0
var _glow: MeshInstance3D = null
var _glow_mat: StandardMaterial3D = null
var _player: Node3D = null


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    if hint:
        hint.text = prompt if prompt != "" else "Travel"
        hint.visible = true
    _ready_at = Time.get_ticks_msec() / 1000.0

    # Hide any pre-existing visible mesh children unless explicitly
    # debugging — older builds shipped a "Veil" black-box; we want
    # the trigger to feel like empty air, not a wall.
    if not debug_visible:
        for child in get_children():
            if child is MeshInstance3D:
                child.visible = false

    _build_glow_ring()
    set_process(true)


func _build_glow_ring() -> void:
    # Soft circular ring on the ground at the trigger's footprint.
    # Sits flat (rotated to face up) so it reads as a paint mark on
    # the dirt path. Material is unshaded + emissive so it remains
    # visible in deep shadow without dominating brightly-lit scenes.
    _glow = MeshInstance3D.new()
    var mesh := TorusMesh.new()
    mesh.inner_radius = GLOW_RING_RADIUS - 0.25
    mesh.outer_radius = GLOW_RING_RADIUS
    mesh.rings = 24
    mesh.ring_segments = 6
    _glow.mesh = mesh
    _glow_mat = StandardMaterial3D.new()
    _glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _glow_mat.albedo_color = Color(0.85, 0.78, 0.55, 0.0)
    _glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _glow_mat.emission_enabled = true
    _glow_mat.emission = Color(0.85, 0.78, 0.55)
    _glow_mat.emission_energy_multiplier = 0.0
    _glow.material_override = _glow_mat
    # Drop the ring to ground level — trigger usually sits ~1.4m up,
    # so offset DOWN by roughly that amount. We can't know exact
    # floor_y here, so just sink to local y = -1.4 which matches the
    # build-script default load_zone height.
    _glow.position = Vector3(0, -1.35, 0)
    add_child(_glow)


func _process(_dt: float) -> void:
    if _glow == null or _glow_mat == null:
        return
    var p: Node3D = _player
    if p == null or not is_instance_valid(p):
        # Lazy-bind the player on first frame we can find them. Cheap
        # to skip when not present (e.g. main_menu) — get_first_node_in_group
        # is O(group-size) so we cache.
        var nodes := get_tree().get_nodes_in_group("player")
        if nodes.size() > 0:
            _player = nodes[0] as Node3D
            p = _player
    if p == null:
        return
    var d: float = global_position.distance_to(p.global_position)
    var t: float = clamp(1.0 - d / GLOW_RADIUS, 0.0, 1.0)
    # Smoothstep so the glow fades in gently, not linearly.
    t = t * t * (3.0 - 2.0 * t)
    _glow_mat.albedo_color.a = t * 0.55
    _glow_mat.emission_energy_multiplier = t * 0.9


func _on_enter(body: Node) -> void:
    if _firing or not auto_trigger:
        return
    if not body.is_in_group("player"):
        return
    var elapsed: float = Time.get_ticks_msec() / 1000.0 - _ready_at
    if elapsed < SPAWN_GRACE:
        # Player materialized inside us at scene load — not a real
        # crossing. Ignore.
        return
    _fire(body)


func _fire(player: Node) -> void:
    if _firing or target_scene == "":
        return
    # Gate check. requires_flag and requires_item accept either a
    # single name or a comma-separated list — the door refuses entry
    # if ANY required flag/item is missing. Stays un-fired so the
    # player can come back later.
    for f in requires_flag.split(",", false):
        var nm := f.strip_edges()
        if nm != "" and not GameState.has_flag(nm):
            if gate_message != "":
                Dialog.show_message(gate_message)
            return
    for it in requires_item.split(",", false):
        var nm := it.strip_edges()
        if nm != "" and not GameState.inventory.get(nm, false):
            if gate_message != "":
                Dialog.show_message(gate_message)
            return
    _firing = true
    GameState.next_spawn_id = target_spawn
    # Mirror the destination spawn into current_spawn_id ahead of the
    # save so the snapshot we take here represents where Tux will be
    # *after* the transition, not where he was.
    GameState.current_spawn_id = target_spawn
    # Pretend we're already on the target scene for the save snapshot
    # so reloading from this autosave puts the player on the other
    # side of the door, not back inside the load zone.
    if GameState.last_slot >= 0:
        var prior_scene_path: String = ""
        var scene := get_tree().current_scene
        if scene:
            prior_scene_path = scene.scene_file_path
            scene.scene_file_path = target_scene
        GameState.save_game(GameState.last_slot)
        if scene and prior_scene_path != "":
            scene.scene_file_path = prior_scene_path
    if player and player is CharacterBody3D:
        player.set_physics_process(false)
    SceneFader.change_scene(target_scene)
