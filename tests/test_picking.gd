extends RefCounted
## What is under the mouse.
##
## Picking was one circle of PICK_RADIUS (46 world units) around the sim's centre point,
## and a 20-file regiment stands 66.5 units to its shoulder -- so **the wings of your own
## line were not clickable at all**, and a 40-file line offered only the middle third of
## itself. At the zoomed-out end that circle was 23 pixels across.
##
## `pick_at` is static and takes a pose, so it tests headless the way `plan_order` does.
## Nothing covered picking at all before this.

const BattleView := preload("res://view/battle/battle_view.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")

const MINE := 1
const THEIRS := 2


func _pose(id: int, owner: int, at: Vector2, width := 20, facing := 0.0,
		state := Regiment.State.IDLE, routs := 0) -> Dictionary:
	return {id: {
		"pos": at, "facing": facing, "owner": owner, "kind": &"spear",
		"strength": 120, "max_strength": 120, "morale": 100.0, "stamina": 1.0,
		"width": width, "state": state, "formation": &"line", "reforming": 0.0,
		"spacing": 1.0, "ammo": 0, "routs": routs,
	}}


func test_the_wing_of_a_wide_line_is_clickable(t) -> void:
	# The complaint, as a number. A 40-file regiment is 273 units across; the old circle
	# reached 46 either side of its middle.
	var pose := _pose(1, MINE, Vector2.ZERO, 40)
	var shoulder := Formation.frontage(120, 40, 1.0)
	t.ok(shoulder > BattleView.PICK_RADIUS,
		"its shoulder is further out than the old pick radius (%.0f against %.0f)" % [
			shoulder, BattleView.PICK_RADIUS])

	for reach in [0.3, 0.7, 0.95]:
		var at := Vector2(0, shoulder * reach)
		t.eq(BattleView.pick_at(pose, at, MINE, true, 0.75), 1,
			"%.0f%% of the way out along the line still picks it" % (reach * 100.0))


func test_a_click_well_outside_the_block_picks_nothing(t) -> void:
	var pose := _pose(1, MINE, Vector2.ZERO, 20)
	var far := Vector2(0, Formation.frontage(120, 20, 1.0) + BattleView.PICK_RADIUS + 200.0)
	t.eq(BattleView.pick_at(pose, far, MINE, true, 0.75), -1, "empty ground is empty")


func test_the_banner_is_a_click_target(t) -> void:
	# The point of it: a banner holds its size on screen, so it stays hittable exactly
	# where the regiment's own footprint has shrunk to nothing.
	var pose := _pose(1, MINE, Vector2.ZERO, 20)
	var rect := BattleView.banner_rect(pose[1], Vector2.ZERO, 0.25)
	t.ok(rect.size.x > 0.0, "a steady regiment has a banner")
	t.eq(BattleView.pick_at(pose, rect.get_center(), MINE, true, 0.25), 1,
		"and clicking it picks the regiment")


func test_a_banner_holds_its_size_on_screen(t) -> void:
	var pose := _pose(1, MINE, Vector2.ZERO, 20)
	for zoom in [0.25, 0.75, 3.0]:
		var rect := BattleView.banner_rect(pose[1], Vector2.ZERO, zoom)
		t.near(rect.size.x * zoom, BattleView.BANNER_W, 0.001,
			"the same %d pixels at zoom %.2f" % [int(BattleView.BANNER_W), zoom])


func test_a_shattered_regiment_has_no_banner(t) -> void:
	# Total War takes the flag away entirely, which is the clearest way to say that this
	# one is never coming back.
	var pose := _pose(1, MINE, Vector2.ZERO, 20, 0.0,
		Regiment.State.ROUTING, Rules.ROUTS_BEFORE_SHATTERED)
	t.near(BattleView.banner_rect(pose[1], Vector2.ZERO, 0.75).size.x, 0.0, 0.001,
		"no flag above a shattered regiment")
	# ...and its block is still clickable, so you can see what it is doing.
	t.eq(BattleView.pick_at(pose, Vector2.ZERO, MINE, true, 0.75), 1,
		"but the men are still there to click")


func test_an_enemy_is_not_picked_as_a_friend(t) -> void:
	var pose := _pose(1, THEIRS, Vector2.ZERO, 20)
	t.eq(BattleView.pick_at(pose, Vector2.ZERO, MINE, true, 0.75), -1, "not one of mine")
	t.eq(BattleView.pick_at(pose, Vector2.ZERO, MINE, false, 0.75), 1, "but it is one of theirs")


func test_the_nearer_block_wins_when_two_overlap(t) -> void:
	var pose := _pose(1, MINE, Vector2.ZERO, 20)
	pose.merge(_pose(2, MINE, Vector2(0, 40), 20))
	# Dead centre of the second one: it is deepest inside that block, so it wins.
	t.eq(BattleView.pick_at(pose, Vector2(0, 40), MINE, true, 0.75), 2,
		"the one you are standing in the middle of")


func test_a_regiment_is_picked_where_it_is_DRAWN(t) -> void:
	# Drawing used the mean of the living men, picking used the sim's centre point, so at
	# half strength the block you could see sat forward of the circle you had to hit.
	var pose := _pose(1, MINE, Vector2.ZERO, 20)
	var drawn := Vector2(60, 0)
	var centres := {1: drawn}
	t.eq(BattleView.pick_at(pose, drawn, MINE, true, 0.75, centres), 1,
		"clicking the men picks the regiment")
