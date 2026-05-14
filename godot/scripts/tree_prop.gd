extends Node3D

# Stand-alone tree prop you can place individually (vs the tree_wall
# script which fills a whole boundary). Has solid trunk collision so
# the player can't walk through, plus a roll-trigger area: roll into
# the trunk and there's a chance a pebble drops out of the canopy.
# Modeled on the OoT bush-tree mechanic.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const WoodPickup := preload("res://scenes/pickup_wood.tscn")

@export var pebble_chance: float = 0.30
@export var trunk_height: float = 4.6
@export var trunk_radius: float = 0.30
@export var canopy_radius: float = 1.7
@export var trunk_color: Color = Color(0.20, 0.13, 0.09, 1)
@export var canopy_color: Color = Color(0.10, 0.22, 0.12, 1)

# Chopping. Each successful hit reduces hp by the swing's damage; at 0
# the tree falls and drops WOOD_DROPS_ON_FELL wood pickups around its
# base. Bare-fist swings do 1 dmg, wooden_sword does 2, axes more —
# TUNE later. For now the tree dies in 4–6 fist swings.
@export var hp_full: int = 5
@export var wood_drops_on_fell: int = 3
var hp: int = 5

@onready var trunk_mesh: MeshInstance3D = $Trunk
@onready var trunk_body: StaticBody3D = $TrunkBody
@onready var canopy_mesh: MeshInstance3D = $Canopy
@onready var roll_area: Area3D = $RollArea

var _shaken: bool = false
var _shake_cooldown: float = 0.0

# Procedural HP banner — a Label3D that pops in above the trunk for a
# few seconds after each hit so the player can see chop progress.
# Built on first damage rather than _ready to keep the idle scene
# cheap (most trees in the world are never hit).
var _hp_label: Label3D = null
var _hp_label_timer: float = 0.0

# Tools that count as "wood-cutting" — bare fists / shields / hammers
# don't chop trees, the player has to bring an edge. The actual per-hit
# damage value comes from the attacker's SwordHitbox (whose `damage`
# tux_player scales by weapon tier), so a Stone Axe does meaningfully
# more per swing than a Sapling Blade without the tree carrying its own
# weapon table.
const CHOPPING_TOOLS: Array[String] = ["sapling_blade", "stone_axe", "stone_sword"]


func _ready() -> void:
    add_to_group("ground_snap")
    add_to_group("tree")
    hp = hp_full
    var trunk: CylinderMesh = trunk_mesh.mesh
    if trunk:
        trunk.height = trunk_height
        trunk.bottom_radius = trunk_radius
        trunk.top_radius = trunk_radius * 0.85
    trunk_mesh.position.y = trunk_height * 0.5
    var canopy: SphereMesh = canopy_mesh.mesh
    if canopy:
        canopy.radius = canopy_radius
        canopy.height = canopy_radius * 1.6
    canopy_mesh.position.y = trunk_height + canopy_radius * 0.5
    var trunk_mat := StandardMaterial3D.new()
    trunk_mat.albedo_color = trunk_color
    trunk_mat.roughness = 0.95
    trunk_mesh.material_override = trunk_mat
    var canopy_mat := StandardMaterial3D.new()
    canopy_mat.albedo_color = canopy_color
    canopy_mat.roughness = 0.85
    canopy_mesh.material_override = canopy_mat
    var trunk_shape: CollisionShape3D = trunk_body.get_node("Shape")
    var cs: CylinderShape3D = trunk_shape.shape
    if cs:
        cs.height = trunk_height
        cs.radius = trunk_radius
    trunk_shape.position.y = trunk_height * 0.5
    roll_area.body_entered.connect(_on_roll_enter)


func _process(delta: float) -> void:
    if _shake_cooldown > 0:
        _shake_cooldown -= delta
    if _hp_label_timer > 0.0:
        _hp_label_timer -= delta
        if _hp_label and is_instance_valid(_hp_label):
            # Linear fade in the last 0.6s of the banner's life.
            _hp_label.modulate.a = clamp(_hp_label_timer / 0.6, 0.0, 1.0)
            if _hp_label_timer <= 0.0:
                _hp_label.queue_free()
                _hp_label = null


func _on_roll_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    if _shake_cooldown > 0 or _shaken:
        return
    # The state machine on the player keeps a public `action` enum.
    # Only count this as a "roll into the tree" if the player is
    # currently rolling — not if they just walked into it.
    var rolling: bool = false
    if "state" in body:
        var s = body.state
        if s != null and "action" in s and "ACT_ROLL" in s:
            rolling = (s.action == s.ACT_ROLL)
    if not rolling:
        return
    _shake_cooldown = 1.0
    _shake_canopy()
    if randf() < pebble_chance:
        _shaken = true
        _drop_pebble()


func _shake_canopy() -> void:
    var t := create_tween()
    var orig: Vector3 = canopy_mesh.position
    t.tween_property(canopy_mesh, "position",
                     orig + Vector3(0.18, -0.05, 0), 0.06)
    t.tween_property(canopy_mesh, "position",
                     orig - Vector3(0.18, 0, 0), 0.08)
    t.tween_property(canopy_mesh, "position", orig, 0.10)


func _drop_pebble() -> void:
    var here: Vector3 = global_position + Vector3(0, trunk_height + 0.5, 0)
    var p := PebblePickup.instantiate()
    p.position = here
    var parent: Node = get_parent()
    if parent:
        parent.call_deferred("add_child", p)


# Called by the trunk-body forwarder when the player's swing hits the
# tree. Signature matches sword_hitbox: take_damage(amount, source_pos,
# attacker). Tools-only — bare fists thunk off; the attacker must carry
# a sapling_blade or stone_axe in their inventory. Each successful hit
# drops a floating HP banner above the trunk for visual progress; at 0
# hp the tree falls and drops WOOD_DROPS_ON_FELL wood pickups.
func take_damage(amount: int, _source_pos: Vector3 = Vector3.ZERO,
        attacker: Node = null) -> void:
    if hp <= 0:
        return
    # Gate on tool ownership — bare fists / hammers thunk off and we
    # flash a hint so the player learns trees need an edge. With a
    # tool, the actual per-hit damage is the SwordHitbox's value
    # (scaled by weapon tier in tux_player) so axes and swords feel
    # distinct.
    if not _attacker_has_chopping_tool(attacker):
        _show_hp_banner("Need an axe to chop")
        return
    hp -= max(amount, 1)
    _shake_canopy()
    if hp > 0:
        _show_hp_banner("HP %d / %d" % [hp, hp_full])
        return
    _fell_and_drop_wood()


func _attacker_has_chopping_tool(attacker: Node) -> bool:
    if attacker == null or not attacker.is_in_group("player"):
        return false
    if not GameState:
        return false
    for tool_id in CHOPPING_TOOLS:
        if bool(GameState.inventory.get(tool_id, false)):
            return true
    return false


# Floating HP banner — lazily built on first hit, repositioned above the
# trunk, and faded out after a couple seconds (timer ticks in _process).
func _show_hp_banner(text: String) -> void:
    if _hp_label == null:
        _hp_label = Label3D.new()
        _hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
        _hp_label.fixed_size = true
        _hp_label.pixel_size = 0.0022
        # no_depth_test so the banner draws ON TOP of the trunk mesh —
        # otherwise the trunk occludes the text and only the edges peek.
        _hp_label.no_depth_test = true
        _hp_label.modulate = Color(1.0, 0.95, 0.55, 1.0)
        _hp_label.outline_modulate = Color(0, 0, 0, 1)
        _hp_label.outline_size = 6
        add_child(_hp_label)
    _hp_label.text = text
    # ~head height so the player reads it in their natural sightline.
    # no_depth_test means we don't need to clear the trunk mesh.
    _hp_label.position = Vector3(0, 1.8, 0)
    _hp_label.modulate.a = 1.0
    _hp_label_timer = 2.0


func _fell_and_drop_wood() -> void:
    # Direct-grant — matches the bush/raspberry path. Feedback comes
    # from the inventory grid live-refresh + SFX.
    if GameState and GameState.has_method("add_resource"):
        GameState.add_resource("wood", wood_drops_on_fell)
    _mark_destroyed()
    SoundBank.play_3d("tree_fall", global_position)
    queue_free()


# Procedural-world persistence hook — see wood_bush.gd. The prop_id meta
# is stamped at spawn by world_chunk.apply_data; hand-placed trees have
# no meta and this is a silent no-op.
func _mark_destroyed() -> void:
    if not has_meta("prop_id"):
        return
    if GameState == null:
        return
    GameState.destroyed_props[String(get_meta("prop_id"))] = true
