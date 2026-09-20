extends SceneTree
## One process, two AI players, nobody watching (M13).
##
##   godot --headless --script res://tests/ai_harness.gd -- --turns 25
##
## The broadest smoke test available: it drives the entire game — economy, building,
## recruitment, marching, contact, real-time battles, casualties written back — with
## no human input and no second process. If anything in the loop is broken, this
## either stalls or never fights, and both are failures.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")

const MAP_SEED := 20260921
const DEFAULT_TURNS := 12
const TIMEOUT := 420.0

var net: Node
var started := false
var turns := DEFAULT_TURNS
var elapsed := 0.0
var failures: PackedStringArray = []

var last_turn := 0
var turns_seen := 0
var battles := 0
var battle_seconds := 0.0
var captures := 0
var was_fighting := false
var fought := 0
var owners_at_start := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--turns" and i + 1 < args.size():
			turns = int(args[i + 1])
	net = root.get_node_or_null("Net")
	if net == null:
		net = load("res://net/net.gd").new()
		net.name = "Net"
		root.add_child(net)


func _start() -> void:
	started = true
	var err: int = net.host(net.PORT, false)      # run the server, take no seat
	if err != OK:
		printerr("[ai] could not host: %d" % err)
		quit(2)
		return
	net.add_ai()
	net.add_ai()
	net.news.connect(func(text: String) -> void:
		if text.begins_with("battle"):
			battles += 1
		print("[ai] %s" % text))
	net.start_campaign(MAP_SEED)
	for s: Dictionary in net.campaign.settlements:
		owners_at_start[s["tile"]] = s["owner"]
	print("[ai] two AI players, seed %d, %d turns" % [MAP_SEED, turns])


func _process(delta: float) -> bool:
	if not started:
		_start()
		return false
	elapsed += delta
	if elapsed > TIMEOUT:
		_fail("timed out on turn %d after %.0fs" % [last_turn, TIMEOUT])
		return _finish()

	var cs = net.campaign
	if cs == null:
		return false

	if net.battle != null:
		was_fighting = true
		battle_seconds += delta
		if battle_seconds > Rules.BATTLE_TIME_LIMIT + 30.0:
			_fail("a battle ran past its own time limit and never ended")
			return _finish()
		return false
	if was_fighting:
		was_fighting = false
		fought += 1
		print("[ai] that battle took %.0fs and the campaign came back" % battle_seconds)
		battle_seconds = 0.0

	if cs.turn != last_turn:
		last_turn = cs.turn
		turns_seen += 1
		if not cs.is_alive(-1) or not cs.is_alive(-2):
			print("[ai] one side has been driven from the map on turn %d" % cs.turn)
			return _finish()
		# Stop as soon as the whole loop has demonstrably run. Battles are fought in
		# real time, so playing every turn out would make this gate minutes long for
		# no coverage a third battle would add.
		if turns_seen >= 3 and fought >= 1 and _captures(cs) >= 1:
			return _finish()

	if cs.turn > turns:
		return _finish()
	return false


func _captures(cs) -> int:
	var n := 0
	for s: Dictionary in cs.settlements:
		if owners_at_start.get(s["tile"], s["owner"]) != s["owner"]:
			n += 1
	return n


func _check(cs) -> void:
	captures = _captures(cs)
	if fought == 0:
		_fail("no real-time battle was ever fought to a finish")
	if turns_seen < 3:
		_fail("turns are not advancing without a human: saw %d" % turns_seen)
	if battles == 0:
		_fail("two AIs marched at each other for %d turns and never fought" % turns_seen)
	if captures == 0:
		_fail("nothing changed hands, so nobody is actually taking ground")

	var built := 0
	var men := 0
	for seat in [-1, -2]:
		men += cs.men_of(seat)
	for tile in cs.structures.size():
		if cs.structure_at(tile) != &"":
			built += 1
	if built <= 2:
		_fail("only %d structures on the whole map: the AI is not developing" % built)
	if men == 0:
		_fail("both AIs have no men left at all")

	print("[ai] turn %d: %d battles, %d settlements changed hands, %d buildings, %d men alive" % [
		cs.turn, battles, captures, built, men])


func _fail(msg: String) -> void:
	if not failures.has(msg):
		failures.append(msg)


func _finish() -> bool:
	if net.campaign != null:
		_check(net.campaign)
	if failures.is_empty():
		print("[ai] PASS  %d turns, %d battle(s) fought and returned from, all by nobody" % [turns_seen, fought])
		quit(0)
	else:
		for f in failures:
			printerr("[ai] FAIL  " + f)
		quit(1)
	return true
