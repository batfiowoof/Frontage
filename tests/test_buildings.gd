extends RefCounted
## M11: buildings, the unit kinds they unlock, upkeep with teeth, and walls.

const Campaign := preload("res://sim/campaign_state.gd")
const Autoresolve := preload("res://sim/autoresolve.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _town_of(cs, owner: int) -> Dictionary:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s
	return {}


func _neutral_town(cs) -> Dictionary:
	return _town_of(cs, 0)


# --- building -------------------------------------------------------------

func test_building_costs_gold_and_sticks(t) -> void:
	var cs = _two_player()
	var town := _town_of(cs, 1)
	var before: int = cs.gold[1]
	t.ok(cs.build(1, town["tile"], &"market"), "owned and affordable")
	t.eq(cs.gold[1], before - int(Rules.BUILDINGS[&"market"]["cost"]))
	t.ok(town["buildings"].has(&"market"))


func test_you_cannot_build_twice_or_abroad_or_broke(t) -> void:
	var cs = _two_player()
	var mine := _town_of(cs, 1)
	cs.build(1, mine["tile"], &"market")
	var after: int = cs.gold[1]
	t.ok(not cs.build(1, mine["tile"], &"market"), "one market is enough")
	t.eq(cs.gold[1], after, "a refused build costs nothing")

	t.ok(not cs.build(1, _town_of(cs, 2)["tile"], &"market"), "not your settlement")
	t.ok(not cs.build(1, Campaign.idx(10, 8), &"market"), "not a settlement at all")
	t.ok(not cs.build(1, mine["tile"], &"pyramid"), "not a building")

	cs.gold[1] = 5
	t.ok(not cs.build(1, mine["tile"], &"farm"), "cannot afford it")


func test_capitals_start_with_a_barracks_and_towns_do_not(t) -> void:
	var cs = _two_player()
	t.ok(_town_of(cs, 1)["buildings"].has(&"barracks"), "you can raise something on turn one")
	t.eq(_neutral_town(cs)["buildings"], [], "a neutral town is a bare town")


# --- income ---------------------------------------------------------------

func test_a_market_pays_out_every_turn(t) -> void:
	var cs = _two_player()
	var plain = Campaign.generate([1, 2], 12345)
	cs.build(1, _town_of(cs, 1)["tile"], &"market")
	var gold_before: int = cs.gold[1]
	var plain_before: int = plain.gold[1]
	cs.end_turn()
	plain.end_turn()
	t.eq(cs.gold[1] - gold_before, (plain.gold[1] - plain_before) + int(Rules.BUILDINGS[&"market"]["gold"]))


func test_a_farm_feeds_the_army(t) -> void:
	var cs = _two_player()
	var town := _town_of(cs, 1)
	cs.gold[1] = 100000
	var before := Campaign.settlement_income(town)
	cs.build(1, town["tile"], &"farm")
	var after := Campaign.settlement_income(town)
	t.eq(after["food"] - before["food"], int(Rules.BUILDINGS[&"farm"]["food"]))
	t.eq(after["gold"], before["gold"], "a farm is not a mint")


# --- unlocks --------------------------------------------------------------

func test_cavalry_needs_a_barracks(t) -> void:
	var cs = _two_player()
	var bare := _neutral_town(cs)
	bare["owner"] = 1
	cs.gold[1] = 100000
	t.ok(not cs.recruit(1, bare["tile"], &"cavalry"), "no barracks, no horse")
	t.ok(cs.recruit(1, bare["tile"], &"spear"), "spearmen need nothing")

	t.ok(cs.build(1, bare["tile"], &"barracks"))
	t.ok(cs.recruit(1, bare["tile"], &"cavalry"), "now it can")


func test_recruitable_lists_what_the_buttons_should_offer(t) -> void:
	var cs = _two_player()
	var bare := _neutral_town(cs)
	var basic: Array = cs.recruitable_at(bare["tile"])
	t.ok(basic.has(&"spear") and basic.has(&"archer"))
	t.ok(not basic.has(&"cavalry") and not basic.has(&"pike"))

	var capital: Array = cs.recruitable_at(_town_of(cs, 1)["tile"])
	t.ok(capital.has(&"cavalry") and capital.has(&"pike"), "the capital has a barracks")
	t.eq(cs.recruitable_at(Campaign.idx(10, 8)).size(), 3, "open ground offers only the basics")


func test_cavalry_is_faster_than_the_line(t) -> void:
	var bs = BattleState.new()
	var horse = bs.add(1, &"cavalry", Vector2.ZERO, 0.0)
	var foot = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	horse.order_move(Vector2(100000, 0), 0.0)
	foot.order_move(Vector2(100000, 0), 0.0)
	for i in Rules.TICK_HZ:
		bs.step()
	t.ok(horse.pos.x > foot.pos.x * 1.4,
		"cavalry must actually get somewhere first (%.0f vs %.0f)" % [horse.pos.x, foot.pos.x])
	t.near(horse.pos.x, Rules.MOVE_SPEED * float(Rules.KINDS[&"cavalry"]["speed"]), 1.0)


# --- upkeep with teeth ----------------------------------------------------

func test_a_starving_army_deserts(t) -> void:
	var cs = _two_player()
	cs.food[1] = 0
	cs.gold[1] = 100000
	var capital: int = _town_of(cs, 1)["tile"]
	for i in 5:
		cs.recruit(1, capital, &"cavalry")        # expensive to feed
	var before: int = cs.men_of(1)
	cs.end_turn()
	t.ok(cs.upkeep_of(1) > Rules.SETTLEMENT_FOOD, "the test needs upkeep to exceed income")
	t.ok(cs.men_of(1) < before, "men should be walking away (%d -> %d)" % [before, cs.men_of(1)])
	t.eq(cs.food[1], 0, "and the larder stays empty, not negative")


func test_a_fed_army_does_not_desert(t) -> void:
	var cs = _two_player()
	cs.food[1] = 10000
	var before: int = cs.men_of(1)
	cs.end_turn()
	t.ok(cs.men_of(1) >= before, "nobody leaves a well-fed camp")


func test_regiments_that_melt_away_entirely_are_removed(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	a["tile"] = Campaign.idx(10, 8)
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			s["owner"] = 0                        # no towns, so no food at all
	cs.food[1] = 0
	for r: Array in a["regiments"]:
		r[1] = 1                                  # one man each, and nothing to eat
	cs.end_turn()
	t.ok(not cs.armies.has(1), "an army of nobody should not still be on the map")


# --- walls ----------------------------------------------------------------

func test_walls_only_help_the_side_that_holds_them(t) -> void:
	var cs = _two_player()
	var town := _town_of(cs, 1)
	cs.gold[1] = 100000
	cs.build(1, town["tile"], &"walls")
	t.near(cs.defense_at(town["tile"], 1), float(Rules.BUILDINGS[&"walls"]["defense"]))
	t.near(cs.defense_at(town["tile"], 2), 0.0, 0.0001, "the attacker gets nothing from them")
	t.near(cs.defense_at(Campaign.idx(10, 8), 1), 0.0, 0.0001, "no walls in open ground")


func test_a_defended_regiment_takes_less_damage(t) -> void:
	var open = BattleState.new()
	var bare = open.add(1, &"spear", Vector2.ZERO, 0.0)
	open.add(2, &"spear", Vector2(20, 0), PI)

	var fort = BattleState.new()
	var walled = fort.add(1, &"spear", Vector2.ZERO, 0.0)
	walled.defense = float(Rules.BUILDINGS[&"walls"]["defense"])
	fort.add(2, &"spear", Vector2(20, 0), PI)

	for i in Rules.TICK_HZ * 2:
		open.step()
		fort.step()
	t.ok(walled.strength > bare.strength,
		"walls should cost the attacker (%d behind walls vs %d in the open)" % [walled.strength, bare.strength])


func test_walls_count_in_an_autoresolve_too(t) -> void:
	# Otherwise taking a town by dice is easier than taking it by hand, and every
	# attacker learns to avoid the battle they would have lost.
	var rng := RandomNumberGenerator.new()
	var attacker := [Campaign.make_regiment(&"spear"), Campaign.make_regiment(&"spear")]
	var defender := [Campaign.make_regiment(&"spear"), Campaign.make_regiment(&"spear")]
	var open_wins := 0
	var walled_wins := 0
	for seed_value in 80:
		rng.seed = seed_value
		if Autoresolve.resolve(attacker, defender, rng, 0.0)["attacker_wins"]:
			open_wins += 1
		rng.seed = seed_value
		if Autoresolve.resolve(attacker, defender, rng, 0.3)["attacker_wins"]:
			walled_wins += 1
	t.ok(walled_wins < open_wins, "walls must swing it (%d wins open, %d against walls)" % [open_wins, walled_wins])


# --- the wire -------------------------------------------------------------

func test_buildings_survive_the_round_trip(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _town_of(cs, 1)
	cs.build(1, town["tile"], &"market")
	cs.build(1, town["tile"], &"walls")
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back == null:
		return
	t.eq(back.settlement_at(town["tile"])["buildings"], town["buildings"])
	t.eq(Snapshot.encode_campaign(back), Snapshot.encode_campaign(cs), "a mirror re-encodes identically")


func test_nonsense_buildings_are_refused_off_the_wire(t) -> void:
	var cs = _two_player()
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var unknown = d.duplicate(true)
	unknown[4][0][3] = [&"deathstar"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(unknown)), null, "a building that does not exist")

	var doubled = d.duplicate(true)
	doubled[4][0][3] = [&"market", &"market"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(doubled)), null, "two markets would double the income")

	var hoard = d.duplicate(true)
	hoard[4][0][3] = [&"farm", &"market", &"barracks", &"walls", &"farm"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(hoard)), null, "more buildings than exist")

	var wrong = d.duplicate(true)
	wrong[4][0][3] = "market"
	t.eq(Snapshot.decode_campaign(var_to_bytes(wrong)), null, "buildings must be a list")


func test_build_orders_validate(t) -> void:
	var order: Dictionary = Orders.decode(Orders.build(40, &"walls"))
	t.eq(order.get("type"), Orders.Type.BUILD)
	t.eq(order.get("tile"), 40)
	t.eq(order.get("building"), &"walls")

	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.BUILD, 999999, &"walls"])), {},
		"off the map")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.BUILD, 40, &"deathstar"])), {},
		"not a building")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.BUILD, 40])), {},
		"missing the building")
