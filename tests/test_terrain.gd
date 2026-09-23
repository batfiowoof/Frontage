extends RefCounted
## The battlefield is laid from the hex AND the six around it, and water is walked round.

const BattleState := preload("res://sim/battle_state.gd")
const CampaignState := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Rules := preload("res://sim/rules.gd")

const PLAINS := 0
const FOREST := 1
const MOUNTAIN := 2
const HILLS := 3
const WATER := 4


func _kinds(bs, kind: int) -> Array:
	var out := []
	for f: Array in bs.features:
		if int(f[0]) == kind:
			out.append(f)
	return out


func _field(here: int, ring: Array, seed_value: int, toward := 3):
	var bs = BattleState.new()
	bs.lay_ground(here, seed_value, ring, toward)
	return bs


# --- the neighbours shape the field ----------------------------------------

func test_a_lake_lies_on_the_side_its_water_hex_is(t) -> void:
	var lakes := 0
	for s in 20:
		# Direction 0 is east, and with the attacker coming from the west (3) east is +x.
		for f: Array in _kinds(_field(PLAINS, [WATER, 0, 0, 0, 0, 0], s), Rules.GROUND_LAKE):
			lakes += 1
			t.ok(float(f[1]) > 0.0, "the lake is on the water's side (x %.0f)" % f[1])
		# ...and turned round when the attacker came from the east instead.
		for f: Array in _kinds(_field(PLAINS, [WATER, 0, 0, 0, 0, 0], s, 0), Rules.GROUND_LAKE):
			t.ok(float(f[1]) < 0.0, "the hex he came from is behind him (x %.0f)" % f[1])
	t.eq(lakes, 20, "one lake for the one water hex, every time")
	t.eq(_kinds(_field(PLAINS, [0, 0, 0, 0, 0, 0], 3), Rules.GROUND_LAKE).size(), 0,
		"and no lake where there is no water")


func test_mountains_raise_higher_hills_than_hills_do(t) -> void:
	var highest := {}
	for here in [HILLS, MOUNTAIN]:
		var peak := 0.0
		for s in 10:
			for f: Array in _kinds(_field(PLAINS, [here, here, here, here, here, here], s), Rules.GROUND_HILL):
				peak = maxf(peak, float(f[3]) * Rules.HILL_RISE)
		highest[here] = peak
	t.ok(highest[MOUNTAIN] > highest[HILLS], "mountains %.0f, hills %.0f" % [highest[MOUNTAIN], highest[HILLS]])


func test_the_same_meeting_is_the_same_field_and_the_next_is_not(t) -> void:
	var ring := [FOREST, WATER, HILLS, PLAINS, MOUNTAIN, FOREST]
	t.eq(_field(PLAINS, ring, 77).features, _field(PLAINS, ring, 77).features)
	t.ok(_field(PLAINS, ring, 77).features != _field(PLAINS, ring, 78).features)
	# Neighbouring seeds -- the same hex a turn later -- used to lay the same KINDS of ground
	# in the same order, because the generator was seeded raw. Something has to vary.
	var shapes := {}
	for s in 10:
		var kinds := []
		for f: Array in _field(PLAINS, ring, 5000 + s).features:
			kinds.append(int(f[0]))
		shapes[str(kinds)] = true
	t.ok(shapes.size() > 2, "ten turns on one hex, %d different fields" % shapes.size())


func test_water_never_swallows_a_deployment(t) -> void:
	var rivers := 0
	for s in 200:
		var bs = _field(WATER, [WATER, WATER, WATER, WATER, WATER, WATER], s)
		for f: Array in _kinds(bs, Rules.GROUND_LAKE):
			t.ok(not BattleState._covers_a_deployment(Vector2(f[1], f[2]), float(f[3])),
				"seed %d lays a lake on somebody's line" % s)
		for f: Array in _kinds(bs, Rules.GROUND_RIVER):
			rivers += 1
			var widest := 0.0
			var y := -Rules.BATTLE_HALF_EXTENT
			while y <= Rules.BATTLE_HALF_EXTENT:
				widest = maxf(widest, absf(BattleState.river_x(f, y)) + float(f[3]))
				y += 20.0
			t.ok(widest < Rules.DEPLOY_MARGIN, "the river stays in no-man's-land (%.0f)" % widest)
			t.ok(_kinds(bs, Rules.GROUND_BRIDGE).size() >= 1, "and there is a way over it")
	t.ok(rivers > 60, "beside water a river is common (%d of 200)" % rivers)


func test_no_wood_or_hill_stands_in_the_water(t) -> void:
	# Woods were laid from the hexes round the field with no regard to the river through
	# it, and the trees grew out of the middle of the water.
	var wet := 0
	var land := 0
	for s in 200:
		var bs = _field(FOREST, [FOREST, WATER, HILLS, FOREST, WATER, MOUNTAIN], s)
		for f: Array in bs.features:
			var kind := int(f[0])
			if kind != Rules.GROUND_WOOD and kind != Rules.GROUND_HILL and kind != Rules.GROUND_MARSH:
				continue
			land += 1
			if bs._to_water(Vector2(f[1], f[2])) < float(f[3]) + Rules.LAND_CLEAR - 0.01:
				wet += 1
	t.ok(land > 400, "there was land to check (%d patches)" % land)
	t.eq(wet, 0, "not one wood, hill or marsh reaches into a lake or the river")


func test_trees_nearby_leave_somewhere_to_hide_on_each_side(t) -> void:
	for s in 20:
		var bs = _field(PLAINS, [FOREST, 0, 0, 0, 0, 0], s)
		var sides := {}
		for f: Array in _kinds(bs, Rules.GROUND_WOOD):
			if absf(float(f[1])) >= Rules.DEPLOY_MARGIN and absf(float(f[1])) <= Rules.DEPLOY_DEPTH:
				sides[signf(float(f[1]))] = true
		t.eq(sides.size(), 2, "seed %d: a wood inside each deployment zone" % s)


func test_the_ring_reads_the_six_neighbours_in_order(t) -> void:
	var cs = CampaignState.new()
	cs.terrain.resize(Rules.MAP_W * Rules.MAP_H)
	for row in [4, 5]:                             # an even row and an odd one
		var tile := CampaignState.idx(6, row)
		var around: PackedInt32Array = cs.adjacent(tile)
		for k in around.size():
			cs.terrain[around[k]] = k % 5
		var ring: Array = cs.ring_of(tile)
		for k in around.size():
			t.eq(ring[k], k % 5)
			t.eq(cs.direction_to(tile, around[k]), k)
	t.eq(cs.direction_to(0, CampaignState.idx(10, 10)), 3, "not a neighbour: from the west")


# --- water ------------------------------------------------------------------

func test_a_march_goes_round_a_lake(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_LAKE, 250.0, 0.0, 100.0]]
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(500, 0), 0.0)
	var soaked := 0
	for i in Rules.TICK_HZ * 40:
		bs.step()
		if bs.wet(r.pos):
			soaked += 1
	t.eq(soaked, 0, "nobody stands in a lake")
	t.ok(r.pos.distance_to(Vector2(500, 0)) < 5.0, "and it got round (%s)" % r.pos)


func test_a_march_into_a_lake_halts_on_its_shore(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_LAKE, 250.0, 0.0, 100.0]]
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(250, 0), 0.0)
	for i in Rules.TICK_HZ * 20:
		bs.step()
	t.ok(not bs.wet(r.pos))
	t.eq(r.state, r.State.IDLE, "stopped, rather than circling the water looking for a way in")
	# Within a planner cell of the margin: it stops at the last open cell on its way in.
	t.ok(r.pos.x > 150.0 - Rules.WATER_CLEAR - 20.0, "at the water's edge (%.0f)" % r.pos.x)
	t.ok(r.pos.x <= 150.0 - Rules.WATER_CLEAR + 0.5, "and its front ranks out of it")


func test_a_river_is_crossed_by_its_bridge(t) -> void:
	var bs = BattleState.new()
	var river := [Rules.GROUND_RIVER, 0.0, 0.0, Rules.RIVER_HALF_WIDTH]
	var span := Vector2(BattleState.river_x(river, 300.0), 300.0)
	bs.features = [river, [Rules.GROUND_BRIDGE, span.x, span.y, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH]]
	# Facing north, so its frontage lies along the river: the case that walked twenty files
	# over the planks strung up and down the water.
	var r = bs.add(1, &"spear", Vector2(-300, 0), -PI / 2.0)
	r.order_move(Vector2(300, 0), -PI / 2.0)
	var soaked := 0
	var planked := 0
	var column := 0
	for i in Rules.TICK_HZ * 60:
		bs.step()
		if bs.wet(r.pos):
			soaked += 1
		if bs.bridge_at(r.pos) != null:
			planked += 1
			if bs.crossing(r) != null and is_equal_approx(float(bs.crossing(r)), 0.0):
				column += 1
	t.eq(soaked, 0, "nobody wades, or comes within WATER_CLEAR of it")
	t.ok(planked > 0, "it went over the bridge")
	t.eq(column, planked, "in a column pointed at the far bank, every tick it was on the planks")
	t.ok(r.pos.distance_to(Vector2(300, 0)) < 5.0, "and arrived on the far bank (%s)" % r.pos)
	t.eq(bs.crossing(r), null, "and is a line again once over")


func test_a_bridge_is_held_like_a_gate(t) -> void:
	# The same fight on the planks and in the open: on the bridge only BRIDGE_FILES reach
	# the enemy, whatever frontage came to it.
	var losses := []
	for on_bridge in [true, false]:
		var bs = BattleState.new()
		if on_bridge:
			bs.features = [[Rules.GROUND_RIVER, 0.0, 0.0, Rules.RIVER_HALF_WIDTH],
				[Rules.GROUND_BRIDGE, 0.0, 0.0, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH]]
		var holder = bs.add(1, &"spear", Vector2.ZERO, 0.0)
		var comer = bs.add(2, &"spear", Vector2.ZERO, PI)
		comer.pos = Vector2(BattleState.contact_distance(holder, comer, Rules.CONTACT_GAP * 0.5), 0)
		comer.target = comer.pos
		for i in Rules.TICK_HZ * 10:
			bs.step()
		losses.append(comer.max_strength - comer.strength)
	t.ok(losses[0] < losses[1], "fewer fall at a bridge (%d) than in the open (%d)" % losses)


func test_the_new_ground_survives_the_wire(t) -> void:
	var bs = _field(WATER, [WATER, MOUNTAIN, FOREST, HILLS, WATER, PLAINS], 5)
	bs.features = ([[Rules.GROUND_RIVER, 12.0, 1.5, Rules.RIVER_HALF_WIDTH],
		[Rules.GROUND_BRIDGE, 12.0, 0.0, 40.0], [Rules.GROUND_LAKE, 900.0, 300.0, 150.0]]
		+ bs.features).slice(0, Rules.MAX_FEATURES)
	bs.add(1, &"spear", Vector2(-260, 0), 0.0)
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	if back != null:
		t.eq(back.features, bs.features)
		t.eq(Snapshot.encode_battle(back), Snapshot.encode_battle(bs))
