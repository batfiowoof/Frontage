extends RefCounted
## The battle fog: what a side can see, what goes on its wire, and what it may act on.

const BattleState := preload("res://sim/battle_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")

const WOOD := Vector2(300, 0)


## Ours at the origin, and a wood at WOOD with somebody of theirs standing in it.
func _hiding() -> Array:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_WOOD, WOOD.x, WOOD.y, 120.0]]
	var ours = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var theirs = bs.add(2, &"spear", WOOD, PI)
	return [bs, ours, theirs]


func test_open_ground_is_seen_as_far_as_sight_reaches(t) -> void:
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var near = bs.add(2, &"spear", Vector2(Rules.BATTLE_SIGHT * 0.9, 0), PI)
	var far = bs.add(2, &"spear", Vector2(Rules.BATTLE_SIGHT * 1.1, 0), PI)
	t.ok(bs.visible_to(1, near))
	t.ok(not bs.visible_to(1, far), "past sight is past sight")
	t.ok(bs.visible_to(1, ours), "your own, always")
	t.ok(bs.visible_to(0, far), "owner 0 is the replay and sees everything")
	t.ok(bs.visible_to(99, far), "and so does somebody with nobody on the field")


func test_higher_ground_sees_further(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_HILL, 0.0, 0.0, 200.0]]
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var far = bs.add(2, &"spear", Vector2(Rules.BATTLE_SIGHT * 1.1, 0), PI)
	t.ok(bs.visible_to(1, far), "from a hilltop you see over the horizon")


func test_a_wood_hides_whoever_stands_in_it(t) -> void:
	var s := _hiding()
	t.ok(not s[0].visible_to(1, s[2]), "300 units off, a regiment in the trees is not there")
	s[1].pos = WOOD - Vector2(60, 0)
	t.ok(s[0].visible_to(1, s[2]), "60 off, you walk into it")


func test_fighting_or_shooting_gives_it_away(t) -> void:
	var s := _hiding()
	s[2].engaged_with = 12345
	t.ok(s[0].visible_to(1, s[2]), "a regiment in a melee is not hiding")
	s[2].engaged_with = -1
	s[2].reload = 1.0
	t.ok(s[0].visible_to(1, s[2]), "nor is one that has just loosed a volley")


func test_the_wire_carries_only_what_you_can_see(t) -> void:
	var s := _hiding()
	var open = s[0].add(2, &"spear", Vector2(400, 300), PI)
	var mine = Snapshot.decode_battle(Snapshot.encode_battle(s[0], 1))
	t.ok(mine != null)
	if mine != null:
		t.ok(mine.regiments.has(s[1].id) and mine.regiments.has(open.id))
		t.ok(not mine.regiments.has(s[2].id), "the hidden one never leaves the server")
		t.eq(Snapshot.encode_battle(mine), Snapshot.encode_battle(s[0], 1), "and what arrives round-trips")
	var theirs = Snapshot.decode_battle(Snapshot.encode_battle(s[0], 2))
	t.eq(theirs.regiments.size(), 3, "they know where their own men are")
	t.eq(Snapshot.decode_battle(Snapshot.encode_battle(s[0])).regiments.size(), 3, "the replay sees all")


func test_nobody_shoots_what_they_cannot_see(t) -> void:
	var s := _hiding()
	for i in Rules.TICK_HZ * 10:
		s[0].step()
	t.eq(s[1].ammo, int(Rules.KINDS[&"archer"]["ammo"]), "not an arrow into the trees")


func test_you_cannot_aim_at_a_man_you_cannot_see(t) -> void:
	var s := _hiding()
	t.ok(not s[0].aim(s[1], s[2].id), "an attack order naming a hidden regiment is refused")
	t.eq(s[1].focus, -1)
	t.ok(s[0].aim(s[1], -1), "clearing one is always fine")
	s[1].pos = WOOD - Vector2(60, 0)
	t.ok(s[0].aim(s[1], s[2].id))
	t.eq(s[1].focus, s[2].id)


func test_an_ai_that_sees_nobody_goes_looking(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_WOOD, 260.0, 0.0, 150.0]]
	var ours = bs.add(1, &"spear", Vector2(-260, 0), 0.0)
	bs.add(2, &"spear", Vector2(260, 0), PI)
	var went := Vector2.INF
	for order in Ai.new(1).battle_orders(bs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.BATTLE_MOVE and d["ids"][0] == ours.id:
			went = d["target"]
	t.ok(went != Vector2.INF, "it moved rather than standing until the clock ran out")
	t.ok(went.x > 0.0, "toward the enemy's side (%s)" % went)


func test_deployment_keeps_to_its_zone(t) -> void:
	var bs = BattleState.new()
	bs.phase = BattleState.Phase.DEPLOY
	var r = bs.add(1, &"spear", Vector2(-260, 0), 0.0)
	bs.add(2, &"spear", Vector2(260, 0), PI)
	t.eq(bs.deployable(r, Vector2(-2000, 2000)), Vector2(-Rules.DEPLOY_DEPTH, Rules.DEPLOY_HALF_WIDTH),
		"no further back or out than the zone")
	t.eq(bs.deployable(r, Vector2(500, 0)), Vector2(-Rules.DEPLOY_MARGIN, 0), "and not into theirs")
	t.eq(bs.deployable(r, Vector2(-400, 50)), Vector2(-400, 50), "anywhere inside is yours")
