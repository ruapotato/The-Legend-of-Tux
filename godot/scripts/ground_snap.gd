class_name GroundSnap
extends RefCounted

# Drop a node down to whatever the world surface is directly below it.
# Used by props that get placed at a fixed `pos.y` in JSON (chests,
# signs, bushes, trees, NPCs, owl statues, bomb flowers, rocks). On
# the new TerrainMesh hills the cell's actual surface Y can be a
# couple of meters above 0; without this the prop spawns inside the
# hill and you can't see it.
#
# Caller should be a Node3D already in the tree; the result writes
# back to `node.global_position.y`. Returns true if a hit landed
# within `max_drop`, false otherwise (in which case position is
# left alone — better to float than to teleport into the void).

const WORLD_LAYER: int = 1


static func snap(node: Node3D, max_drop: float = 50.0,
                 y_offset: float = 0.0) -> bool:
    if node == null or not node.is_inside_tree():
        return false
    var world := node.get_world_3d()
    if world == null:
        return false
    var space := world.direct_space_state
    var p: Vector3 = node.global_position
    var query := PhysicsRayQueryParameters3D.create(
        p + Vector3(0.0, max_drop, 0.0),
        p + Vector3(0.0, -max_drop, 0.0))
    query.collision_mask = WORLD_LAYER
    var hit: Dictionary = space.intersect_ray(query)
    if hit.is_empty():
        return false
    node.global_position.y = float(hit["position"].y) + y_offset
    return true
