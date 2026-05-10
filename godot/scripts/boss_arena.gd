extends Node3D

# Boss arena framework. A trigger Area3D detects the player entering,
# locks the arena (invisible barrier), spawns the boss, fades briefly,
# swaps to "boss" music, and posts a name-bar on the HUD. On boss death
# the barrier drops, victory stinger plays, region music resumes, and a
# heart container (or fallback heart pickup) drops where the boss died.
#
# Authoring:
#   @export var boss_scene: PackedScene = preload("res://scenes/...tscn")
#   @export var boss_name : String      = "Wyrd Tomato"
#
# State machine (single-shot — once defeated, the arena stays inert):
#   IDLE     — armed; trigger waiting for player
#   FIGHT    — barrier up, boss alive, music = boss
#   CLEARED  — boss dead, barrier down, region music restored
#
# Intentional simplifications:
#   - "barrier" is a single thin invisible cylinder StaticBody3D ringing
#     the arena. The player physically can't leave; enemies/projectiles
#     could in principle, but no boss currently strays beyond its
#     spawn radius so it's fine.
#   - The 1.5s "intro cinematic" is just SceneFader.fade_to(0.4) → wait
#     → fade_to(0). No camera moves; we don't want a sub-agent fighting
#     the orbit-camera scripting.

const HeartPickup = preload("res://scenes/pickup_heart.tscn")
# TODO: replace with a real heart-container pickup once it exists.
const HEART_CONTAINER_SCENE: String = "res://scenes/pickup_heart_container.tscn"

@export var boss_name: String = "Boss"
@export var boss_scene: PackedScene = null
@export var arena_radius: float = 7.0
@export var spawn_offset: Vector3 = Vector3(0, 5, 0)
# Optional region music id to restore after the fight (empty = re-read
# the dungeon root's music_track).
@export var region_track: String = ""
# Boss id — recorded in GameState.bosses_defeated on victory so chest
# `requires` checks (e.g. anchor-boots gated by gale_roost_defeated)
# can resolve. If left empty, derived from the boss_scene basename.
@export var boss_id: String = ""

enum State { IDLE, FIGHT, CLEARED }

var state: int = State.IDLE
var _boss: Node3D = null
var _barrier: StaticBody3D = null
var _trigger: Area3D = null
var _hud_bar: Control = null
var _boss_max_hp: int = 1


func _ready() -> void:
    _trigger = get_node_or_null("Trigger")
    if _trigger:
        _trigger.body_entered.connect(_on_player_entered)
    else:
        # If the .tscn didn't author the trigger, build one defensively.
        _trigger = _build_trigger()
        add_child(_trigger)
        _trigger.body_entered.connect(_on_player_entered)


# Construct a cylinder Area3D detector centered on this node.
func _build_trigger() -> Area3D:
    var a := Area3D.new()
    a.name = "Trigger"
    a.collision_layer = 0
    a.collision_mask = 2   # player
    a.monitoring = true
    a.monitorable = false
    var cs := CollisionShape3D.new()
    var sh := CylinderShape3D.new()
    sh.radius = arena_radius
    sh.height = 8.0
    cs.shape = sh
    a.add_child(cs)
    return a


func _on_player_entered(body: Node) -> void:
    if state != State.IDLE:
        return
    if not body.is_in_group("player"):
        return
    if boss_scene == null:
        push_warning("BossArena[%s]: boss_scene not set; aborting" % boss_name)
        return
    state = State.FIGHT
    # Disable the trigger so we don't re-fire.
    _trigger.set_deferred("monitoring", false)
    _raise_barrier()
    _spawn_boss()
    _intro_cinematic()
    _attach_hud_bar()
    # Delay the boss-music swap so the region track keeps playing
    # through the intro fade — the music kicks in right as the boss
    # actually starts harassing the player rather than the moment they
    # cross the arena threshold. ~2.5 s lines up with the boss's
    # first attack telegraph.
    var music_timer := Timer.new()
    music_timer.one_shot = true
    music_timer.wait_time = 2.5
    add_child(music_timer)
    music_timer.timeout.connect(func() -> void:
        if state != State.FIGHT:
            return
        var mb := get_node_or_null("/root/MusicBank")
        if mb and mb.has_method("play"):
            mb.play("boss", 0.6))
    music_timer.start()


func _raise_barrier() -> void:
    # Hollow cylinder of segments approximating a ring. Cheaper than a
    # CSG donut and good enough — the player capsule can't squeeze
    # through a 0.4m thick wall regardless.
    _barrier = StaticBody3D.new()
    _barrier.name = "Barrier"
    _barrier.collision_layer = 1
    _barrier.collision_mask = 0
    var segments := 16
    var h := 6.0
    var thick := 0.4
    for i in segments:
        var ang: float = (i / float(segments)) * TAU
        var seg := CollisionShape3D.new()
        var box := BoxShape3D.new()
        # Each segment chord ≈ 2 * r * sin(pi/segments).
        var chord: float = 2.0 * arena_radius * sin(PI / segments) * 1.05
        box.size = Vector3(chord, h, thick)
        seg.shape = box
        var t := Transform3D()
        t.origin = Vector3(cos(ang) * arena_radius, h * 0.5, sin(ang) * arena_radius)
        # Tangent rotation so the box faces outward.
        t.basis = Basis(Vector3.UP, ang + PI * 0.5)
        seg.transform = t
        _barrier.add_child(seg)
    add_child(_barrier)


func _drop_barrier() -> void:
    if _barrier and is_instance_valid(_barrier):
        _barrier.queue_free()
        _barrier = null


func _spawn_boss() -> void:
    _boss = boss_scene.instantiate() as Node3D
    if _boss == null:
        push_warning("BossArena[%s]: instantiation produced non-Node3D" % boss_name)
        return
    _boss.position = spawn_offset
    add_child(_boss)
    # Best-effort capture of the boss's max HP so the bar can scale.
    if "max_hp" in _boss:
        _boss_max_hp = max(1, int(_boss.max_hp))
    elif "hp" in _boss:
        _boss_max_hp = max(1, int(_boss.hp))
    if _boss.has_signal("died"):
        _boss.died.connect(_on_boss_died)
    elif _boss.has_signal("tree_exited"):
        _boss.tree_exited.connect(_on_boss_died)


func _intro_cinematic() -> void:
    # Brief translucent flash + stinger. SceneFader is the only autoload
    # that owns the curtain, so reuse it instead of stamping a new one.
    var sf := get_node_or_null("/root/SceneFader")
    if sf and sf.has_method("fade_to"):
        sf.fade_to(0.45, 0.35)
        # Schedule the fade-back without blocking _ready chain.
        var t := create_tween()
        t.tween_interval(1.15)
        t.tween_callback(func ():
            if is_instance_valid(sf):
                sf.fade_to(0.0, 0.4))
    SoundBank.play_2d("sword_charge_ready")


func _on_boss_died() -> void:
    if state == State.CLEARED:
        return
    state = State.CLEARED
    var bid: String = boss_id
    if bid == "" and boss_scene:
        var p: String = boss_scene.resource_path
        if p.begins_with("res://scenes/enemy_"):
            bid = p.substr("res://scenes/enemy_".length())
            if bid.ends_with(".tscn"):
                bid = bid.substr(0, bid.length() - ".tscn".length())
    if bid != "":
        var gs := get_node_or_null("/root/GameState")
        if gs and gs.has_method("mark_boss_defeated"):
            gs.mark_boss_defeated(bid)
    _drop_barrier()
    SoundBank.play_2d("gate_open")
    _drop_reward()
    _detach_hud_bar()
    var mb := get_node_or_null("/root/MusicBank")
    if mb and mb.has_method("play"):
        var track := region_track
        if track == "":
            # Re-derive from the owning dungeon root if it's labeled.
            var root := get_tree().current_scene
            if root and "music_track" in root:
                track = root.music_track
                if track == "":
                    var p: String = root.scene_file_path
                    if p.begins_with("res://scenes/"):
                        p = p.substr("res://scenes/".length())
                    if p.ends_with(".tscn"):
                        p = p.substr(0, p.length() - ".tscn".length())
                    track = p
        if track != "":
            mb.play(track, 1.0)


func _drop_reward() -> void:
    var here: Vector3 = global_position + spawn_offset
    here.y = 0.5    # snap to the ground so the pickup floats correctly
    var pickup: Node3D = null
    if ResourceLoader.exists(HEART_CONTAINER_SCENE):
        var p := load(HEART_CONTAINER_SCENE)
        if p:
            pickup = p.instantiate()
    if pickup == null:
        # Fallback: drop a regular heart pickup so the player gets SOMETHING.
        pickup = HeartPickup.instantiate()
    pickup.position = here
    var parent := get_parent()
    if parent:
        parent.call_deferred("add_child", pickup)


# ---- HUD bar -----------------------------------------------------------

func _attach_hud_bar() -> void:
    var hud := _find_hud()
    if hud == null:
        return
    var box := VBoxContainer.new()
    box.name = "BossBar_%s" % name
    box.anchor_left = 0.5
    box.anchor_right = 0.5
    box.anchor_top = 0.0
    box.anchor_bottom = 0.0
    box.offset_left = -180
    box.offset_right = 180
    box.offset_top = 12
    box.offset_bottom = 60
    box.alignment = BoxContainer.ALIGNMENT_CENTER
    var label := Label.new()
    label.name = "Name"
    label.text = boss_name
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    box.add_child(label)
    var bar := ProgressBar.new()
    bar.name = "Bar"
    bar.custom_minimum_size = Vector2(360, 14)
    bar.max_value = float(_boss_max_hp)
    bar.value = float(_boss_max_hp)
    bar.show_percentage = false
    box.add_child(bar)
    hud.add_child(box)
    _hud_bar = box
    set_process(true)


func _detach_hud_bar() -> void:
    if _hud_bar and is_instance_valid(_hud_bar):
        _hud_bar.queue_free()
    _hud_bar = null


func _process(_delta: float) -> void:
    if _hud_bar and is_instance_valid(_hud_bar) and _boss and is_instance_valid(_boss):
        var bar: ProgressBar = _hud_bar.get_node_or_null("Bar") as ProgressBar
        if bar and "hp" in _boss:
            bar.value = clamp(float(_boss.hp), 0.0, float(_boss_max_hp))


func _find_hud() -> CanvasLayer:
    var root := get_tree().current_scene
    if root == null:
        return null
    var n := root.get_node_or_null("HUD")
    if n is CanvasLayer:
        return n
    for child in root.get_children():
        if child is CanvasLayer and child.name == "HUD":
            return child
    return null
