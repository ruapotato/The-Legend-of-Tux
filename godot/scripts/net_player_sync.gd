extends Node

# Per-Tux MultiplayerSynchronizer-substitute. Lives as a child of a
# Tux CharacterBody3D and either broadcasts (authority) or absorbs
# (puppet) position + rotation at ~10 Hz. Smooth motion comes from
# the puppet lerping its parent toward the latest synced pose every
# physics tick; the network rate stays low so traffic is bounded.
#
# We use a hand-rolled @rpc(unreliable) instead of MultiplayerSynchronizer
# because the Tux is instanced from a packed scene at runtime — its
# NodePath isn't stable across peers unless we name spawn children
# deterministically (which we do: "TuxPeer<id>"), but the synchronizer
# also wants identical replication config on every peer. Doing it by
# hand is fewer moving parts for an MVP.

const SEND_HZ: float = 10.0
const SEND_DT: float = 1.0 / SEND_HZ
# Snappy enough that 100 ms gaps don't read as teleports, gentle
# enough that jitter doesn't show as twitching.
const LERP_RATE: float = 14.0

# Set by world_disc when this node is added. The peer id whose
# authority is being mirrored — for the local Tux this matches
# multiplayer.get_unique_id().
var peer_id: int = 0

var _send_timer: float = 0.0
var _target_position: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _has_target: bool = false


func _ready() -> void:
	# This Node is logically owned by `peer_id`; setting authority on
	# the sync node itself isn't strictly required for the RPC pattern
	# below (we route by peer id through any_peer), but doing so makes
	# the intent clear and lets us swap to MultiplayerSynchronizer
	# later without changing world_disc.
	set_multiplayer_authority(peer_id)
	var parent := get_parent() as Node3D
	if parent:
		_target_position = parent.global_position
		_target_yaw = parent.rotation.y
		_has_target = true


func _physics_process(delta: float) -> void:
	if not NetManager.is_active():
		return
	var parent := get_parent() as Node3D
	if parent == null:
		return
	if is_multiplayer_authority():
		_send_timer += delta
		if _send_timer >= SEND_DT:
			_send_timer = 0.0
			# Broadcast to all other peers. unreliable_ordered drops
			# stale packets cleanly so a brief stall doesn't snap us
			# back in time once the buffer drains.
			_rpc_pose.rpc(parent.global_position, parent.rotation.y)
	else:
		# Puppet — smooth toward the last received pose. lerp_angle
		# handles the wrap-around at ±PI so a 359°→1° turn doesn't
		# spin the body the long way.
		if _has_target:
			parent.global_position = parent.global_position.lerp(
					_target_position, clamp(LERP_RATE * delta, 0.0, 1.0))
			parent.rotation.y = lerp_angle(parent.rotation.y, _target_yaw,
					clamp(LERP_RATE * delta, 0.0, 1.0))


# Authority → all peers: latest pose. any_peer + call_remote so the
# packet only travels outward; the sender doesn't bounce it back.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_pose(pos: Vector3, yaw: float) -> void:
	# Trust the sender id matches our peer_id — the authority check on
	# is_multiplayer_authority() above means a puppet won't *send*,
	# and the engine routes RPCs by node path so only the matching
	# sync node receives this call.
	_target_position = pos
	_target_yaw = yaw
	_has_target = true
