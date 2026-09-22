extends RefCounted
## Jev advises; it never decides.
##
## Two halves. The first is the parser, because a reply off a network is hostile until
## proven otherwise and a confidence threshold that silently stopped working would look
## exactly like an AI having opinions. The second is the thing that actually matters:
## every one of these runs with NO key and NO network, and proves that advice which is
## absent, stale, unaffordable or outright nonsense costs the AI nothing. That is what
## keeps test.cmd, nettest.cmd, camptest.cmd and aitest.cmd green on a machine that has
## never heard of TypeSafe.

const Jev := preload("res://net/jev.gd")
const Ai := preload("res://sim/ai.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")
const Net := preload("res://net/net.gd")


## A reply shaped exactly like the one in TypeSafe's API reference.
const REPLY := {
	"model": "jev-1.13.0",
	"answers": {
		"tech": {"type": "choice", "choice": "drill", "confidence": 0.82},
		"target": {"type": "choice", "choice": "47", "confidence": 0.61},
		"frustration": {"type": "score", "score": 1.035, "confidence": 0.7},
		"is_urgent": {"type": "noul", "noul": 0.95},
	},
	"usage": {"input_tokens": 296, "output_tokens": 20},
}


# --- reading the key ------------------------------------------------------

func test_env_parsing(t) -> void:
	var cfg := Jev.read_env("# a comment\n\nTYPESAFE_API_KEY=sk-ab=cd\n  TYPESAFE_BASE_URL = https://x  \nrubbish\n")
	t.eq(cfg.get("TYPESAFE_API_KEY"), "sk-ab=cd", "splits on the FIRST = so a value may contain one")
	t.eq(cfg.get("TYPESAFE_BASE_URL"), "https://x", "trims either side of the =")
	t.eq(cfg.size(), 2, "comments, blanks and a line with no = are not settings")


# --- reading the answer ---------------------------------------------------

func test_a_reply_becomes_advice(t) -> void:
	var a := Jev.parse_answers(REPLY)
	t.eq(a.get("tech"), &"drill", "a choice comes back as the option it named")
	t.eq(a.get("target"), &"47", "and a tile is just another option")
	t.near(float(a.get("frustration", 0.0)), 1.035, 0.0001, "a score lands between levels")
	t.near(float(a.get("is_urgent", 0.0)), 0.95, 0.0001, "a noul is its own confidence")


func test_an_unconfident_answer_is_not_an_answer(t) -> void:
	var a := Jev.parse_answers({"answers": {
		"tech": {"type": "choice", "choice": "drill", "confidence": 0.1}}})
	t.ok(not a.has("tech"), "below the threshold is the same as never having asked")


func test_a_reply_that_is_not_one_yields_nothing(t) -> void:
	t.eq(Jev.parse_answers({}).size(), 0, "no answers block")
	t.eq(Jev.parse_answers({"answers": "boom"}).size(), 0, "answers that are not a dictionary")
	t.eq(Jev.parse_answers({"answers": {"tech": 7}}).size(), 0, "an answer that is not a dictionary")
	t.eq(Jev.parse_answers({"answers": {"tech": {"type": "choice", "confidence": 0.9}}}).size(), 0,
		"a confident choice that chose nothing")


# --- the log --------------------------------------------------------------

func test_the_log_shows_what_was_taken_and_what_was_dropped(t) -> void:
	var reply := {"answers": {
		"tech": {"type": "choice", "choice": "drill", "confidence": 0.82},
		"target": {"type": "choice", "choice": "245", "confidence": 0.11},
	}}
	var line := Jev.decisions(reply, Jev.parse_answers(reply))
	t.ok(line.contains("tech=drill (0.82)"), "the choice and how sure it was: %s" % line)
	t.ok(not line.contains("tech=drill (0.82) DROPPED"), "a confident answer is not marked")
	t.ok(line.contains("target=245 (0.11) DROPPED"),
		"and the one that fell below the threshold is still shown, marked: %s" % line)


func test_the_log_survives_a_reply_that_is_not_one(t) -> void:
	t.eq(Jev.decisions({}, {}), "nothing usable came back", "no answers block")
	t.eq(Jev.decisions("boom", {}), "nothing usable came back", "not even a dictionary")
	t.eq(Jev.decisions({"answers": {}}, {}), "nothing usable came back", "an empty one")


# --- the campaign ---------------------------------------------------------

func _rich(seat := 1) -> Array:
	var cs = Campaign.generate([seat, 2], 12345)
	cs.gold[seat] = 100000
	cs.research[seat] = 100000
	cs.food[seat] = 100000
	return [cs, Ai.new(seat)]


func _decoded(cs, ai) -> Array:
	var out := []
	for bytes: PackedByteArray in ai.campaign_orders(cs):
		out.append(Orders.decode(bytes))
	return out


func _first(orders: Array, type: int) -> Dictionary:
	for o: Dictionary in orders:
		if o.get("type") == type:
			return o
	return {}


func test_with_nobody_advising_it_plays_its_own_list(t) -> void:
	var pair := _rich()
	var o := _first(_decoded(pair[0], pair[1]), Orders.Type.RESEARCH)
	t.eq(o.get("tech"), Ai.TECH_ORDER[0], "the hardcoded order still stands with an empty dictionary")


func test_the_advised_tech_wins_when_it_is_legal(t) -> void:
	var pair := _rich()
	pair[1].advice["tech"] = &"drill"
	var o := _first(_decoded(pair[0], pair[1]), Orders.Type.RESEARCH)
	t.eq(o.get("tech"), &"drill", "it takes the advice over the head of its own list")


func test_a_tech_it_has_not_the_prerequisites_for_is_refused(t) -> void:
	var pair := _rich()
	pair[1].advice["tech"] = &"stirrups"       # needs horsemanship, which it does not have
	var o := _first(_decoded(pair[0], pair[1]), Orders.Type.RESEARCH)
	t.eq(o.get("tech"), Ai.TECH_ORDER[0], "can_learn is the gate, not the advice")


func test_a_tech_it_cannot_afford_is_refused(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.research[1] = 45                        # husbandry is 40, armoury is 60
	var ai = Ai.new(1)
	ai.advice["tech"] = &"armoury"
	var o := _first(_decoded(cs, ai), Orders.Type.RESEARCH)
	t.eq(o.get("tech"), &"husbandry", "it cannot pay for what it was told, so its own list has it")


func test_the_advised_settlement_is_where_it_marches(t) -> void:
	var pair := _rich()
	var cs = pair[0]
	var ai = pair[1]
	# Deliberately the FURTHEST thing worth taking, so it cannot be what the distance
	# scan behind the advice would have landed on.
	var home := -1
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == 1:
			home = int(cs.armies[id]["tile"])
			break
	var far := -1
	var far_distance := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			continue
		var d := Campaign.hex_distance(home, int(s["tile"]))
		if d > far_distance:
			far_distance = d
			far = int(s["tile"])
	ai.advice["target"] = StringName(str(far))
	var o := _first(_decoded(cs, ai), Orders.Type.ARMY_MOVE)
	t.ok(not o.is_empty(), "it marched somewhere")
	t.eq(int(o.get("dest", -1)), far, "and it marched where it was told, not at the nearest")


func test_a_target_it_already_owns_is_refused(t) -> void:
	var pair := _rich()
	var cs = pair[0]
	var mine := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			mine = int(s["tile"])
			break
	pair[1].advice["target"] = StringName(str(mine))
	var o := _first(_decoded(cs, pair[1]), Orders.Type.ARMY_MOVE)
	t.ok(int(o.get("dest", -1)) != mine, "advice gone stale falls back to the distance scan")


func test_advice_it_cannot_understand_changes_nothing(t) -> void:
	var plain := _rich()
	var muddled := _rich()
	muddled[1].advice = {"tech": &"not_a_tech", "build": &"not_a_thing", "target": &"999999"}
	t.eq(str(_decoded(muddled[0], muddled[1])), str(_decoded(plain[0], plain[1])),
		"an answer it cannot use is byte for byte the same as no answer")


# --- the battle -----------------------------------------------------------

## Two blocks facing each other, close enough that committing means closing.
func _duel():
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2(-100.0, 0.0), 0.0)
	bs.add(2, &"spear", Vector2(100.0, 0.0), PI)
	return bs


func _target(bs, ai):
	for bytes: PackedByteArray in ai.battle_orders(bs):
		var o := Orders.decode(bytes)
		if o.get("type") == Orders.Type.BATTLE_MOVE:
			return o["target"]
	return null


func test_committing_closes_and_holding_does_not(t) -> void:
	var bs = _duel()
	var committed = _target(bs, Ai.new(1))
	t.ok(committed != null, "committing is the default with no advice at all")
	t.near(committed.x, 100.0, 1.0, "it walks onto the enemy it can already reach")

	var holder = Ai.new(1)
	holder.advice["posture"] = &"hold"
	var held = _target(bs, holder)
	t.ok(held != null and held.x < committed.x, "holding stops at the standoff line instead")


func test_withdrawing_is_an_order_and_it_points_away(t) -> void:
	var bs = _duel()
	var ai = Ai.new(1)
	ai.advice["posture"] = &"withdraw"
	var away = _target(bs, ai)
	t.ok(away != null, "withdrawing is an order, not the absence of one")
	t.ok(away.x < -100.0, "and it is away from the enemy, not toward them")


func test_a_posture_it_does_not_recognise_is_committing(t) -> void:
	var bs = _duel()
	var muddled = Ai.new(1)
	muddled.advice["posture"] = &"nonsense"
	t.eq(str(_target(bs, muddled)), str(_target(bs, Ai.new(1))),
		"nothing it can read means the fight it would have had anyway")


# --- when to ask ----------------------------------------------------------
#
# The stance is asked for when the fight CHANGES, not on a clock. These are the tests
# that keep it that way: one proving it notices the things that matter, and one proving
# it ignores the thing that happens every single tick. Get the second one wrong and this
# is the two-second timer again, only now firing sixty times a second.
#
# Every one of these calls a static. Nothing here may construct a Jev and call
# consider_battle, because the machine running the suite may well have a real key in
# .env and a unit test has no business reaching the internet.

func test_the_shape_ignores_movement(t) -> void:
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2(-800.0, 0.0), 0.0)
	bs.add(2, &"spear", Vector2(800.0, 0.0), PI)
	var before := Jev._shape(bs, 1)
	for id in bs.sorted_ids():
		bs.regiments[id].order_move(Vector2.ZERO, 0.0)
	for n in 20:
		bs.step()
	t.ok(bs.regiments[bs.sorted_ids()[0]].pos.x > -800.0, "they did actually march")
	t.eq(Jev._shape(bs, 1), before, "marching is not news, or this is the old timer again")


func test_the_shape_notices_a_rout(t) -> void:
	var bs = _duel()
	var before := Jev._shape(bs, 1)
	bs.regiments[bs.sorted_ids()[0]].state = Regiment.State.ROUTING
	t.ok(Jev._shape(bs, 1) != before, "a regiment breaking is exactly when a stance is wrong")


func test_the_shape_takes_casualties_in_tenths(t) -> void:
	var bs = _duel()
	var r: Regiment = bs.regiments[bs.sorted_ids()[0]]
	var before := Jev._shape(bs, 1)
	r.strength = r.max_strength - 2
	t.eq(Jev._shape(bs, 1), before, "a couple of men is not a change of situation")
	r.strength = int(r.max_strength * 0.5)
	t.ok(Jev._shape(bs, 1) != before, "half the regiment gone certainly is")


func test_the_shape_notices_an_empty_quiver(t) -> void:
	var bs = BattleState.new()
	bs.add(1, &"archer", Vector2(-100.0, 0.0), 0.0)
	bs.add(2, &"spear", Vector2(100.0, 0.0), PI)
	var before := Jev._shape(bs, 1)
	bs.regiments[bs.sorted_ids()[0]].ammo = 0
	t.ok(Jev._shape(bs, 1) != before,
		"out of arrows they are bad infantry, which is a different fight to be holding for")


func test_the_sentence_survived_the_refactor(t) -> void:
	var bs = _duel()
	var split: Array = Jev._sides(bs, 1)
	t.eq(Jev._side("Ours", split[0]),
		"Ours: 1 regiments ({ \"spear\": 1 }), 120 of 120 men, average morale 100 percent, 0 in melee, 0 routing.",
		"_side still writes what it wrote before _tally was lifted out of it")
	t.eq(Jev._side("Ours", []), "Ours: nobody left standing.", "and the empty case")


## What the change-trigger is actually worth, over a whole battle rather than a duel.
## Both sides get a brain and the fight is run to its end at the real think cadence,
## counting how often the shape moves. Printed as well as asserted: the number drifts
## with the combat constants, and what matters is that it sits well under one ask every
## two seconds without being zero.
func test_how_often_a_real_battle_asks_for_a_stance(t) -> void:
	const LINE := [&"spear", &"sword", &"archer", &"pike"]
	var bs = BattleState.new()
	for i in LINE.size():
		var y := (float(i) - float(LINE.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(1, LINE[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(2, LINE[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)

	var brains := {1: Ai.new(1), 2: Ai.new(2)}
	var shapes := {1: "", 2: ""}
	var asks := 0
	var last_think := -1
	while not bs.is_over() and bs.tick < int(120.0 * Rules.TICK_HZ):
		if Net.due(bs.tick, last_think, Net.AI_THINK_TICKS):
			last_think = bs.tick
			for seat in [1, 2]:
				for bytes: PackedByteArray in brains[seat].battle_orders(bs):
					var o := Orders.decode(bytes)
					# FOCUS as well as BATTLE_MOVE. Dropping it made this harness lie:
					# a regiment going round a flank latches a waypoint, arrives, hands
					# itself to the sim with a focus order and then says nothing more.
					# Swallow that order and it never commits, so it re-latches from the
					# enemy's CURRENT position every think -- which is exactly the churn
					# the latch exists to prevent, measured here as stance questions.
					if o.get("type") == Orders.Type.BATTLE_MOVE:
						for id in o["ids"]:
							bs.regiments[id].order_move(o["target"], o["facing"])
					elif o.get("type") == Orders.Type.FOCUS:
						for id in o["ids"]:
							bs.regiments[id].focus = int(o["mark"])
				var now := Jev._shape(bs, seat)
				if now != shapes[seat]:
					shapes[seat] = now
					asks += 1
		bs.step()

	var seconds := float(bs.tick) / float(Rules.TICK_HZ)
	var on_a_timer := int(seconds / 2.0) * 2          # what the old poll cost, both seats
	var every_think := 2 * int(bs.tick / Net.AI_THINK_TICKS)
	print("  [feel] %.0fs battle: %d stance questions, against %d on the 2s timer and %d asking every think" % [
		seconds, asks, on_a_timer, every_think])
	t.ok(asks > 0, "something changed over a whole battle, so it is not asking never")
	# Measured against asking EVERY THINK, which is the real alternative for something
	# that fires on a change. It used to beat the two-second poll three times over as
	# well -- 31 against 108 -- and no longer does: the AI now sends its spare regiments
	# round a flank, so regiments join and leave melees far more often and the fight
	# genuinely changes more. The in-flight guard is what caps the cost in practice, at
	# one question per seat at a time, so a livelier fingerprint buys information rather
	# than calls.
	t.ok(asks * 3 < every_think,
		"asking on change is a fraction of asking every time (%d vs %d)" % [asks, every_think])


func test_the_think_gap_is_counted_in_ticks(t) -> void:
	t.ok(Net.due(0, -1, 7), "the first think of a battle is always due")
	t.ok(not Net.due(6, 0, 7), "six ticks on is not yet")
	t.ok(Net.due(7, 0, 7), "seven is")
	t.ok(Net.due(200, 0, 7), "and so is anything past it")
	# The one that matters: battle.tick restarts at 0 every fight. Without this clause a
	# stale counter from the last battle silences the AI for minutes into the next one.
	t.ok(Net.due(3, 5000, 7), "a tick counter that went backwards is a new battle, not a wait")


# --- more of Jev ----------------------------------------------------------
# Jev answers three shapes and this file has always PARSED all three. Until now it only
# ever asked `choice`, so `score` and `noul` were handled code nothing reached.
#
# The lever that makes the rest cheap: every question in one request is evaluated in
# parallel and costs only its own tokens, so the expensive thing is the round trip and
# there is exactly one of those either way.

func test_a_battle_asks_for_more_than_a_posture_now(t) -> void:
	var bs = _duel()
	bs.add(1, &"cavalry", Vector2(-400, 200), 0.0)
	var jev = Jev.new()
	jev.consider_battle(1, bs, Ai.new(1))
	var asked: Dictionary = jev.last_questions
	t.ok(asked.has("posture"), "the one it always asked")
	t.ok(asked.has("charge"), "when to release the horse")
	t.ok(asked.has("envelop"), "how much to send round")
	t.eq(asked["posture"]["type"], "choice")
	t.eq(asked["charge"]["type"], "noul")
	t.eq(asked["envelop"]["type"], "score")


func test_all_three_shapes_are_now_asked_for(t) -> void:
	# The point of the pass: `score` and `noul` were parsed and never requested.
	var cs = Campaign.generate([1, 2], 12345)
	var shapes := {}
	for key in Jev.new().campaign_questions(cs, 1, 2):
		shapes[str(Jev.new().campaign_questions(cs, 1, 2)[key]["type"])] = true
	t.ok(shapes.has("choice"))
	t.ok(shapes.has("noul"))
	t.ok(shapes.has("score"))


func test_the_extra_questions_ride_in_the_same_request(t) -> void:
	# The whole economy of this. If they cost a round trip each, they would not be worth
	# asking at all -- so the number of REQUESTS must not move, only the questions in one.
	var bs = _duel()
	bs.add(1, &"cavalry", Vector2(-400, 200), 0.0)
	var jev = Jev.new()
	jev.consider_battle(1, bs, Ai.new(1))
	t.eq(jev.requests, 1, "one round trip")
	t.ok(jev.last_questions.size() >= 3, "carrying %d questions" % jev.last_questions.size())


func test_a_side_with_no_horse_is_not_asked_about_charging(t) -> void:
	# A question nobody can act on is a question not worth the tokens.
	var jev = Jev.new()
	jev.consider_battle(1, _duel(), Ai.new(1))
	t.ok(not jev.last_questions.has("charge"))


func test_the_horse_waits_until_it_is_told(t) -> void:
	var brain = Ai.new(1)
	brain.advice["charge"] = 0.1
	var held := _horse_target(brain)
	brain = Ai.new(1)
	brain.advice["charge"] = 0.9
	var sent := _horse_target(brain)
	t.ok(held != sent, "a charge held and a charge released are different orders")


## Where the cavalry is sent on the first think of an even fight.
func _horse_target(brain) -> Vector2:
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2(-200, 0), 0.0)
	var horse = bs.add(1, &"cavalry", Vector2(-200, 200), 0.0)
	bs.add(2, &"spear", Vector2(200, 0), PI)
	for id in bs.sorted_ids():
		bs.regiments[id].target = bs.regiments[id].pos
	for i in Rules.TICK_HZ * 12:
		bs.step()
	for bytes: PackedByteArray in brain.battle_orders(bs):
		var o := Orders.decode(bytes)
		if o.get("type") == Orders.Type.BATTLE_MOVE and o["ids"][0] == horse.id:
			return o["target"]
	return Vector2.INF


func test_no_advice_leaves_every_one_of_them_as_it_was(t) -> void:
	# The bar the whole feature lives under: with no key, the AI plays exactly the game
	# it played before any of this existed.
	var brain = Ai.new(1)
	t.ok(brain.advice.is_empty())
	t.near(brain._envelop_appetite(), 0.5, 0.0001, "the middle is what the geometry did")
	t.ok(brain._release_the_horse(true), "locked lines released the horse before, and do")
	t.ok(not brain._release_the_horse(false))
	t.ok(not brain._pressed(), "and nothing is on fire until somebody says it is")


func test_being_told_the_empire_is_overextended_stops_it_expanding(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var calm = Ai.new(1)
	var warned = Ai.new(1)
	warned.advice["overextended"] = 0.9
	t.ok(calm._wants_a_settler(cs), "precondition: it would otherwise expand")
	t.ok(not warned._wants_a_settler(cs))


func test_a_threat_score_digs_the_army_in(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var brain = Ai.new(1)
	brain.advice["threat"] = 0.9
	var dug := false
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var o := Orders.decode(bytes)
		if o.get("type") == Orders.Type.ARMY_STANCE and o["stance"] == Campaign.Stance.FORTIFY:
			dug = true
	t.ok(dug, "pressed, so it stands where it is instead of marching at them")


func test_a_quiet_score_does_not(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var brain = Ai.new(1)
	brain.advice["threat"] = 0.1
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var o := Orders.decode(bytes)
		if o.get("type") == Orders.Type.ARMY_STANCE:
			t.ok(o["stance"] != Campaign.Stance.FORTIFY, "nothing to dig in against")


func test_the_named_mark_becomes_a_focus_order(t) -> void:
	var bs = BattleState.new()
	var mine = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	bs.add(2, &"spear", Vector2(300, 0), PI)
	var weak = bs.add(2, &"archer", Vector2(300, 200), PI)
	for id in bs.sorted_ids():
		bs.regiments[id].target = bs.regiments[id].pos
	var brain = Ai.new(1)
	brain.advice["mark"] = str(weak.id)
	var focused := -1
	for bytes: PackedByteArray in brain.battle_orders(bs):
		var o := Orders.decode(bytes)
		if o.get("type") == Orders.Type.FOCUS and o["ids"][0] == mine.id:
			focused = int(o["mark"])
	t.eq(focused, weak.id)


func test_a_mark_that_died_in_flight_is_ignored(t) -> void:
	# The answer takes a few hundred milliseconds and a battle does not wait for it.
	var bs = BattleState.new()
	var mine = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	bs.add(2, &"spear", Vector2(300, 0), PI)
	mine.target = mine.pos
	var brain = Ai.new(1)
	brain.advice["mark"] = "9999"
	for bytes: PackedByteArray in brain.battle_orders(bs):
		t.ok(Orders.decode(bytes).get("type") != Orders.Type.FOCUS,
			"it names nobody who is on the field")


func test_a_score_is_read_the_same_either_way_it_arrives(t) -> void:
	# The API's own docs do not pin whether a score comes back as a fraction or as a rung
	# index, and every threshold in sim/ai.gd is written as a fraction -- so guessing
	# wrong would move all of them at once and fail nowhere visible.
	t.near(Ai._rung(0.0, 3), 0.0)
	t.near(Ai._rung(1.0, 3), 1.0, 0.0001, "1.0 is the top of a fraction")
	t.near(Ai._rung(2.0, 3), 1.0, 0.0001, "...and rung 2 of 3 is also the top")
	t.near(Ai._rung(0.5, 3), 0.5)
	t.near(Ai._rung(99.0, 3), 1.0, 0.0001, "clamped whatever arrives")


func test_a_raider_is_never_asked_anything(t) -> void:
	# It builds nothing, researches nothing and marches at the nearest held town. Four
	# questions a turn for answers nothing would read is a request per band per turn.
	var cs = Campaign.generate([1, 2], 12345)
	var band = Ai.new(Rules.BARBARIAN_SEAT)
	band.raids = true
	var jev = Jev.new()
	t.ok(not jev.consider_turn(Rules.BARBARIAN_SEAT, cs, band))
	t.eq(jev.requests, 0)


func test_a_score_question_carries_its_levels_in_order(t) -> void:
	# ORDERED ARRAY, not a dictionary: a score rates against levels in order, so the
	# shape has to carry the ordering. The endpoint answers 422 for the wrong one, and
	# the only sign was "no answer (http 422)" in the log.
	var cs = Campaign.generate([1, 2], 12345)
	var asked := Jev.new().campaign_questions(cs, 1, 0)
	t.eq(typeof(asked["threat"]["criteria"]), TYPE_ARRAY)
	t.eq(asked["threat"]["criteria"].size(), Ai.THREAT_LEVELS)


func test_a_choice_question_still_carries_named_options(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.research[1] = 100000                # or it can afford no tech and none is asked
	var asked := Jev.new().campaign_questions(cs, 1, 0)
	t.ok(asked.has("tech"), "precondition: it can afford more than one")
	t.eq(typeof(asked["tech"]["criteria"]), TYPE_DICTIONARY,
		"a choice names its options; only a score is ordered")
