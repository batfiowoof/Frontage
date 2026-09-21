extends RefCounted

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _ticks(n: int) -> float:
	return n * Rules.TICK_DELTA


func test_ids_are_unique_and_sorted(t) -> void:
	var bs = BattleState.new()
	for i in 5:
		bs.add(1, &"spear", Vector2(i * 100, 0))
	t.eq(bs.regiments.size(), 5)
	t.eq(bs.sorted_ids(), [1, 2, 3, 4, 5], "iteration order must not depend on insertion")


func test_a_regiment_marches_to_its_target_and_stops(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(Rules.MOVE_SPEED, 0), 0.0)
	for i in Rules.TICK_HZ * 6:
		bs.step()
	t.near(r.pos.x, Rules.MOVE_SPEED, 0.5, "it gets there")
	t.eq(r.state, Regiment.State.IDLE, "and stops there")
	t.near(r.pace, 0.0, 0.001, "with nothing left running")


## It used to be at full pace on the first tick of an order and still at full pace on the
## tick it arrived, where it snapped up to a stride onto its destination.
func test_a_regiment_builds_up_to_its_pace(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(100000, 0), 0.0)
	for i in Rules.TICK_HZ:
		bs.step()
	var first: float = r.pos.x
	for i in Rules.TICK_HZ:
		bs.step()
	var second: float = r.pos.x - first
	t.ok(second > first * 1.5,
		"the second second covers much more ground than the first (%.0f then %.0f)" % [
			first, second])
	t.ok(first < Rules.MOVE_SPEED * 0.8, "nobody is at marching pace from a standing start")

	for i in Rules.TICK_HZ * 4:
		bs.step()
	var settled: float = r.pos.x
	for i in Rules.TICK_HZ:
		bs.step()
	# Close to its pace, but never quite on it: marching tires a regiment now, so a long
	# march is always being fought by its own legs(). That gap IS the new system.
	var held: float = r.pos.x - settled
	t.ok(held > Rules.MOVE_SPEED * 0.9 and held <= Rules.MOVE_SPEED,
		"it reaches its pace and holds it, a shade under on tired legs (%.1f of %.0f)" % [
			held, Rules.MOVE_SPEED])


## The regiment brakes into its destination instead of stopping dead on it. The arrival
## used to be `r.pos = r.target` from full speed, a jump of up to a whole stride.
func test_a_regiment_brakes_into_its_destination(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(400, 0), 0.0)
	var last := 0.0
	var jump := 0.0
	while r.state == Regiment.State.MOVING and bs.tick < Rules.TICK_HZ * 30:
		var was: float = r.pos.x
		bs.step()
		last = r.pos.x - was
		jump = maxf(jump, last)
	t.eq(r.state, Regiment.State.IDLE, "it arrived")
	var stride := Rules.MOVE_SPEED * Rules.TICK_DELTA
	t.ok(last < stride * 0.5,
		"the last step is a shuffle, not a stride (%.2f against %.2f)" % [last, stride])


## The bug this whole change is for. A regiment used to turn to face wherever it was
## walking, so ordering one to a point BEHIND it swung the entire block round -- the end
## files sweeping 209 units in a second, three times marching pace. Movement never needed
## a front: it walks straight at the target whatever way it faces.
func test_a_regiment_keeps_the_facing_it_was_given(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)      # facing +X
	r.order_move(Vector2(0, 1000), 0.0)                 # marched +Y, still facing +X
	for i in Rules.TICK_HZ * 4:
		bs.step()
	t.near(r.facing, 0.0, 0.05, "it holds the facing it was ordered and walks sideways")
	t.ok(r.pos.y > 50.0, "and it really did go (%.0f units)" % r.pos.y)


func test_marching_backwards_does_not_turn_it_round(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)      # facing +X
	r.order_move(Vector2(-600, 0), 0.0)                 # ordered straight backwards
	for i in Rules.TICK_HZ * 4:
		bs.step()
	t.near(r.facing, 0.0, 0.05, "it backs up rather than spinning to face the way it goes")
	t.ok(r.pos.x < -50.0, "and it really did back up (%.0f units)" % r.pos.x)


func test_routers_outrun_marchers_and_do_not_stop(t) -> void:
	var bs = BattleState.new()
	# Apart, not on top of one another: at a standing start they would be in contact for
	# long enough to be dragged into a melee before either of them got moving.
	var marcher = bs.add(1, &"spear", Vector2(0, -900), 0.0)
	var router = bs.add(2, &"spear", Vector2(0, 900), PI)   # facing -X, so it runs +X
	marcher.order_move(Vector2(100000, -900), 0.0)
	router.shock(Rules.MORALE_MAX)
	for i in Rules.TICK_HZ * 4:
		bs.step()
	t.ok(router.pos.x > marcher.pos.x, "routers run faster than men march (%.0f vs %.0f)" % [
		router.pos.x, marcher.pos.x])
	t.eq(router.state, Regiment.State.ROUTING, "and they do not stop when they arrive")


## This used to read `t.near(r.morale, 50.0 + Rules.MORALE_RECOVERY, 0.01)` -- written
## against the constant, so changing 4.0 to 0.8 still passed and the recovery rate was in
## practice untested. What matters is not the number, it is that a regiment has to stand
## there for a WHILE before it gets anything back.
func test_a_regiment_has_to_stand_a_while_before_morale_comes_back(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO)
	# A friend at its shoulder, or ALONE_SHOCK quietly eats the thing being measured: a
	# regiment standing on its own loses heart, which is a different test.
	bs.add(1, &"spear", Vector2(0, Rules.SHOULDER_RADIUS * 0.5))
	r.morale = 50.0
	r.rally_wait = Rules.RALLY_DELAY
	for i in int((Rules.RALLY_DELAY - 1.0) * Rules.TICK_HZ):
		bs.step()
	t.near(r.morale, 50.0, 0.001, "nothing at all while it is still catching its breath")

	for i in int(10.0 * Rules.TICK_HZ):
		bs.step()
	t.ok(r.morale > 50.0, "and then it starts to come back (%.1f)" % r.morale)
	t.ok(r.morale < Rules.MORALE_MAX, "gradually, not all at once")


func test_engaged_regiments_do_not_recover(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.add(2, &"spear", Vector2(20, 0), PI)          # a real enemy, in reach
	r.morale = 50.0
	for i in Rules.TICK_HZ:
		bs.step()
	t.eq(r.state, Regiment.State.FIGHTING, "contact is what makes a regiment engaged")
	t.ok(r.morale < 50.0, "you cannot catch your breath mid-melee")


func test_battle_is_over_when_one_side_will_not_stand(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2.ZERO)
	var b = bs.add(2, &"spear", Vector2(100, 0))
	t.ok(not bs.is_over(), "two sides standing")
	t.eq(bs.winner(), 0)

	b.shock(Rules.MORALE_MAX)
	t.ok(bs.is_over(), "a routing side has lost the field")
	t.eq(bs.winner(), 1)

	a.take_casualties(a.strength)
	t.ok(bs.is_over())
	t.eq(bs.winner(), 0, "nobody left standing is not a victory")
