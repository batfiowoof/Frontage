extends Node
## Transport and authority. The only file in the project that touches MultiplayerAPI.
##
## Listen server: the host runs the simulation AND plays. The host's own clicks go
## through _receive_order exactly like a remote client's — see `submit` below. There is
## no path from the view layer to the sim that skips validation, and there must never be.

const Rules := preload("res://sim/rules.gd")
const BattleState := preload("res://sim/battle_state.gd")
const CampaignState := preload("res://sim/campaign_state.gd")
const Autoresolve := preload("res://sim/autoresolve.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")

const PORT := 7777
const MAX_CLIENTS := 7
const MAX_CATCHUP := 0.25          # seconds of simulation we will chew in one frame

signal battle_updated(battle)      # server: stepped. client: snapshot decoded.
signal campaign_updated(campaign)  # turn-based, so this fires on every change
signal players_changed
signal order_rejected(peer_id, reason)
signal news(text)          # something happened that a player should be told about
signal connection_failed
signal server_left

## Server: the authoritative world. Client: a decoded mirror, never stepped locally.
var battle: BattleState = null
var campaign: CampaignState = null
var players := {}                  # peer_id -> display name
var running := false               # is the battle sim ticking?

## The exact bytes the server last sent us. Kept so a client can prove its mirror is
## the server's state and not merely a self-consistent decode of its own encode.
var last_battle_bytes := PackedByteArray()
var last_campaign_bytes := PackedByteArray()

var _accum := 0.0
var _since_snapshot := 0
var _rng := RandomNumberGenerator.new()

## While a battle runs the campaign is frozen. These remember what to put back.
var _battle_armies := {}           # owner_id -> campaign army id
var _battle_tile := -1
var _battle_attacker := 0
var _battle_seconds := 0.0

## Snapshots go out unreliably and the end-of-battle message goes out reliably, and
## nothing orders one against the other. Without an epoch, a snapshot still in flight
## when the battle ends arrives afterwards and resurrects it on the client, which then
## waits forever for a second ending. Numbering the battles makes the stale packet
## obviously stale.
var battle_epoch := 0
var _dead_epoch := -1


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


## Everyone in the lobby, in a stable order, so colours and turn order agree.
func player_ids() -> Array:
	var ids := players.keys()
	ids.sort()
	return ids


func close() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	battle = null
	campaign = null
	running = false


## Server only: deal a fresh campaign and tell everyone about it.
func start_campaign(map_seed := 0) -> void:
	assert(is_server(), "only the server owns the world")
	if map_seed == 0:
		map_seed = randi()
	campaign = CampaignState.generate(player_ids(), map_seed)
	broadcast_campaign()
	campaign_updated.emit(campaign)


func broadcast_campaign() -> void:
	if campaign != null and multiplayer.has_multiplayer_peer() and is_server():
		_campaign_snapshot.rpc(Snapshot.encode_campaign(campaign))


## Server only: put a battle on the table and start ticking it.
func start_battle(bs: BattleState) -> void:
	assert(is_server(), "only the server owns a battle")
	battle = bs
	running = true
	battle_epoch += 1
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
		_battle_seconds += Rules.TICK_DELTA
		_since_snapshot += 1
		if _since_snapshot >= Rules.SNAPSHOT_EVERY_N_TICKS:
			_since_snapshot = 0
			broadcast_battle()
		if battle.is_over() or _battle_seconds >= Rules.BATTLE_TIME_LIMIT:
			broadcast_battle()
			_finish_battle()
			return


func broadcast_battle() -> void:
	if battle != null and multiplayer.has_multiplayer_peer() and is_server():
		_battle_snapshot.rpc(battle_epoch, Snapshot.encode_battle(battle))


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


func order_army_move(army_id: int, dest_tile: int) -> void:
	submit(Orders.army_move(army_id, dest_tile))


func order_recruit(tile: int, kind: StringName) -> void:
	submit(Orders.recruit(tile, kind))


func order_ready(value: bool) -> void:
	submit(Orders.ready(value))


func _receive_order(sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty():
		_reject(sender, "malformed order")
		return
	match order["type"]:
		Orders.Type.BATTLE_MOVE:
			_battle_move(sender, order)
		Orders.Type.ARMY_MOVE:
			_army_move(sender, order)
		Orders.Type.RECRUIT:
			_recruit(sender, order)
		Orders.Type.READY:
			_set_ready(sender, order)


# --- campaign orders ------------------------------------------------------

func _army_move(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	var a = campaign.armies.get(order["army_id"])
	if a == null:
		_reject(sender, "army %d does not exist" % order["army_id"])
		return
	if a["owner"] != sender:
		_reject(sender, "army %d belongs to %d" % [order["army_id"], a["owner"]])
		return
	var result: Dictionary = campaign.move_army(order["army_id"], order["dest"])
	broadcast_campaign()
	campaign_updated.emit(campaign)
	if not result["collision"].is_empty():
		_on_armies_met(result["collision"])


func _recruit(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	if not campaign.recruit(sender, order["tile"], order["kind"]):
		_reject(sender, "cannot recruit %s at tile %d" % [order["kind"], order["tile"]])
		return
	broadcast_campaign()
	campaign_updated.emit(campaign)


func _set_ready(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	campaign.set_ready(sender, order["value"])
	if campaign.all_ready(player_ids()):
		campaign.end_turn()
	broadcast_campaign()
	campaign_updated.emit(campaign)


## Two armies have met. For now the dice decide; M7 hands this to the real battle.
## The loop that matters -- march, fight, take losses, march on -- closes here.
func _on_armies_met(pair: Array) -> void:
	var attacker = campaign.armies.get(pair[0])
	var defender = campaign.armies.get(pair[1])
	if attacker == null or defender == null:
		return
	# Two humans fight it out. Anything else is not worth making a player watch.
	if players.has(attacker["owner"]) and players.has(defender["owner"]):
		_begin_battle(attacker, defender)
	else:
		_autoresolve(attacker, defender)


func _autoresolve(attacker: Dictionary, defender: Dictionary) -> void:
	var contested: int = defender["tile"]
	var result := Autoresolve.resolve(attacker["regiments"], defender["regiments"], _rng)
	for i in result["attacker_losses"]:
		attacker["regiments"].pop_back()
	for i in result["defender_losses"]:
		defender["regiments"].pop_back()
	var winner_id: int = attacker["owner"] if result["attacker_wins"] else defender["owner"]
	_announce("battle at tile %d: player %d carried the field (%d and %d regiments lost)" % [
		contested, winner_id, result["attacker_losses"], result["defender_losses"]])
	_settle_field(attacker, defender, contested, result["attacker_wins"])


## Deploy both armies and hand the tile to the real-time battle.
func _begin_battle(attacker: Dictionary, defender: Dictionary) -> void:
	_battle_tile = defender["tile"]
	_battle_attacker = attacker["owner"]
	_battle_armies = {attacker["owner"]: attacker["id"], defender["owner"]: defender["id"]}
	_battle_seconds = 0.0

	var bs = BattleState.new()
	_deploy(bs, attacker, -Rules.DEPLOY_SEPARATION * 0.5, 0.0)
	_deploy(bs, defender, Rules.DEPLOY_SEPARATION * 0.5, PI)
	_announce("battle at tile %d: %d men against %d" % [
		_battle_tile, CampaignState.army_men(attacker), CampaignState.army_men(defender)])
	start_battle(bs)


func _deploy(bs: BattleState, army: Dictionary, x: float, facing: float) -> void:
	var line: Array = army["regiments"]
	for i in line.size():
		var y := (float(i) - float(line.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		var r = bs.add(army["owner"], line[i][0], Vector2(x, y), facing)
		r.strength = int(line[i][1])          # it arrives as battered as it left


## The battle is over: survivors go back into their campaign army and the campaign
## picks up where it left off. This is the seam the whole design turns on, so it is
## deliberately one function you can read top to bottom.
func _finish_battle() -> void:
	var survivors := {}
	for id in battle.sorted_ids():
		var r = battle.regiments[id]
		if r.is_alive():
			var owner: int = r.owner_id
			if not survivors.has(owner):
				survivors[owner] = []
			survivors[owner].append([r.kind, r.strength])

	var winner_id: int = battle.winner()
	stop_battle()
	battle = null

	var attacker = null
	var defender = null
	for owner in _battle_armies:
		var army = campaign.armies.get(_battle_armies[owner])
		if army == null:
			continue
		army["regiments"] = survivors.get(owner, [])
		if owner == _battle_attacker:
			attacker = army
		else:
			defender = army

	_announce("the field at tile %d goes to player %d" % [_battle_tile, winner_id])
	if attacker != null and defender != null:
		_settle_field(attacker, defender, _battle_tile, winner_id == _battle_attacker)
	_battle_armies.clear()
	_battle_over.rpc(battle_epoch)
	battle_updated.emit(null)


@rpc("authority", "call_remote", "reliable")
func _battle_over(epoch: int) -> void:
	_dead_epoch = maxi(_dead_epoch, epoch)
	battle = null
	battle_updated.emit(null)


## Disband what is gone, give the ground to whoever is still standing on it, and
## report anyone who has been knocked out of the game.
func _settle_field(attacker: Dictionary, defender: Dictionary, contested: int, attacker_wins: bool) -> void:
	var owners := [attacker["owner"], defender["owner"]]
	# A battle ends both armies' turn. Without this a survivor with movement left
	# simply attacks again, and two armies on adjacent tiles grind through three
	# battles a turn until somebody's move points run out.
	attacker["move_left"] = 0
	defender["move_left"] = 0
	campaign.disband_if_empty(attacker["id"])
	campaign.disband_if_empty(defender["id"])
	if attacker_wins and not campaign.armies.has(defender["id"]):
		attacker["tile"] = contested
		campaign._capture_if_undefended(attacker)
	for owner in owners:
		if not campaign.is_alive(owner):
			_announce("player %d has been driven from the map" % owner)
	broadcast_campaign()
	campaign_updated.emit(campaign)


func _announce(text: String) -> void:
	print("[net] " + text)
	_news.rpc(text)
	news.emit(text)


@rpc("authority", "call_remote", "reliable")
func _news(text: String) -> void:
	news.emit(text)


# --- battle orders --------------------------------------------------------

func _battle_move(sender: int, order: Dictionary) -> void:
	if battle == null:
		_reject(sender, "no battle in progress")
		return
	for id in order["ids"]:
		var r = battle.get_regiment(id)
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

@rpc("authority", "call_remote", "reliable")
func _campaign_snapshot(bytes: PackedByteArray) -> void:
	var cs = Snapshot.decode_campaign(bytes)
	if cs == null:
		push_warning("[net] dropped an undecodable campaign snapshot (%d bytes)" % bytes.size())
		return
	campaign = cs
	last_campaign_bytes = bytes
	campaign_updated.emit(campaign)


@rpc("authority", "call_remote", "unreliable_ordered")
func _battle_snapshot(epoch: int, bytes: PackedByteArray) -> void:
	if epoch <= _dead_epoch:
		return                     # a packet from a battle that is already over
	var bs = Snapshot.decode_battle(bytes)
	if bs == null:
		push_warning("[net] dropped an undecodable snapshot (%d bytes)" % bytes.size())
		return
	# unreliable_ordered drops late packets but cannot resurrect them; ignore anything
	# older than what we already have rather than rewinding the world.
	if battle != null and bs.tick < battle.tick:
		return
	battle = bs
	last_battle_bytes = bytes
	battle_updated.emit(battle)


# --- peers ----------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	players[id] = "player %d" % id
	players_changed.emit()
	if battle != null:
		broadcast_battle()
	if campaign != null:
		broadcast_campaign()


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	players_changed.emit()
