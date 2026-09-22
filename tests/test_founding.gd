extends RefCounted
## Founding a town, which is the whole Civ half of this game and did not exist.
##
## The map used to be dealt once at `generate()` -- one capital each plus four neutral
## towns -- and never change shape again, so the only way to grow was to take somebody
## else's. A settler is how a player makes a new one.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


## A hex far enough from every town to build on, with an army of ours standing on it.
func _party_somewhere_legal(cs, owner := 1) -> int:
	for tile in cs.terrain.size():
		if not cs.passable(tile) or cs.army_at(tile) != null:
			continue
		var clear := true
		for s: Dictionary in cs.settlements:
			if Campaign.hex_distance(tile, int(s["tile"])) < Rules.MIN_TOWN_DISTANCE:
				clear = false
				break
		if clear:
			return cs.add_army(owner, tile, [Rules.SETTLER, &"spear"])["id"]
	return -1


# --- the settler ----------------------------------------------------------

func test_a_settler_can_be_raised_in_a_bare_town(t) -> void:
	var cs = _two_player()
	var home := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			home = int(s["tile"])
	t.ok(cs.recruitable_at(home).has(Rules.SETTLER),
		"expansion must not be gated behind a building")


func test_settler_in_finds_it_wherever_it_stands(t) -> void:
	var a := {"regiments": [Campaign.make_regiment(&"spear"),
		Campaign.make_regiment(Rules.SETTLER)]}
	t.eq(cs_settler_in(a), 1)
	var none := {"regiments": [Campaign.make_regiment(&"spear")]}
	t.eq(cs_settler_in(none), -1)


func cs_settler_in(a: Dictionary) -> int:
	return Campaign.new().settler_in(a)


# --- where a town may go --------------------------------------------------

func test_founding_puts_a_town_down(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	t.ok(id >= 0, "precondition: there is room on this map")
	var before: int = cs.settlements_of(1)
	var where: int = cs.armies[id]["tile"]
	t.ok(cs.found(1, id))
	t.eq(cs.settlements_of(1), before + 1)
	t.ok(cs.settlement_at(where) != null, "and it is on the hex the army was standing on")


func test_too_close_to_another_town_is_refused(t) -> void:
	# Otherwise two towns bank the same fields and founding is a way of counting land
	# somebody is already working twice over.
	var cs = _two_player()
	var home := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 1:
			home = int(s["tile"])
	var beside: int = cs.adjacent(home)[0]
	if cs.army_at(beside) != null:
		cs.armies.erase(cs.army_at(beside)["id"])
	var id: int = cs.add_army(1, beside, [Rules.SETTLER])["id"]
	t.ok(not cs.can_found(1, id))
	t.ok(not cs.found(1, id), "and the order does nothing, not merely nothing visible")


func test_an_army_with_no_settler_cannot_found(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	cs.armies[id]["regiments"] = [Campaign.make_regiment(&"spear")]
	t.ok(not cs.can_found(1, id))


func test_you_cannot_found_with_somebody_elses_army(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs, 1)
	t.ok(not cs.can_found(2, id), "ownership is checked in the sim, not only at the socket")
	t.ok(not cs.found(2, id))


func test_an_army_that_has_already_moved_cannot_found(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	cs.armies[id]["move_left"] = 0
	t.ok(not cs.can_found(1, id), "founding a town is a turn's work, like razing")


# --- what it costs --------------------------------------------------------

func test_founding_consumes_the_settler_and_the_turn(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	t.ok(cs.found(1, id))
	var a: Dictionary = cs.armies[id]
	t.eq(cs.settler_in(a), -1, "the settlers became the town")
	t.eq(a["regiments"].size(), 1, "and the escort stayed behind")
	t.eq(a["move_left"], 0)


func test_an_army_of_nothing_but_settlers_disbands(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	cs.armies[id]["regiments"] = [Campaign.make_regiment(Rules.SETTLER)]
	t.ok(cs.found(1, id))
	t.ok(not cs.armies.has(id), "there is nobody left to be an army")


func test_a_new_town_works_its_own_land(t) -> void:
	# The nearest-town rule already decides who banks a hex; a new town simply joins the
	# competition. If it did not, founding would produce a town that earned nothing.
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	var where: int = cs.armies[id]["tile"]
	t.ok(cs.found(1, id))
	var working = cs.working_settlement(where)
	t.ok(working != null and int(working["tile"]) == where,
		"a town works the hex it stands on")


func test_a_new_town_can_see(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	var where: int = cs.armies[id]["tile"]
	t.ok(cs.found(1, id))
	t.ok(cs.can_see(1, where), "a town is a pair of eyes as well as an income")


func test_founding_clears_whatever_stood_there(t) -> void:
	# A town on top of a farm would be worked by itself and counted twice.
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	var where: int = cs.armies[id]["tile"]
	cs.structures[where] = Campaign.structure_code(&"farm")
	t.ok(cs.found(1, id))
	t.eq(cs.structure_at(where), &"", "the ground is the town's now")


# --- the order ------------------------------------------------------------

func test_the_order_round_trips(t) -> void:
	var decoded := Orders.decode(Orders.found(7))
	t.eq(decoded["type"], Orders.Type.FOUND)
	t.eq(decoded["army_id"], 7)


func test_a_malformed_found_order_is_refused(t) -> void:
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FOUND, "not an id"])), {})
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FOUND])), {})


func test_the_enum_was_appended_to(t) -> void:
	# The file says APPEND ONLY: these ints go into every .rpl ever recorded, so
	# renumbering them silently reinterprets old recordings.
	t.eq(Orders.Type.BATTLE_MOVE, 0)
	t.eq(Orders.Type.STANCE, 12, "FOUND went after STANCE, not in the middle")
	t.eq(Orders.Type.FOUND, 13)


func test_a_settler_survives_the_wire(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null, "a settler is a regiment kind like any other")
	t.eq(back.settler_in(back.armies[id]), 0)


func test_a_founded_town_survives_the_wire(t) -> void:
	var cs = _two_player()
	var id := _party_somewhere_legal(cs)
	var where: int = cs.armies[id]["tile"]
	t.ok(cs.found(1, id))
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.eq(back.settlements.size(), cs.settlements.size())
	t.ok(back.settlement_at(where) != null)


# --- the AI ---------------------------------------------------------------

func test_the_ai_founds_a_town_when_it_is_standing_on_one(t) -> void:
	# It has to actually issue the order, or the AI simply loses on production to any
	# player who expands.
	var cs = _two_player()
	var ai = Ai.new(1)
	var id := _party_somewhere_legal(cs, 1)
	var found := false
	for order in ai.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.FOUND and d.get("army_id") == id:
			found = true
	t.ok(found, "the AI put the town down")


func test_the_ai_does_not_march_its_settlers_at_the_enemy(t) -> void:
	# A settler party sent at a defended capital is 200 gold walking into a battle it
	# is the worst possible unit for.
	var cs = _two_player()
	var ai = Ai.new(1)
	var id: int = cs.add_army(1, _far_empty_hex(cs), [Rules.SETTLER, &"spear"])["id"]
	var prize := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] != 1:
			prize = int(s["tile"])
			break
	for order in ai.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.ARMY_MOVE and d.get("army_id") == id:
			t.ok(d["dest"] != prize, "it is going somewhere to settle, not at the enemy")


func test_the_ai_never_raises_a_settler_as_a_soldier(t) -> void:
	# It is 40 men with farm tools. Picking "the best it can afford" would have raised
	# them over a spear regiment the moment the purse allowed.
	var cs = _two_player()
	cs.gold[1] = 100000
	var ai = Ai.new(1)
	# Already carrying one, so the deliberate expansion branch is closed.
	cs.add_army(1, _far_empty_hex(cs), [Rules.SETTLER])
	for order in ai.campaign_orders(cs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.RECRUIT:
			t.ok(d["kind"] != Rules.SETTLER, "raised %s, not a second settler" % d["kind"])


func _far_empty_hex(cs) -> int:
	for tile in cs.terrain.size():
		if cs.passable(tile) and cs.army_at(tile) == null and cs.settlement_at(tile) == null:
			return tile
	return 0
