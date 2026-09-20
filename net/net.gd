extends Node
## Transport and authority. The only file in the project that touches MultiplayerAPI.
##
## Listen server: the host runs the simulation AND plays. The host's own clicks go
## through _receive_order exactly like a remote client's — see `submit` below. There is
## no path from the view layer to the sim that skips validation, and there must never be.

const Rules := preload("res://sim/rules.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")

const PORT := 7777
const MAX_CLIENTS := 7
const MAX_CATCHUP := 0.25          # seconds of simulation we will chew in one frame

signal battle_updated(battle)      # server: stepped. client: snapshot decoded.
signal players_changed
signal order_rejected(peer_id, reason)
signal connection_failed
signal server_left

## Server: the authoritative battle. Client: a decoded mirror, never stepped locally.
var battle: BattleState = null
var players := {}                  # peer_id -> display name
var running := false               # is the battle sim ticking?

var _accum := 0.0
var _since_snapshot := 0


func is_server() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0


func host(port := PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	players = {1: "host"}
	players_changed.emit()
	return OK


func join(address: String, port := PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.connection_failed.connect(func(): connection_failed.emit())
	multiplayer.server_disconnected.connect(func(): server_left.emit())
	return OK


func close() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	battle = null
	running = false


## Server only: put a battle on the table and start ticking it.
func start_battle(bs: BattleState) -> void:
	assert(is_server(), "only the server owns a battle")
	battle = bs
	running = true
	_accum = 0.0
	_since_snapshot = 0
	broadcast_battle()


func stop_battle() -> void:
	running = false


# --- simulation -----------------------------------------------------------

func _process(delta: float) -> void:
	if not running or battle == null or not is_server():
		return
	# A long frame (loading, a breakpoint) must not make us simulate for a minute
	# afterwards; drop the excess rather than stall every client.
	_accum = minf(_accum + delta, MAX_CATCHUP)
	while _accum >= Rules.TICK_DELTA:
		_accum -= Rules.TICK_DELTA
		battle.step()
		battle_updated.emit(battle)
		_since_snapshot += 1
		if _since_snapshot >= Rules.SNAPSHOT_EVERY_N_TICKS:
			_since_snapshot = 0
			broadcast_battle()


func broadcast_battle() -> void:
	if battle != null and multiplayer.has_multiplayer_peer() and is_server():
		_battle_snapshot.rpc(Snapshot.encode_battle(battle))


# --- orders ---------------------------------------------------------------

## Called by the view layer on every machine, host included. Never mutates the sim.
func submit(bytes: PackedByteArray) -> void:
	if is_server():
		# Deliberately the same function a remote order lands in, not a shortcut.
		# rpc_id-to-self semantics are ambiguous enough that going direct is clearer.
		_receive_order(my_id(), bytes)
	else:
		submit_order.rpc_id(1, bytes)


func order_battle_move(ids: PackedInt32Array, target: Vector2, facing: float) -> void:
	submit(Orders.battle_move(ids, target, facing))


@rpc("any_peer", "call_remote", "reliable")
func submit_order(bytes: PackedByteArray) -> void:
	if not is_server():
		return                     # a client that receives an "order" is being lied to
	_receive_order(multiplayer.get_remote_sender_id(), bytes)


func _receive_order(sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty():
		_reject(sender, "malformed order")
		return
	if battle == null:
		_reject(sender, "no battle in progress")
		return
	for id in order["ids"]:
		var r := battle.get_regiment(id)
		if r == null:
			_reject(sender, "regiment %d does not exist" % id)
			continue
		if r.owner_id != sender:
			_reject(sender, "regiment %d belongs to %d" % [id, r.owner_id])
			continue
		r.order_move(order["target"], order["facing"])


func _reject(peer_id: int, reason: String) -> void:
	push_warning("[net] rejected order from %d: %s" % [peer_id, reason])
	order_rejected.emit(peer_id, reason)


# --- snapshots ------------------------------------------------------------

@rpc("authority", "call_remote", "unreliable_ordered")
func _battle_snapshot(bytes: PackedByteArray) -> void:
	var bs = Snapshot.decode_battle(bytes)
	if bs == null:
		push_warning("[net] dropped an undecodable snapshot (%d bytes)" % bytes.size())
		return
	# unreliable_ordered drops late packets but cannot resurrect them; ignore anything
	# older than what we already have rather than rewinding the world.
	if battle != null and bs.tick < battle.tick:
		return
	battle = bs
	battle_updated.emit(battle)


# --- peers ----------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	players[id] = "player %d" % id
	players_changed.emit()
	if battle != null:
		broadcast_battle()


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	players_changed.emit()
