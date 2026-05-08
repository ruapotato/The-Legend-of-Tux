extends Node3D

# Root of every JSON-built dungeon scene. Reads GameState.next_spawn_id
# at _ready and repositions Tux at the matching Marker3D under
# $Spawns/. Falls back to a marker named "default" if no match.

func _ready() -> void:
    var spawn_id: String = GameState.next_spawn_id
    if spawn_id == "":
        spawn_id = "default"
    GameState.next_spawn_id = ""    # consumed

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
