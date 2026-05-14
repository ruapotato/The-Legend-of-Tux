extends Node3D

# Root of the procedural overworld scene. Wires the WorldStreamer to
# Tux + the Chunks container, force-loads the spawn chunks before the
# first frame so Tux doesn't free-fall, and snaps Tux onto the surface.
#
# Multiplayer awareness: when NetManager is active we treat the
# scene-local Tux as THIS peer's player, attach a sync node, and
# spawn a puppet Tux for every other peer the host already knows
# about. New peers that join later are handled by a host→all
# RPC that creates the puppet on every other client.
# When NetManager is disconnected this scene behaves exactly as
# single-player did before.

const TuxScene: PackedScene = preload("res://scenes/tux.tscn")
const NetPlayerSync = preload("res://scripts/net_player_sync.gd")

@onready var _tux: Node3D = $Tux
@onready var _chunks_root: Node3D = $Chunks

# peer_id → puppet Tux node. Empty in single-player.
var _puppets: Dictionary = {}


func _ready() -> void:
	if NetManager.is_active():
		await _setup_networked()
	else:
		_setup_singleplayer()
	# Rebuild any survival pieces the player has placed across this
	# playthrough. Done after the chunks + workbench spawn so the parent
	# (this node) is fully constructed and any positional math (terrain
	# height, etc.) sees the same world the builder saw at place-time.
	_restore_placed_pieces()


func _setup_singleplayer() -> void:
	WorldStreamer.set_container(_chunks_root)
	WorldStreamer.set_player(_tux)
	# Spawn Tux at the centre of the starter island, snapped to the
	# surface plus a small clearance. Phase 4 (POI seeder) will likely
	# move this to a specific entry POI; for now (0, 0) is fine.
	var sy: float = WorldGen.height_at(0.0, 0.0) + 1.5
	_tux.position = Vector3(0, sy, 0)
	# Pre-warm the chunks around the spawn so collision exists by the
	# time gravity kicks in this frame.
	WorldStreamer.force_load_around(_tux.position)
	# Workbench-anywhere: crafting is now done from the pause-menu
	# inventory grid (the agent that built the grid added a craft panel
	# that consumes Recipes.RECIPES anywhere). No need to litter the
	# starter island with a free-standing workbench — it kept landing
	# inside river beds anyway. The workbench scene still exists if
	# we want to scatter it via a POI later.


func _setup_networked() -> void:
	# The scene-local Tux IS our local player. Assign authority to our
	# peer id so the tux_player input gate (added in tux_player.gd)
	# lets it read inputs and so the sync node it owns broadcasts.
	var my_id: int = NetManager.local_id()
	_tux.set_multiplayer_authority(my_id)
	_attach_sync(_tux, my_id)

	# Wire signals so peers that join AFTER us still get a puppet
	# spawned, and so a leaving peer's puppet is cleaned up.
	NetManager.peer_joined.connect(_on_peer_joined)
	NetManager.peer_left.connect(_on_peer_left)

	# If we're a client, wait until the host's world seed has landed
	# before any chunk gets generated. The seed RPC is queued during
	# connection; in practice it has already arrived by the time
	# _ready runs here, but we guard for the cold path.
	if not NetManager.is_host and not NetManager.has_synced_seed():
		await NetManager.world_seed_synced

	WorldStreamer.set_container(_chunks_root)
	WorldStreamer.set_player(_tux)
	var sy: float = WorldGen.height_at(0.0, 0.0) + 1.5
	_tux.position = Vector3(0, sy, 0)
	WorldStreamer.force_load_around(_tux.position)

	# (Starter workbench removed — crafting lives in the inventory grid.)

	# Spawn puppets for every peer we already know about. On the host
	# that's the full list of clients; on a client that's typically
	# empty (we'll learn about siblings as the host echoes joins).
	if NetManager.is_host:
		for pid in NetManager.peer_ids:
			if pid != my_id:
				_spawn_puppet(pid)
		# Tell every existing client to also spawn a puppet for the
		# rest of the cohort — the simplest way to bootstrap a late
		# joiner's view of the room.
		_rpc_announce_existing_peers.rpc()
	else:
		# Ask the host who else is in the room so we can spawn their
		# puppets. The host replies with one _rpc_spawn_puppet call
		# per known peer.
		_rpc_request_roster.rpc_id(1)


func _attach_sync(tux: Node3D, owning_peer: int) -> void:
	var sync := NetPlayerSync.new()
	sync.name = "NetSync"
	sync.peer_id = owning_peer
	tux.add_child(sync)


func _spawn_puppet(peer_id: int) -> void:
	if _puppets.has(peer_id):
		return
	var puppet := TuxScene.instantiate() as Node3D
	puppet.name = "TuxPeer%d" % peer_id
	# The puppet has no input authority — the original peer owns it.
	# Its tux_player script will run but its _read_inputs is gated on
	# is_multiplayer_authority() so the state machine just idles.
	puppet.set_multiplayer_authority(peer_id)
	# Surface-snap at origin; the first sync packet will warp them to
	# wherever the owner actually is. Without an initial snap the
	# CharacterBody3D would fall through the void for a frame.
	var sy: float = WorldGen.height_at(0.0, 0.0) + 1.5
	puppet.position = Vector3(0, sy, 0)
	# Strip the camera_path so the puppet doesn't try to grab the
	# local camera. tux_player tolerates a null camera_path.
	if puppet.has_method("set"):
		puppet.set("camera_path", NodePath(""))
	add_child(puppet)
	_attach_sync(puppet, peer_id)
	_puppets[peer_id] = puppet


func _despawn_puppet(peer_id: int) -> void:
	var n: Node = _puppets.get(peer_id)
	if n and is_instance_valid(n):
		n.queue_free()
	_puppets.erase(peer_id)


func _on_peer_joined(peer_id: int) -> void:
	if peer_id == NetManager.local_id():
		return
	# Host: a new peer arrived; spawn a local puppet for them and
	# tell every other client to do the same.
	if NetManager.is_host:
		_spawn_puppet(peer_id)
		_rpc_spawn_puppet.rpc(peer_id)


func _on_peer_left(peer_id: int) -> void:
	_despawn_puppet(peer_id)
	if NetManager.is_host:
		_rpc_despawn_puppet.rpc(peer_id)


# ---- RPCs ---------------------------------------------------------------

# Host → all clients: existing peers in the room. Sent right after
# the host's world_disc finishes its own setup so a freshly-joined
# client can fill in any siblings the join sequence raced past.
@rpc("authority", "call_remote", "reliable")
func _rpc_announce_existing_peers() -> void:
	# Each peer asks the host for the roster from its own _ready;
	# nothing to do here in the broadcast case — kept as a hook for
	# future "everyone reload" semantics.
	pass


# Client → host: who else is in the room? Host replies with one
# _rpc_spawn_puppet for each peer (excluding the requester).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_roster() -> void:
	if not NetManager.is_host:
		return
	var requester: int = multiplayer.get_remote_sender_id()
	for pid in NetManager.peer_ids:
		if pid == requester:
			continue
		_rpc_spawn_puppet.rpc_id(requester, pid)
	# Also ensure the host itself appears in the requester's world.
	_rpc_spawn_puppet.rpc_id(requester, 1)


# Host → clients: spawn a puppet for `peer_id` locally.
@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_puppet(peer_id: int) -> void:
	if peer_id == NetManager.local_id():
		return
	_spawn_puppet(peer_id)


# Host → clients: a peer disconnected; drop their puppet.
@rpc("authority", "call_remote", "reliable")
func _rpc_despawn_puppet(peer_id: int) -> void:
	_despawn_puppet(peer_id)


# ---- Misc ---------------------------------------------------------------

func _spawn_starter_workbench() -> void:
	var wb_scene: PackedScene = load("res://scenes/workbench.tscn") as PackedScene
	if wb_scene == null:
		return
	var wb: Node3D = wb_scene.instantiate() as Node3D
	add_child(wb)
	var wx: float = 4.0
	var wz: float = -2.0
	var wy: float = WorldGen.height_at(wx, wz)
	wb.global_position = Vector3(wx, wy, wz)
	wb.rotation.y = PI    # face the player at spawn


# Replay every entry in GameState.placed_pieces under this level root.
# The entries are dicts in the shape `{piece_id, pos: {x,y,z}, yaw}`;
# BuildMode.instantiate_placed centralises the scene-load + transform
# math so this walker stays a one-liner per piece. Tolerates a missing
# BuildMode autoload (e.g. a future scene that doesn't ship the system).
func _restore_placed_pieces() -> void:
	if GameState == null:
		print("[world_disc] restore_placed_pieces: GameState null")
		return
	print("[world_disc] restore_placed_pieces: %d entries in GameState.placed_pieces"
			% GameState.placed_pieces.size())
	var bm: Node = get_node_or_null("/root/BuildMode")
	if bm == null or not bm.has_method("instantiate_placed"):
		print("[world_disc] restore_placed_pieces: BuildMode autoload missing!")
		return
	for entry in GameState.placed_pieces:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry as Dictionary
		var pos_raw: Variant = d.get("pos", null)
		if typeof(pos_raw) != TYPE_DICTIONARY:
			continue
		var pos_dict: Dictionary = pos_raw as Dictionary
		var pos: Vector3 = Vector3(
			float(pos_dict.get("x", 0.0)),
			float(pos_dict.get("y", 0.0)),
			float(pos_dict.get("z", 0.0))
		)
		var piece_id := String(d.get("piece_id", ""))
		var yaw_v := float(d.get("yaw", 0.0))
		print("[world_disc] restoring %s @ (%.1f, %.1f, %.1f) yaw=%.2f"
				% [piece_id, pos.x, pos.y, pos.z, yaw_v])
		var inst: Variant = bm.call("instantiate_placed", piece_id, pos, yaw_v, self)
		if inst == null:
			print("[world_disc]   → instantiate_placed returned null!")
