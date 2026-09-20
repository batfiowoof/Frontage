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
const Ai := preload("res://sim/ai.gd")
const Replay := preload("res://net/replay.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")

const PORT := 7777
const MAX_CLIENTS := 7
const MAX_CATCHUP := 0.25          # seconds of simulation we will chew in one frame
## How often an AI reconsiders a battle. Every tick would be pointless -- orders take
## seconds to carry out -- and it would also thrash the order log.
const AI_THINK_TICKS := 20

signal battle_updated(battle)      # server: stepped. client: snapshot decoded.
signal campaign_updated(campaign)  # turn-based, so this fires on every change
signal players_changed
signal order_rejected(peer_id, reason)
signal news(text)          # something happened that a player should be told about
signal replay_saved(path)
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

## AI seats. Keyed by a NEGATIVE id, which no ENet peer can ever be, so an AI is a
## player everywhere that matters -- seating, colours, the end-turn ready check --
## without any special case in the order pipeline.
var _ais := {}                     # seat id -> Ai
var _ai_ticks := 0

## Every battle is recorded. It costs a few hundred bytes and it is the only way to
## watch the same fight twice with one constant changed.
var _recorder = null
var _playback = null               # set while watching one back
var _playback_schedule := {}

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


## `as_player` false runs the server without taking a seat, which is what a machine
## watching two AIs play needs -- otherwise the host holds a seat nobody is playing
## and the end-turn ready check waits on it forever.
func host(port := PORT, as_player := true) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	players = {1: "host"} if as_player else {}
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


## Server only. Add an AI player; call before start_campaign().
func add_ai() -> int:
	assert(is_server(), "only the server runs the opposition")
	var seat := -1
	while players.has(seat):
		seat -= 1
	players[seat] = "AI %d" % (-seat)
	_ais[seat] = Ai.new(seat)
	players_changed.emit()
	return seat


func ai_count() -> int:
	return _ais.size()


func close() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	_ais.clear()
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


## Watch a recorded battle. The orders are fed back in on the ticks they were given, so
## what you see is the fight that happened, not an approximation of it.
func play_replay(r) -> bool:
	assert(is_server(), "only the server owns a battle")
	var bs = Snapshot.decode_battle(r.opening)
	if bs == null:
		return false
	_playback = r
	_playback_schedule = r.by_tick()
	_battle_armies.clear()
	_battle_tile = -1
	_battle_seconds = 0.0
	battle = bs
	running = true
	battle_epoch += 1
	_recorder = null                   # watching one is not making another
	_announce("replaying a battle: %d regiments, %d ticks" % [bs.regiments.size(), r.ticks])
	broadcast_battle()
	battle_updated.emit(battle)
	return true


## Drop straight into a battle with no campaign behind it, for tuning how the
## thing feels to drive. Two mirrored lines, so anything that decides the fight is
## something a player did.
func start_demo_battle() -> void:
	assert(is_server(), "only the server owns a battle")
	var seats := player_ids()
	var left: int = seats[0] if seats.size() > 0 else 1
	var right: int = seats[1] if seats.size() > 1 else left
	# Cavalry on one wing on purpose: the demo exists to answer whether a flank reads,
	# and a line with nothing that can outrun it cannot produce one.
	var line := [&"cavalry", &"spear", &"pike", &"sword", &"archer"]
	var bs = BattleState.new()
	for i in line.size():
		var y := (float(i) - float(line.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(left, line[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(right, line[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)
	_battle_armies.clear()
	_battle_tile = -1
	_battle_seconds = 0.0
	_announce("demo battle: %d regiments a side" % line.size())
	start_battle(bs)


## Server only: put a battle on the table and start ticking it.
func start_battle(bs: BattleState) -> void:
	assert(is_server(), "only the server owns a battle")
	battle = bs
	running = true
	battle_epoch += 1
	_recorder = Replay.new()
	_recorder.begin(Snapshot.encode_battle(bs))
	_accum = 0.0
	_since_snapshot = 0
	broadcast_battle()


func stop_battle() -> void:
	running = false


# --- simulation -----------------------------------------------------------

func _process(delta: float) -> void:
	if not is_server():
		return
	_think_for_ais()
	if not running or battle == null:
		return
	# A long frame (loading, a breakpoint) must not make us simulate for a minute
	# afterwards; drop the excess rather than stall every client.
	_accum = minf(_accum + delta, MAX_CATCHUP)
	while _accum >= Rules.TICK_DELTA:
		_accum -= Rules.TICK_DELTA
		if _playback != null:
			for row: Array in _playback_schedule.get(battle.tick, []):
				Replay.apply_order(battle, row[1], row[2])
		battle.step()
		battle_updated.emit(battle)
		_battle_seconds += Rules.TICK_DELTA
		_since_snapshot += 1
		if _since_snapshot >= Rules.SNAPSHOT_EVERY_N_TICKS:
			_since_snapshot = 0
			broadcast_battle()
		if _playback != null:
			if battle.tick >= _playback.ticks:
				_announce("replay over")
				_playback = null
				_playback_schedule.clear()
				stop_battle()
			continue
		if battle.is_over() or _battle_seconds >= Rules.BATTLE_TIME_LIMIT:
			broadcast_battle()
			_finish_battle()
			return


## Polled from _process rather than hung off campaign_updated: an AI order triggers
## that signal, and an AI that thinks on its own output recurses until the stack ends.
func _think_for_ais() -> void:
	if _ais.is_empty():
		return
	if battle != null:
		_ai_ticks += 1
		if _ai_ticks < AI_THINK_TICKS:
			return
		_ai_ticks = 0
		for seat in _ais:
			for bytes: PackedByteArray in _ais[seat].battle_orders(battle):
				_receive_order(seat, bytes)
		return
	if campaign != null:
		for seat in _ais:
			for bytes: PackedByteArray in _ais[seat].campaign_orders(campaign):
				_receive_order(seat, bytes)


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


func order_build(tile: int, building: StringName) -> void:
	submit(Orders.build(tile, building))


func _receive_order(sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty():
		_reject(sender, "malformed order")
		return
	if order["type"] == Orders.Type.BATTLE_MOVE and battle != null and _recorder != null:
		_recorder.note(battle.tick, sender, bytes)
	match order["type"]:
		Orders.Type.BATTLE_MOVE:
			_battle_move(sender, order)
		Orders.Type.ARMY_MOVE:
			_army_move(sender, order)
		Orders.Type.RECRUIT:
			_recruit(sender, order)
		Orders.Type.READY:
			_set_ready(sender, order)
		Orders.Type.BUILD:
			_build(sender, order)


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


func _build(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	if not campaign.build(sender, order["tile"], order["building"]):
		_reject(sender, "cannot build %s at tile %d" % [order["building"], order["tile"]])
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
	var result := Autoresolve.resolve(attacker["regiments"], defender["regiments"], _rng,
		campaign.defense_at(defender["tile"], defender["owner"]))
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
	var fortified := campaign.defense_at(_battle_tile, defender["owner"])
	_deploy(bs, attacker, -Rules.DEPLOY_SEPARATION * 0.5, 0.0, 0.0)
	_deploy(bs, defender, Rules.DEPLOY_SEPARATION * 0.5, PI, fortified)
	if fortified > 0.0:
		_announce("the defenders are behind walls at tile %d" % _battle_tile)
	_announce("battle at tile %d: %d men against %d" % [
		_battle_tile, CampaignState.army_men(attacker), CampaignState.army_men(defender)])
	start_battle(bs)


func _deploy(bs: BattleState, army: Dictionary, x: float, facing: float, defense := 0.0) -> void:
	var line: Array = army["regiments"]
	for i in line.size():
		var y := (float(i) - float(line.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		var r = bs.add(army["owner"], line[i][0], Vector2(x, y), facing)
		r.strength = int(line[i][1])          # it arrives as battered as it left
		r.defense = defense


## The battle is over: survivors go back into their campaign army and the campaign
## picks up where it left off. This is the seam the whole design turns on, so it is
## deliberately one function you can read top to bottom.
func _finish_battle() -> void:
	_keep_the_recording()
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

	if _battle_armies.is_empty():
		_announce("demo battle over: player %d held the field" % winner_id)
		_battle_over.rpc(battle_epoch)
		battle_updated.emit(null)
		return

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


## A battle that has finished is worth keeping. Verifying it here is cheap and catches
## the one thing that would make the whole format worthless: a recording that does not
## reproduce the battle it came from.
func _keep_the_recording() -> void:
	if _recorder == null or battle == null:
		return
	_recorder.finish(Snapshot.encode_battle(battle), battle.tick)
	if not _recorder.verify():
		push_warning("[replay] a battle did not reproduce itself -- something in the sim is not deterministic")
	var path: String = _recorder.save()
	_recorder = null
	if not path.is_empty():
		print("[replay] saved %s" % path)
		replay_saved.emit(path)


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
