extends RefCounted
## Somebody on the map who is nobody's.
##
## The early game had no pressure in it: the only thing that could come for you was the
## other player, and they were across the map. A barbarian is an owner id and NOT a seat,
## which is the whole trick -- it is never in `players`, so every rule that reads the
## seating ignores it for free.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _bands(cs) -> int:
	var n := 0
	for a in cs.armies.values():
		if a["owner"] == Rules.BARBARIAN_SEAT:
			n += 1
	return n


## Run turns until the raisers have had a chance, without the economy getting in the way.
func _turns(cs, n: int) -> void:
	for i in n:
		cs.food[1] = 10000
		cs.food[2] = 10000
		cs.end_turn()


# --- they turn up ---------------------------------------------------------

func test_a_band_appears(t) -> void:
	var cs = _two_player()
	t.eq(_bands(cs), 0, "the map starts quiet")
	_turns(cs, Rules.BARBARIAN_EVERY)
	t.ok(_bands(cs) > 0, "and does not stay that way")


func test_they_come_every_few_turns_and_not_every_turn(t) -> void:
	var cs = _two_player()
	_turns(cs, 1)
	t.eq(_bands(cs), 0, "not on turn one")


func test_there_is_a_ceiling_on_them(t) -> void:
	# Or a long campaign silts up with bands nobody ever got round to killing.
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY * (Rules.BARBARIAN_BANDS + 4))
	t.ok(_bands(cs) <= Rules.BARBARIAN_BANDS,
		"%d bands, ceiling is %d" % [_bands(cs), Rules.BARBARIAN_BANDS])


func test_they_appear_where_nobody_is_looking(t) -> void:
	# A band that materialised in the middle of somebody's territory reads as a cheat
	# rather than as a raid. This is the one thing fog bought that nothing else uses.
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	for a in cs.armies.values():
		if a["owner"] != Rules.BARBARIAN_SEAT:
			continue
		# Checked against the fog as it was BEFORE they arrived, which is what the raiser
		# saw: an army of its own now makes its hex visible to itself.
		t.ok(not cs.can_see(1, int(a["tile"])) or not cs.can_see(2, int(a["tile"])),
			"it did not walk out of somebody's back garden")


func test_they_cannot_share_a_hex_with_anybody(t) -> void:
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY * 3)
	var seen := {}
	for a in cs.armies.values():
		t.ok(not seen.has(a["tile"]), "two armies on tile %d" % a["tile"])
		seen[a["tile"]] = true


func test_they_stand_on_passable_ground(t) -> void:
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY * 3)
	for a in cs.armies.values():
		if a["owner"] == Rules.BARBARIAN_SEAT:
			t.ok(cs.passable(int(a["tile"])), "nobody raids out of a lake")


func test_raising_them_is_deterministic(t) -> void:
	# So a save reloaded plays the same campaign.
	var a = _two_player()
	var b = _two_player()
	_turns(a, Rules.BARBARIAN_EVERY * 2)
	_turns(b, Rules.BARBARIAN_EVERY * 2)
	t.eq(Snapshot.encode_campaign(a), Snapshot.encode_campaign(b))


# --- they are not a player ------------------------------------------------

func test_they_are_not_in_the_economy(t) -> void:
	# No income, no upkeep, no starvation. They cost nothing to keep because there is
	# nothing keeping them.
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	t.ok(not cs.gold.has(Rules.BARBARIAN_SEAT))
	t.ok(not cs.food.has(Rules.BARBARIAN_SEAT))
	# `upkeep_of` will happily add up what their swords WOULD cost -- it is a sum over
	# armies and knows nothing about seats. What matters is that end_turn only charges
	# owners in `gold`, so the number is never taken from anybody.
	var larder: int = cs.food[1]
	var owed: int = cs.upkeep_of(1)
	cs.end_turn()
	t.ok(cs.food[1] >= larder - owed - Rules.SETTLEMENT_FOOD * 2,
		"player 1 was not billed for somebody else's raiders")


func test_they_do_not_starve_away(t) -> void:
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	var before := _bands(cs)
	t.ok(before > 0)
	cs.food[1] = 0
	cs.food[2] = 0
	for i in 3:
		cs.end_turn()
	t.ok(_bands(cs) >= before, "everybody else is starving; they are not")


func test_they_cannot_win_and_do_not_stop_anybody_winning(t) -> void:
	# `winner` is asked with the SEATS, and a barbarian is not one. Nothing had to be
	# added to it for this -- that is the point of the distinction.
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	for s: Dictionary in cs.settlements:
		s["owner"] = 1
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == 2:
			cs.armies.erase(id)
	t.ok(_bands(cs) > 0, "precondition: there are raiders on the map")
	t.eq(cs.winner([1, 2]), 1, "player 2 is out, and the raiders are not a third player")


func test_nobody_waits_for_them_to_end_a_turn(t) -> void:
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	cs.set_ready(1, true)
	cs.set_ready(2, true)
	t.ok(cs.all_ready([1, 2]), "the seats are what the turn waits on")


func test_they_survive_the_wire(t) -> void:
	var cs = _two_player()
	_turns(cs, Rules.BARBARIAN_EVERY)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null, "a negative owner is an owner like any other")
	t.eq(_bands(back), _bands(cs))


# --- what they do ---------------------------------------------------------

func test_a_raider_only_marches(t) -> void:
	var cs = _two_player()
	cs.gold[Rules.BARBARIAN_SEAT] = 100000        # even handed a purse
	cs.add_army(Rules.BARBARIAN_SEAT, _somewhere_empty(cs), [&"sword"])
	var brain = Ai.new(Rules.BARBARIAN_SEAT)
	brain.raids = true
	for order in brain.campaign_orders(cs):
		var kind: int = int(Orders.decode(order).get("type", -1))
		t.ok(kind == Orders.Type.ARMY_MOVE or kind == Orders.Type.READY
				or kind == Orders.Type.ARMY_STANCE,
			"a raider builds nothing and researches nothing (got order %d)" % kind)


func test_a_raider_goes_for_a_town_somebody_holds(t) -> void:
	# An empty village is not a raid, and going for one would park every band on a
	# neutral town for the whole campaign.
	var cs = _two_player()
	var here := _somewhere_empty(cs)
	var band: Dictionary = cs.add_army(Rules.BARBARIAN_SEAT, here, [&"sword"])
	var brain = Ai.new(Rules.BARBARIAN_SEAT)
	brain.raids = true
	var held := {}
	for s: Dictionary in cs.settlements:
		if s["owner"] != 0:
			held[int(s["tile"])] = true
	for order in brain.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.ARMY_MOVE:
			# It marches along a path, so the DESTINATION is what is being judged.
			t.ok(held.has(int(d["dest"])), "tile %d is somebody's" % d["dest"])


func test_an_ordinary_ai_still_takes_neutral_towns(t) -> void:
	# The raider rule must not leak into the player-AI, whose whole early game is those
	# four towns down the middle of the map.
	var cs = _two_player()
	var brain = Ai.new(1)
	var targets := []
	for order in brain.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.ARMY_MOVE:
			targets.append(int(d["dest"]))
	t.ok(not targets.is_empty(), "it is going somewhere")


func _somewhere_empty(cs) -> int:
	for tile in cs.terrain.size():
		if cs.passable(tile) and cs.army_at(tile) == null and cs.settlement_at(tile) == null:
			return tile
	return 0
