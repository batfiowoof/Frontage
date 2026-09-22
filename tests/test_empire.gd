extends RefCounted
## Towns that grow and resent you, roads, and what an army does between turns.
##
## A settlement used to be a static object worth a flat SETTLEMENT_GOLD forever, and
## taking one was permanent, silent and free. Between them that made the campaign a
## headcount of towns: no reason to develop what you had and no cost to taking more.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Save := preload("res://net/save.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _town_of(cs, owner := 1) -> Dictionary:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s
	return {}


func _army_of(cs, owner := 1) -> Dictionary:
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == owner:
			return cs.armies[id]
	return {}


# --- towns that grow ------------------------------------------------------

func test_a_town_starts_at_one_and_is_worth_what_it_always_was(t) -> void:
	# The balance everything else was tuned against has to survive this landing.
	var s := _town_of(_two_player())
	t.eq(Campaign.pop_of(s), Rules.START_POP)
	t.eq(Campaign.settlement_income(s)["gold"], Rules.SETTLEMENT_GOLD)
	t.eq(Campaign.settlement_income(s)["food"], Rules.SETTLEMENT_FOOD)


func test_population_multiplies_what_a_town_pays(t) -> void:
	var small := {"tile": 0, "owner": 1, "name": "a", "pop": 1, "unrest": 0}
	var big := {"tile": 0, "owner": 1, "name": "b", "pop": Rules.MAX_POP, "unrest": 0}
	t.ok(Campaign.settlement_income(big)["gold"] > Campaign.settlement_income(small)["gold"])
	t.ok(Campaign.settlement_income(big)["research"] > Campaign.settlement_income(small)["research"])


func test_a_surplus_grows_a_town_and_is_spent_doing_it(t) -> void:
	var cs = _two_player()
	cs.food[1] = 10000
	var before: int = Campaign.pop_of(_town_of(cs))
	var larder: int = cs.food[1]
	cs.end_turn()
	t.ok(Campaign.pop_of(_town_of(cs)) > before, "a fed empire grows")
	t.ok(cs.food[1] < larder + Rules.SETTLEMENT_FOOD, "and the surplus went into it")


func test_growth_stops_at_the_cap(t) -> void:
	var cs = _two_player()
	cs.food[1] = 100000
	for i in 20:
		cs.end_turn()
	t.eq(Campaign.pop_of(_town_of(cs)), Rules.MAX_POP, "a town is not a city forever")


func test_an_empire_with_nothing_spare_does_not_grow(t) -> void:
	# Growth is bought with the SURPLUS. An empire that eats everything it makes is fed
	# and static, which is the decision: another regiment or another point of population.
	var cs = _two_player()
	cs.food[1] = 0
	var before: int = Campaign.pop_of(_town_of(cs))
	cs.end_turn()
	t.eq(Campaign.pop_of(_town_of(cs)), before)


# --- towns that resent you ------------------------------------------------

func test_taking_a_town_makes_it_angry(t) -> void:
	var cs = _two_player()
	var neutral := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 0:
			neutral = int(s["tile"])
			break
	var a: Dictionary = _army_of(cs)
	a["tile"] = neutral
	cs._capture_if_undefended(a)
	var taken = cs.settlement_at(neutral)
	t.eq(taken["owner"], 1)
	t.eq(Campaign.unrest_of(taken), Rules.UNREST_ON_CAPTURE, "it came with people")


func test_an_angry_town_pays_less(t) -> void:
	var calm := {"tile": 0, "owner": 1, "name": "a", "pop": 3, "unrest": 0}
	var cross := {"tile": 0, "owner": 1, "name": "b", "pop": 3, "unrest": Rules.UNREST_ON_CAPTURE}
	t.ok(Campaign.settlement_income(cross)["gold"] < Campaign.settlement_income(calm)["gold"])
	t.near(Campaign.contentment(calm), 1.0)
	t.ok(Campaign.contentment(cross) < 1.0 and Campaign.contentment(cross) > 0.0,
		"suppressed, not switched off: there is no cliff where a town stops paying")


func test_a_small_empire_calms_a_town_down(t) -> void:
	var cs = _two_player()
	var mine: Dictionary = _town_of(cs)
	mine["unrest"] = Rules.UNREST_ON_CAPTURE
	cs.end_turn()
	t.ok(Campaign.unrest_of(mine) < Rules.UNREST_ON_CAPTURE, "one or two towns is governable")


func test_an_angry_town_does_not_grow(t) -> void:
	# Or a province in revolt would still be quietly getting bigger.
	var cs = _two_player()
	cs.food[1] = 100000
	var mine: Dictionary = _town_of(cs)
	mine["unrest"] = Rules.UNREST_ON_CAPTURE
	var before: int = Campaign.pop_of(mine)
	cs.end_turn()
	t.eq(Campaign.pop_of(mine), before)


func test_a_big_empire_cannot_calm_them_all(t) -> void:
	# The ceiling on conquest: not that you cannot take the next town, but that taking
	# it keeps the last one angry.
	var cs = _two_player()
	for s: Dictionary in cs.settlements:
		s["owner"] = 1
		s["unrest"] = Rules.UNREST_ON_CAPTURE
	t.ok(cs.settlements_of(1) > Rules.UNREST_FREE_TOWNS, "precondition: it is overstretched")
	var before: int = Campaign.unrest_of(cs.settlements[0])
	cs.end_turn()
	t.ok(Campaign.unrest_of(cs.settlements[0]) >= before, "it did not settle down")


## Every town on the map handed to one player and left simmering: overstretched, which
## is the only state a revolt can happen in. A small empire always settles down, and that
## is deliberate -- the empire term is what makes unrest a ceiling rather than a tax.
func _overstretched():
	var cs = _two_player()
	for s: Dictionary in cs.settlements:
		s["owner"] = 1
		s["unrest"] = Rules.UNREST_REVOLT
	return cs


func test_a_town_pushed_far_enough_revolts(t) -> void:
	var cs = _overstretched()
	var mine: Dictionary = cs.settlements[0]
	cs.end_turn()
	t.eq(mine["owner"], 0, "it went back to being nobody's")
	t.eq(Campaign.unrest_of(mine), 0, "and starts again from calm")


func test_a_small_empire_never_loses_a_town_to_unrest(t) -> void:
	# However angry it is. Governing what you can hold has to actually work, or the
	# mechanic is a timer rather than a ceiling.
	var cs = _two_player()
	var mine: Dictionary = _town_of(cs)
	mine["unrest"] = Rules.UNREST_REVOLT
	for i in Rules.UNREST_REVOLT + 1:      # it settles a point a turn, so give it that many
		cs.end_turn()
	t.eq(mine["owner"], 1)
	t.eq(Campaign.unrest_of(mine), 0, "and it eventually settles completely")


func test_a_revolt_never_hands_the_town_to_an_enemy(t) -> void:
	# It revolted against YOU. Giving it to whoever is nearest would make unrest a
	# weapon pointed at somebody else.
	var cs = _overstretched()
	cs.end_turn()
	for s: Dictionary in cs.settlements:
		t.ok(s["owner"] != 2, "a revolt goes neutral, never to the other player")


# --- roads ----------------------------------------------------------------

func test_a_single_road_hex_buys_nothing(t) -> void:
	# A road is worth nothing alone and everything as a chain, which is what a road IS.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	var onward: int = _passable_neighbour(cs, int(a["tile"]))
	cs.structures[onward] = Campaign.structure_code(&"road")
	var before: int = a["move_left"]
	cs.move_army(a["id"], onward)
	t.eq(a["move_left"], before - 1, "one made-up hex out of two is not a road")


func test_road_to_road_is_free(t) -> void:
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	var onward: int = _passable_neighbour(cs, int(a["tile"]))
	cs.structures[int(a["tile"])] = Campaign.structure_code(&"road")
	cs.structures[onward] = Campaign.structure_code(&"road")
	var before: int = a["move_left"]
	cs.move_army(a["id"], onward)
	t.eq(a["tile"], onward, "it moved")
	t.eq(a["move_left"], before, "and it cost nothing")


func _passable_neighbour(cs, tile: int) -> int:
	for n in cs.adjacent(tile):
		if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
			return n
	return -1


# --- what an army is doing between turns ----------------------------------

func test_an_army_marches_by_default(t) -> void:
	t.eq(Campaign.stance_of(_army_of(_two_player())), Campaign.Stance.MARCH)
	t.eq(Campaign.move_points(_army_of(_two_player())), Rules.ARMY_MOVE_POINTS)


func test_a_forced_march_covers_more_ground(t) -> void:
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	t.ok(cs.set_stance(1, a["id"], Campaign.Stance.FORCED))
	t.eq(Campaign.move_points(a), Rules.ARMY_MOVE_POINTS + Rules.FORCED_MARCH_BONUS)
	t.ok(a["move_left"] > 0, "and it does not cost this turn's movement")


func test_digging_in_costs_the_turn(t) -> void:
	# Otherwise an army marches its three hexes, digs in on arrival and pays nothing.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	t.ok(cs.set_stance(1, a["id"], Campaign.Stance.FORTIFY))
	t.eq(a["move_left"], 0)
	t.near(Campaign.fortification(a), Rules.FORTIFY_DEFENSE)


func test_lying_in_wait_costs_the_turn_too(t) -> void:
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	t.ok(cs.set_stance(1, a["id"], Campaign.Stance.AMBUSH))
	t.eq(a["move_left"], 0)


func test_an_ambushing_army_is_not_sent_to_the_enemy(t) -> void:
	# The one stance fog makes possible: seeing the hex is not seeing the army.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs, 1)
	cs.seen[2] = PackedByteArray()
	cs.seen[2].resize(cs.terrain.size())
	cs.seen[2].fill(1)                                  # player 2 can see everywhere
	t.ok(_has_army(cs.armies_visible_to(2), a["id"]), "precondition: normally visible")
	cs.set_stance(1, a["id"], Campaign.Stance.AMBUSH)
	t.ok(not _has_army(cs.armies_visible_to(2), a["id"]))
	t.ok(_has_army(cs.armies_visible_to(1), a["id"]), "but you can always see your own")


func test_marching_gives_away_a_hiding_army(t) -> void:
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	cs.set_stance(1, a["id"], Campaign.Stance.AMBUSH)
	a["move_left"] = Rules.ARMY_MOVE_POINTS          # as a new turn would
	cs.move_army(a["id"], _passable_neighbour(cs, int(a["tile"])))
	t.eq(Campaign.stance_of(a), Campaign.Stance.MARCH,
		"an army that walked is not dug in and is not hiding")


func test_a_forced_march_survives_marching(t) -> void:
	# It is the one stance that describes HOW it is moving, so moving must not clear it.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	cs.set_stance(1, a["id"], Campaign.Stance.FORCED)
	cs.move_army(a["id"], _passable_neighbour(cs, int(a["tile"])))
	t.eq(Campaign.stance_of(a), Campaign.Stance.FORCED)


func test_you_cannot_post_somebody_elses_army(t) -> void:
	var cs = _two_player()
	t.ok(not cs.set_stance(2, _army_of(cs, 1)["id"], Campaign.Stance.FORTIFY))


func test_a_stance_nobody_has_heard_of_is_refused(t) -> void:
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	t.ok(not cs.set_stance(1, a["id"], 99))
	t.ok(not cs.set_stance(1, a["id"], -1))
	t.eq(Campaign.stance_of(a), Campaign.Stance.MARCH)


func _has_army(list: Array, id: int) -> bool:
	for a: Dictionary in list:
		if a["id"] == id:
			return true
	return false


# --- the wire -------------------------------------------------------------

func test_the_stance_order_round_trips(t) -> void:
	var d := Orders.decode(Orders.army_stance(4, Campaign.Stance.AMBUSH))
	t.eq(d["type"], Orders.Type.ARMY_STANCE)
	t.eq(d["army_id"], 4)
	t.eq(d["stance"], Campaign.Stance.AMBUSH)


func test_a_stance_off_the_end_of_the_enum_is_refused(t) -> void:
	# It would be stored on the army and go straight back out to everybody.
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.ARMY_STANCE, 1, 99])), {})
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.ARMY_STANCE, 1, -1])), {})


func test_the_order_enum_was_appended_to(t) -> void:
	t.eq(Orders.Type.FOUND, 13)
	t.eq(Orders.Type.ARMY_STANCE, 14)


func test_pop_unrest_and_stance_survive_the_wire(t) -> void:
	var cs = _two_player()
	var mine: Dictionary = _town_of(cs)
	mine["pop"] = 3
	mine["unrest"] = 2
	var a: Dictionary = _army_of(cs)
	cs.set_stance(1, a["id"], Campaign.Stance.FORTIFY)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	t.eq(Campaign.pop_of(back.settlement_at(mine["tile"])), 3)
	t.eq(Campaign.unrest_of(back.settlement_at(mine["tile"])), 2)
	t.eq(Campaign.stance_of(back.armies[a["id"]]), Campaign.Stance.FORTIFY)


func test_an_impossible_population_is_refused(t) -> void:
	# It multiplies a town's output, so a peer that could name it could name its income.
	var cs = _two_player()
	_town_of(cs)["pop"] = Rules.MAX_POP + 40
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_an_impossible_unrest_is_refused(t) -> void:
	var cs = _two_player()
	_town_of(cs)["unrest"] = -3
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_all_of_it_survives_a_save(t) -> void:
	var cs = _two_player()
	_town_of(cs)["pop"] = 4
	_town_of(cs)["unrest"] = 3
	var a: Dictionary = _army_of(cs)
	cs.set_stance(1, a["id"], Campaign.Stance.AMBUSH)
	var back = Save.from_bytes(Save.of(cs, [1, 2]).to_bytes()).restore([1, 2])
	t.ok(back != null)
	t.eq(Campaign.pop_of(back.settlement_at(_town_of(cs)["tile"])), 4)
	t.eq(Campaign.stance_of(back.armies[a["id"]]), Campaign.Stance.AMBUSH)
