extends RefCounted
## M24: two trees, one pool, and one test per row proving the row.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Replay := preload("res://net/replay.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _rich(owner := 1):
	var cs = Campaign.generate([1, 2], 12345)
	cs.gold[owner] = 100000
	cs.research[owner] = 100000
	return cs


func _own_town(cs, owner := 1) -> Dictionary:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s
	return {}


func _spot_for(cs, name: StringName, owner := 1) -> int:
	var town := _own_town(cs, owner)
	for tile in cs.structures.size():
		if Campaign.hex_distance(tile, town["tile"]) > Rules.WORK_RADIUS:
			continue
		if cs.can_place(owner, tile, name):
			return tile
	return -1


# --- the pool and the prerequisites ---------------------------------------

func test_research_accumulates_every_turn(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var before: int = int(cs.research.get(1, 0))
	cs.end_turn()
	t.ok(int(cs.research[1]) > before, "a town produces research on its own")


func test_learning_costs_the_pool(t) -> void:
	var cs = _rich()
	var before: int = cs.research[1]
	t.ok(cs.learn(1, &"husbandry"))
	t.eq(cs.research[1], before - int(Rules.TECHS[&"husbandry"]["cost"]))
	t.ok(cs.techs_of(1).has(&"husbandry"))


func test_you_cannot_learn_what_you_cannot_pay_for(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.research[1] = 1
	t.ok(not cs.learn(1, &"husbandry"))
	t.ok(cs.techs_of(1).is_empty())


func test_prerequisites_are_enforced(t) -> void:
	var cs = _rich()
	t.ok(not cs.can_learn(1, &"irrigation"), "irrigation needs husbandry first")
	t.ok(cs.learn(1, &"husbandry"))
	t.ok(cs.learn(1, &"irrigation"))


func test_nothing_is_learned_twice(t) -> void:
	var cs = _rich()
	t.ok(cs.learn(1, &"drill"))
	t.ok(not cs.learn(1, &"drill"), "or its effect would compound")
	t.eq(cs.techs_of(1).size(), 1)


func test_one_pool_feeds_both_trees(t) -> void:
	# The reason there are two trees rather than one list: every tech taken in one is a
	# tech not taken in the other.
	var cs = Campaign.generate([1, 2], 12345)
	# Enough for either one on its own, not enough for both.
	cs.research[1] = maxi(int(Rules.TECHS[&"husbandry"]["cost"]), int(Rules.TECHS[&"drill"]["cost"]))
	t.ok(cs.can_learn(1, &"drill"), "either is affordable to start with")
	t.ok(cs.learn(1, &"husbandry"))
	t.ok(not cs.can_learn(1, &"drill"), "but not both")


func test_what_one_player_knows_is_their_own(t) -> void:
	var cs = _rich()
	cs.learn(1, &"drill")
	t.ok(cs.techs_of(2).is_empty(), "nobody learns by watching")


# --- the economy tree, a row at a time ------------------------------------

func _yield_with(tech: StringName, structure: StringName, key: String) -> Array:
	var plain = _rich()
	var learned = _rich()
	for needed: StringName in Rules.TECHS[tech]["needs"]:
		learned.learn(1, needed)
	learned.learn(1, tech)
	var out := []
	for cs in [plain, learned]:
		var tile: int = _spot_for(cs, structure)
		if tile < 0:
			out.append(-1)
			continue
		cs.place(1, tile, structure)
		out.append(int(cs.worked_yield(1)[key]))
	return out


func test_husbandry_feeds_more(t) -> void:
	var both := _yield_with(&"husbandry", &"farm", "food")
	t.ok(both[1] > both[0], "a farm should feed more with husbandry (%d vs %d)" % [both[1], both[0]])


func test_irrigation_feeds_more_still(t) -> void:
	var husbandry := _yield_with(&"husbandry", &"farm", "food")
	var irrigated := _yield_with(&"irrigation", &"farm", "food")
	t.ok(irrigated[1] > husbandry[1], "and irrigation compounds on top of it (%d vs %d)" % [
		irrigated[1], husbandry[1]])


func test_coinage_pays_more(t) -> void:
	var both := _yield_with(&"coinage", &"market", "gold")
	t.ok(both[1] > both[0], "a market should pay more with coinage (%d vs %d)" % [both[1], both[0]])


func test_masonry_makes_building_cheaper(t) -> void:
	var cs = _rich()
	var full: int = cs.cost_of(1, &"barracks")
	cs.learn(1, &"masonry")
	t.ok(cs.cost_of(1, &"barracks") < full,
		"masonry should cut the price (%d vs %d)" % [cs.cost_of(1, &"barracks"), full])

	var tile := _spot_for(cs, &"barracks")
	if tile >= 0:
		var purse: int = cs.gold[1]
		cs.place(1, tile, &"barracks")
		t.eq(cs.gold[1], purse - cs.cost_of(1, &"barracks"), "and the discount is what is charged")


func test_banking_pays_every_town(t) -> void:
	var plain = Campaign.generate([1, 2], 12345)
	var banked = _rich()
	banked.learn(1, &"coinage")
	banked.learn(1, &"banking")
	var plain_before: int = plain.gold[1]
	var banked_before: int = banked.gold[1]
	plain.end_turn()
	banked.end_turn()
	t.ok(banked.gold[1] - banked_before > plain.gold[1] - plain_before,
		"a banked treasury grows faster")


func test_guilds_widen_a_towns_reach(t) -> void:
	var cs = _rich()
	var before: int = cs.reach_of(1)
	cs.learn(1, &"masonry")
	cs.learn(1, &"guilds")
	t.eq(cs.reach_of(1), before + 1, "guilds reach a hex further")

	# And that reach is what decides where you may build.
	var town := _own_town(cs)
	var further := -1
	for tile in cs.structures.size():
		if Campaign.hex_distance(tile, town["tile"]) == before + 1 \
				and cs.terrain[tile] == Campaign.Terrain.PLAINS and cs.structure_at(tile) == &"":
			further = tile
			break
	if further >= 0:
		t.ok(cs.can_place(1, further, &"farm"), "so a hex that was out of reach is in it now")


# --- the battle tree, a row at a time -------------------------------------

func _duel(learned: Array, seconds := 12.0, kind := &"spear") -> Array:
	var bs = BattleState.new()
	var mine = bs.add(1, kind, Vector2.ZERO, 0.0)
	var theirs = bs.add(2, &"spear", Vector2.ZERO, PI)
	var apart := BattleState.reach(mine, BattleState.Exposure.FRONT) \
		+ BattleState.reach(theirs, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	mine.pos = Vector2(-apart * 0.5, 0)
	theirs.pos = Vector2(apart * 0.5, 0)
	mine.target = mine.pos
	theirs.target = theirs.pos
	bs.techs[1] = learned
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()
	return [bs, mine, theirs]


func test_drill_keeps_a_regiment_fresher(t) -> void:
	var plain := _duel([])
	var drilled := _duel([&"drill"])
	t.ok(drilled[1].stamina > plain[1].stamina,
		"drilled men tire slower (%.2f vs %.2f)" % [drilled[1].stamina, plain[1].stamina])


func test_discipline_keeps_a_regiment_steadier(t) -> void:
	var plain := _duel([])
	var steady := _duel([&"drill", &"discipline"])
	t.ok(steady[1].morale > plain[1].morale,
		"disciplined men hold on longer (%.0f vs %.0f)" % [steady[1].morale, plain[1].morale])


func test_armoury_cuts_what_gets_through(t) -> void:
	var plain := _duel([])
	var armoured := _duel([&"armoury"])
	t.ok(armoured[1].strength > plain[1].strength,
		"armour should keep men alive (%d vs %d)" % [armoured[1].strength, plain[1].strength])


func test_stirrups_make_cavalry_hit_harder(t) -> void:
	var plain := _duel([&"horsemanship"], 12.0, &"cavalry")
	var shod := _duel([&"horsemanship", &"stirrups"], 12.0, &"cavalry")
	t.ok(shod[2].strength < plain[2].strength,
		"stirrups should cost the enemy more (%d left vs %d)" % [shod[2].strength, plain[2].strength])


func test_stirrups_do_nothing_for_infantry(t) -> void:
	var plain := _duel([&"horsemanship"])
	var shod := _duel([&"horsemanship", &"stirrups"])
	t.eq(shod[2].strength, plain[2].strength, "a spearman has no stirrups")


func test_horsemanship_makes_cavalry_faster(t) -> void:
	var bs = BattleState.new()
	var quick = bs.add(1, &"cavalry", Vector2.ZERO, 0.0)
	var plain = bs.add(2, &"cavalry", Vector2(0, 900), 0.0)
	bs.techs[1] = [&"horsemanship"]
	quick.order_move(Vector2(100000, 0), 0.0)
	plain.order_move(Vector2(100000, 900), 0.0)
	for i in Rules.TICK_HZ:
		bs.step()
	t.ok(quick.pos.x > plain.pos.x * 1.1,
		"better horsemen cover more ground (%.0f vs %.0f)" % [quick.pos.x, plain.pos.x])


func test_siegecraft_makes_walls_count_for_less(t) -> void:
	var bs = BattleState.new()
	bs.techs[1] = [&"armoury", &"siegecraft"]
	t.near(bs.tech(1, &"siege"), float(Rules.TECHS[&"siegecraft"]["effect"]["siege"]))
	t.near(bs.tech(2, &"siege"), 1.0, 0.0001, "and does nothing for somebody who has not learned it")


func test_a_battle_between_unequal_armies_is_measurably_different(t) -> void:
	# A full battle, not a skirmish: under frontage-limited combat attrition is slow, so
	# a few per cent of damage only reads over the length of a real fight.
	var plain := _duel([], 70.0)
	var trained := _duel([&"drill", &"armoury"], 70.0)
	t.ok(trained[1].strength > plain[1].strength)
	t.ok(trained[2].strength < plain[2].strength, "and it should be doing more damage too")
	print("  [feel] 70s duel: untrained keeps %d men and leaves the enemy %d;" % [
		plain[1].strength, plain[2].strength])
	print("         drilled and armoured keeps %d and leaves them %d" % [
		trained[1].strength, trained[2].strength])


# --- the wire -------------------------------------------------------------

func test_what_is_known_survives_the_campaign_wire(t) -> void:
	var cs = _rich()
	cs.learn(1, &"husbandry")
	cs.learn(1, &"drill")
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back != null:
		t.eq(back.known, cs.known)
		t.eq(back.research, cs.research)
		t.eq(Snapshot.encode_campaign(back), Snapshot.encode_campaign(cs))


func test_techs_survive_the_battle_wire(t) -> void:
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.techs[1] = [&"drill", &"armoury"]
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	if back != null:
		t.eq(back.techs, bs.techs)
		t.near(back.tech(1, &"stamina"), bs.tech(1, &"stamina"))


func test_a_trained_battle_replays(t) -> void:
	# Battle techs have to be on the wire or a replay rebuilds the fight without them.
	var s := _duel([&"drill", &"armoury"], 0.0)
	var bs = s[0]
	var r = Replay.new()
	r.begin(Snapshot.encode_battle(bs))
	for i in int(20.0 * Rules.TICK_HZ):
		bs.step()
	r.finish(Snapshot.encode_battle(bs), bs.tick)
	t.ok(r.verify(), "a trained army has to fight the same battle twice")


func test_nonsense_techs_off_the_wire_are_refused(t) -> void:
	var cs = _rich()
	cs.learn(1, &"drill")
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var unknown = d.duplicate(true)
	unknown[11][1] = [&"alchemy"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(unknown)), null, "a tech nobody has heard of")

	var doubled = d.duplicate(true)
	doubled[11][1] = [&"drill", &"drill"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(doubled)), null, "learning it twice would compound it")

	var wrong = d.duplicate(true)
	wrong[11][1] = "drill"
	t.eq(Snapshot.decode_campaign(var_to_bytes(wrong)), null, "what is known has to be a list")

	var battle = BattleState.new()
	battle.techs[1] = [&"drill"]
	var b = bytes_to_var(Snapshot.encode_battle(battle))
	b[5][1] = [&"alchemy"]
	t.eq(Snapshot.decode_battle(var_to_bytes(b)), null, "and the same on the battle wire")


func test_the_research_order_validates(t) -> void:
	var order: Dictionary = Orders.decode(Orders.research(&"drill"))
	t.eq(order.get("type"), Orders.Type.RESEARCH)
	t.eq(order.get("tech"), &"drill")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.RESEARCH, &"alchemy"])), {},
		"not a tech")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.RESEARCH, 7])), {},
		"not even a name")


# --- a loaded campaign remembers -------------------------------------------

func test_the_ai_learns_something(t) -> void:
	var cs = _rich()
	var brain = Ai.new(1)
	var learned := false
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var order := Orders.decode(bytes)
		if not order.is_empty() and order["type"] == Orders.Type.RESEARCH:
			learned = true
			t.ok(cs.can_learn(1, order["tech"]), "and it picks one it can actually afford")
	t.ok(learned, "an AI with a full treasury should be researching")
