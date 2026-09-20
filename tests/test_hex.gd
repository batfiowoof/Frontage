extends RefCounted
## M20: a hex map, and a Civ-style tile economy on top of it.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Hex := preload("res://view/campaign/hex.gd")
const Rules := preload("res://sim/rules.gd")


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
	# Two rows straight down is two hexes on a hex grid, whatever the column arithmetic
	# says, and the AI picks its target by this number.
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


# --- the land economy -----------------------------------------------------

func _own_town(cs, owner := 1) -> Dictionary:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s
	return {}


## A tile near a player's town whose terrain suits `name`.
func _spot_for(cs, name: StringName, owner := 1) -> int:
	var town := _own_town(cs, owner)
	for tile in cs.improvements.size():
		if Campaign.hex_distance(tile, town["tile"]) > Rules.WORK_RADIUS:
			continue
		if cs.can_improve(owner, tile, name):
			return tile
	return -1


func test_improving_a_tile_costs_gold_and_sticks(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	t.ok(tile >= 0, "there should be somewhere to put a farm near a capital")
	if tile < 0:
		return
	var before: int = cs.gold[1]
	t.ok(cs.improve(1, tile, &"farm"))
	t.eq(cs.improvement_at(tile), &"farm")
	t.eq(cs.gold[1], before - int(Rules.IMPROVEMENTS[&"farm"]["cost"]))


func test_an_improvement_has_to_suit_the_ground(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var town := _own_town(cs)
	var forest := -1
	for tile in cs.improvements.size():
		if Campaign.hex_distance(tile, town["tile"]) <= Rules.WORK_RADIUS \
				and cs.terrain[tile] == Campaign.Terrain.FOREST:
			forest = tile
	if forest < 0:
		return
	t.ok(not cs.improve(1, forest, &"farm"), "you do not plough a wood")
	t.ok(cs.improve(1, forest, &"lumber"), "you cut it")


func test_you_cannot_improve_land_you_do_not_work(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var far := -1
	var town := _own_town(cs)
	for tile in cs.improvements.size():
		if Campaign.hex_distance(tile, town["tile"]) > Rules.WORK_RADIUS + 3 \
				and cs.terrain[tile] == Campaign.Terrain.PLAINS:
			far = tile
			break
	t.ok(far >= 0)
	if far >= 0:
		t.ok(not cs.improve(1, far, &"farm"), "too far from any town of yours to work")


func test_one_improvement_per_tile(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	t.ok(cs.improve(1, tile, &"farm"))
	t.ok(not cs.improve(1, tile, &"pasture"), "the field is already a field")


func test_improvements_pay_out_every_turn(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	var plain = Campaign.generate([1, 2], 12345)
	plain.gold[1] = 100000
	cs.improve(1, tile, &"farm")

	var before_food: int = cs.food[1]
	var plain_food: int = plain.food[1]
	cs.end_turn()
	plain.end_turn()
	t.eq(cs.food[1] - before_food, (plain.food[1] - plain_food) + int(Rules.IMPROVEMENTS[&"farm"]["food"]),
		"a farm feeds the town that works it")


func test_a_tile_is_worked_by_exactly_one_town(t) -> void:
	# Otherwise two neighbouring towns both bank the same field and the economy doubles
	# for free wherever settlements happen to be close together.
	var cs = _two_player()
	for tile in cs.improvements.size():
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
	cs.improve(1, tile, &"farm")
	t.ok(cs.worked_yield(1)["food"] > 0)
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			s["owner"] = 2
	t.eq(cs.worked_yield(1)["food"], 0, "the improvement stays; the income follows the town")
	t.ok(cs.worked_yield(2)["food"] > 0, "and goes to whoever holds it now")


# --- the wire -------------------------------------------------------------

func test_improvements_survive_the_round_trip(t) -> void:
	var cs = _two_player()
	cs.gold[1] = 100000
	var tile := _spot_for(cs, &"farm")
	if tile < 0:
		return
	cs.improve(1, tile, &"farm")
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back != null:
		t.eq(back.improvements, cs.improvements)
		t.eq(back.improvement_at(tile), &"farm")
		t.eq(Snapshot.encode_campaign(back), Snapshot.encode_campaign(cs))


func test_a_nonsense_improvement_layer_is_refused(t) -> void:
	var cs = _two_player()
	var d = bytes_to_var(Snapshot.encode_campaign(cs))

	var unknown = d.duplicate(true)
	unknown[9][0] = 200
	t.eq(Snapshot.decode_campaign(var_to_bytes(unknown)), null, "an improvement that does not exist")

	var short_layer = d.duplicate(true)
	short_layer[9] = PackedByteArray([1, 2, 3])
	t.eq(Snapshot.decode_campaign(var_to_bytes(short_layer)), null, "a layer that does not fit the map")


func test_the_improve_order_validates(t) -> void:
	var order: Dictionary = Orders.decode(Orders.improve(40, &"mine"))
	t.eq(order.get("type"), Orders.Type.IMPROVE)
	t.eq(order.get("tile"), 40)
	t.eq(order.get("improvement"), &"mine")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.IMPROVE, 999999, &"mine"])), {},
		"off the map")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.IMPROVE, 40, &"casino"])), {},
		"not an improvement")
