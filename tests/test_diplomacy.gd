extends RefCounted
## War and peace between seats, which nothing modelled at all.
##
## Everyone was permanently at war with everyone, which is not a state so much as the
## absence of one: two armies meeting always fought, and there was nothing a player could
## do about a second enemy except lose to both at once.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Save := preload("res://net/save.gd")
const Jev := preload("res://net/jev.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _army_of(cs, owner := 1) -> Dictionary:
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == owner:
			return cs.armies[id]
	return {}


# --- the default --------------------------------------------------------

func test_everybody_starts_at_war(t) -> void:
	# It is what it always was, and every balance decision so far assumed it.
	var cs = _two_player()
	t.ok(cs.at_war(1, 2))
	t.ok(cs.at_war(2, 1))
	t.eq(cs.relations.size(), 0, "and it costs no rows to say so")


func test_nobody_fights_themselves(t) -> void:
	t.ok(not _two_player().at_war(1, 1))


func test_the_neutral_towns_are_always_fair_game(t) -> void:
	# A peace with nobody-in-particular would make them untakeable, and they exist to
	# be taken.
	var cs = _two_player()
	t.ok(cs.at_war(1, 0))
	t.ok(not cs.make_peace(1, 0))
	t.ok(cs.at_war(1, 0), "still")


# --- making it ------------------------------------------------------------

func test_peace_is_symmetric_by_construction(t) -> void:
	# The pair is stored low-id-first, so at_war(a, b) and at_war(b, a) cannot disagree.
	var cs = _two_player()
	t.ok(cs.make_peace(2, 1))
	t.ok(not cs.at_war(1, 2))
	t.ok(not cs.at_war(2, 1))
	t.eq(cs.relations.size(), 1, "one row per pair, whichever way round it was asked")


func test_making_peace_twice_is_still_one_row(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	cs.make_peace(2, 1)
	t.eq(cs.relations.size(), 1)


func test_war_can_be_declared_again(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	t.ok(cs.declare_war(1, 2))
	t.ok(cs.at_war(1, 2))


func test_a_relation_nobody_has_heard_of_is_refused(t) -> void:
	var cs = _two_player()
	t.ok(not cs.set_relation(1, 2, 99))
	t.ok(cs.at_war(1, 2))


# --- what it stops --------------------------------------------------------

func test_two_armies_at_peace_do_not_fight(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	var mine: Dictionary = _army_of(cs, 1)
	var theirs: Dictionary = _army_of(cs, 2)
	theirs["tile"] = _empty_neighbour(cs, int(mine["tile"]))
	var result: Dictionary = cs.move_army(int(mine["id"]), int(theirs["tile"]))
	t.eq(result["collision"], [], "walking into them is not a battle")
	t.ok(mine["tile"] != theirs["tile"], "and they still cannot share a hex")


func test_two_armies_at_war_still_fight(t) -> void:
	var cs = _two_player()
	var mine: Dictionary = _army_of(cs, 1)
	var theirs: Dictionary = _army_of(cs, 2)
	theirs["tile"] = _empty_neighbour(cs, int(mine["tile"]))
	var result: Dictionary = cs.move_army(int(mine["id"]), int(theirs["tile"]))
	t.eq(result["collision"], [mine["id"], theirs["id"]])


func test_you_do_not_take_the_town_of_somebody_you_are_at_peace_with(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	var theirs := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 2:
			theirs = int(s["tile"])
	var a: Dictionary = _army_of(cs, 1)
	a["tile"] = theirs
	cs._capture_if_undefended(a)
	t.eq(cs.settlement_at(theirs)["owner"], 2, "walking into a friend's town is a visit")


func _empty_neighbour(cs, tile: int) -> int:
	for n in cs.adjacent(tile):
		if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
			return n
	return -1


# --- the orders -----------------------------------------------------------

func test_the_orders_round_trip(t) -> void:
	var p := Orders.decode(Orders.propose(7))
	t.eq(p["type"], Orders.Type.PROPOSE)
	t.eq(p["seat"], 7)
	var a := Orders.decode(Orders.answer(7, true))
	t.eq(a["type"], Orders.Type.ANSWER)
	t.eq(a["seat"], 7)
	t.eq(a["accept"], true)


func test_malformed_treaty_orders_are_refused(t) -> void:
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.PROPOSE, "not a seat"])), {})
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.ANSWER, 1])), {})


func test_the_enum_was_appended_to(t) -> void:
	t.eq(Orders.Type.DEPLOYED, 15)
	t.eq(Orders.Type.PROPOSE, 16)
	t.eq(Orders.Type.ANSWER, 17)


# --- the wire and the save ------------------------------------------------

func test_relations_survive_the_wire(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	t.ok(not back.at_war(1, 2))


func test_an_unsorted_pair_is_refused(t) -> void:
	# The sim relies on low-id-first: a row the other way round would make at_war(a, b)
	# and at_war(b, a) disagree, and nothing else would notice.
	var cs = _two_player()
	cs.relations = [[2, 1, Campaign.Relation.PEACE]]
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_a_relation_off_the_end_of_the_enum_is_refused(t) -> void:
	var cs = _two_player()
	cs.relations = [[1, 2, 44]]
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_a_peace_survives_a_save(t) -> void:
	var cs = _two_player()
	cs.make_peace(1, 2)
	var back = Save.from_bytes(Save.of(cs, [1, 2]).to_bytes()).restore([1, 2])
	t.ok(back != null and not back.at_war(1, 2))


func test_a_peace_follows_the_seats_it_belonged_to(t) -> void:
	# Peer ids are random per session, so relations remap with the treasuries and the
	# fog. Missing it would put a peace between the wrong two people.
	var cs = _two_player()
	cs.make_peace(1, 2)
	var back = Save.from_bytes(Save.of(cs, [1, 2]).to_bytes()).restore([88, 77])
	t.ok(back != null)
	t.ok(not back.at_war(88, 77), "the pair came across")
	t.eq(back.relations[0][0], 77, "and is still stored low-id-first after the remap")
	t.eq(back.relations[0][1], 88)


# --- who accepts ----------------------------------------------------------

func test_a_losing_ai_takes_the_peace(t) -> void:
	# A peace is worth most to whoever is losing.
	var cs = _two_player()
	for s: Dictionary in cs.settlements:
		s["owner"] = 2
	var brain = Ai.new(1)
	brain.pending_offer = 2
	t.ok(_answers(brain, cs), "outmatched, so it takes what it is offered")


func test_a_winning_ai_fights_on(t) -> void:
	var cs = _two_player()
	for s: Dictionary in cs.settlements:
		s["owner"] = 1
	var brain = Ai.new(1)
	brain.pending_offer = 2
	t.ok(not _answers(brain, cs), "a player who is winning has no reason to stop")


func test_jev_overrules_the_heuristic(t) -> void:
	# The noul is a probability, and at or above 0.5 it is a yes. The heuristic here
	# would refuse, so this only passes if the advice is what decided it.
	var cs = _two_player()
	for s: Dictionary in cs.settlements:
		s["owner"] = 1
	var brain = Ai.new(1)
	brain.pending_offer = 2
	brain.advice["peace"] = 0.9
	t.ok(_answers(brain, cs), "it was told to take it")
	brain = Ai.new(1)
	brain.pending_offer = 2
	brain.advice["peace"] = 0.1
	t.ok(not _answers(brain, cs))


func test_the_offer_is_answered_once(t) -> void:
	var cs = _two_player()
	var brain = Ai.new(1)
	brain.pending_offer = 2
	brain.campaign_orders(cs)
	t.eq(brain.pending_offer, 0)
	var again := 0
	for order in brain.campaign_orders(cs):
		if Orders.decode(order).get("type") == Orders.Type.ANSWER:
			again += 1
	t.eq(again, 0, "an offer already answered is not answered again")


## Whether the brain's answer to its pending offer is yes.
func _answers(brain, cs) -> bool:
	for order in brain.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.ANSWER:
			return bool(d["accept"])
	return false


# --- the question Jev is asked --------------------------------------------

func test_the_peace_question_is_a_noul(t) -> void:
	# The first question in this game that is not a `choice`, and the right shape for
	# it: there is no list of options, and the number IS the confidence.
	var cs = _two_player()
	var asked := Jev.new().campaign_questions(cs, 1, 2)
	t.ok(asked.has("peace"))
	t.eq(asked["peace"]["type"], "noul")
	t.ok(str(asked["peace"]["instructions"]).contains("2"), "it names who is asking")


func test_nothing_is_asked_when_nobody_is_waiting(t) -> void:
	# Or it would cost a question on every turn of every campaign.
	var cs = _two_player()
	t.ok(not Jev.new().campaign_questions(cs, 1, 0).has("peace"))


func test_a_noul_is_parsed_without_a_separate_confidence(t) -> void:
	var out := Jev.parse_answers({"answers": {"peace": {"type": "noul", "noul": 0.81}}})
	t.near(float(out["peace"]), 0.81, 0.0001, "the number already is one")
