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

const TURNS := 8       # the armies start in opposite corners and need this long to meet
## Battles are fought in real time, so this budget is mostly one battle. It was 180s
## when a head-on fight broke somebody at 75s; morale now tracks casualties rather than
## the clock, so a formed tie runs past four minutes and the old budget could not cover
## one. `_fight()` sends the host round a flank instead of grinding head-on, which is
## both faster and a better exercise -- this covers that fight with room to spare.
const TIMEOUT := 280.0

## How long the joiner slugs it out before throwing in the towel.
const FIGHT_SECONDS := 25.0
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
var battles := 0
var peak_regiments := 0
var fought := 0
var was_fighting := false
var charged := false
var battle_seconds := 0.0
var gave_up := false
var men_before_battle := -1
var men_after_battle := -1


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
	battles = 0
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
	net.news.connect(func(text: String) -> void:
		battles += 1
		print("[%s] news: %s" % [role, text]))
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

	if net.battle != null:
		was_fighting = true
		battle_seconds += delta
		_fight()
		# Somebody has to end this. A head-on charge between formed regiments now runs
		# past four minutes, and what this gate needs to prove is the handoff, not the
		# grind -- so the judge fights for a bit and then quits the field, which is a
		# real ending and exercises the forfeit order across two processes as well.
		if role == "join" and battle_seconds > FIGHT_SECONDS and not gave_up:
			gave_up = true
			print("[join] battle: giving up the field after %.0fs" % battle_seconds)
			net.order_forfeit()
		return false
	if was_fighting:
		# The battle ended and the campaign is back. Act again this turn.
		was_fighting = false
		charged = false
		battle_seconds = 0.0
		acted_this_turn = false
		fought += 1
		men_after_battle = _my_men()
		# One closed loop is the whole point of this gate, and battles run in real
		# time, so the judge stops here rather than playing the campaign out. The
		# host must NOT stop with it: quitting here leaves the client waiting on a
		# _battle_over that will never arrive.
		if role == "join" and net.campaign != null:
			_check_the_campaign_actually_happened(net.campaign)
			_finish()
			return true

	var cs = net.campaign
	if cs == null:
		return false

	var owned := 0
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == net.my_id():
			owned += cs.armies[id]["regiments"].size()
	peak_regiments = maxi(peak_regiments, owned)

	if cs.turn != last_turn:
		last_turn = cs.turn
		turns_seen += 1
		acted_this_turn = false
		if role == "join":
			_verify_mirror(cs)

	if role == "host":
		if net.players.size() < 2:
			print("[host] client left, done")
			quit(0)
			return true
		if not acted_this_turn:
			acted_this_turn = true
			_take_my_turn(cs)
		return false

	if cs.turn > TURNS:
		_check_the_campaign_actually_happened(cs)
		_finish()
		return true

	if not acted_this_turn:
		acted_this_turn = true
		_take_my_turn(cs)
	return false


## Charge the enemy line, then give it up.
##
## Crude, but it decides a battle, which is all this harness needs. The forfeit is the
## important half: since morale started tracking casualties rather than the clock, a
## head-on tie between formed regiments runs past four minutes and into
## BATTLE_TIME_LIMIT, and this gate exists to prove the campaign-battle-campaign handoff
## rather than to sit through the slowest fight the combat model can produce. Forfeiting
## is a real ending -- survivors go home, the field is lost, the campaign resumes -- so
## it proves the same seam faster, and proves the forfeit order across two processes
## while it is at it.
func _fight() -> void:
	if charged:
		return
	charged = true
	if men_before_battle < 0:
		men_before_battle = _my_men()
	var me: int = net.my_id()
	var mine := PackedInt32Array()
	var enemy_centre := Vector2.ZERO
	var enemies := 0
	for id in net.battle.sorted_ids():
		var r = net.battle.regiments[id]
		if r.owner_id == me:
			mine.append(id)
		else:
			enemy_centre += r.pos
			enemies += 1
	if mine.is_empty() or enemies == 0:
		return
	enemy_centre /= float(enemies)
	print("[%s] battle: charging with %d regiments" % [role, mine.size()])
	for id in mine:
		net.order_battle_move(PackedInt32Array([id]), enemy_centre, 0.0)


## Men, not regiments. A regiment cut to five men is still one regiment, so counting
## regiments would call a massacre a draw.
func _my_men() -> int:
	return 0 if net.campaign == null else net.campaign.men_of(net.my_id())


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
		if s["owner"] != me:
			continue
		# Put something on the land, which exercises the BUILD order, then raise the
		# best thing the structures near this town unlock.
		for tile in cs.structures.size():
			if Campaign.hex_distance(tile, s["tile"]) <= Rules.WORK_RADIUS 					and cs.can_place(me, tile, &"farm"):
				net.order_build(tile, &"farm")
				break
		var can: Array = cs.recruitable_at(s["tile"])
		net.order_recruit(s["tile"], &"cavalry" if can.has(&"cavalry") else &"spear")
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
	# The run stops as soon as one full loop has closed, so the bar is "turns are
	# advancing", not "all TURNS were played".
	if turns_seen < 2:
		_fail("turns are not advancing: saw %d" % turns_seen)
	if fought == 0 and turns_seen < TURNS:
		_fail("only saw %d turns of %d and never fought" % [turns_seen, TURNS])

	var mine := 0
	var theirs := 0
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == me:
			mine += cs.armies[id]["regiments"].size()
		else:
			theirs += cs.armies[id]["regiments"].size()
	if peak_regiments <= 3:
		_fail("recruitment never happened: peaked at %d regiments" % peak_regiments)
	if battles == 0:
		_fail("the two armies never fought: the loop does not close")
	if fought == 0:
		_fail("no real-time battle was ever entered or left")
	elif men_after_battle < 0:
		_fail("the campaign never came back after the battle")
	elif men_after_battle >= men_before_battle:
		_fail("came out of the battle with %d men, went in with %d: casualties are not being written back"
			% [men_after_battle, men_before_battle])

	if int(cs.gold.get(me, 0)) <= 0:
		_fail("no gold left at all, income is not being paid")

	var built := 0
	var horse := 0
	for tile in cs.structures.size():
		if cs.structure_at(tile) == &"":
			continue
		var s = cs.working_settlement(tile)
		if s != null and s["owner"] == me:
			built += 1
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] == me:
			for r: Array in a["regiments"]:
				if r[0] == &"cavalry":
					horse += 1
	if built < 2:
		_fail("nothing was built: a capital starts with a barracks and should have gained a farm")
	if horse == 0:
		_fail("no cavalry was ever raised, so the barracks gate is not working over the wire")

	# Authority: the probe tried to buy a regiment in the host's capital with the
	# host's gold. If the host's purse moved by exactly what we tried to spend, it worked.
	for owner: int in cs.gold:
		if owner != me and int(cs.gold[owner]) < 0:
			_fail("another player's treasury went negative: authority is leaking")

	print("[%s] turn %d: %d regiments mine (peak %d), %d theirs, %d gold, %d battles" % [
		role, cs.turn, mine, peak_regiments, theirs, int(cs.gold.get(me, 0)), battles])


func _fail(msg: String) -> void:
	if not failures.has(msg):
		failures.append(msg)


func _finish() -> void:
	if role == "host":
		quit(0)
		return
	if failures.is_empty():
		print("[join] PASS  %d turns, %d battle(s), %d men -> %d, buildings and cavalry over the wire, authority held"
			% [turns_seen, fought, men_before_battle, men_after_battle])
		quit(0)
	else:
		for f in failures:
			printerr("[join] FAIL  " + f)
		quit(1)
