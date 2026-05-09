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


func _ready() -> void:
    _attach_mini_map()
    _apply_key_group()
    _attach_enemy_culler()
    _start_music()
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


func _attach_enemy_culler() -> void:
    var culler := EnemyCuller.new()
    culler.name = "EnemyCuller"
    add_child(culler)
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        culler.bind(ps[0])


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
