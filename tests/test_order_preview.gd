extends RefCounted
## M26: the ghosts a right-drag draws are the order it will send.
##
## Both the preview and the order read the rows `plan_order` returns and neither works
## anything out on its own, so testing the plan tests both.

const BattleView := preload("res://view/battle/battle_view.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _pose(count: int, width := 12, spacing := 1.0) -> Dictionary:
	var out := {}
	for i in count:
		out[i] = {
			"pos": Vector2(0, float(i) * 120.0), "facing": 0.0, "owner": 1, "kind": &"spear",
			"strength": 120, "max_strength": 120, "morale": 100.0, "stamina": 1.0,
			"width": width, "state": Regiment.State.IDLE, "formation": &"line",
			"reforming": 0.0, "spacing": spacing, "ammo": 0, "hits": [], "threats": PackedVector2Array(),
		}
	return out


func _all(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in count:
		out.append(i)
	return out


func test_nothing_selected_plans_nothing(t) -> void:
	t.eq(BattleView.plan_order(_pose(3), PackedInt32Array(), Vector2.ZERO, Vector2(100, 0)).size(), 0)
	t.eq(BattleView.plan_order(_pose(3), _all(3), Vector2.INF, Vector2(100, 0)).size(), 0)


func test_every_selected_regiment_gets_a_place(t) -> void:
	var plan := BattleView.plan_order(_pose(4), _all(4), Vector2(500, 500), Vector2(700, 500))
	t.eq(plan.size(), 4)
	var seen := {}
	for row: Dictionary in plan:
		t.ok(not seen.has(row["id"]), "nobody is ordered twice")
		seen[row["id"]] = true


func test_a_drag_sets_everybody_the_same_facing(t) -> void:
	var plan := BattleView.plan_order(_pose(3), _all(3), Vector2.ZERO, Vector2(0, 400))
	for row: Dictionary in plan:
		t.near(row["face"], PI / 2.0, 0.0001, "everyone faces the way the drag went")


func test_a_click_faces_each_regiment_at_its_own_destination(t) -> void:
	# No drag worth speaking of, so there is no shared facing to take.
	var pose := _pose(3)
	var plan := BattleView.plan_order(pose, _all(3), Vector2(900, 0), Vector2(903, 0))
	for row: Dictionary in plan:
		var want: float = (row["target"] - pose[row["id"]]["pos"]).angle()
		t.near(row["face"], want, 0.0001, "it turns toward where it is going")


func test_the_line_is_spread_across_the_facing(t) -> void:
	var plan := BattleView.plan_order(_pose(3), _all(3), Vector2.ZERO, Vector2(400, 0))
	# Dragging along +X means the line runs along Y.
	for row: Dictionary in plan:
		t.near(row["target"].x, 0.0, 0.001, "nobody stands in front of or behind the line")
	var ys := []
	for row: Dictionary in plan:
		ys.append(row["target"].y)
	t.ok(ys[0] < ys[1] and ys[1] < ys[2], "and they are in order along it")
	t.near(ys[1], 0.0, 0.001, "centred on where the drag began")


func test_a_single_regiment_lands_exactly_where_you_dragged_from(t) -> void:
	var plan := BattleView.plan_order(_pose(1), _all(1), Vector2(320, -80), Vector2(520, -80))
	t.eq(plan[0]["target"], Vector2(320, -80))


func test_a_wider_regiment_takes_more_room(t) -> void:
	# The reason the preview matters: frontage is what decides the fight, and until now
	# it was a number in a HUD line.
	var narrow := BattleView.plan_order(_pose(2, 6), _all(2), Vector2.ZERO, Vector2(400, 0))
	var wide := BattleView.plan_order(_pose(2, 24), _all(2), Vector2.ZERO, Vector2(400, 0))
	var narrow_gap: float = absf(narrow[1]["target"].y - narrow[0]["target"].y)
	var wide_gap: float = absf(wide[1]["target"].y - wide[0]["target"].y)
	t.ok(wide_gap > narrow_gap, "a wider line needs more room (%.0f vs %.0f)" % [wide_gap, narrow_gap])


func test_the_ghost_is_the_regiments_real_footprint(t) -> void:
	var plan := BattleView.plan_order(_pose(1, 12), _all(1), Vector2.ZERO, Vector2(400, 0))
	t.near(plan[0]["half_width"], Formation.frontage(120, 12, 1.0), 0.0001)
	t.near(plan[0]["half_depth"], Formation.half_depth(120, 12, 1.0), 0.0001)


func test_loose_order_draws_wider_than_close_order(t) -> void:
	var close := BattleView.plan_order(_pose(1, 12, 1.0), _all(1), Vector2.ZERO, Vector2(400, 0))
	var loose := BattleView.plan_order(_pose(1, 12, 1.9), _all(1), Vector2.ZERO, Vector2(400, 0))
	t.ok(loose[0]["half_width"] > close[0]["half_width"],
		"the formation's spacing shows in the ghost too")


func test_the_plan_remembers_where_each_regiment_started(t) -> void:
	# The lead line joining a regiment to its destination is drawn from this.
	var pose := _pose(3)
	for row: Dictionary in BattleView.plan_order(pose, _all(3), Vector2(600, 0), Vector2(800, 0)):
		t.eq(row["from"], pose[row["id"]]["pos"])
