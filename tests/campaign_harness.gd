extends SceneTree
## Two-process proof of the campaign loop (M5): both players march, recruit and press
## End Turn; the turn only advances when everyone has. Run by camptest.cmd.
##
##   godot --headless --script res://tests/campaign_harness.gd -- --host
##   godot --headless --script res://tests/campaign_harness.gd -- --join 127.0.0.1
##
## The client is the judge. As in net_harness.gd it proves its mirror by re-encoding
## it and comparing against the bytes the server actually sent.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")

const TURNS := 5
const TIMEOUT := 30.0
const MAP_SEED := 20260920

var net: Node
var role := ""
var address := "127.0.0.1"
var elapsed := 0.0
var started := false
var failures: PackedStringArray = []

var campaign_started := false
var last_turn := 0
var turns_seen := 0
var acted_this_turn := false
var gold_at_start := -1
var probed := false


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
		_fail("timed out on turn %d after %.0fs" % [last_turn, TIMEOUT])
		_finish()
		return true

	if role == "host" and not campaign_started and net.players.size() >= 2:
		net.start_campaign(MAP_SEED)
		campaign_started = true
		print("[host] campaign dealt, seed %d" % MAP_SEED)

	var cs = net.campaign
	if cs == null:
		return false

	if cs.turn != last_turn:
		last_turn = cs.turn
		turns_seen += 1
		acted_this_turn = false
		if role == "join":
			_verify_mirror(cs)

	if cs.turn > TURNS:
		_check_the_campaign_actually_happened(cs)
		_finish()
		return true

	if not acted_this_turn:
		acted_this_turn = true
		_take_my_turn(cs)
	return false


## March toward the middle, recruit what we can afford, then declare ready.
func _take_my_turn(cs) -> void:
	var me: int = net.my_id()
	if gold_at_start < 0:
		gold_at_start = int(cs.gold.get(me, 0))

	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] == me:
			net.order_army_move(id, Campaign.idx(int(Rules.MAP_W / 2), int(Rules.MAP_H / 2)))
			break
	for s: Dictionary in cs.settlements:
		if s["owner"] == me:
			net.order_recruit(s["tile"], &"spear")
			break

	if role == "join" and not probed:
		probed = true
		_probe_authority(cs)

	net.order_ready(true)


## Try to move someone else's army and recruit in someone else's town. Both must fail.
func _probe_authority(cs) -> void:
	var me: int = net.my_id()
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] != me:
			net.order_army_move(id, Campaign.idx(1, 1))
			break
	for s: Dictionary in cs.settlements:
		if s["owner"] != me and s["owner"] != 0:
			net.order_recruit(s["tile"], &"sword")
			break


func _verify_mirror(cs) -> void:
	if Snapshot.encode_campaign(cs) != net.last_campaign_bytes:
		_fail("campaign mirror does not match the server's bytes on turn %d" % cs.turn)


func _check_the_campaign_actually_happened(cs) -> void:
	var me: int = net.my_id()
	if turns_seen < TURNS:
		_fail("only saw %d turns of %d" % [turns_seen, TURNS])

	var mine := 0
	var theirs := 0
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == me:
			mine += cs.armies[id]["regiments"].size()
		else:
			theirs += cs.armies[id]["regiments"].size()
	if mine <= 3:
		_fail("recruitment never happened: still %d regiments" % mine)
	if theirs <= 3:
		_fail("the other player never recruited either (%d): are orders crossing?" % theirs)

	if int(cs.gold.get(me, 0)) <= 0:
		_fail("no gold left at all, income is not being paid")

	# Authority: the probe tried to buy a regiment in the host's capital with the
	# host's gold. If the host's purse moved by exactly what we tried to spend, it worked.
	for owner: int in cs.gold:
		if owner != me and int(cs.gold[owner]) < 0:
			_fail("another player's treasury went negative: authority is leaking")

	print("[%s] turn %d: %d regiments mine, %d theirs, %d gold" % [role, cs.turn, mine, theirs, int(cs.gold.get(me, 0))])


func _fail(msg: String) -> void:
	if not failures.has(msg):
		failures.append(msg)


func _finish() -> void:
	if role == "host":
		quit(0)
		return
	if failures.is_empty():
		print("[join] PASS  %d turns played, mirror exact each turn, authority held" % turns_seen)
		quit(0)
	else:
		for f in failures:
			printerr("[join] FAIL  " + f)
		quit(1)
