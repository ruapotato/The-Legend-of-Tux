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


static var debug_log: bool = false  # flip true for per-prop snap traces


static func snap(node: Node3D, max_drop: float = 50.0,
                 y_offset: float = 0.0) -> bool:
    if node == null or not node.is_inside_tree():
        if debug_log:
            print("[ground_snap] SKIP not-in-tree: %s" % [
                node.name if node else "<null>"])
        return false
    var world := node.get_world_3d()
    if world == null:
        if debug_log:
            print("[ground_snap] SKIP no-world: %s" % node.name)
        return false
    var space := world.direct_space_state
    var p: Vector3 = node.global_position
    var query := PhysicsRayQueryParameters3D.create(
        p + Vector3(0.0, max_drop, 0.0),
        p + Vector3(0.0, -max_drop, 0.0))
    query.collision_mask = WORLD_LAYER
    # Exclude EVERY ground-snap-able prop's collision body, not just
    # the caller's own. Trees, signs, NPCs all carry StaticBody3D's on
    # layer 1 (same as terrain), and trees clustering within 1-2m of
    # each other meant a snap from Tree19 hit Tree55's TrunkBody —
    # snapping the prop to the TOP of a neighbour's trunk (+4.6m
    # above the actual ground). Same for Sign3 + Npc Smith Brann
    # co-located at (12, 4). The terrain mesh's StaticBody3D is also
    # on layer 1; with all props excluded, raycast lands on it cleanly.
    var excludes: Array[RID] = []
    if node.is_inside_tree():
        for other in node.get_tree().get_nodes_in_group("ground_snap"):
            _gather_collision_rids(other, excludes)
    else:
        _gather_collision_rids(node, excludes)
    query.exclude = excludes
    var hit: Dictionary = space.intersect_ray(query)
    if hit.is_empty():
        # When a prop can't find ground beneath it the caller has no
        # way to know — the prop just stays where it was (likely
        # floating). Surface it loud so we can see WHY.
        push_warning("ground_snap: no ground beneath %s @ %s" % [
            node.name, p
        ])
        if debug_log:
            print("[ground_snap] FAIL %s @ (%.2f,%.2f,%.2f) — no hit; excludes=%d" % [
                node.name, p.x, p.y, p.z, excludes.size()])
        return false
    var new_y: float = float(hit["position"].y) + y_offset
    if debug_log:
        var collider_name: String = "?"
        var collider_path: String = "?"
        var collider_rid: RID
        var is_own: bool = false
        if hit.has("collider") and hit["collider"] != null:
            var hc: Node = hit["collider"] as Node
            collider_name = str(hc.name)
            collider_path = str(hc.get_path())
            if hc is CollisionObject3D:
                collider_rid = (hc as CollisionObject3D).get_rid()
                is_own = excludes.has(collider_rid)
        var jump: float = new_y - p.y
        var marker: String = "OK" if abs(jump) < 1.0 else "JUMP"
        print("[ground_snap] %s %s y %.2f -> %.2f (Δ %+.2f) hit %s%s" % [
            marker, node.name, p.y, new_y, jump, collider_path,
            "  [SELF-HIT BUG]" if is_own else ""])
    node.global_position.y = new_y
    return true


static func _gather_collision_rids(n: Node, out: Array[RID]) -> void:
    if n is CollisionObject3D:
        out.append((n as CollisionObject3D).get_rid())
    for c in n.get_children():
        _gather_collision_rids(c, out)
