extends RefCounted

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


# --- map ------------------------------------------------------------------

func test_generated_map_is_sane(t) -> void:
	var cs = _two_player()
	t.eq(cs.terrain.size(), Rules.MAP_W * Rules.MAP_H)
	t.eq(cs.settlements_of(1), 1, "one capital each")
	t.eq(cs.settlements_of(2), 1)
	t.eq(cs.settlements_of(0), 4, "four neutral towns to fight over")
	t.eq(cs.armies.size(), 2, "one starting army each")
	t.eq(cs.gold[1], Rules.START_GOLD)


func test_generation_is_deterministic(t) -> void:
	t.eq(Campaign.generate([1, 2], 999).terrain, Campaign.generate([1, 2], 999).terrain)
	t.ok(Campaign.generate([1, 2], 999).terrain != Campaign.generate([1, 2], 1000).terrain,
		"different seeds give different maps")


func test_capitals_are_never_walled_in(t) -> void:
	for seed_value in [1, 2, 3, 7, 42, 999]:
		var cs = Campaign.generate([1, 2], seed_value)
		for s in cs.settlements:
			if s["owner"] != 0:
				t.ok(not cs.neighbours(s["tile"]).is_empty(),
					"capital on seed %d has somewhere to march" % seed_value)


func test_path_avoids_mountains_and_reports_failure(t) -> void:
	var cs = _two_player()
	# A pocket: wall one tile in on all four sides.
	var target := Campaign.idx(10, 8)
	cs.terrain[target] = Campaign.Terrain.PLAINS
	for n in [target - 1, target + 1, target - Rules.MAP_W, target + Rules.MAP_W]:
		cs.terrain[n] = Campaign.Terrain.MOUNTAIN
	t.eq(cs.path(Campaign.idx(3, 3), target).size(), 0, "unreachable means no route")

	cs.terrain[target + 1] = Campaign.Terrain.PLAINS
	var route: PackedInt32Array = cs.path(Campaign.idx(3, 3), target)
	t.ok(route.size() > 0, "one gap is enough")
	for step in route:
		t.ok(cs.passable(step), "no step of a route is a mountain")
	t.eq(route[route.size() - 1], target, "a route ends where it was asked to")


func test_path_to_self_is_empty(t) -> void:
	var cs = _two_player()
	t.eq(cs.path(Campaign.idx(3, 3), Campaign.idx(3, 3)).size(), 0)


# --- movement -------------------------------------------------------------

func test_army_spends_move_points_and_stops(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	var start: int = a["tile"]
	var far := Campaign.idx(Rules.MAP_W / 2, Rules.MAP_H / 2)
	var result: Dictionary = cs.move_army(1, far)
	t.eq(result["moved"], Rules.ARMY_MOVE_POINTS, "spends exactly its allowance")
	t.eq(a["move_left"], 0)
	t.ok(a["tile"] != start, "and is somewhere else now")

	t.eq(cs.move_army(1, far)["moved"], 0, "an exhausted army goes nowhere")


func test_end_turn_restores_movement_and_pays_income(t) -> void:
	var cs = _two_player()
	cs.move_army(1, Campaign.idx(Rules.MAP_W / 2, Rules.MAP_H / 2))
	var gold_before: int = cs.gold[1]
	cs.end_turn()
	t.eq(cs.turn, 2)
	t.eq(cs.armies[1]["move_left"], Rules.ARMY_MOVE_POINTS)
	t.eq(cs.gold[1], gold_before + Rules.SETTLEMENT_GOLD, "one settlement, one income")


func test_upkeep_eats_food(t) -> void:
	var cs = _two_player()
	var upkeep: int = cs.upkeep_of(1)
	t.ok(upkeep > 0, "three regiments cost something")
	var before: int = cs.food[1]
	cs.end_turn()
	t.eq(cs.food[1], before + Rules.SETTLEMENT_FOOD - upkeep)


func test_food_floors_at_zero_rather_than_going_negative(t) -> void:
	var cs = _two_player()
	cs.food[1] = 0
	for i in 20:
		cs.armies[1]["regiments"].append(Campaign.make_regiment(&"sword"))
	cs.end_turn()
	t.eq(cs.food[1], 0, "deliberately floored, see the ponytail note in end_turn")


# --- contact --------------------------------------------------------------

func test_marching_into_an_enemy_reports_a_collision(t) -> void:
	var cs = _two_player()
	var defender = cs.armies[2]
	var attacker = cs.armies[1]
	# Put them two tiles apart on clear ground.
	var here := Campaign.idx(10, 8)
	var there := Campaign.idx(12, 8)
	for i in [here, here + 1, there]:
		cs.terrain[i] = Campaign.Terrain.PLAINS
	attacker["tile"] = here
	defender["tile"] = there

	var result: Dictionary = cs.move_army(1, there)
	t.eq(result["collision"], [1, 2], "the mover and whoever it ran into")
	t.ok(attacker["tile"] != there, "it stops short; the battle decides the tile")


func test_a_friendly_army_blocks_the_road_without_a_battle(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	var b = cs.add_army(1, Campaign.idx(12, 8), [&"spear"])
	for i in [Campaign.idx(10, 8), Campaign.idx(11, 8), Campaign.idx(12, 8)]:
		cs.terrain[i] = Campaign.Terrain.PLAINS
	a["tile"] = Campaign.idx(10, 8)
	var result: Dictionary = cs.move_army(1, Campaign.idx(12, 8))
	t.eq(result["collision"], [], "no battle with your own side")
	t.eq(a["tile"], Campaign.idx(11, 8), "it pulls up behind them")


func test_walking_into_an_undefended_settlement_takes_it(t) -> void:
	var cs = _two_player()
	var town = null
	for s in cs.settlements:
		if s["owner"] == 0:
			town = s
			break
	var a = cs.armies[1]
	# Stand next to it on clear ground.
	var approach: int = cs.neighbours(town["tile"])[0]
	a["tile"] = approach
	cs.move_army(1, town["tile"])
	t.eq(town["owner"], 1, "an undefended town changes hands")
	t.eq(cs.settlements_of(1), 2)


# --- recruitment ----------------------------------------------------------

func test_recruiting_costs_gold_and_adds_a_regiment(t) -> void:
	var cs = _two_player()
	var capital: int = cs.armies[1]["tile"]
	var before: int = cs.gold[1]
	var count: int = cs.armies[1]["regiments"].size()
	t.ok(cs.recruit(1, capital, &"sword"), "affordable and owned")
	t.eq(cs.gold[1], before - int(Rules.KINDS[&"sword"]["cost"]))
	t.eq(cs.armies[1]["regiments"].size(), count + 1)


func test_you_cannot_recruit_where_you_have_no_claim(t) -> void:
	var cs = _two_player()
	var enemy_capital: int = cs.armies[2]["tile"]
	t.ok(not cs.recruit(1, enemy_capital, &"sword"), "not your settlement")
	var field := Campaign.idx(10, 8)
	t.ok(not cs.recruit(1, field, &"sword"), "not a settlement at all")
	t.eq(cs.gold[1], Rules.START_GOLD, "a refused order costs nothing")


func test_you_cannot_recruit_what_you_cannot_afford(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 10
	t.ok(not cs.recruit(1, cs.armies[1]["tile"], &"sword"))
	t.eq(cs.gold[1], 10)


func test_armies_have_a_ceiling(t) -> void:
	var cs = _two_player()
	var capital: int = cs.armies[1]["tile"]
	cs.gold[1] = 100000
	for i in 20:
		cs.recruit(1, capital, &"spear")
	t.eq(cs.armies[1]["regiments"].size(), Campaign.MAX_REGIMENTS_PER_ARMY)


# --- ready check ----------------------------------------------------------

func test_the_turn_waits_for_everyone(t) -> void:
	var cs = _two_player()
	t.ok(not cs.all_ready([1, 2]), "nobody has pressed End Turn")
	cs.set_ready(1, true)
	t.ok(not cs.all_ready([1, 2]), "one of two is not everyone")
	cs.set_ready(2, true)
	t.ok(cs.all_ready([1, 2]))
	cs.end_turn()
	t.ok(not cs.all_ready([1, 2]), "a new turn starts with nobody ready")


func test_an_empty_lobby_is_never_ready(t) -> void:
	t.ok(not _two_player().all_ready([]), "otherwise a solo host would spin turns forever")


# --- elimination ----------------------------------------------------------

func test_a_player_with_nothing_left_is_out(t) -> void:
	var cs = _two_player()
	t.ok(cs.is_alive(2))
	cs.armies.erase(2)
	for s in cs.settlements:
		if s["owner"] == 2:
			s["owner"] = 1
	t.ok(not cs.is_alive(2), "no settlements and no armies")


# --- serialization --------------------------------------------------------

func test_campaign_round_trips(t) -> void:
	var cs = _two_player()
	cs.move_army(1, Campaign.idx(8, 6))
	cs.recruit(1, cs.settlements[0]["tile"], &"sword")
	cs.set_ready(1, true)
	var bytes: PackedByteArray = Snapshot.encode_campaign(cs)
	var back = Snapshot.decode_campaign(bytes)
	t.ok(back != null, "decodes")
	if back == null:
		return
	print("  [size] campaign snapshot: %d bytes" % bytes.size())
	t.eq(back.turn, cs.turn)
	t.eq(back._next_army, cs._next_army)
	t.eq(back.terrain, cs.terrain)
	t.eq(back.gold, cs.gold)
	t.eq(back.food, cs.food)
	t.eq(back.ready, cs.ready)
	t.eq(back.settlements.size(), cs.settlements.size())
	for i in cs.settlements.size():
		t.eq(back.settlements[i], cs.settlements[i], "settlement %d" % i)
	t.eq(back.armies.size(), cs.armies.size())
	for id in cs.sorted_army_ids():
		t.eq(back.armies[id], cs.armies[id], "army %d" % id)
	t.eq(Snapshot.encode_campaign(back), bytes, "re-encoding a mirror reproduces the bytes")


func test_malformed_campaign_snapshots_are_rejected(t) -> void:
	t.eq(Snapshot.decode_campaign(PackedByteArray()), null, "empty")
	t.eq(Snapshot.decode_campaign(var_to_bytes("nope")), null, "wrong root type")
	t.eq(Snapshot.decode_campaign(var_to_bytes([Snapshot.VERSION, 1, 1])), null, "too few members")

	var cs = _two_player()
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var short_map = d.duplicate(true)
	short_map[3] = PackedByteArray([1, 2, 3])
	t.eq(Snapshot.decode_campaign(var_to_bytes(short_map)), null, "a map of the wrong size")

	var bad_terrain = d.duplicate(true)
	bad_terrain[3][0] = 200
	t.eq(Snapshot.decode_campaign(var_to_bytes(bad_terrain)), null, "terrain id that does not exist")

	var bad_tile = d.duplicate(true)
	bad_tile[5][0][2] = 999999
	t.eq(Snapshot.decode_campaign(var_to_bytes(bad_tile)), null, "an army off the edge of the map")

	var bad_kind = d.duplicate(true)
	bad_kind[5][0][4] = [&"dragon"]
	t.eq(Snapshot.decode_campaign(var_to_bytes(bad_kind)), null, "a regiment kind that does not exist")

	var huge_army = d.duplicate(true)
	huge_army[5][0][4] = []
	for i in 50:
		huge_army[5][0][4].append(&"spear")
	t.eq(Snapshot.decode_campaign(var_to_bytes(huge_army)), null, "an army over the ceiling")

	var bad_gold = d.duplicate(true)
	bad_gold[6] = {1: "lots"}
	t.eq(Snapshot.decode_campaign(var_to_bytes(bad_gold)), null, "treasury that is not a number")


# --- order validation -----------------------------------------------------

func test_campaign_orders_round_trip(t) -> void:
	var move: Dictionary = Orders.decode(Orders.army_move(3, 77))
	t.eq(move.get("type"), Orders.Type.ARMY_MOVE)
	t.eq(move.get("army_id"), 3)
	t.eq(move.get("dest"), 77)

	var rec: Dictionary = Orders.decode(Orders.recruit(77, &"archer"))
	t.eq(rec.get("type"), Orders.Type.RECRUIT)
	t.eq(rec.get("kind"), &"archer")

	var rdy: Dictionary = Orders.decode(Orders.ready(true))
	t.eq(rdy.get("type"), Orders.Type.READY)
	t.eq(rdy.get("value"), true)


func test_orders_off_the_map_or_out_of_the_catalogue_are_refused(t) -> void:
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.ARMY_MOVE, 1, 999999])), {},
		"destination off the map")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.ARMY_MOVE, 1, -1])), {},
		"negative destination")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.RECRUIT, 5, &"dragon"])), {},
		"a unit kind that does not exist")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.READY, "yes"])), {},
		"ready must be a bool")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, 99, 1, 1])), {}, "unknown order type")


func test_battle_move_rejects_infinities(t) -> void:
	var nan_order := var_to_bytes([Orders.VERSION, Orders.Type.BATTLE_MOVE,
		PackedInt32Array([1]), Vector2(NAN, 0.0), 0.0])
	t.eq(Orders.decode(nan_order), {}, "a NaN would poison the sim forever")
	var inf_order := var_to_bytes([Orders.VERSION, Orders.Type.BATTLE_MOVE,
		PackedInt32Array([1]), Vector2(INF, 0.0), 0.0])
	t.eq(Orders.decode(inf_order), {}, "so would an infinity")


func test_battle_move_targets_are_clamped_to_the_field(t) -> void:
	var order: Dictionary = Orders.decode(Orders.battle_move(PackedInt32Array([1]), Vector2(1e9, -1e9), 0.0))
	t.near(order["target"].x, Rules.BATTLE_HALF_EXTENT)
	t.near(order["target"].y, -Rules.BATTLE_HALF_EXTENT)


# --- strength carries through ---------------------------------------------

func test_a_recruited_regiment_starts_at_full_strength(t) -> void:
	var cs = _two_player()
	var capital: int = cs.armies[1]["tile"]
	cs.recruit(1, capital, &"sword")
	var last: Array = cs.armies[1]["regiments"][-1]
	t.eq(last[0], &"sword")
	t.eq(last[1], int(Rules.KINDS[&"sword"]["strength"]), "fresh recruits are not pre-battered")


func test_army_men_counts_men_not_regiments(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	t.eq(Campaign.army_men(a), 2 * int(Rules.KINDS[&"spear"]["strength"]) + int(Rules.KINDS[&"archer"]["strength"]))
	a["regiments"][0][1] = 5
	t.ok(Campaign.army_men(a) < cs.men_of(2), "a battered army is weaker than a fresh one")


func test_an_army_resting_at_home_fills_its_ranks(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]                       # starts on its own capital
	a["regiments"][0][1] = 10
	cs.end_turn()
	t.eq(a["regiments"][0][1], 10 + Rules.REINFORCE_PER_TURN, "a turn at home is a turn recruiting")


func test_reinforcement_stops_at_full_strength(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	var full := int(Rules.KINDS[&"spear"]["strength"])
	a["regiments"][0][1] = full - 2
	cs.end_turn()
	t.eq(a["regiments"][0][1], full, "never more men than the regiment can hold")


func test_an_army_in_the_field_does_not_reinforce(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	a["tile"] = Campaign.idx(10, 8)            # open ground
	a["regiments"][0][1] = 10
	cs.end_turn()
	t.eq(a["regiments"][0][1], 10, "no fresh men out in the field")


func test_an_army_in_an_enemy_settlement_does_not_reinforce(t) -> void:
	var cs = _two_player()
	var a = cs.armies[1]
	a["tile"] = cs.armies[2]["tile"]           # standing on the enemy capital
	a["regiments"][0][1] = 10
	cs.end_turn()
	t.eq(a["regiments"][0][1], 10, "their town does not raise your men")


func test_a_battered_regiment_survives_the_wire(t) -> void:
	var cs = _two_player()
	cs.armies[1]["regiments"][0][1] = 7
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back != null:
		t.eq(back.armies[1]["regiments"][0][1], 7, "strength must survive the round trip")


func test_absurd_regiment_strengths_are_refused(t) -> void:
	var cs = _two_player()
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var negative = d.duplicate(true)
	negative[5][0][4][0][1] = -50
	t.eq(Snapshot.decode_campaign(var_to_bytes(negative)), null, "a negative regiment")

	var bloated = d.duplicate(true)
	bloated[5][0][4][0][1] = 999999
	t.eq(Snapshot.decode_campaign(var_to_bytes(bloated)), null, "more men than the kind allows")

	var bare = d.duplicate(true)
	bare[5][0][4][0] = &"spear"
	t.eq(Snapshot.decode_campaign(var_to_bytes(bare)), null, "a kind with no strength beside it")
