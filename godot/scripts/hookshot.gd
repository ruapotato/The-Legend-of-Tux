extends Node

# Static utility for the hookshot item. `try_fire(player, direction)`
# kicks off a one-shot projectile + chain animation; on hit it pulls
# the player toward the impact point. The pull itself runs on a child
# Node attached under the player so this script can be a stateless
# class_name-free utility.
#
# `Hookshot.try_fire(self, fwd)` from tux_player.gd is the only
# entry point. The cooldown lives on the player itself (a simple
# tree_exited check + a script-side timer), so we don't need an
# autoload for one-shot state.

const HookshotTipScene := preload("res://scenes/hookshot_tip.tscn")
const PullScript := preload("res://scripts/hookshot_pull.gd")


# Spawns a hookshot tip in front of the player aimed along `direction`.
# Returns the tip node (or null if the spawn failed).
static func try_fire(player: Node3D, direction: Vector3) -> Node3D:
    if player == null or not is_instance_valid(player):
        return null
    var scene_root: Node = player.get_tree().current_scene
    if scene_root == null:
        return null
    var tip: Node3D = HookshotTipScene.instantiate()
    scene_root.add_child(tip)
    var origin: Vector3 = player.global_position + Vector3(0, 1.0, 0)
    tip.global_position = origin
    if tip.has_method("set_owner_player"):
        tip.set_owner_player(player)
    if tip.has_method("set_direction"):
        tip.set_direction(direction)
    # Terminal-corner narration. Lore-canon command: `cd <visible-tile>`.
    # We don't actually know which tile until the tip lands (or whiffs),
    # so we emit at fire-time with a placeholder coordinate built from
    # the tip's spawn point + aim direction. Reads as "I tried to cd
    # somewhere over there" which is exactly what the player just did.
    var tl: Node = player.get_node_or_null("/root/TerminalLog")
    if tl:
        var dest: Vector3 = origin + direction.normalized() * 8.0
        tl.cmd("cd ./tile@(%.0f,%.0f)" % [dest.x, dest.z])
    return tip


# Begin the player-pull. Called by the tip when it hits a valid anchor.
# Attaches a HookshotPull node under the player; that node overrides
# velocity each tick until the player reaches the target or the timeout
# expires. Subsequent calls replace any in-flight pull.
static func begin_pull(player: Node3D, target_pos: Vector3) -> void:
    if player == null or not is_instance_valid(player):
        return
    # Cancel any pre-existing pull node so a chain-fire re-aims cleanly.
    for c in player.get_children():
        if c is Node and c.get_script() == PullScript:
            (c as Node).queue_free()
    var pull := Node.new()
    pull.set_script(PullScript)
    player.add_child(pull)
    pull.set("target_pos", target_pos)
