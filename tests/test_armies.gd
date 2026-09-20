extends RefCounted
## M25: armies that combine and divide.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


## Two armies of `owner`, side by side on clear ground, with the given compositions.
func _side_by_side(cs, left: Array, right: Array, owner := 1) -> Array:
	var here := -1
	var there := -1
	for tile in cs.structures.size():
		if not cs.passable(tile) or cs.army_at(tile) != null or cs.settlement_at(tile) != null:
			continue
		for n in cs.adjacent(tile):
			if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
				here = tile
				there = n
				break
		if here >= 0:
			break
	var a = cs.add_army(owner, here, left)
	var b = cs.add_army(owner, there, right)
	return [a, b]


# --- merging --------------------------------------------------------------

func test_two_armies_beside_each_other_become_one(t) -> void:
	var cs = _two_player()
	var pair := _side_by_side(cs, [&"spear", &"spear"], [&"archer"])
	var a: Dictionary = pair[0]
	var b: Dictionary = pair[1]

	t.ok(cs.merge(1, a["id"], b["id"]))
	t.eq(b["regiments"].size(), 3, "everybody moved across")
	t.ok(not cs.armies.has(a["id"]), "and the empty army is gone")


func test_merging_never_buys_a_move(t) -> void:
	var cs = _two_player()
	var pair := _side_by_side(cs, [&"spear"], [&"spear"])
	pair[0]["move_left"] = 3
	pair[1]["move_left"] = 1
	cs.merge(1, pair[0]["id"], pair[1]["id"])
	t.eq(pair[1]["move_left"], 1, "the slower half sets the pace")


func test_the_cap_is_respected_and_the_rest_stay_behind(t) -> void:
	var cs = _two_player()
	var big := []
	for i in Campaign.MAX_REGIMENTS_PER_ARMY - 1:
		big.append(&"spear")
	var pair := _side_by_side(cs, [&"archer", &"archer", &"archer"], big)
	var a: Dictionary = pair[0]
	var b: Dictionary = pair[1]

	t.ok(cs.merge(1, a["id"], b["id"]))
	t.eq(b["regiments"].size(), Campaign.MAX_REGIMENTS_PER_ARMY, "filled to the brim")
	t.ok(cs.armies.has(a["id"]), "and the remainder is still an army")
	t.eq(a["regiments"].size(), 2, "with what would not fit")


func test_a_full_army_cannot_be_joined(t) -> void:
	var cs = _two_player()
	var full := []
	for i in Campaign.MAX_REGIMENTS_PER_ARMY:
		full.append(&"spear")
	var pair := _side_by_side(cs, [&"archer"], full)
	t.ok(not cs.merge(1, pair[0]["id"], pair[1]["id"]), "there is no room")
	t.eq(pair[0]["regiments"].size(), 1)


func test_armies_across_the_map_cannot_merge(t) -> void:
	var cs = _two_player()
	var a = cs.armies[cs.sorted_army_ids()[0]]
	var far = cs.add_army(1, Campaign.idx(12, 8), [&"spear"])
	t.ok(not cs.can_merge(1, far["id"], a["id"]), "they have to be standing next to each other")


func test_you_cannot_merge_somebody_elses_army(t) -> void:
	var cs = _two_player()
	var pair := _side_by_side(cs, [&"spear"], [&"spear"])
	t.ok(not cs.merge(2, pair[0]["id"], pair[1]["id"]), "not your troops to move")
	t.ok(not cs.merge(1, pair[0]["id"], pair[0]["id"]), "nor can an army join itself")


func test_an_army_that_has_marched_all_day_cannot_also_merge(t) -> void:
	var cs = _two_player()
	var pair := _side_by_side(cs, [&"spear"], [&"spear"])
	pair[0]["move_left"] = 0
	t.ok(not cs.merge(1, pair[0]["id"], pair[1]["id"]))


# --- splitting ------------------------------------------------------------

func _with_army(cs, kinds: Array, owner := 1) -> Dictionary:
	for tile in cs.structures.size():
		if not cs.passable(tile) or cs.army_at(tile) != null or cs.settlement_at(tile) != null:
			continue
		var free := -1
		for n in cs.adjacent(tile):
			if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
				free = n
		if free < 0:
			continue
		var a = cs.add_army(owner, tile, kinds)
		a["free"] = free
		return a
	return {}


func test_a_detachment_marches_out_as_its_own_army(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"spear", &"cavalry"])
	var made: int = cs.split(1, a["id"], PackedInt32Array([2]), a["free"])
	t.ok(made > 0, "a new army")
	if made < 0:
		return
	t.eq(a["regiments"].size(), 2, "and the rest stayed")
	t.eq(cs.armies[made]["regiments"].size(), 1)
	t.eq(cs.armies[made]["regiments"][0][0], &"cavalry", "the one that was picked")
	t.eq(cs.armies[made]["tile"], a["free"])
	t.eq(cs.armies[made]["move_left"], 0, "forming up takes the day")


func test_a_detachment_keeps_its_wounds(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry"])
	a["regiments"][1][1] = 19
	var made: int = cs.split(1, a["id"], PackedInt32Array([1]), a["free"])
	if made > 0:
		t.eq(cs.armies[made]["regiments"][0][1], 19, "a battered regiment stays battered")


func test_something_always_stays_behind(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry"])
	t.eq(cs.split(1, a["id"], PackedInt32Array([0, 1]), a["free"]), -1,
		"an army cannot detach itself out of existence")
	t.eq(a["regiments"].size(), 2)


func test_a_detachment_needs_an_empty_hex_beside_it(t) -> void:
	# Two armies on one hex would break army_at(), and movement, collisions and razing
	# all lean on it -- so this rule is load-bearing rather than cosmetic.
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry"])
	cs.add_army(2, a["free"], [&"spear"])
	t.eq(cs.split(1, a["id"], PackedInt32Array([1]), a["free"]), -1, "somebody is already there")

	var far := Campaign.idx(2, 2)
	t.eq(cs.split(1, a["id"], PackedInt32Array([1]), far), -1, "and it has to be next door")


func test_nonsense_indices_are_refused(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry", &"archer"])
	t.eq(cs.split(1, a["id"], PackedInt32Array([9]), a["free"]), -1, "no such regiment")
	t.eq(cs.split(1, a["id"], PackedInt32Array([-1]), a["free"]), -1, "nor that one")
	t.eq(cs.split(1, a["id"], PackedInt32Array([1, 1]), a["free"]), -1,
		"the same regiment twice would clone it")
	t.eq(cs.split(1, a["id"], PackedInt32Array(), a["free"]), -1, "nobody to detach")
	t.eq(a["regiments"].size(), 3, "and none of that moved anybody")


func test_you_cannot_split_somebody_elses_army(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry"])
	t.eq(cs.split(2, a["id"], PackedInt32Array([1]), a["free"]), -1)


func test_a_raiding_party_is_the_point_of_it(t) -> void:
	# Peeling one horse regiment off to go and burn farmland is the move split exists
	# for, so it gets a test end to end.
	var cs = _two_player()
	cs.gold[2] = 100000
	var a := _with_army(cs, [&"spear", &"spear", &"cavalry"], 1)
	var made: int = cs.split(1, a["id"], PackedInt32Array([2]), a["free"])
	t.ok(made > 0)
	if made < 0:
		return
	t.eq(cs.armies[made]["regiments"][0][0], &"cavalry")

	# Next turn it can ride, and burn.
	cs.end_turn()
	t.ok(cs.armies[made]["move_left"] > 0, "the day after, it rides")


# --- the wire and the AI --------------------------------------------------

func test_merge_and_split_orders_validate(t) -> void:
	var m: Dictionary = Orders.decode(Orders.merge(3, 4))
	t.eq(m.get("type"), Orders.Type.MERGE)
	t.eq(m.get("army_id"), 3)
	t.eq(m.get("into_id"), 4)
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.MERGE, 3, 3])), {},
		"an army cannot join itself")

	var sp: Dictionary = Orders.decode(Orders.split(3, PackedInt32Array([0, 2]), 40))
	t.eq(sp.get("type"), Orders.Type.SPLIT)
	t.eq(sp.get("to_tile"), 40)
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.SPLIT, 3,
		PackedInt32Array(), 40])), {}, "nobody to detach")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.SPLIT, 3,
		PackedInt32Array([1]), 999999])), {}, "off the map")


func test_a_split_army_survives_the_wire(t) -> void:
	var cs = _two_player()
	var a := _with_army(cs, [&"spear", &"cavalry"])
	var made: int = cs.split(1, a["id"], PackedInt32Array([1]), a["free"])
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	if back != null and made > 0:
		t.eq(back.armies[made]["regiments"], cs.armies[made]["regiments"])
		t.eq(back.armies[made]["tile"], cs.armies[made]["tile"])
		t.eq(Snapshot.encode_campaign(back), Snapshot.encode_campaign(cs))


func test_the_ai_gathers_a_remnant_into_a_bigger_army(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var pair := _side_by_side(cs, [&"spear"], [&"spear", &"spear", &"spear", &"spear"], 1)
	var brain = Ai.new(1)
	var merged := false
	for bytes: PackedByteArray in brain.campaign_orders(cs):
		var order := Orders.decode(bytes)
		if not order.is_empty() and order["type"] == Orders.Type.MERGE:
			merged = true
			t.eq(order["army_id"], pair[0]["id"], "the small one joins the big one")
			t.eq(order["into_id"], pair[1]["id"])
	t.ok(merged, "a lone regiment beside a real army should not wander off alone")
