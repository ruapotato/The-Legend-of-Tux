extends Node3D

# Root of every JSON-built dungeon scene. Reads GameState.next_spawn_id
# at _ready and repositions Tux at the matching Marker3D under
# $Spawns/. Falls back to a marker named "default" if no match.
#
# Also auto-instances the mini-map widget under the scene's HUD
# CanvasLayer so every built dungeon shows it without each scene file
# having to opt in.

const MINI_MAP_SCENE: String = "res://scenes/mini_map.tscn"
const EnemyCuller = preload("res://scripts/enemy_culler.gd")

# Per-dungeon key group. Keys collected here can only be spent on doors
# tagged with the same group (or doors that inherit the scene's group
# by leaving their own key_group empty). Defaults to the scene file's
# basename if left blank — so adjacent levels intentionally share keys
# only when authored to do so via the level JSON's `key_group` field.
@export var key_group: String = ""

# Region music id passed to MusicBank.play(). Defaults to the scene
# file's basename so authors don't have to repeat themselves on every
# level — only override to share a track between scenes (or use
# build_dungeon.py's emitted "music_track" line).
@export var music_track: String = ""

# Filesystem coordinates. The Wyrdmark sits inside The Mount — see
# LORE.md §6 and FILESYSTEM.md. The build script writes both fields
# from a PATH_MAP keyed on the level id.
@export var display_name: String = ""    # "Wyrdkin Glade"
@export var fs_path:      String = ""    # "/opt/wyrdmark/glade"

# Per-directory aesthetic palette (DESIGN.md §8). The build script
# writes these from the palette table keyed on each region. When the
# scene has no authored WorldEnvironment / DirectionalLight3D, _ready()
# constructs a procedural sky + sun from these four colors so every
# directory looks visibly distinct on entry. Default Color() is
# (0,0,0,1); a fully-zero palette is treated as "unset" and the
# fallback is skipped (the existing static Environment node, if any,
# wins regardless).
@export var sky_color:     Color = Color(0, 0, 0, 1)
@export var fog_color:     Color = Color(0, 0, 0, 1)
@export var ambient_color: Color = Color(0, 0, 0, 1)
@export var sun_color:     Color = Color(0, 0, 0, 1)


func _ready() -> void:
    _attach_mini_map()
    _apply_key_group()
    _attach_enemy_culler()
    _start_music()
    _mark_visited()
    _apply_environment()
    # Drop placed props onto the actual terrain surface — chests, signs,
    # bushes, NPCs etc. are authored at fixed pos.y in JSON but the
    # TerrainMesh's per-cell hills can put real ground a couple of
    # meters above 0. One physics-frame defer so the trimesh shape is
    # registered before the rays cast.
    call_deferred("_snap_props_to_ground")
    # Clear any puzzle latch state from the previous dungeon so a
    # crystal switch on "boss_door" in level A doesn't auto-open the
    # gate of the same name in level B.
    if Engine.has_singleton("WorldEvents") or get_tree().root.has_node("WorldEvents"):
        WorldEvents.reset()

    var spawn_id: String = GameState.next_spawn_id
    if spawn_id == "":
        spawn_id = "default"
    GameState.next_spawn_id = ""    # consumed
    GameState.current_spawn_id = spawn_id

    var spawns_root: Node = get_node_or_null("Spawns")
    if not spawns_root:
        return
    var marker: Node3D = spawns_root.get_node_or_null(spawn_id) as Node3D
    if marker == null:
        marker = spawns_root.get_node_or_null("default") as Node3D
    if marker == null:
        return

    var player: Node3D = null
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        player = ps[0]
    if player == null:
        return
    player.global_position = marker.global_position
    if player is CharacterBody3D:
        player.rotation.y = marker.rotation.y

    # Snap the camera behind the player so they aren't staring at the
    # wall of the load zone they just stepped through. _yaw + PI puts
    # the camera behind, looking forward in the player's facing
    # direction.
    var camera_node: Node = get_node_or_null("Camera")
    if camera_node and camera_node.has_method("set_yaw"):
        camera_node.set_yaw(marker.rotation.y + PI)


func _scene_id() -> String:
    var p: String = scene_file_path
    if p.begins_with("res://scenes/"):
        p = p.substr("res://scenes/".length())
    if p.ends_with(".tscn"):
        p = p.substr(0, p.length() - ".tscn".length())
    return p


func _mark_visited() -> void:
    var sid := _scene_id()
    if sid != "" and GameState.has_method("mark_visited"):
        GameState.mark_visited(sid)


func _attach_enemy_culler() -> void:
    var culler := EnemyCuller.new()
    culler.name = "EnemyCuller"
    add_child(culler)
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        culler.bind(ps[0])


func _snap_props_to_ground() -> void:
    # Wait several physics ticks so the TerrainMesh's trimesh collision
    # shape has had time to register with the physics server, then
    # raycast every node in the "ground_snap" group down to it.
    #
    # With per-cell hills (terrain_height_pass) every level now ships a
    # mesh with hundreds of varying-height triangles; the trimesh shape
    # rebuild + physics-server registration sometimes takes more than a
    # single frame, especially on the bigger hubs (crown ~24k cells).
    # If we snap before it's ready, every ray returns empty and props
    # hover. Three ticks is empirically enough on sourceplain (the
    # heaviest level); we then verify by sampling one terrain_mesh
    # node and waiting until *its* StaticBody3D answers a ray.
    await get_tree().physics_frame
    await get_tree().physics_frame
    await get_tree().physics_frame
    # Verify terrain collision is live by raying down through it from
    # high above the level origin; if nothing comes back, give it a few
    # more frames before giving up. Caps at ~10 extra frames so we
    # don't deadlock on a genuinely terrain-less scene.
    var world := get_world_3d()
    if world != null:
        var space := world.direct_space_state
        var probe := PhysicsRayQueryParameters3D.create(
            Vector3(0.0, 200.0, 0.0), Vector3(0.0, -200.0, 0.0))
        probe.collision_mask = 1
        for _i in range(10):
            var hit: Dictionary = space.intersect_ray(probe)
            if not hit.is_empty():
                break
            await get_tree().physics_frame
    var snap = preload("res://scripts/ground_snap.gd")
    for n in get_tree().get_nodes_in_group("ground_snap"):
        if n is Node3D:
            snap.snap(n)


func _start_music() -> void:
    var track := music_track
    if track == "":
        var p: String = scene_file_path
        if p.begins_with("res://scenes/"):
            p = p.substr("res://scenes/".length())
        if p.ends_with(".tscn"):
            p = p.substr(0, p.length() - ".tscn".length())
        track = p
    if track == "":
        return
    # MusicBank lives as an autoload; if it isn't registered yet (e.g.,
    # running a scene in isolation from the editor), just skip.
    var mb := get_node_or_null("/root/MusicBank")
    if mb and mb.has_method("play"):
        mb.play(track)


func _apply_key_group() -> void:
    var group := key_group
    if group == "":
        var p: String = scene_file_path
        if p.begins_with("res://scenes/"):
            p = p.substr("res://scenes/".length())
        if p.ends_with(".tscn"):
            p = p.substr(0, p.length() - ".tscn".length())
        group = p
    GameState.set_key_group(group)


func _attach_mini_map() -> void:
    # Find a HUD CanvasLayer already in the tree and parent the
    # mini-map under it so it draws above the world but below pause UI.
    var hud: Node = get_node_or_null("HUD")
    if hud == null:
        for child in get_children():
            if child is CanvasLayer and child.name == "HUD":
                hud = child
                break
    if hud == null:
        return
    if hud.get_node_or_null("MiniMap") != null:
        return
    var packed: PackedScene = load(MINI_MAP_SCENE)
    if packed == null:
        return
    var instance: Node = packed.instantiate()
    hud.add_child(instance)


func _palette_set() -> bool:
    # A four-zero palette means "no override authored" — leave the
    # scene's existing lighting alone (or just use Godot's default).
    return (sky_color != Color(0, 0, 0, 1)
        or fog_color != Color(0, 0, 0, 1)
        or ambient_color != Color(0, 0, 0, 1)
        or sun_color != Color(0, 0, 0, 1))


func _has_world_environment() -> bool:
    for child in get_children():
        if child is WorldEnvironment:
            return true
    return false


func _has_directional_light() -> bool:
    for child in get_children():
        if child is DirectionalLight3D:
            return true
    return false


func _apply_environment() -> void:
    # Per-directory aesthetic fallback. Only runs when this node is the
    # top-level scene (not loaded as a sub-scene), the palette is set,
    # AND the scene file didn't already author a static WorldEnvironment
    # / DirectionalLight3D — the existing rich environment block built
    # by build_dungeon.py wins, so this only kicks in for scenes that
    # were authored without one.
    if get_tree() == null or get_tree().current_scene != self:
        return
    if not _palette_set():
        return
    if not _has_world_environment():
        var env := Environment.new()
        env.background_mode = Environment.BG_SKY
        var sky_mat := ProceduralSkyMaterial.new()
        # Pull the horizon a bit warmer/lighter than the dome so the
        # palette reads as "sky color" without flattening the gradient.
        sky_mat.sky_top_color = sky_color
        sky_mat.sky_horizon_color = sky_color.lerp(Color(1, 1, 1, 1), 0.35)
        sky_mat.ground_horizon_color = sky_color.lerp(Color(0, 0, 0, 1), 0.35)
        sky_mat.ground_bottom_color = sky_color.lerp(Color(0, 0, 0, 1), 0.6)
        var sky := Sky.new()
        sky.sky_material = sky_mat
        env.sky = sky
        env.fog_enabled = true
        env.fog_light_color = fog_color
        env.fog_density = 0.005
        env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
        env.ambient_light_color = ambient_color
        env.ambient_light_energy = 0.45
        var we := WorldEnvironment.new()
        we.name = "WorldEnvironment"
        we.environment = env
        add_child(we)
    if not _has_directional_light():
        var sun := DirectionalLight3D.new()
        sun.name = "Sun"
        sun.light_color = sun_color
        sun.light_energy = 1.0
        sun.shadow_enabled = true
        # Late-morning angle: high in the sky, slightly off to one side.
        # Vector3(-0.85, -0.5, -0.2) per DESIGN.md hints.
        sun.rotation = Vector3(-0.85, -0.5, -0.2)
        add_child(sun)
