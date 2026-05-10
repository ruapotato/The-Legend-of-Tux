extends Node3D

# Init the Sleeper — final boss of Dungeon 8 (Null Door). Three phases,
# each with its own hp pool. The arena bar reads `hp` and `max_hp` for
# the CURRENT phase so each phase change snaps the bar back to full.
#
# Phase 1 (CHILD, 60 hp):
#   Slow circular drift, throws single seed-like projectiles toward the
#   player. Sword damages directly. No defenses.
#
# Phase 2 (TRUE, 70 hp):
#   Faster, larger silhouette. Summons one enemy_init_shade every 10s
#   (capped at SHADE_CAP live shades). Bow damage is doubled — seed/sword
#   damage normal.
#
# Phase 3 (AWAKENING, 70 hp):
#   Charges a "Final Word" laser at the player every FINAL_WORD_CYCLE
#   seconds. The laser ONE-SHOTS Tux unless the player holds the
#   Glim Mirror passive (GameState.inventory.has("glim_mirror")), in
#   which case the beam reflects back and damages Init for FINAL_WORD_REFLECT
#   per reflection. Three reflections kills the boss outright.
#
# `died` is emitted ONCE on the final death (phase 3 hp <= 0 OR three
# reflections). Phase changes are internal.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const SeedScene: PackedScene = preload("res://scenes/seed.tscn")

signal died

# These are the current-phase values — the boss arena bar reads these.
@export var max_hp: int = 60
@export var hp: int = 60

# Tunables.
@export var detect_range: float = 18.0
@export var contact_damage: int = 4
@export var pebble_reward: int = 18
@export var seed_cooldown: float = 1.6
@export var seed_speed: float = 8.0
@export var shade_spawn_interval: float = 10.0
@export var shade_cap: int = 3
@export var bow_damage_multiplier: int = 2
@export var final_word_cycle: float = 7.0
@export var final_word_charge: float = 2.5
@export var final_word_beam: float = 0.45
@export var final_word_reflect_damage: int = 25

const PHASE_HP: Array = [60, 70, 70]
const PHASE_NAMES: Array = ["child", "true", "awakening"]
# Movement per phase.
const PHASE_ORBIT_SPEED: Array = [0.45, 0.85, 0.55]
const PHASE_ORBIT_RADIUS: Array = [3.5, 4.2, 5.0]

enum State { ORBIT, CHARGING, BEAM, HURT, PHASE_CHANGE, DEAD }

var state: int = State.ORBIT
var state_time: float = 0.0
var player: Node3D = null
var phase: int = 0
var _orbit_phase: float = 0.0
var _seed_t: float = 0.0
var _shade_t: float = 0.0
var _final_word_t: float = 0.0
var _shades: Array = []
var _reflections: int = 0
# When TRUE, take_damage interpretation routes through phase-2 / phase-3
# rules. PHASE_CHANGE briefly suspends incoming damage.
var _ignore_damage: bool = false
# Tracks beam state-machine within a Final Word cycle.
var _beam_started: bool = false
var _beam_target: Vector3 = Vector3.ZERO

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var contact_area: Area3D = $ContactArea
@onready var body_mesh: MeshInstance3D = $Visual/Body
@onready var halo_mesh: MeshInstance3D = $Visual/Halo


func _ready() -> void:
    add_to_group("enemy")
    _enter_phase(0)
    if contact_area:
        contact_area.body_entered.connect(_on_contact_player)


func _enter_phase(p: int) -> void:
    phase = clamp(p, 0, 2)
    max_hp = int(PHASE_HP[phase])
    hp = max_hp
    _orbit_phase = randf() * TAU
    _seed_t = 0.6
    _shade_t = shade_spawn_interval * 0.5    # first summon comes quick
    _final_word_t = final_word_cycle * 0.4
    _beam_started = false
    _reflections = 0
    _ignore_damage = true
    # Visual scale grows phase to phase.
    var s: float = [1.0, 1.4, 1.8][phase]
    visual.scale = Vector3.ONE * s
    # Color shifts phase to phase.
    var col: Color = [Color(0.85, 0.80, 0.95, 1),
                      Color(0.55, 0.30, 0.85, 1),
                      Color(0.95, 0.20, 0.30, 1)][phase]
    if body_mesh and body_mesh.material_override is StandardMaterial3D:
        var m := body_mesh.material_override as StandardMaterial3D
        m.albedo_color = col
        m.emission = col
    if halo_mesh and halo_mesh.material_override is StandardMaterial3D:
        var m2 := halo_mesh.material_override as StandardMaterial3D
        m2.emission = col
    # Skip the alert SFX on the very first phase entry (_ready calls
    # _enter_phase(0)). It both spams nothing meaningful at fight start
    # and leaks an audio stream when the scene is booted in isolation.
    if phase > 0:
        SoundBank.play_3d("blob_alert", global_position)
    _set_state(State.PHASE_CHANGE)


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta
    if state == State.DEAD:
        return
    _ensure_player()

    # Drift along the orbit.
    var spd: float = float(PHASE_ORBIT_SPEED[phase])
    var rad: float = float(PHASE_ORBIT_RADIUS[phase])
    _orbit_phase += spd * delta
    var ox: float = cos(_orbit_phase) * rad
    var oz: float = sin(_orbit_phase) * rad
    visual.position = Vector3(ox, 1.5 + sin(state_time * 1.4) * 0.30, oz)
    hitbox.position = visual.position
    contact_area.position = visual.position

    match state:
        State.PHASE_CHANGE:
            # ~0.8s of damage immunity for the phase swap shimmer.
            if state_time > 0.8:
                _ignore_damage = false
                _set_state(State.ORBIT)
        State.ORBIT:
            _phase_behavior(delta)
        State.CHARGING:
            _do_charging(delta)
        State.BEAM:
            _do_beam(delta)
        State.HURT:
            if state_time >= 0.18:
                _set_state(State.ORBIT)


# Per-phase behavior dispatched while in ORBIT.
func _phase_behavior(delta: float) -> void:
    match phase:
        0:
            _seed_t -= delta
            if _seed_t <= 0.0 and player and is_instance_valid(player):
                _throw_seed()
                _seed_t = seed_cooldown
        1:
            _seed_t -= delta
            if _seed_t <= 0.0 and player and is_instance_valid(player):
                _throw_seed()
                _seed_t = seed_cooldown * 0.7
            _shade_t -= delta
            if _shade_t <= 0.0:
                _try_summon_shade()
                _shade_t = shade_spawn_interval
        2:
            _final_word_t -= delta
            if _final_word_t <= 0.0:
                _set_state(State.CHARGING)
                _final_word_t = final_word_cycle


func _do_charging(_delta: float) -> void:
    # Visual: pulse the halo brighter while charging.
    if halo_mesh and halo_mesh.material_override is StandardMaterial3D:
        var m := halo_mesh.material_override as StandardMaterial3D
        m.emission_energy_multiplier = 1.0 + 4.0 * (state_time / max(0.1, final_word_charge))
    if state_time >= final_word_charge:
        _beam_started = false
        if player and is_instance_valid(player):
            _beam_target = player.global_position
        _set_state(State.BEAM)


func _do_beam(_delta: float) -> void:
    if not _beam_started:
        _beam_started = true
        _resolve_final_word()
    if state_time >= final_word_beam:
        # Reset halo glow.
        if halo_mesh and halo_mesh.material_override is StandardMaterial3D:
            var m := halo_mesh.material_override as StandardMaterial3D
            m.emission_energy_multiplier = 1.0
        _set_state(State.ORBIT)


# The Final Word resolution: if the player holds the Glim Mirror, the
# beam reflects (boss takes damage); otherwise the player is one-shot.
func _resolve_final_word() -> void:
    SoundBank.play_3d("sword_swing", global_position)
    if player == null or not is_instance_valid(player):
        return
    if _player_has_glim_mirror():
        _reflections += 1
        # Apply reflection damage directly — we treat it as a separate
        # damage source so it isn't gated by the immunity flag.
        hp -= final_word_reflect_damage
        SoundBank.play_3d("crystal_hit", global_position)
        if _reflections >= 3 or hp <= 0:
            _final_die()
        else:
            _set_state(State.HURT)
        return
    # No mirror — instant kill the player.
    if player.has_method("take_damage"):
        # Damage equal to a huge number; player.take_damage clamps.
        player.take_damage(99, global_position, self)


func _player_has_glim_mirror() -> bool:
    var gs := get_node_or_null("/root/GameState")
    if gs == null:
        return false
    if not "inventory" in gs:
        return false
    var inv: Variant = gs.get("inventory")
    if inv is Dictionary:
        return (inv as Dictionary).has("glim_mirror") and bool((inv as Dictionary).get("glim_mirror", false))
    if inv != null and inv.has_method("has"):
        return bool(inv.call("has", "glim_mirror"))
    return false


func _throw_seed() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var s := SeedScene.instantiate() as Area3D
    if s == null:
        return
    parent.call_deferred("add_child", s)
    var here: Vector3 = visual.global_position
    s.global_position = here + Vector3(0, -0.3, 0)
    var dir: Vector3 = Vector3.FORWARD
    if player and is_instance_valid(player):
        var to_p: Vector3 = player.global_position - here
        if to_p.length() > 0.05:
            dir = to_p.normalized()
    if s.has_method("setup"):
        s.setup(dir * seed_speed, self)
    else:
        s.set("velocity", dir * seed_speed)


func _try_summon_shade() -> void:
    # Prune dead refs.
    var live: Array = []
    for sh in _shades:
        if is_instance_valid(sh):
            live.append(sh)
    _shades = live
    if _shades.size() >= shade_cap:
        return
    var parent: Node = get_parent()
    if parent == null:
        return
    var scene: PackedScene = load("res://scenes/enemy_init_shade.tscn") as PackedScene
    if scene == null:
        return
    var sh := scene.instantiate() as Node3D
    if sh == null:
        return
    var here: Vector3 = visual.global_position
    here.y = 0.2
    var ang: float = randf() * TAU
    sh.position = here + Vector3(cos(ang) * 1.8, 0, sin(ang) * 1.8)
    parent.call_deferred("add_child", sh)
    _shades.append(sh)


# Damage routing. Phase 1: standard. Phase 2: bow doubled, others normal.
# Phase 3: only Final Word reflections deal damage; everything else is
# rejected so the only kill path is mirror-reflection.
func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
    if state == State.DEAD or _ignore_damage:
        return
    var actual: int = amount
    if phase == 1:
        # The bow's arrow has DAMAGE = 2; we recognize it by checking
        # the attacker chain for an arrow signature. The most reliable
        # signal is "the source is an Area3D area-entry" — but we don't
        # have that here. Instead, we defensively double damage any time
        # the source isn't the player's own CharacterBody3D within sword
        # reach. Practical heuristic: if `source_pos` is far from the
        # player's body (>= 3.5m) AND amount equals the arrow constant,
        # it's an arrow.
        if attacker == null or _looks_like_ranged_hit(source_pos, attacker):
            actual = amount * bow_damage_multiplier
    elif phase == 2:
        # Phase 3 in the spec is "awakening form" — only reflections
        # damage it. Reject all incoming damage from take_damage().
        SoundBank.play_3d("shield_block", global_position)
        return
    hp -= actual
    SoundBank.play_3d("hurt", visual.global_position)
    if hp <= 0:
        _advance_phase_or_die()
    else:
        _set_state(State.HURT)


# Heuristic: a hit is "ranged" if the source is far from the attacker
# (which would be the player CharacterBody3D). Sword swings are within
# arm's reach (~1.5m); bow shots originate at the impact point which is
# usually 3+ m from the shooter.
func _looks_like_ranged_hit(source_pos: Vector3, attacker: Node) -> bool:
    if attacker is Node3D:
        var d: float = (attacker as Node3D).global_position.distance_to(source_pos)
        if d > 3.0:
            return true
    return false


func _advance_phase_or_die() -> void:
    # Phase 0 → 1, 1 → 2, 2 → die. (Phase 2 = awakening = phase index 2.)
    if phase < 2:
        _enter_phase(phase + 1)
    else:
        _final_die()


func get_knockback(_direction: Vector3, _force: float) -> void:
    _set_state(State.HURT)


func _on_contact_player(body: Node) -> void:
    if state == State.DEAD:
        return
    if not body.is_in_group("player"):
        return
    if body.has_method("take_damage"):
        body.take_damage(contact_damage, visual.global_position, self)


func _final_die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    if contact_area:
        contact_area.set_deferred("monitoring", false)
    SoundBank.play_3d("death", visual.global_position)
    # World flag for "the sleeper is gone" — game-end gate.
    var gs := get_node_or_null("/root/GameState")
    if gs and "inventory" in gs and gs.inventory is Dictionary:
        gs.inventory["init_defeated"] = true
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", visual.scale * Vector3(0.05, 0.05, 0.05), 0.85)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = visual.global_position
    here.y = 0.3
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
