extends SceneTree
## Two-process proof of the networked core (M3) and the order pipeline (M4).
## Not part of the unit suite — run it with tests/nettest.cmd.
##
##   godot --headless -- --host
##   godot --headless -- --join 127.0.0.1
##
## The client is the judge, and it needs no digest exchange with the server: if
## its re-encoded mirror equals the bytes the server sent, the mirror is exactly the
## server's state. The server's encoder walks regiments in sorted id order precisely
## so that this holds.

const Rules := preload("res://sim/rules.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")

const TICKS_BEFORE_FREEZE := 40           # two seconds of marching
const TIMEOUT := 25.0
## Somewhere on the field, derived from the field rather than picked. A literal here
## was (1234, -567), which sat inside a 3000-unit half-extent and outside a 1200-unit
## one, so shrinking the battlefield silently turned the order-delivery probe into an
## out-of-bounds-clamping probe and this harness failed saying the order never arrived.
## It had arrived; `Orders.clamp_to_field` had moved it.
const PROBE_TARGET := Vector2(Rules.BATTLE_HALF_EXTENT * 0.5, -Rules.BATTLE_HALF_EXTENT * 0.25)

var net: Node
var role := ""
var address := "127.0.0.1"
var elapsed := 0.0
var started := false
var failures: PackedStringArray = []

# client bookkeeping
var snapshots := 0
var last_tick := -1
var moved := false
var ordered := false
var order_sent_at := 0.0
var my_ids: PackedInt32Array = []
var enemy_id := -1
var _first_positions := {}

# server bookkeeping
var battle_started := false
var frozen := false
var _rebroadcast := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--host": role = "host"
			"--join":
				role = "join"
				if i + 1 < args.size():
					address = args[i + 1]
	if role == "":
		printerr("usage: --host | --join <address>")
		quit(2)
		return

	net = root.get_node_or_null("Net")
	if net == null:
		net = load("res://net/net.gd").new()
		net.name = "Net"
		root.add_child(net)


## Node.multiplayer is not resolvable during _initialize(), so connect on the first frame.
func _start() -> void:
	started = true
	var err: int = net.host() if role == "host" else net.join(address)
	if err != OK:
		printerr("[%s] could not start: %d" % [role, err])
		quit(2)
		return
	print("[%s] up" % role)


func _process(delta: float) -> bool:
	if not started:
		_start()
		return false
	elapsed += delta
	if elapsed > TIMEOUT:
		_fail("timed out after %.0fs (snapshots seen: %d)" % [TIMEOUT, snapshots])
		_finish()
		return true
	if role == "host":
		_host_tick(delta)
	else:
		_client_tick(delta)
	return false


# --- server side ----------------------------------------------------------

func _host_tick(delta: float) -> void:
	if not battle_started and net.players.size() >= 2:
		var client_id: int = net.players.keys().filter(func(k): return k != 1)[0]
		var bs = BattleState.new()
		# Host's line, facing +X. Client's line opposite it, facing -X.
		bs.add(1, &"spear", Vector2(-300, -60), 0.0)
		bs.add(1, &"sword", Vector2(-300, 60), 0.0)
		bs.add(client_id, &"spear", Vector2(300, -60), PI)
		bs.add(client_id, &"archer", Vector2(300, 60), PI)
		net.start_battle(bs)
		battle_started = true
		print("[host] battle started, %d regiments, client is peer %d" % [bs.regiments.size(), client_id])
		# The host issues its own orders through the same pipeline a client uses.
		net.order_battle_move(PackedInt32Array([1, 2]), Vector2(0, 0), 0.0)
		return

	if battle_started and not frozen and net.battle.tick >= TICKS_BEFORE_FREEZE:
		net.stop_battle()
		frozen = true
		print("[host] frozen at tick %d" % net.battle.tick)

	if frozen:
		# Keep the final state flowing so the client is sure to see it settle.
		_rebroadcast += delta
		if _rebroadcast >= 0.2:
			_rebroadcast = 0.0
			net.broadcast_battle()

	if battle_started and net.players.size() < 2:
		print("[host] client left, done")
		quit(0)


# --- client side ----------------------------------------------------------

func _client_tick(delta: float) -> void:
	if net.battle == null:
		return
	var bs = net.battle

	if bs.tick != last_tick:
		last_tick = bs.tick
		snapshots += 1
		_check_mirror_is_exact(bs)
		_check_things_moved(bs)

	if not ordered and snapshots >= 3:
		_send_probe_orders(bs)
		return

	if ordered and elapsed - order_sent_at > 1.5:
		print("[join] checking orders at tick %d" % bs.tick)
		_check_orders_landed(bs)
		_finish()


func _check_mirror_is_exact(bs) -> void:
	# Against the bytes the SERVER sent, not against a re-encode of our own encode --
	# the latter only proves the codec is stable, which is a much weaker claim.
	if Snapshot.encode_battle(bs) != net.last_battle_bytes:
		_fail("mirror does not re-encode to the server's bytes at tick %d" % bs.tick)


func _check_things_moved(bs) -> void:
	for id in bs.sorted_ids():
		var p: Vector2 = bs.regiments[id].pos
		if not _first_positions.has(id):
			_first_positions[id] = p
		elif _first_positions[id].distance_to(p) > 1.0:
			moved = true


func _send_probe_orders(bs) -> void:
	var me: int = net.my_id()
	for id in bs.sorted_ids():
		var r = bs.regiments[id]
		if r.owner_id == me:
			my_ids.append(id)
		elif enemy_id == -1:
			enemy_id = id
	if my_ids.is_empty() or enemy_id == -1:
		_fail("expected to own some regiments and to face some (own %d, enemy %d)" % [my_ids.size(), enemy_id])
		_finish()
		return

	print("[join] peer %d owns %s, probing with enemy regiment %d" % [me, str(my_ids), enemy_id])
	net.order_battle_move(my_ids, PROBE_TARGET, 0.0)
	net.order_battle_move(PackedInt32Array([enemy_id]), PROBE_TARGET, 0.0)   # must be refused
	ordered = true
	order_sent_at = elapsed


func _check_orders_landed(bs) -> void:
	for id in my_ids:
		var r = bs.regiments.get(id)
		if r == null:
			_fail("regiment %d vanished" % id)
		elif r.target.distance_to(PROBE_TARGET) > 0.001:
			_fail("my order never reached regiment %d (target %s)" % [id, str(r.target)])
	var enemy = bs.regiments.get(enemy_id)
	if enemy != null and enemy.target.distance_to(PROBE_TARGET) < 0.001:
		_fail("SERVER ACCEPTED AN ORDER FOR A REGIMENT I DO NOT OWN (%d)" % enemy_id)
	if snapshots < 3:
		_fail("only %d snapshots arrived" % snapshots)
	if not moved:
		_fail("nothing ever moved: the server is not simulating, or not transmitting")
	_check_i_know_who_is_playing(bs)


## A client has to be told the ROSTER, and nothing used to tell it.
##
## `players` was written only on the server, `join()` never filled it and no rpc carried
## it, so a joined client's player_ids() was empty for the whole session. Four view call
## sites take that array as the seating and Colors.of_owner() returns NEUTRAL for an id it
## cannot find in it -- so on the client BOTH ARMIES DREW THE SAME GREY, along with the
## strength bars and every settlement and army on the campaign map. Nothing failed, no
## warning was pushed, and the host's own window looked perfect.
func _check_i_know_who_is_playing(bs) -> void:
	var seats: Array = net.player_ids()
	if seats.is_empty():
		_fail("I do not know who is playing: player_ids() is empty, so everybody draws grey")
		return
	if not seats.has(net.my_id()):
		_fail("my own seat %d is not in the roster %s" % [net.my_id(), str(seats)])
	# The test the colour actually turns on. Colors.of_owner() looks an owner up in this
	# array and gives NEUTRAL when it is not there, so every owner ON THE FIELD has to be
	# in it, and there have to be at least two of them or both armies match anyway.
	var owners := {}
	for id in bs.sorted_ids():
		owners[bs.regiments[id].owner_id] = true
	for owner in owners:
		if not seats.has(owner):
			_fail("regiments owned by %d are on the field but %d is not in the roster %s -- "
				% [owner, owner, str(seats)] + "they will all draw NEUTRAL grey")
	if owners.size() < 2:
		_fail("only one owner on the field, so this proves nothing about telling sides apart")


# --- verdict --------------------------------------------------------------

func _fail(msg: String) -> void:
	if not failures.has(msg):
		failures.append(msg)


func _finish() -> void:
	print("[%s] finishing at %.2fs, %d snapshots, %d failures" % [role, elapsed, snapshots, failures.size()])
	if role == "host":
		quit(0)
		return
	if failures.is_empty():
		print("[join] PASS  %d snapshots, mirror exact, own orders applied, foreign order refused" % snapshots)
		quit(0)
	else:
		for f in failures:
			printerr("[join] FAIL  " + f)
		quit(1)
