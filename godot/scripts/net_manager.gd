extends Node

# Autoload. Owns the ENet peer + the network state so the rest of the
# game can stay single-player aware: when network_state == DISCONNECTED
# every other system behaves exactly as before. Nothing in here talks
# to the game scene directly — world_disc.gd reads us on _ready and
# wires up peers from there.
#
# MVP scope:
#   * host()/join()/disconnect_all() — flips state, owns the peer
#   * tracks peer_ids on the host so world_disc can spawn puppets
#   * sync_world_seed() — host pushes its WorldGen.world_seed to a
#     joining client; the client applies it BEFORE the chunk streamer
#     starts producing geometry, which is enough for deterministic
#     terrain + biomes + foliage across peers
#
# What it deliberately does NOT do:
#   * spawn players (world_disc owns that)
#   * sync trees, animals, weather, time, inventory — each peer
#     simulates those locally
#   * chat / lobby / authoritative server semantics

enum NetworkState {
	DISCONNECTED,
	HOSTING,
	CONNECTED,
}

const DEFAULT_PORT: int = 24847
const MAX_PEERS: int = 8

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connected_to_host()
signal connection_failed()
signal disconnected()
# Fired on the client once the host's world seed has been applied to
# WorldGen. world_disc.gd waits for this before force-loading chunks.
signal world_seed_synced()

var network_state: int = NetworkState.DISCONNECTED
var is_host: bool = false
# All peer ids the host knows about (everyone except the host's own
# id 1). On the client this stays empty — clients just talk to the
# host and learn about siblings through spawn RPCs in world_disc.
var peer_ids: Array[int] = []

# Cached so the client can ack-and-forget — once we've received the
# seed we ignore further pushes (host could have re-set it during a
# late join cycle, but for MVP one is enough).
var _seed_applied: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---- Lifecycle ----------------------------------------------------------

func host(port: int = DEFAULT_PORT) -> bool:
	if network_state != NetworkState.DISCONNECTED:
		push_warning("[NetManager] host() called while not disconnected")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		push_error("[NetManager] create_server(%d) failed: %s" % [port, error_string(err)])
		return false
	multiplayer.multiplayer_peer = peer
	network_state = NetworkState.HOSTING
	is_host = true
	peer_ids.clear()
	_seed_applied = true   # host is the source of truth, no sync needed
	print("[NetManager] Hosting on port %d" % port)
	return true


func join(ip: String, port: int = DEFAULT_PORT) -> bool:
	if network_state != NetworkState.DISCONNECTED:
		push_warning("[NetManager] join() called while not disconnected")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("[NetManager] create_client(%s:%d) failed: %s" % [ip, port, error_string(err)])
		return false
	multiplayer.multiplayer_peer = peer
	# Flip state optimistically — world_disc.gd checks is_active() in
	# _ready, which runs the instant we change scene below in
	# main_menu. If the connection actually fails, _on_connection_failed
	# clears state back to DISCONNECTED. The handshake-complete signal
	# is `connected_to_host` for anything that cares about the wire
	# being up vs. just intent to join.
	network_state = NetworkState.CONNECTED
	is_host = false
	peer_ids.clear()
	_seed_applied = false
	print("[NetManager] Connecting to %s:%d" % [ip, port])
	return true


func disconnect_all() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var was: int = network_state
	network_state = NetworkState.DISCONNECTED
	is_host = false
	peer_ids.clear()
	_seed_applied = false
	if was != NetworkState.DISCONNECTED:
		disconnected.emit()
	print("[NetManager] Disconnected")


# ---- Multiplayer callbacks ----------------------------------------------

func _on_peer_connected(id: int) -> void:
	# On the host: a new client showed up. Track them and push the
	# world seed so their WorldGen matches ours before any chunk
	# generates. On the client: this fires for every other client we
	# learn about (Godot mirrors the peer list); we just record them
	# so world_disc can spawn puppets.
	if is_host:
		if not peer_ids.has(id):
			peer_ids.append(id)
		_rpc_set_world_seed.rpc_id(id, WorldGen.world_seed)
	peer_joined.emit(id)
	print("[NetManager] Peer connected: %d" % id)


func _on_peer_disconnected(id: int) -> void:
	if is_host:
		peer_ids.erase(id)
	peer_left.emit(id)
	print("[NetManager] Peer disconnected: %d" % id)


func _on_connected_to_server() -> void:
	network_state = NetworkState.CONNECTED
	connected_to_host.emit()
	print("[NetManager] Connected to host as peer %d" % multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	push_warning("[NetManager] Connection failed")
	connection_failed.emit()
	disconnect_all()


func _on_server_disconnected() -> void:
	push_warning("[NetManager] Server disconnected")
	disconnect_all()


# ---- RPCs ---------------------------------------------------------------

# Host → joining client: here's the world seed, set yours to match
# before anyone generates chunks. Reliable + authority-only so a
# misbehaving client can't poison its sibling's terrain. The client
# applies it idempotently — second call is a no-op.
@rpc("authority", "call_remote", "reliable")
func _rpc_set_world_seed(new_seed: int) -> void:
	if _seed_applied:
		return
	WorldGen.world_seed = new_seed
	# WorldGen's noise objects are built in its _ready() against the
	# initial seed. Re-seed them now so height_at()/biome lookups use
	# the host's seed. We mirror the same offsets WorldGen uses so
	# every channel lines up.
	if WorldGen.has_method("rebuild_noise"):
		WorldGen.rebuild_noise()
	else:
		_reseed_world_gen_noise(new_seed)
	_seed_applied = true
	world_seed_synced.emit()
	print("[NetManager] World seed synced: %d" % new_seed)


# Fallback: rebuild WorldGen's FastNoiseLite seeds in place. WorldGen
# names them with predictable offsets (+0..+7); we mirror that here so
# we don't have to add a method to world_gen.gd. If WorldGen ever grows
# more noise channels we should switch to having it expose a
# rebuild_noise() of its own.
func _reseed_world_gen_noise(s: int) -> void:
	var fields := [
		"_mountain_noise", "_hills_noise", "_detail_noise",
		"_biome_noise", "_continent_noise", "_river_noise",
		"_density_noise", "_cluster_noise",
	]
	for i in fields.size():
		var n: FastNoiseLite = WorldGen.get(fields[i])
		if n != null:
			n.seed = s + i


# ---- Helpers ------------------------------------------------------------

func is_active() -> bool:
	return network_state != NetworkState.DISCONNECTED


func local_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 0
	return multiplayer.get_unique_id()


# True when this peer's WorldGen seed matches the host's (host: always
# true; client: true once _rpc_set_world_seed has landed). world_disc
# checks this before starting the chunk streamer.
func has_synced_seed() -> bool:
	return _seed_applied
