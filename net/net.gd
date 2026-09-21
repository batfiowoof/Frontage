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
const Jev := preload("res://net/jev.gd")
const Replay := preload("res://net/replay.gd")
const Save := preload("res://net/save.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")

const PORT := 7777
const MAX_CLIENTS := 7
const MAX_CATCHUP := 0.25          # seconds of simulation we will chew in one frame
## How often an AI reconsiders a battle, in SIM TICKS -- 7 of them at TICK_HZ 20, so a
## third of a second on every machine. It used to count frames, which meant the
## opposition thought 2.4x more often on a 144 Hz monitor than on a 60 Hz one and a
## loaded host played a different battle from an idle one.
##
## It must not go much lower. `order_move` is not idempotent: it sets a regiment back to
## MOVING, and IDLE is what gates shooting, morale recovery and stamina recovery. An
## archer re-ordered every tick is never IDLE, so it never looses, never empties its
## quiver, never joins the line, and the battle never ends.
const AI_THINK_TICKS := 7

signal battle_updated(battle)      # server: stepped. client: snapshot decoded.
signal campaign_updated(campaign)  # turn-based, so this fires on every change
signal players_changed
signal order_rejected(peer_id, reason)
signal news(text)          # something happened that a player should be told about
signal replay_saved(path)
signal campaign_saved(path)
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
var _last_think_tick := -1         # battle.tick the AIs last thought on

## Jev scores the AI's decisions when there is a key for it, and is simply absent when
## there is not. It never issues an order; it writes into an Ai's `advice` and the Ai
## goes on producing the same validated orders it always did.
var _jev = null

## Turned off by the headless harnesses. A gate that reaches across the internet fails
## when somebody else's API is slow or down, which says nothing about this game, and
## aitest.cmd budgets its whole run in real seconds so a few round trips a turn are
## enough to tip it over. Jev is for playing against, not for proving the sim works.
var use_jev := true

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
## The seat that threw in the towel, or 0. Read instead of battle.winner() when set,
## because a side that quits has lost the field whatever its regiments were still doing.
var _battle_forfeit := 0

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
	_roster_changed()
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


## The roster changed, so tell everybody before saying so locally.
##
## `players` was server state that four view call sites treated as global truth --
## Colors.of_owner() takes the seating and falls back to NEUTRAL for an id it cannot
## find, so on a joined client, where `players` was empty for the whole session, BOTH
## ARMIES DREW THE SAME GREY. So did the strength bars, the settlements and the armies on
## the campaign map. `join()` sets up the transport and nothing ever sent it a roster.
func _roster_changed() -> void:
	if multiplayer.has_multiplayer_peer() and is_server():
		var seats := player_ids()
		var names := []
		for seat in seats:
			names.append(players[seat])
		_roster.rpc(seats, names)
	players_changed.emit()


## Seats as an ORDERED array rather than the dictionary: the order is the thing that
## decides colour, so sending it explicitly is what makes host and client agree by
## construction instead of by both happening to sort the same way.
@rpc("authority", "call_remote", "reliable")
func _roster(seats: Array, names: Array) -> void:
	if seats.size() != names.size():
		return                             # off the network, so it is not to be trusted
	players.clear()
	for i in seats.size():
		if typeof(seats[i]) != TYPE_INT:
			continue
		players[seats[i]] = str(names[i])
	players_changed.emit()


## Server only. Add an AI player; call before start_campaign().
func add_ai() -> int:
	assert(is_server(), "only the server runs the opposition")
	var seat := -1
	while players.has(seat):
		seat -= 1
	players[seat] = "AI %d" % (-seat)
	_ais[seat] = Ai.new(seat)
	if use_jev and _jev == null and Jev.have_key():
		_jev = Jev.new()
		add_child(_jev)
		news.emit("Jev is advising the opposition")
	_roster_changed()
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


## Server only. A campaign is only coherent between battles, so saving mid-fight is
## refused rather than half-done.
func save_campaign(path := "") -> String:
	if not is_server() or campaign == null or battle != null:
		return ""
	var written: String = Save.of(campaign, player_ids()).save(path)
	if not written.is_empty():
		_announce("campaign saved: %s" % written)
		campaign_saved.emit(written)
	return written


## Server only. Everyone has to be here first: the seats are filled in order, so a
## different number of players is a different game.
func load_campaign(path: String) -> bool:
	if not is_server():
		return false
	var file = Save.load_from(path)
	if file == null:
		push_warning("[save] %s will not load" % path)
		return false
	var restored = file.restore(player_ids())
	if restored == null:
		push_warning("[save] that save wants %d players and %d are here" % [
			file.seats.size(), player_ids().size()])
		return false
	campaign = restored
	broadcast_campaign()
	campaign_updated.emit(campaign)
	_announce("campaign loaded from turn %d" % campaign.turn)
	return true


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
	_battle_forfeit = 0
	_battle_tile = -1
	_battle_seconds = 0.0
	_battle_forfeit = 0
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
	bs.lay_ground(1, 20260921)          # a wooded field, so the demo has ground to use
	for i in line.size():
		var y := (float(i) - float(line.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(left, line[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(right, line[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)
	_battle_armies.clear()
	_battle_forfeit = 0
	_battle_tile = -1
	_battle_seconds = 0.0
	_battle_forfeit = 0
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
		if battle.is_over() or _battle_forfeit != 0 \
				or _battle_seconds >= Rules.BATTLE_TIME_LIMIT:
			broadcast_battle()
			_finish_battle()
			return


## True when `every` sim ticks have gone by since the AIs last thought.
##
## `last < 0` is the first think of a battle. `now < last` is a NEW battle, whose tick
## counter has restarted below a stale value from the last one -- without that clause the
## opposition would stand still until the new fight counted its way back up, which at 20
## Hz is minutes. The guard lives here rather than as a reset in `start_battle`, so every
## caller gets it instead of whoever remembers.
static func due(now: int, last: int, every: int) -> bool:
	return last < 0 or now < last or now - last >= every


## Polled from _process rather than hung off campaign_updated: an AI order triggers
## that signal, and an AI that thinks on its own output recurses until the stack ends.
func _think_for_ais() -> void:
	if _ais.is_empty():
		return
	if battle != null:
		if not due(battle.tick, _last_think_tick, AI_THINK_TICKS):
			return
		_last_think_tick = battle.tick
		for seat in _ais:
			# Never gated on the answer: a 20 Hz battle cannot wait on a network, so the
			# posture lands a few ticks after the state it was asked about and the fight
			# carries on meanwhile.
			if _jev != null:
				_jev.consider_battle(seat, battle, _ais[seat])
			for bytes: PackedByteArray in _ais[seat].battle_orders(battle):
				_receive_order(seat, bytes)
		return
	if campaign != null:
		for seat in _ais:
			# Asked once at the top of the turn. While the answer is out the AI is held
			# back entirely -- campaign_orders is what appends End Turn, so holding it
			# holds the turn rather than spending the money twice. A timeout clears it.
			if _jev != null and _jev.consider_turn(seat, campaign, _ais[seat]):
				continue
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


func order_set_formation(ids: PackedInt32Array, shape: StringName, width := 0) -> void:
	submit(Orders.set_formation(ids, shape, width))


func order_focus(ids: PackedInt32Array, mark: int) -> void:
	submit(Orders.focus(ids, mark))


func order_raze(army_id: int) -> void:
	submit(Orders.raze(army_id))


## Give up the battle. Goes through submit() like every other order, so the host's own
## surrender travels the same path a remote one does.
func order_forfeit() -> void:
	submit(Orders.forfeit(true))


func order_stance(ids: PackedInt32Array, mask: int) -> void:
	submit(Orders.stance(ids, mask))


func order_research(tech: StringName) -> void:
	submit(Orders.research(tech))


func order_merge(army_id: int, into_id: int) -> void:
	submit(Orders.merge(army_id, into_id))


func order_split(army_id: int, indices: PackedInt32Array, to_tile: int) -> void:
	submit(Orders.split(army_id, indices, to_tile))


func _receive_order(sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty():
		_reject(sender, "malformed order")
		return
	if battle != null and _recorder != null and (order["type"] == Orders.Type.BATTLE_MOVE
			or order["type"] == Orders.Type.SET_FORMATION or order["type"] == Orders.Type.FOCUS
			or order["type"] == Orders.Type.STANCE):
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
		Orders.Type.SET_FORMATION:
			_set_formation(sender, order)
		Orders.Type.FOCUS:
			_focus(sender, order)
		Orders.Type.RAZE:
			_raze(sender, order)
		Orders.Type.RESEARCH:
			_research(sender, order)
		Orders.Type.MERGE:
			_merge(sender, order)
		Orders.Type.SPLIT:
			_split(sender, order)
		Orders.Type.FORFEIT:
			_forfeit(sender, order)
		Orders.Type.STANCE:
			_stance(sender, order)


func _stance(sender: int, order: Dictionary) -> void:
	if battle == null:
		_reject(sender, "no battle in progress")
		return
	for id in order["ids"]:
		var r = battle.get_regiment(id)
		if r == null or r.owner_id != sender:
			_reject(sender, "regiment %d is not yours to order" % id)
			continue
		r.stance = int(order["mask"])


## Give up the field. Deliberately NOT routed through _campaign_is_open: it is the one
## order that only makes sense DURING a battle, where every campaign order is refused.
##
## The sender is the peer id the transport reports, never anything in the packet, so a
## spectator or a third player cannot end somebody else's fight -- they have no army in
## _battle_armies and are turned away here.
func _forfeit(sender: int, order: Dictionary) -> void:
	if battle == null:
		_reject(sender, "no battle in progress")
		return
	if not bool(order["confirm"]):
		return
	if not _battle_armies.has(sender) and not _battle_armies.is_empty():
		_reject(sender, "you have no army on this field")
		return
	# Only FLAGGED here, never finished here. _process ends a battle inside the tick
	# loop, straight after a step and before any order lands on the new tick; ending it
	# from the order handler instead left this tick's orders in the closing snapshot,
	# while a replay stops before applying them and so reproduced a different battle.
	# `_keep_the_recording()` says so out loud, which is how this was caught.
	_battle_forfeit = sender
	_announce("player %d has quit the field" % sender)


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


func _focus(sender: int, order: Dictionary) -> void:
	if battle == null:
		_reject(sender, "no battle in progress")
		return
	for id in order["ids"]:
		var r = battle.get_regiment(id)
		if r == null or r.owner_id != sender:
			_reject(sender, "regiment %d is not yours to aim" % id)
			continue
		r.focus = int(order["mark"])


func _set_formation(sender: int, order: Dictionary) -> void:
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
		# Shape first, then frontage: picking a formation resets the width to what that
		# formation wants, and a width of 0 means the player did not ask for more.
		var changed: bool = r.set_formation(order["formation"])
		if int(order["width"]) > 0 and not changed:
			r.set_width(int(order["width"]))


func _merge(sender: int, order: Dictionary) -> void:
	if not _campaign_is_open(sender):
		return
	if not campaign.merge(sender, order["army_id"], order["into_id"]):
		_reject(sender, "army %d cannot join army %d" % [order["army_id"], order["into_id"]])
		return
	broadcast_campaign()
	campaign_updated.emit(campaign)


func _split(sender: int, order: Dictionary) -> void:
	if not _campaign_is_open(sender):
		return
	var made: int = campaign.split(sender, order["army_id"], order["indices"], order["to_tile"])
	if made < 0:
		_reject(sender, "army %d cannot detach onto tile %d" % [order["army_id"], order["to_tile"]])
		return
	broadcast_campaign()
	campaign_updated.emit(campaign)


## The three things every campaign order needs to be true before it means anything.
func _campaign_is_open(sender: int) -> bool:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return false
	if battle != null:
		_reject(sender, "a battle is being fought")
		return false
	return true


func _research(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if not campaign.learn(sender, order["tech"]):
		_reject(sender, "cannot learn %s yet" % order["tech"])
		return
	_announce("player %d has learned %s" % [sender, order["tech"]])
	broadcast_campaign()
	campaign_updated.emit(campaign)


func _raze(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	var tile: int = -1
	var a = campaign.armies.get(order["army_id"])
	var burned := &""
	if a != null:
		tile = a["tile"]
		burned = campaign.structure_at(tile)
	if not campaign.raze(sender, order["army_id"]):
		_reject(sender, "army %d has nothing to burn" % order["army_id"])
		return
	_announce("player %d burned a %s at tile %d" % [sender, burned, tile])
	broadcast_campaign()
	campaign_updated.emit(campaign)


func _build(sender: int, order: Dictionary) -> void:
	if campaign == null:
		_reject(sender, "no campaign in progress")
		return
	if battle != null:
		_reject(sender, "a battle is being fought")
		return
	if not campaign.place(sender, order["tile"], order["structure"]):
		_reject(sender, "cannot put a %s on tile %d" % [order["structure"], order["tile"]])
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
	_battle_forfeit = 0

	var bs = BattleState.new()
	bs.lay_ground(int(campaign.terrain[_battle_tile]), _battle_tile * 7919 + campaign.turn)
	for side in [attacker["owner"], defender["owner"]]:
		bs.techs[side] = campaign.techs_of(side).duplicate()
	# Siegecraft is the attacker's answer to a wall, so it is folded in here rather than
	# left for the battle to discover -- the defence is a property of the ground.
	var fortified := campaign.defense_at(_battle_tile, defender["owner"]) \
		* bs.tech(attacker["owner"], &"siege")
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

	# A side that quits has lost the field whatever its regiments were still doing, so
	# the forfeit overrides what the sim would have called it. With only two sides on a
	# field, the winner is simply the other one.
	var winner_id: int = battle.winner()
	if _battle_forfeit != 0:
		winner_id = 0
		for owner in _battle_armies:
			if owner != _battle_forfeit:
				winner_id = owner
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

	# Breaking contact costs men: those who did not get away. Done before _settle_field
	# so a forfeiting army that is cut down to nothing is disbanded with everyone else.
	if _battle_forfeit != 0:
		var quitter = campaign.armies.get(_battle_armies.get(_battle_forfeit, -1))
		if quitter != null:
			var left := campaign.retreat(quitter["id"])
			_announce("player %d falls back to tile %d" % [_battle_forfeit, left]
				if left >= 0 else "player %d is cornered and cannot fall back" % _battle_forfeit)

	_announce("the field at tile %d goes to player %d" % [_battle_tile, winner_id])
	if attacker != null and defender != null:
		_settle_field(attacker, defender, _battle_tile, winner_id == _battle_attacker)
	_battle_armies.clear()
	_battle_forfeit = 0
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
	# The ground is yours if nobody is left holding it -- the defender destroyed, or
	# having quit the field and fallen back off it. Testing only for destruction meant a
	# forfeit handed the enemy the win and the tile at the same time, which made giving
	# up strictly worse than dying where you stood.
	var held: bool = campaign.armies.has(defender["id"]) and int(defender["tile"]) == contested
	if attacker_wins and not held:
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
	_roster_changed()
	if battle != null:
		broadcast_battle()
	if campaign != null:
		broadcast_campaign()


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	_roster_changed()
