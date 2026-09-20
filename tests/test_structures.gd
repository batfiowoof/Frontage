extends RefCounted
## M20 and M23: a hex map, and everything you can put on it.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Hex := preload("res://view/campaign/hex.gd")
const Rules := preload("res://sim/rules.gd")
const Ai := preload("res://sim/ai.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


# --- the grid -------------------------------------------------------------

func test_every_hex_in_the_middle_has_six_neighbours(t) -> void:
	var cs = _two_player()
	for y in range(2, Rules.MAP_H - 2):
		for x in range(2, Rules.MAP_W - 2):
			t.eq(cs.adjacent(Campaign.idx(x, y)).size(), 6,
				"a hex away from the edge has six ways out, not four")


func test_neighbours_are_mutual(t) -> void:
	# The classic offset-coordinate bug: get the row parity wrong and A is next to B
	# while B is not next to A, so armies path one way and not back.
	var cs = _two_player()
	for y in Rules.MAP_H:
		for x in Rules.MAP_W:
			var here := Campaign.idx(x, y)
			for n in cs.adjacent(here):
				t.ok(Array(cs.adjacent(n)).has(here),
					"(%d,%d) and (%d,%d) disagree about being neighbours" % [
						x, y, Campaign.tile_x(n), Campaign.tile_y(n)])


func test_neighbours_are_all_one_hex_away(t) -> void:
	var cs = _two_player()
	for y in range(1, Rules.MAP_H - 1):
		for x in range(1, Rules.MAP_W - 1):
			var here := Campaign.idx(x, y)
			for n in cs.adjacent(here):
				t.eq(Campaign.hex_distance(here, n), 1, "a neighbour is one hex away by definition")


func test_hex_distance_is_not_manhattan(t) -> void:
	var a := Campaign.idx(4, 4)
	t.eq(Campaign.hex_distance(a, a), 0)
	t.eq(Campaign.hex_distance(Campaign.idx(4, 4), Campaign.idx(4, 6)), 2)
	t.ok(Campaign.hex_distance(Campaign.idx(0, 0), Campaign.idx(10, 8)) < 18,
		"a diagonal is shorter on hexes than counting rows plus columns")


func test_distance_is_symmetric(t) -> void:
	for seed_value in 40:
		var a := (seed_value * 37) % (Rules.MAP_W * Rules.MAP_H)
		var b := (seed_value * 113 + 7) % (Rules.MAP_W * Rules.MAP_H)
		t.eq(Campaign.hex_distance(a, b), Campaign.hex_distance(b, a))


func test_water_and_mountains_stop_an_army(t) -> void:
	var cs = _two_player()
	var tile := Campaign.idx(10, 8)
	cs.terrain[tile] = Campaign.Terrain.WATER
	t.ok(not cs.passable(tile), "nobody marches across a lake")
	cs.terrain[tile] = Campaign.Terrain.HILLS
	t.ok(cs.passable(tile), "but hills are only hills")


# --- clicking on one ------------------------------------------------------

func test_a_click_in_the_middle_of_a_hex_finds_that_hex(t) -> void:
	for y in range(1, Rules.MAP_H - 1):
		for x in range(1, Rules.MAP_W - 1):
			var tile := Campaign.idx(x, y)
			t.eq(Hex.at(Hex.centre(tile)), tile, "(%d,%d) does not pick itself" % [x, y])


func test_a_click_near_an_edge_still_lands_in_the_right_hex(t) -> void:
	# Flooring a division puts clicks in the wrong hex along every slanted edge, which
	# is most of them, so this is the test that says the rounding is real.
	var tile := Campaign.idx(9, 7)
	var at := Hex.centre(tile)
	for i in 6:
		var angle := deg_to_rad(60.0 * float(i))
		var nudged := at + Vector2(cos(angle), sin(angle)) * (Rules.HEX_SIZE * 0.7)
		t.eq(Hex.at(nudged), tile, "a point well inside the hex belongs to it (corner %d)" % i)


func test_clicking_off_the_map_finds_nothing(t) -> void:
	t.eq(Hex.at(Vector2(-500, -500)), -1)
	t.eq(Hex.at(Vector2(100000, 100000)), -1)


# --- putting things on the land -------------------------------------------

func _own_town(cs, owner := 1) -> Dictionary:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s
	return {}


## A hex near a player's town that will take `name`.
func _spot_for(cs, name: StringName, owner := 1) -> int:
	var town := _own_town(cs, owner)
	for tile in cs.structures.size():
		if Campaign.hex_distance(tile, town["tile"]) > Rules.WORK_RADIUS:
			continue
		if cs.can_place(owner, tile, name):
			return tile
	return -1


func test_building_costs_gold_and_stands_where_it_was_put(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	t.ok(tile >= 0, "there should be somewhere to put a farm near a capital")
	if tile < 0:
		return
	var before: int = cs.gold[1]
	t.ok(cs.place(1, tile, &"farm"))
	t.eq(cs.structure_at(tile), &"farm")
	t.eq(cs.gold[1], before - int(Rules.STRUCTURES[&"farm"]["cost"]))


func test_a_structure_has_to_suit_the_ground(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _own_town(cs)
	var forest := -1
	for tile in cs.structures.size():
		if Campaign.hex_distance(tile, town["tile"]) <= Rules.WORK_RADIUS \
				and cs.terrain[tile] == Campaign.Terrain.FOREST and cs.structure_at(tile) == &"":
			forest = tile
	if forest < 0:
		return
	t.ok(not cs.place(1, forest, &"farm"), "you do not plough a wood")
	t.ok(cs.place(1, forest, &"lumber"), "you cut it")


func test_you_cannot_build_on_land_you_do_not_work(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _own_town(cs)
	var far := -1
	for tile in cs.structures.size():
		if Campaign.hex_distance(tile, town["tile"]) > Rules.WORK_RADIUS + 3 \
				and cs.terrain[tile] == Campaign.Terrain.PLAINS:
			far = tile
			break
	t.ok(far >= 0)
	if far >= 0:
		t.ok(not cs.place(1, far, &"farm"), "too far from any town of yours")


func test_one_structure_per_hex(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	t.ok(cs.place(1, tile, &"farm"))
	t.ok(not cs.place(1, tile, &"pasture"), "the hex is already spoken for")


func test_walls_go_on_the_town_and_nothing_else_does(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _own_town(cs)
	t.ok(not cs.can_place(1, town["tile"], &"farm"), "the town hex is for the town's own walls")
	t.ok(cs.place(1, town["tile"], &"walls"))
	t.eq(cs.structure_at(town["tile"]), &"walls")

	var field := _spot_for(cs, &"farm")
	if field >= 0:
		t.ok(not cs.can_place(1, field, &"walls"), "and walls go nowhere else")


func test_walls_defend_the_town_they_stand_on(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _own_town(cs)
	t.near(cs.defense_at(town["tile"], 1), 0.0, 0.0001, "no walls, no help")
	cs.place(1, town["tile"], &"walls")
	t.near(cs.defense_at(town["tile"], 1), float(Rules.STRUCTURES[&"walls"]["defense"]))
	t.near(cs.defense_at(town["tile"], 2), 0.0, 0.0001, "the attacker gets nothing from them")


func test_structures_pay_out_every_turn(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	var plain = Campaign.generate([1, 2], 12345)
	plain.gold[1] = 100000
	cs.place(1, tile, &"farm")

	var before_food: int = cs.food[1]
	var plain_food: int = plain.food[1]
	cs.end_turn()
	plain.end_turn()
	t.eq(cs.food[1] - before_food, (plain.food[1] - plain_food) + int(Rules.STRUCTURES[&"farm"]["food"]),
		"a farm feeds the town that works it")


func test_a_library_produces_research(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"library")
	if tile < 0:
		return
	var before: int = cs.worked_yield(1)["research"]
	cs.place(1, tile, &"library")
	t.eq(cs.worked_yield(1)["research"], before + int(Rules.STRUCTURES[&"library"]["research"]))


func test_a_hex_is_worked_by_exactly_one_town(t) -> void:
	# Otherwise two neighbouring towns both bank the same field and the economy doubles
	# for free wherever settlements happen to be close together.
	var cs = _two_player()
	for tile in cs.structures.size():
		var s = cs.working_settlement(tile)
		if s == null:
			continue
		t.ok(Campaign.hex_distance(tile, s["tile"]) <= Rules.WORK_RADIUS,
			"a town cannot work land it cannot reach")


func test_losing_the_town_loses_the_land(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	t.ok(cs.worked_yield(1)["food"] > 0)
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			s["owner"] = 2
	t.eq(cs.worked_yield(1)["food"], 0, "the structure stays; the income follows the town")
	t.ok(cs.worked_yield(2)["food"] > 0, "and goes to whoever holds it now")


# --- a barracks is a place on the map -------------------------------------

func _barracks_near(cs, town: Dictionary) -> int:
	for tile in cs.structures.size():
		if cs.structure_at(tile) == &"barracks" \
				and Campaign.hex_distance(tile, town["tile"]) <= Rules.WORK_RADIUS:
			return tile
	return -1


func test_a_capital_starts_with_a_barracks_standing_near_it(t) -> void:
	var cs = _two_player()
	var town := _own_town(cs)
	t.ok(_barracks_near(cs, town) >= 0, "and it is somewhere an enemy could march to")
	t.ok(cs.recruitable_at(town["tile"]).has(&"cavalry"), "so the capital can raise horse")


func test_burning_the_barracks_takes_the_cavalry_with_it(t) -> void:
	# The whole reason a building has a location.
	var cs = _two_player()
	var town := _own_town(cs)
	t.ok(cs.recruitable_at(town["tile"]).has(&"cavalry"))

	var barracks := _barracks_near(cs, town)
	t.ok(barracks >= 0)
	if barracks < 0:
		return
	cs.structures[barracks] = 0
	t.ok(not cs.recruitable_at(town["tile"]).has(&"cavalry"),
		"no barracks on the land, no horse in the town")
	t.ok(cs.recruitable_at(town["tile"]).has(&"spear"), "but spearmen need nothing")


# --- burning it -----------------------------------------------------------

func _raider(cs, tile: int, owner := 2) -> int:
	return cs.add_army(owner, tile, [&"cavalry"])["id"]


func test_an_enemy_can_burn_what_it_is_standing_on(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	var raider := _raider(cs, tile)
	var purse: int = int(cs.gold.get(2, 0))

	t.ok(cs.raze(2, raider), "they should be able to burn it")
	t.eq(cs.structure_at(tile), &"", "and it should be gone")
	t.eq(cs.armies[raider]["move_left"], 0, "burning it ends their turn")
	t.eq(cs.gold[2], purse + int(round(float(Rules.STRUCTURES[&"farm"]["cost"]) * Rules.RAZE_LOOT)),
		"and pays them something for the trouble")


func test_nobody_burns_their_own_barns(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	t.ok(not cs.raze(1, _raider(cs, tile, 1)))
	t.eq(cs.structure_at(tile), &"farm")


func test_there_has_to_be_something_to_burn(t) -> void:
	var cs = _two_player()
	var bare := -1
	for tile in cs.structures.size():
		if cs.structure_at(tile) == &"" and cs.passable(tile) and cs.settlement_at(tile) == null:
			bare = tile
			break
	t.ok(not cs.raze(2, _raider(cs, bare)), "an empty field does not burn")


func test_an_army_that_has_marched_all_day_cannot_also_burn(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	var raider := _raider(cs, tile)
	cs.armies[raider]["move_left"] = 0
	t.ok(not cs.raze(2, raider), "no movement left, no raid")


func test_razing_somebody_elses_army_is_refused(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	t.ok(not cs.raze(1, _raider(cs, tile)), "you do not give orders to their cavalry")
	t.eq(cs.structure_at(tile), &"farm")


func test_burned_ground_can_be_built_on_again(t) -> void:
	# Pillage, not salting the earth.
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	cs.raze(2, _raider(cs, tile))
	t.ok(cs.place(1, tile, &"farm"), "the owner may rebuild")


# --- the wire -------------------------------------------------------------

func test_structures_survive_the_round_trip(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	cs.research[1] = 42
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back != null:
		t.eq(back.structures, cs.structures)
		t.eq(back.structure_at(tile), &"farm")
		t.eq(back.research, cs.research)
		t.eq(Snapshot.encode_campaign(back), Snapshot.encode_campaign(cs))


func test_a_nonsense_structure_layer_is_refused(t) -> void:
	var cs = _two_player()
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var unknown = d.duplicate(true)
	unknown[9][0] = 200
	t.eq(Snapshot.decode_campaign(var_to_bytes(unknown)), null, "a structure that does not exist")

	var short_layer = d.duplicate(true)
	short_layer[9] = PackedByteArray([1, 2, 3])
	t.eq(Snapshot.decode_campaign(var_to_bytes(short_layer)), null, "a layer that does not fit the map")

	var bad_pool = d.duplicate(true)
	bad_pool[10] = {1: "lots"}
	t.eq(Snapshot.decode_campaign(var_to_bytes(bad_pool)), null, "research that is not a number")


func test_the_build_and_raze_orders_validate(t) -> void:
	var order: Dictionary = Orders.decode(Orders.build(40, &"mine"))
	t.eq(order.get("type"), Orders.Type.BUILD)
	t.eq(order.get("tile"), 40)
	t.eq(order.get("structure"), &"mine")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.BUILD, 999999, &"mine"])), {},
		"off the map")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.BUILD, 40, &"casino"])), {},
		"not a structure")

	var burn: Dictionary = Orders.decode(Orders.raze(9))
	t.eq(burn.get("type"), Orders.Type.RAZE)
	t.eq(burn.get("army_id"), 9)
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.RAZE, "x"])), {},
		"an army id that is not a number")


# --- the AI burns what it walks over --------------------------------------

func test_the_ai_torches_an_enemy_structure_it_is_standing_on(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm", 1)
	t.ok(tile >= 0)
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	cs.add_army(2, tile, [&"cavalry"])          # their raider is already on it

	var brain = Ai.new(2)
	var orders: Array = brain.campaign_orders(cs)
	var found := false
	for bytes: PackedByteArray in orders:
		var order := Orders.decode(bytes)
		if not order.is_empty() and order["type"] == Orders.Type.RAZE:
			found = true
	t.ok(found, "an AI standing on an enemy farm should decide to burn it")


func test_the_ai_does_not_torch_its_own(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm", 1)
	if tile < 0:
		return
	cs.place(1, tile, &"farm")
	cs.add_army(1, tile, [&"cavalry"])

	var brain = Ai.new(1)
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var order := Orders.decode(bytes)
		t.ok(order.is_empty() or order["type"] != Orders.Type.RAZE,
			"it should not burn its own farm to stand on the ashes")


func test_the_ai_puts_structures_on_the_land(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.gold[1] = 100000
	var brain = Ai.new(1)
	var built := false
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var order := Orders.decode(bytes)
		if not order.is_empty() and order["type"] == Orders.Type.BUILD:
			built = true
			t.ok(cs.can_place(1, order["tile"], order["structure"]),
				"and it should pick a hex that will actually take one")
	t.ok(built, "an AI with money should be building something")
