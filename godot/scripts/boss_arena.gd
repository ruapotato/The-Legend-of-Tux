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
# Real Heart Container pickup — adds a max-HP slot (handled inside the
# pickup script via GameState.add_heart_container).
const HEART_CONTAINER_SCENE: String = "res://scenes/heart_container.tscn"

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
        _trigger.body_exited.connect(_on_player_exited)
    else:
        # If the .tscn didn't author the trigger, build one defensively.
        _trigger = _build_trigger()
        add_child(_trigger)
        _trigger.body_entered.connect(_on_player_entered)
        _trigger.body_exited.connect(_on_player_exited)


# If the player spawned INSIDE the trigger (cramped dungeons where the
# entry spawn lands within the boss arena radius), body_entered fires
# the moment physics catches up — and the boss fight starts before the
# player can look around. Track whether the player has been outside the
# trigger at least once; only after they have can a re-entry arm the
# fight. Player spawning outside → flips true on first _process tick;
# spawning inside → stays false until they walk out (body_exited).
var _ever_outside: bool = false


func _on_player_exited(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _ever_outside = true


func _physics_process(_delta: float) -> void:
    # Run for ONE frame after _ready. If the player is NOT inside the
    # trigger (the common case — they entered the dungeon at a spawn
    # away from the arena), flip _ever_outside true so the next
    # body_entered actually starts the fight. If the player IS inside,
    # leave _ever_outside false; body_exited will flip it later.
    if _trigger and is_instance_valid(_trigger):
        var ps := get_tree().get_nodes_in_group("player")
        if not ps.is_empty():
            if not _trigger.overlaps_body(ps[0]):
                _ever_outside = true
    set_physics_process(false)


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
    if not _ever_outside:
        # Player was inside on spawn — wait for them to walk out first.
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
    # Boss-name reveal banner. Drops in from above, holds 1.4 s, fades.
    # Mirrors OoT's "Volvagia" / "Phantom Ganon" splash card.
    _spawn_name_reveal()


func _spawn_name_reveal() -> void:
    var layer := CanvasLayer.new()
    layer.layer = 88
    var name_label := Label.new()
    name_label.text = boss_name
    name_label.add_theme_font_size_override("font_size", 44)
    name_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.36, 1.0))
    name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
    name_label.add_theme_constant_override("shadow_offset_x", 2)
    name_label.add_theme_constant_override("shadow_offset_y", 2)
    name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    name_label.anchor_left = 0.0; name_label.anchor_right = 1.0
    name_label.anchor_top = 0.32; name_label.anchor_bottom = 0.40
    name_label.modulate.a = 0.0
    layer.add_child(name_label)
    var sub := Label.new()
    sub.text = "BOSS"
    sub.add_theme_font_size_override("font_size", 14)
    sub.add_theme_color_override("font_color", Color(0.85, 0.55, 0.35, 1.0))
    sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    sub.anchor_left = 0.0; sub.anchor_right = 1.0
    sub.anchor_top = 0.42; sub.anchor_bottom = 0.46
    sub.modulate.a = 0.0
    layer.add_child(sub)
    add_child(layer)
    var tw := create_tween().set_parallel(false)
    tw.tween_property(name_label, "modulate:a", 1.0, 0.45)
    tw.parallel().tween_property(sub, "modulate:a", 1.0, 0.45)
    tw.tween_interval(1.4)
    tw.tween_property(name_label, "modulate:a", 0.0, 0.5)
    tw.parallel().tween_property(sub, "modulate:a", 0.0, 0.5)
    tw.tween_callback(layer.queue_free)


func _on_boss_died() -> void:
    if state == State.CLEARED:
        return
    state = State.CLEARED

    # 1. Mark the boss defeated in the persistent registry so chest
    # `requires` checks resolve on the very next frame.
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

    # Capture where the boss was — we anchor the heart-container ceremony
    # there even after the boss node sinks and frees itself.
    var ceremony_origin: Vector3 = global_position + spawn_offset
    if _boss and is_instance_valid(_boss):
        ceremony_origin = _boss.global_position

    # 2. Slow-mo. Restore via a timer that explicitly ignores time_scale
    # so the restore actually fires after 0.6s of WALL-clock time
    # (otherwise 0.6 / 0.4 = 1.5s of real time, awkward).
    Engine.time_scale = 0.4
    _schedule_time_scale_restore(0.6)

    # 3. Camera flash — full-screen white CanvasLayer ColorRect, fades in
    # 0.2s then out 0.6s. Self-frees after the fade-out.
    _spawn_camera_flash()

    # 4. Music sting. Silent-fallback safe (SoundBank skips missing wavs).
    SoundBank.play_2d("boss_clear")
    # Keep gate_open as a secondary "barrier dissolves" cue — it's the
    # original SFX and lines up nicely under boss_clear.
    SoundBank.play_2d("gate_open")

    # 5+6+7+8 in sequence — kicked off in a deferred coroutine so this
    # handler returns immediately (the boss script is in the middle of
    # emitting `died` and we don't want to await mid-emission).
    _run_completion_sequence(ceremony_origin)


# Restore Engine.time_scale to 1.0 after `wall_seconds` of real time.
# The 4th arg to create_timer (ignore_time_scale) lets the timer tick at
# wall-clock speed even though Engine.time_scale is 0.4 right now.
func _schedule_time_scale_restore(wall_seconds: float) -> void:
    var t := get_tree().create_timer(wall_seconds, true, false, true)
    t.timeout.connect(func() -> void:
        Engine.time_scale = 1.0)


# Build a CanvasLayer with a white ColorRect that fades in then out.
func _spawn_camera_flash() -> void:
    var cl := CanvasLayer.new()
    cl.layer = 90    # below pause_menu (80? — pause uses 80; flash should
                    # appear over gameplay but can sit beneath pause).
    var rect := ColorRect.new()
    rect.color = Color(1.0, 1.0, 1.0, 0.0)
    rect.anchor_right = 1.0
    rect.anchor_bottom = 1.0
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    cl.add_child(rect)
    # Parent to the current_scene so the layer survives even if this
    # boss arena is freed mid-fade (defensive — shouldn't happen).
    var holder: Node = get_tree().current_scene
    if holder == null:
        holder = self
    holder.add_child(cl)
    # Tween runs in real time (the tween's callbacks here are
    # short-lived and benefit from feeling crisp regardless of slow-mo).
    var tw := cl.create_tween()
    tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    tw.set_ignore_time_scale(true)
    tw.tween_property(rect, "color:a", 0.85, 0.20)
    tw.tween_property(rect, "color:a", 0.0, 0.60)
    tw.tween_callback(cl.queue_free)


# Top-level orchestrator coroutine. Plays the boss-sink, the heart-
# container reveal, then the save prompt, then the music swap.
func _run_completion_sequence(ceremony_origin: Vector3) -> void:
    # 5. Boss sink — 1s tween down 1m and scale → 0. Use real-time tween
    # so the visual lands on its 1s budget regardless of slow-mo.
    if _boss and is_instance_valid(_boss):
        var sink_target: Vector3 = _boss.position + Vector3(0, -1.0, 0)
        var tw := _boss.create_tween()
        tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        tw.set_ignore_time_scale(true)
        tw.set_parallel(true)
        tw.tween_property(_boss, "position", sink_target, 1.0)
        tw.tween_property(_boss, "scale", Vector3.ZERO, 1.0)
        tw.chain().tween_callback(func() -> void:
            if _boss and is_instance_valid(_boss):
                _boss.queue_free()
                _boss = null)
    # Wait through the slow-mo window (~0.6s real-time) AND let the boss
    # sink occupy most of its 1s before the heart container appears.
    await get_tree().create_timer(0.8, true, false, true).timeout

    # 6. Heart container ceremony — instantiate at ground beneath the
    # boss, lift it 2m up over 1.5s, surround with a yellow light beam
    # that fades in then out around it.
    _drop_reward(ceremony_origin)

    # 7. Save prompt — wait a beat so the heart visual reads first.
    await get_tree().create_timer(1.6, true, false, true).timeout
    _show_save_prompt()

    # 8. Drop barrier + detach HUD bar + resume region music.
    # (The barrier was previously dropped immediately; defer it so the
    # player can't bolt mid-cinematic.)
    _drop_barrier()
    _detach_hud_bar()
    _resume_region_music()


func _resume_region_music() -> void:
    var mb := get_node_or_null("/root/MusicBank")
    if mb == null or not mb.has_method("play"):
        return
    var track: String = region_track
    if track == "":
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


# Spawn the heart container pickup at the boss's last position, then
# tween it 2m up over ~1.5s. Wrap it in a CSGCylinder3D light beam with
# a tween that fades emission + alpha in for the first half, holds, then
# fades out.
func _drop_reward(ceremony_origin: Vector3 = Vector3.INF) -> void:
    # Backwards-compat: the previous _drop_reward took no args. If the
    # caller didn't supply an origin (legacy call paths) fall back to
    # the historical "snap to y=0.5 above spawn_offset" behaviour.
    var here: Vector3 = ceremony_origin
    if here == Vector3.INF:
        here = global_position + spawn_offset
        here.y = 0.5

    var pickup: Node3D = null
    if ResourceLoader.exists(HEART_CONTAINER_SCENE):
        var p := load(HEART_CONTAINER_SCENE)
        if p:
            pickup = p.instantiate()
    if pickup == null:
        # Fallback: drop a regular heart pickup so the player gets SOMETHING.
        pickup = HeartPickup.instantiate()

    # Spawn at ground beneath the boss; lift will move it to ~2m up.
    var ground: Vector3 = here
    ground.y = max(0.5, here.y * 0.0 + 0.5)
    pickup.position = ground
    var parent := get_parent()
    if parent == null:
        return
    parent.add_child(pickup)

    # Tween the pickup upward 2m over 1.5s.
    var lift_target: Vector3 = ground + Vector3(0, 2.0, 0)
    var lift_tw := pickup.create_tween()
    lift_tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    lift_tw.set_ignore_time_scale(true)
    lift_tw.set_trans(Tween.TRANS_SINE)
    lift_tw.set_ease(Tween.EASE_OUT)
    lift_tw.tween_property(pickup, "position", lift_target, 1.5)

    # Light beam — CSGCylinder3D, emissive yellow, alpha+emission tweened
    # in then out over ~3s total. Centered on the lift trajectory.
    var beam := CSGCylinder3D.new()
    beam.radius = 0.5
    beam.height = 6.0
    beam.sides = 24
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1.0, 0.92, 0.55, 0.0)
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.emission_enabled = true
    mat.emission = Color(1.0, 0.92, 0.55)
    mat.emission_energy_multiplier = 0.0
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    beam.material = mat
    # Beam stands so its bottom is at ground level — sits behind/around
    # the pickup as it rises.
    beam.position = ground + Vector3(0, beam.height * 0.5, 0)
    parent.add_child(beam)

    var beam_tw := beam.create_tween()
    beam_tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    beam_tw.set_ignore_time_scale(true)
    beam_tw.set_parallel(true)
    # Fade in over 0.4s.
    beam_tw.tween_property(mat, "albedo_color:a", 0.55, 0.4)
    beam_tw.tween_property(mat, "emission_energy_multiplier", 4.0, 0.4)
    # Hold (1.6s) then fade out (1.0s) — sequence after the parallel-in.
    beam_tw.chain().tween_interval(1.6)
    beam_tw.chain().tween_property(mat, "albedo_color:a", 0.0, 1.0)
    beam_tw.parallel().tween_property(mat, "emission_energy_multiplier", 0.0, 1.0)
    beam_tw.chain().tween_callback(beam.queue_free)


# ---- Save prompt overlay -----------------------------------------------

# Build a simple Control with a "Save your progress?" prompt and two
# buttons. Auto-dismisses after 8 seconds if untouched. Built in style
# consistent with pause_menu.gd (golden #FBE988 title on dark backdrop).
func _show_save_prompt() -> void:
    if state != State.CLEARED:
        return
    var cl := CanvasLayer.new()
    cl.layer = 85    # above the camera flash, below the pause menu (80
                    # uses lower numbers; we sit slightly above HUD).
    cl.process_mode = Node.PROCESS_MODE_ALWAYS

    var root := Control.new()
    root.anchor_right = 1.0
    root.anchor_bottom = 1.0
    root.mouse_filter = Control.MOUSE_FILTER_STOP
    cl.add_child(root)

    # Dim backdrop covering the screen (subtle — we want the player to
    # still see the heart container glowing in the world behind).
    var backdrop := ColorRect.new()
    backdrop.color = Color(0.05, 0.04, 0.08, 0.55)
    backdrop.anchor_right = 1.0
    backdrop.anchor_bottom = 1.0
    backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.add_child(backdrop)

    # Centre panel.
    var panel := PanelContainer.new()
    panel.anchor_left = 0.5
    panel.anchor_right = 0.5
    panel.anchor_top = 0.5
    panel.anchor_bottom = 0.5
    panel.offset_left = -240
    panel.offset_right = 240
    panel.offset_top = -90
    panel.offset_bottom = 90
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0.08, 0.07, 0.12, 0.96)
    sb.border_color = Color(0.98, 0.91, 0.53, 1.0)
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(8)
    panel.add_theme_stylebox_override("panel", sb)
    root.add_child(panel)

    var vb := VBoxContainer.new()
    vb.add_theme_constant_override("separation", 16)
    panel.add_child(vb)

    var heading := Label.new()
    heading.text = "Boss defeated! Save your progress?"
    heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    heading.add_theme_font_size_override("font_size", 22)
    heading.add_theme_color_override("font_color", Color(0.98, 0.91, 0.53, 1.0))
    vb.add_child(heading)

    var btn_row := HBoxContainer.new()
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_theme_constant_override("separation", 24)
    vb.add_child(btn_row)

    var save_btn := Button.new()
    save_btn.text = "Save"
    save_btn.custom_minimum_size = Vector2(140, 40)
    save_btn.add_theme_font_size_override("font_size", 18)
    btn_row.add_child(save_btn)

    var cont_btn := Button.new()
    cont_btn.text = "Continue"
    cont_btn.custom_minimum_size = Vector2(140, 40)
    cont_btn.add_theme_font_size_override("font_size", 18)
    btn_row.add_child(cont_btn)

    var holder: Node = get_tree().current_scene
    if holder == null:
        holder = self
    holder.add_child(cl)

    # Capture a closure over the layer + holder so both buttons + the
    # auto-dismiss timer dispose of the same overlay exactly once.
    var dismissed := [false]
    var dismiss := func() -> void:
        if dismissed[0]:
            return
        dismissed[0] = true
        if is_instance_valid(cl):
            cl.queue_free()

    save_btn.pressed.connect(func() -> void:
        var gs := get_node_or_null("/root/GameState")
        var ok: bool = false
        if gs and gs.has_method("save_game") and "last_slot" in gs and gs.last_slot >= 0:
            ok = bool(gs.save_game(gs.last_slot))
        SoundBank.play_2d("menu_confirm")
        dismiss.call()
        _show_saved_toast(ok))

    cont_btn.pressed.connect(func() -> void:
        SoundBank.play_2d("menu_back")
        dismiss.call())

    # Auto-dismiss after 8s of real time (ignore_time_scale=true).
    var t := get_tree().create_timer(8.0, true, false, true)
    t.timeout.connect(func() -> void: dismiss.call())


# Brief "Saved." toast at the top of the screen. 2s lifetime: 0.25s
# fade-in, 1.5s hold, 0.25s fade-out.
func _show_saved_toast(success: bool) -> void:
    var cl := CanvasLayer.new()
    cl.layer = 95    # over everything else for the brief notification.
    var label := Label.new()
    label.text = ("Saved." if success else "Save failed.")
    label.anchor_left = 0.5
    label.anchor_right = 0.5
    label.offset_left = -120
    label.offset_right = 120
    label.offset_top = 24
    label.offset_bottom = 64
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.add_theme_font_size_override("font_size", 22)
    label.add_theme_color_override("font_color", Color(0.98, 0.91, 0.53, 0.0))
    # Drop shadow for readability against bright scenes.
    label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
    label.add_theme_constant_override("shadow_outline_size", 2)
    cl.add_child(label)
    var holder: Node = get_tree().current_scene
    if holder == null:
        holder = self
    holder.add_child(cl)
    var tw := cl.create_tween()
    tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    tw.set_ignore_time_scale(true)
    tw.tween_property(label, "modulate:a", 1.0, 0.25)
    tw.tween_interval(1.5)
    tw.tween_property(label, "modulate:a", 0.0, 0.25)
    tw.tween_callback(cl.queue_free)


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
