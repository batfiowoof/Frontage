extends RefCounted
## M26: the ghosts a right-drag draws are the order it will send.
##
## Both the preview and the order read the rows `plan_order` returns and neither works
## anything out on its own, so testing the plan tests both.
##
## The drag IS the line: press and release are the two ends of the formation, the facing is
## perpendicular to it, and its LENGTH is each regiment's frontage. The length used to
## become slack inserted BETWEEN neighbours, so a long drag gave you the same blocks
## further apart -- and with one regiment selected it gave you nothing at all, because the
## slack was divided by n - 1. Every fault has a test below.
##
## A regiment has a maximum frontage, so the line cannot be stretched indefinitely: past
## MAX_WIDTH it caps and centres on the drag instead. Tests here measure FILES, and treat
## how far apart the targets ended up as the side effect it is.

const BattleView := preload("res://view/battle/battle_view.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Orders := preload("res://net/orders.gd")
const Bodies := preload("res://view/battle/bodies.gd")


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


## The seam the whole feature hangs on: a frontage the preview worked out has to survive
## being encoded, decoded and applied by the server, and then has to reach the men.
##
## Every piece of this is tested on its own elsewhere. What is only testable here is that
## they AGREE -- a drag that derives 40 files is worth nothing if _set_formation drops it,
## and _set_formation drops any width that arrives beside a formation it treats as a
## change of shape.
func test_a_dragged_frontage_reaches_the_regiment_and_then_the_men(t) -> void:
	var r = Regiment.make(0, 1, &"spear", Vector2.ZERO)
	var pose := {0: {
		"pos": r.pos, "facing": 0.0, "owner": 1, "kind": r.kind,
		"strength": r.strength, "max_strength": r.max_strength, "morale": 100.0,
		"stamina": 1.0, "width": r.width, "state": Regiment.State.IDLE,
		"formation": r.formation, "reforming": 0.0, "spacing": r.spacing(), "ammo": 0,
		"hits": [], "threats": PackedVector2Array(),
	}}
	var plan := BattleView.plan_order(pose, PackedInt32Array([0]), Vector2(-500, 0), Vector2(500, 0))
	var row: Dictionary = plan[0]
	t.ok(int(row["width"]) != r.width, "a real change, not the frontage it already had")

	# Exactly what _finish_order puts on the wire, and exactly what net.gd does with it.
	t.ok(row["rewidth"], "and the row says so")
	var order := Orders.decode(Orders.set_formation(PackedInt32Array([0]),
		row["formation"], row["width"]))
	t.ok(not order.is_empty(), "the frontage survives the wire")
	var changed: bool = r.set_formation(order["formation"])
	t.ok(not changed, "the shape is unchanged, which is what lets the width through")
	if int(order["width"]) > 0 and not changed:
		r.set_width(int(order["width"]))
	t.eq(r.width, int(row["width"]), "the server ends up at the frontage the ghost drew")
	t.near(r.reforming, 0.0, 0.001, "and pays nothing for it")

	# ...and the men re-file into it, which is the thing the player actually sees. Slots
	# come from the mirror's width, so this is the last link in the chain.
	var men := Bodies.new()
	pose[0]["width"] = r.width
	men.build(pose, [1], 0.05)
	t.eq(men.men_per_file(0).size(), r.width,
		"the soldiers stand in as many files as the drag asked for")
	t.eq(men.living(0), r.strength, "and re-forming loses nobody")


## The frontage the whole plan actually covers: every regiment's own width added up. That
## is what a drag now buys, where `_span` only says how far apart the centres ended up.
func _frontage(plan: Array) -> float:
	var total := 0.0
	for row: Dictionary in plan:
		total += float(row["half_width"]) * 2.0
	return total


## The distance between the two outermost regiments in a plan.
func _span(plan: Array) -> float:
	var lo := Vector2.INF
	var hi := Vector2.INF
	for row: Dictionary in plan:
		if lo == Vector2.INF or row["target"].distance_to(plan[0]["target"]) > lo.distance_to(plan[0]["target"]):
			lo = row["target"]
	for row: Dictionary in plan:
		if hi == Vector2.INF or row["target"].distance_to(lo) > hi.distance_to(lo):
			hi = row["target"]
	return lo.distance_to(hi)


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


# --- the drag is the line -------------------------------------------------

func test_a_longer_drag_makes_a_wider_line(t) -> void:
	# The bug this file exists for. The drag's length used to be read for one thing --
	# whether it counted as a drag at all -- and then discarded.
	var short := BattleView.plan_order(_pose(3), _all(3), Vector2(0, 0), Vector2(300, 0))
	var long := BattleView.plan_order(_pose(3), _all(3), Vector2(0, 0), Vector2(1400, 0))
	# The claim is FILES. More room between the same blocks is what the old code did.
	for i in 3:
		t.ok(int(long[i]["width"]) > int(short[i]["width"]),
			"each regiment stands wider, %d files against %d" % [
				int(long[i]["width"]), int(short[i]["width"])])
	t.ok(_frontage(long) > _frontage(short) * 2.0,
		"so the line covers more ground (%.0f vs %.0f)" % [_frontage(long), _frontage(short)])
	t.ok(_span(long) > _span(short) * 2.0,
		"and the centres spread with it (%.0f vs %.0f)" % [_span(long), _span(short)])


func test_a_drag_reshapes_a_single_regiment_too(t) -> void:
	# With one selected, the drag length was thrown away entirely: the slack it became was
	# divided by n - 1 and never consumed, so a lone regiment was sent to the PRESS point
	# at its original width however far you dragged.
	var wide := BattleView.plan_order(_pose(1), _all(1), Vector2(-500, 0), Vector2(500, 0))
	t.eq(int(wide[0]["width"]), Rules.MAX_WIDTH, "a long drag widens it to its limit")
	t.ok(wide[0]["rewidth"], "and that is a change of frontage, so it has to be ordered")
	t.near(wide[0]["target"].x, 0.0, 0.001, "centred on the line, not left at the press point")

	var deep := BattleView.plan_order(_pose(1), _all(1), Vector2(-35, 0), Vector2(35, 0))
	t.ok(int(deep[0]["width"]) < int(wide[0]["width"]),
		"a short one packs it deep again (%d files against %d)" % [
			int(deep[0]["width"]), int(wide[0]["width"])])
	t.near(deep[0]["target"].x, 0.0, 0.001, "and it is centred too")


func test_a_drag_never_orders_a_conga_line(t) -> void:
	# Shoulders alone exceed a short drag over four regiments, so the share of the line
	# each one gets goes NEGATIVE. Without a floor that derives MIN_WIDTH: two files,
	# sixty ranks deep, which is not a formation.
	var plan := BattleView.plan_order(_pose(4), _all(4), Vector2(0, 0), Vector2(40, 0))
	for row: Dictionary in plan:
		var ranks := ceili(120.0 / float(row["width"]))
		t.ok(ranks <= BattleView.DRAG_MAX_RANKS,
			"%d files is %d ranks deep, past the %d the drag may ask for" % [
				int(row["width"]), ranks, BattleView.DRAG_MAX_RANKS])


func test_the_frontage_never_exceeds_what_the_sim_allows(t) -> void:
	# Regiment.set_width clamps to MAX_WIDTH and to the headcount both, so a ghost that
	# promised more would be drawing an order that comes straight back refused.
	var pose := _pose(1)
	pose[0]["max_strength"] = 30
	pose[0]["strength"] = 30
	var plan := BattleView.plan_order(pose, _all(1), Vector2(-2000, 0), Vector2(2000, 0))
	t.ok(int(plan[0]["width"]) <= 30, "never more files than there are men")
	t.ok(int(plan[0]["width"]) <= Rules.MAX_WIDTH, "and never wider than the field allows")


func test_a_drag_that_changes_nothing_does_not_re_form(t) -> void:
	# Without a deadband every ordinary move-drag would cost FORMATION_CHANGE_SECONDS,
	# because the derived frontage would land a file either side of what it already is.
	var wanted := Formation.frontage(120, 12, 1.0) * 2.0
	var plan := BattleView.plan_order(_pose(1), _all(1),
		Vector2(-wanted * 0.5, 0), Vector2(wanted * 0.5, 0))
	t.eq(int(plan[0]["width"]), 12, "a drag its own width wide leaves the frontage alone")
	t.ok(not plan[0]["rewidth"], "so no order goes out at all")


func test_a_regiment_already_re_forming_still_takes_a_new_frontage(t) -> void:
	# It used to be refused mid-change and the preview had to lie about it to stay
	# honest. set_width is free and refuses nothing now, so the ghost can simply show
	# what was asked for.
	var pose := _pose(1)
	pose[0]["reforming"] = 3.0
	var plan := BattleView.plan_order(pose, _all(1), Vector2(-900, 0), Vector2(900, 0))
	t.eq(int(plan[0]["width"]), Rules.MAX_WIDTH, "changing shape does not lock the frontage")
	t.ok(plan[0]["rewidth"], "and it is ordered like any other")


func test_the_line_runs_between_where_you_pressed_and_released(t) -> void:
	var plan := BattleView.plan_order(_pose(3), _all(3), Vector2(-600, 200), Vector2(600, 200))
	for row: Dictionary in plan:
		t.near(row["target"].y, 200.0, 1.0, "everybody stands on the line you drew")
	# Not "it reaches the far end": three spears cap at MAX_WIDTH long before 1200 units,
	# because a regiment has a maximum frontage. What it must do is fill the line with MEN
	# rather than with air, and stay centred on the drag while it cannot reach further.
	t.ok(_frontage(plan) > 800.0,
		"and fills it with frontage, not gaps (%.0f units of men)" % _frontage(plan))
	var middle := 0.0
	for row: Dictionary in plan:
		middle += row["target"].x / float(plan.size())
	t.near(middle, 0.0, 1.0, "centred between press and release")


func test_the_facing_is_perpendicular_to_the_drag(t) -> void:
	# Drag left to right, they face away from you.
	var plan := BattleView.plan_order(_pose(3), _all(3), Vector2(-400, 0), Vector2(400, 0))
	for row: Dictionary in plan:
		t.near(row["face"], -PI / 2.0, 0.0001, "square to the line, not along it")


func test_a_short_drag_is_still_a_click(t) -> void:
	var pose := _pose(3)
	var plan := BattleView.plan_order(pose, _all(3), Vector2(900, 0), Vector2(903, 0))
	for row: Dictionary in plan:
		var want: float = (row["target"] - pose[row["id"]]["pos"]).angle()
		t.near(row["face"], want, 0.0001, "it turns toward where it is going")


func test_a_line_is_never_squeezed_into_itself(t) -> void:
	# Ask for a line shorter than the men can physically stand in and they stand
	# shoulder to shoulder rather than inside one another.
	var plan := BattleView.plan_order(_pose(4), _all(4), Vector2(0, 0), Vector2(40, 0))
	_assert_nobody_overlaps(t, plan)


# --- the three quieter faults ---------------------------------------------

func test_a_mixed_selection_does_not_stand_inside_itself(t) -> void:
	# Slots were spaced by each regiment's OWN half-width, so a 16-wide archer beside a
	# 10-wide cavalry got 42 units of room where it needed 84.
	# A right-CLICK, not a drag: a drag hands both regiments the same share of the line and
	# so the same frontage, and there would be no mixed selection left to test.
	var pose := _pose(2)
	pose[0]["width"] = 24
	pose[1]["width"] = 6
	var plan := BattleView.plan_order(pose, _all(2), Vector2(0, 0), Vector2(10, 0))
	t.eq(int(plan[0]["width"]), int(pose[plan[0]["id"]]["width"]), "a click reshapes nobody")
	_assert_nobody_overlaps(t, plan)


func test_they_keep_their_left_to_right_order(t) -> void:
	# Slots used to be handed out in id order, so box-selecting a line whose ids ran
	# right to left sent every regiment to the opposite end and they crossed on the way.
	var pose := _pose(3)
	pose[0]["pos"] = Vector2(0, 400.0)         # id 0 is on the RIGHT
	pose[1]["pos"] = Vector2(0, 0.0)
	pose[2]["pos"] = Vector2(0, -400.0)        # id 2 is on the LEFT
	var plan := BattleView.plan_order(pose, _all(3), Vector2(0, -500), Vector2(0, 500))
	var place := {}
	for row: Dictionary in plan:
		place[row["id"]] = row["target"].y
	t.ok(place[2] < place[1] and place[1] < place[0],
		"the one on the left stays on the left, so nobody marches through anybody")


func test_a_worn_regiment_keeps_its_real_footprint(t) -> void:
	# half_width used to come from current strength while half_depth and the sim's own
	# reach() came from max_strength, so the "honest" ghost lied about width for any
	# regiment that had taken losses.
	var pose := _pose(1)
	pose[0]["strength"] = 30
	var plan := BattleView.plan_order(pose, _all(1), Vector2.ZERO, Vector2(400, 0))
	var w: int = plan[0]["width"]
	t.near(plan[0]["half_width"], Formation.frontage(120, w, 1.0), 0.0001,
		"the width the sim will measure against, not the width of who is left")
	t.ok(absf(Formation.frontage(30, w, 1.0) - float(plan[0]["half_width"])) > 1.0,
		"and the two really are different numbers, or this proves nothing")


# --- the ghost is the footprint -------------------------------------------

func test_the_ghost_is_the_regiments_real_footprint(t) -> void:
	# The footprint of the shape it is being ORDERED into, which is the whole reason the
	# preview exists: frontage decides the fight and should not stay invisible until after
	# you have committed to it.
	var plan := BattleView.plan_order(_pose(1, 12), _all(1), Vector2.ZERO, Vector2(400, 0))
	var w: int = plan[0]["width"]
	t.near(plan[0]["half_width"], Formation.frontage(120, w, 1.0), 0.0001)
	t.near(plan[0]["half_depth"], Formation.half_depth(120, w, 1.0), 0.0001)
	t.ok(plan[0]["half_depth"] < Formation.half_depth(120, 12, 1.0),
		"a drag this wide leaves it shallower than it was")


func test_a_wider_regiment_takes_more_room(t) -> void:
	# The reason the preview matters: frontage is what decides the fight, and until now
	# it was a number in a HUD line.
	# Again a click: the point is that the frontage a regiment ALREADY has decides how much
	# room it is given, which a drag would overwrite before the packing ever saw it.
	var narrow := BattleView.plan_order(_pose(2, 6), _all(2), Vector2.ZERO, Vector2(10, 0))
	var wide := BattleView.plan_order(_pose(2, 24), _all(2), Vector2.ZERO, Vector2(10, 0))
	t.ok(_span(wide) > _span(narrow), "a wider line needs more room (%.0f vs %.0f)" % [
		_span(wide), _span(narrow)])


func test_loose_order_draws_wider_than_close_order(t) -> void:
	var close := BattleView.plan_order(_pose(1, 12, 1.0), _all(1), Vector2.ZERO, Vector2(400, 0))
	var loose := BattleView.plan_order(_pose(1, 12, 1.9), _all(1), Vector2.ZERO, Vector2(400, 0))
	t.ok(loose[0]["half_width"] > close[0]["half_width"],
		"the formation's spacing shows in the ghost too")
	# And it fills the same drag with FEWER men, because the drag is a length of ground and
	# loose order needs more of it per file. Both answers are right at once.
	t.ok(int(loose[0]["width"]) < int(close[0]["width"]),
		"loose order covers the same line with fewer files (%d against %d)" % [
			int(loose[0]["width"]), int(close[0]["width"])])


func test_the_plan_remembers_where_each_regiment_started(t) -> void:
	# The lead line joining a regiment to its destination is drawn from this.
	var pose := _pose(3)
	for row: Dictionary in BattleView.plan_order(pose, _all(3), Vector2(600, 0), Vector2(800, 0)):
		t.eq(row["from"], pose[row["id"]]["pos"])


## No two ghosts may overlap: every pair must be at least their two half-widths apart.
func _assert_nobody_overlaps(t, plan: Array) -> void:
	for i in plan.size():
		for j in range(i + 1, plan.size()):
			var a: Dictionary = plan[i]
			var b: Dictionary = plan[j]
			var apart: float = a["target"].distance_to(b["target"])
			var want: float = float(a["half_width"]) + float(b["half_width"])
			t.ok(apart >= want - 0.01,
				"%.0f apart, needs %.0f -- they are ordered to stand inside each other" % [
					apart, want])


# --- the path arrow -----------------------------------------------------------

func _marcher(owner: int, state := Regiment.State.MOVING, path := PackedVector2Array([Vector2(100, 0)])) -> Dictionary:
	return {"owner": owner, "state": state, "path": path, "pos": Vector2.ZERO}


func test_a_selected_marching_regiment_shows_its_path(t) -> void:
	var pose := {1: _marcher(7), 2: _marcher(7)}
	t.eq(BattleView.paths_to_draw(pose, PackedInt32Array([1]), 7, false), [1],
		"the selected one, and not its unselected neighbour")


func test_space_shows_every_one_of_yours(t) -> void:
	var pose := {1: _marcher(7), 2: _marcher(7), 3: _marcher(8)}
	t.eq(BattleView.paths_to_draw(pose, PackedInt32Array(), 7, true), [1, 2])


func test_an_enemy_path_is_never_drawn(t) -> void:
	# The wire never sends one; the rule does not rely on that.
	var pose := {3: _marcher(8)}
	t.eq(BattleView.paths_to_draw(pose, PackedInt32Array([3]), 7, true), [],
		"not selected, not with Space held")


func test_only_a_march_with_a_plan_is_drawn(t) -> void:
	var pose := {1: _marcher(7, Regiment.State.IDLE), 2: _marcher(7, Regiment.State.MOVING, PackedVector2Array()),
		3: _marcher(7, Regiment.State.FIGHTING)}
	t.eq(BattleView.paths_to_draw(pose, PackedInt32Array([1, 2, 3]), 7, true), [],
		"standing, planless and fighting regiments show nothing")
