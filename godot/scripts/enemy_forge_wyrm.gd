extends CharacterBody3D

# Forge Wyrm — boss of the Forge (Dungeon 5). Three-headed serpent of
# living iron. The fight inherits its structural twist from
# enemy_fork_hydra: damaging a head makes it SPLIT into two of the next
# tier instead of dying. Tiers cascade twice, so a single un-managed
# head can balloon into four heads in seconds.
#
# Counter-tool: the Striker's Maul (group `hammer`). A maul strike
# bypasses the split entirely and one-shots whichever head it touches.
# So combat reads as: chase the splits with the sword (slow, eventually
# safe) OR weave in the maul to permanently delete heads.
#
# HP bookkeeping for the boss arena bar:
#   max_hp 90  = sum of three tier-0 heads (30 each)
#   hp         = current sum across all live heads
#
# This scene IS one head + the trunk. On _ready we spawn two SIBLING
# heads as children so the boss arena sees one Node and the bar reads
# the aggregate hp via _recompute_hp(). Each head publishes its own
# `head_hp` and notifies the trunk via signals when struck.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 90              # 3 heads × 30 hp at tier 0
@export var detect_range: float = 12.0
@export var contact_damage: int = 4
@export var pebble_reward: int = 14

const GRAVITY: float = 22.0
const HURT_TIME: float = 0.20
const KNOCKBACK_SPEED: float = 4.0
# Per-tier numbers for an individual head.
const HEAD_TIER_HP:    Array = [30, 14, 6]
const HEAD_TIER_SCALE: Array = [1.0, 0.7, 0.5]
const HEAD_TIER_BITE:  Array = [4, 2, 1]
# How far apart child heads spawn from a split parent.
const SPLIT_OFFSET: float = 1.0

# Per-head record: { "node": MeshInstance3D, "tier": int, "hp": int,
#                    "alive": bool, "phase": float }
var heads: Array = []

var hp: int = 90
var state_dead: bool = false
var player: Node3D = null
var _last_contact_t: float = -1000.0
var _contact_cooldown: float = 0.9

@onready var trunk: Node3D = $Trunk
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea


func _ready() -> void:
    add_to_group("enemy")
    hp = max_hp
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)
    _spawn_initial_heads()


# Three tier-0 heads on the trunk, splayed in a small fan.
func _spawn_initial_heads() -> void:
    var positions: Array = [
        Vector3(-0.8, 1.6, -0.4),
        Vector3( 0.0, 1.9,  0.0),
        Vector3( 0.8, 1.6, -0.4),
    ]
    for p in positions:
        _make_head(p, 0)


func _make_head(local_pos: Vector3, tier: int) -> Dictionary:
    tier = clamp(tier, 0, 2)
    var node := MeshInstance3D.new()
    var mesh := SphereMesh.new()
    var s: float = float(HEAD_TIER_SCALE[tier])
    mesh.radius = 0.45 * s
    mesh.height = 0.90 * s
    mesh.radial_segments = 12
    mesh.rings = 8
    node.mesh = mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.85, 0.32, 0.10, 1)
    mat.metallic = 0.55
    mat.roughness = 0.40
    mat.emission_enabled = true
    mat.emission = Color(1.0, 0.45, 0.10, 1)
    mat.emission_energy_multiplier = 0.6
    node.material_override = mat
    node.position = local_pos
    trunk.add_child(node)
    var rec: Dictionary = {
        "node": node,
        "tier": tier,
        "hp":   int(HEAD_TIER_HP[tier]),
        "alive": true,
        "phase": randf() * TAU,
    }
    heads.append(rec)
    _recompute_hp()
    return rec


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    if state_dead:
        if not is_on_floor():
            velocity.y -= GRAVITY * delta
            move_and_slide()
        return
    _ensure_player()

    # Sway the trunk gently. Heads bob.
    if trunk:
        trunk.rotation.y = sin(Time.get_ticks_msec() / 1000.0 * 0.5) * 0.25
    for rec in heads:
        if rec["alive"] and is_instance_valid(rec["node"]):
            rec["phase"] += delta * 3.0
            var bob: float = sin(rec["phase"]) * 0.10
            var n: MeshInstance3D = rec["node"]
            n.position.y += (bob - (n.position.y - _resting_y(n))) * 4.0 * delta

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()


# Heads have their initial Y baked into their position; bob is RELATIVE
# to that. We approximate "resting Y" by tracking the canonical height
# per tier.
func _resting_y(node: MeshInstance3D) -> float:
    return 1.6 + 0.0 * node.position.x


# Damage routing. The boss exposes a single hitbox covering all heads.
# We pick whichever head is closest to the source position and apply
# damage there. If the attacker is in the "hammer" group (or its source
# carries that tag), the head is one-shot regardless of tier — and does
# NOT split.
func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
    if state_dead:
        return
    var idx: int = _nearest_live_head(source_pos)
    if idx < 0:
        return
    var rec: Dictionary = heads[idx]

    var is_hammer: bool = false
    if attacker and attacker.is_in_group("hammer"):
        is_hammer = true

    if is_hammer:
        _kill_head(idx)
        SoundBank.play_3d("crystal_hit", global_position)
    else:
        rec["hp"] = int(rec["hp"]) - amount
        if rec["hp"] <= 0:
            # On death-by-non-hammer, SPLIT to next tier instead of clearing,
            # unless we're at the last tier.
            if int(rec["tier"]) < 2:
                _split_head(idx)
            else:
                _kill_head(idx)
        SoundBank.play_3d("hurt", global_position)

    var away: Vector3 = global_position - source_pos
    away.y = 0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
        velocity.y = 1.6

    _recompute_hp()
    if hp <= 0 and not state_dead:
        _die()


# Find the nearest still-alive head's index by world position.
func _nearest_live_head(world_pos: Vector3) -> int:
    var best: int = -1
    var best_d: float = 1e9
    for i in range(heads.size()):
        var rec: Dictionary = heads[i]
        if not rec["alive"]:
            continue
        var n: MeshInstance3D = rec["node"]
        if not is_instance_valid(n):
            continue
        var d: float = n.global_position.distance_to(world_pos)
        if d < best_d:
            best_d = d
            best = i
    return best


# Split a head into two next-tier heads, perpendicular to the trunk's
# axis. Both children sit near the parent's local position, then queue
# the parent for visual removal.
func _split_head(idx: int) -> void:
    var rec: Dictionary = heads[idx]
    rec["alive"] = false
    var parent_node: MeshInstance3D = rec["node"]
    var parent_local: Vector3 = parent_node.position
    var next_tier: int = int(rec["tier"]) + 1
    parent_node.queue_free()
    for sgn in [-1, 1]:
        var off: Vector3 = Vector3(SPLIT_OFFSET * 0.6 * float(sgn), 0.0, 0.0)
        _make_head(parent_local + off, next_tier)


func _kill_head(idx: int) -> void:
    var rec: Dictionary = heads[idx]
    rec["alive"] = false
    if is_instance_valid(rec["node"]):
        var n: MeshInstance3D = rec["node"]
        var t := create_tween()
        t.tween_property(n, "scale", n.scale * Vector3(1.4, 0.05, 1.4), 0.25)
        t.tween_callback(n.queue_free)


func _recompute_hp() -> void:
    var total: int = 0
    for rec in heads:
        if rec["alive"]:
            total += int(rec["hp"])
    hp = total


func get_knockback(_direction: Vector3, _force: float) -> void:
    pass


func _on_contact_player(body: Node) -> void:
    if state_dead:
        return
    if not body.is_in_group("player"):
        return
    var now: float = Time.get_ticks_msec() / 1000.0
    if now - _last_contact_t < _contact_cooldown:
        return
    _last_contact_t = now
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, global_position, self)


func _die() -> void:
    state_dead = true
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    if contact_area:
        contact_area.set_deferred("monitoring", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    if trunk:
        t.tween_property(trunk, "scale", trunk.scale * Vector3(1.2, 0.05, 1.2), 0.45)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.4, 1.4), 0.0, randf_range(-1.4, 1.4))
        parent.call_deferred("add_child", p)
