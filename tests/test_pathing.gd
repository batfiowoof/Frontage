extends RefCounted
## Regiments find their way: round standing blocks, over bridges, through gates.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _run(bs, seconds: float) -> void:
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()


func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


func test_an_open_field_costs_no_search(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2(-400, 0), 0.0)
	r.order_move(Vector2(400, 200), 0.0)
	_run(bs, 30.0)
	t.eq(bs.nav().searches, 0, "a straight line is checked, never searched")
	t.ok(r.pos.distance_to(Vector2(400, 200)) < 2.0, "and walked (%s)" % r.pos)


func test_a_march_goes_round_a_standing_friend(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var friend = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(300, 0), 0.0)
	var worst := INF
	for i in Rules.TICK_HZ * 40:
		bs.step()
		worst = minf(worst, BattleState.gap_between(r, friend))
	t.ok(worst >= -1.0, "never through its own men (closest gap %.0f)" % worst)
	t.ok(r.pos.distance_to(Vector2(300, 0)) < 2.0, "and arrived (%s)" % r.pos)
	t.eq(friend.pos, Vector2.ZERO, "without shoving the one it went round")


func test_a_march_goes_round_a_standing_enemy_without_blundering_into_it(t) -> void:
	# Behind an enemy is somewhere you can be sent -- the flanking march -- and getting
	# there does not mean walking into him.
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	bs.add(2, &"spear", Vector2.ZERO, PI)
	r.order_move(Vector2(300, 0), PI)
	var fought := 0
	for i in Rules.TICK_HZ * 40:
		bs.step()
		if r.engaged_with >= 0:
			fought += 1
	t.eq(fought, 0, "not a tick in contact")
	t.ok(r.pos.distance_to(Vector2(300, 0)) < 2.0, "and behind him (%s)" % r.pos)


func test_the_plan_does_not_see_through_the_fog(t) -> void:
	# Its path is drawn on its owner's screen: bending round men in a wood nobody can see
	# would give them away. The march does not know they are there -- and walks into them.
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_WOOD, 0.0, 0.0, 150.0]]
	var r = bs.add(1, &"spear", Vector2(-400, 0), 0.0)
	bs.add(2, &"spear", Vector2.ZERO, PI)
	r.target = Vector2(400, 0)
	t.eq(bs.nav().plan(bs, r), PackedVector2Array([Vector2(400, 0)]), "straight on, into the trees")
	var seen = BattleState.new()
	var r2 = seen.add(1, &"spear", Vector2(-400, 0), 0.0)
	seen.add(2, &"spear", Vector2.ZERO, PI)
	r2.target = Vector2(400, 0)
	t.ok(seen.nav().plan(seen, r2).size() > 1, "the same man in the open is gone round")


func test_the_enemy_you_were_sent_at_is_not_in_the_way(t) -> void:
	# The mark is not an obstacle, or an attack order would walk round the man it names.
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var mark = bs.add(2, &"spear", Vector2.ZERO, PI)
	r.focus = mark.id
	_run(bs, 20.0)
	t.eq(r.engaged_with, mark.id, "it went and fought him")


func test_a_river_is_crossed_down_the_middle_of_its_bridge(t) -> void:
	var bs = BattleState.new()
	var river := [Rules.GROUND_RIVER, 0.0, 0.0, Rules.RIVER_HALF_WIDTH]
	var span := Vector2(BattleState.river_x(river, 300.0), 300.0)
	bs.features = [river, [Rules.GROUND_BRIDGE, span.x, span.y, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH]]
	var r = bs.add(1, &"spear", Vector2(-300, 0), -PI / 2.0)
	r.order_move(Vector2(300, 0), -PI / 2.0)
	var over := 0
	var worst := 0.0
	for i in Rules.TICK_HZ * 60:
		bs.step()
		# Whenever any part of its column could be over the water, it is on the centreline:
		# its outer files are then on the planks, and its rear is not left over the river
		# while its front turns for the target.
		var column: float = BattleState.column_reach(r)
		if absf(r.pos.x - BattleState.river_x(river, r.pos.y)) < Rules.RIVER_HALF_WIDTH + column:
			over += 1
			worst = maxf(worst, absf(r.pos.y - span.y))
	t.ok(over > 0, "it went over")
	t.ok(worst < 3.0, "down the middle of the planks (%.1f off it at worst)" % worst)
	t.ok(r.pos.distance_to(Vector2(300, 0)) < 2.0, "and on to the far bank (%s)" % r.pos)


func test_told_to_stand_on_a_bridge_it_stands_on_the_middle(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_RIVER, 0.0, 0.0, Rules.RIVER_HALF_WIDTH],
		[Rules.GROUND_BRIDGE, 0.0, 100.0, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH]]
	var r = bs.add(1, &"spear", Vector2(-300, 100), 0.0)
	bs.steer(r, Vector2(10, 130), 0.0)
	t.near(r.target.y, 100.0, 0.001, "snapped to the centreline")
	bs.steer(r, Vector2(10, 400), 0.0)
	t.near(r.target.y, 400.0, 0.001, "and only on a bridge")


func test_friends_standing_in_one_another_are_eased_apart(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var b = bs.add(1, &"spear", Vector2(0, 40), 0.0)
	t.ok(BattleState.gap_between(a, b) < 0.0, "they start inside one another")
	_run(bs, 10.0)
	t.ok(BattleState.gap_between(a, b) > -1.0, "and end beside one another (%.0f)" % BattleState.gap_between(a, b))


func test_friends_on_the_move_are_not_shoved_apart(t) -> void:
	# The push is for friends that have STOPPED inside one another. Two marching side by
	# side, overlapping a little, walk on; the push would have them fanning out.
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-200, 0), PI / 2.0)
	var b = bs.add(1, &"spear", Vector2(-200, 120), PI / 2.0)
	a.order_move(Vector2(200, 0), PI / 2.0)
	b.order_move(Vector2(200, 120), PI / 2.0)
	var strayed := 0.0
	for i in Rules.TICK_HZ * 20:
		bs.step()
		strayed = maxf(strayed, absf(a.pos.y))
	t.ok(strayed < 1.0, "nobody is pushed off his line (%.1f)" % strayed)
	t.ok(a.pos.distance_to(Vector2(200, 0)) < 2.0)


func test_the_same_field_plans_the_same_path(t) -> void:
	var paths := []
	for k in 2:
		var bs = BattleState.new()
		bs.lay_ground(4, 99, [4, 4, 1, 3, 1, 2], 3)
		bs.add(1, &"spear", Vector2(40, -30), 0.0)
		var r = bs.add(1, &"spear", Vector2(-500, 0), 0.0)
		r.target = Vector2(500, 150)
		paths.append(bs.nav().plan(bs, r))
	t.eq(paths[0], paths[1], "a replay walks exactly the recorded march")


func test_going_round_costs_a_search_a_second_at_most(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(300, 0), 0.0)
	_run(bs, 10.0)
	var searches: int = bs.nav().searches
	t.ok(searches >= 1, "it did have to search")
	t.ok(searches <= int(10.0 / Rules.REPLAN_SECONDS) + 1, "%d searches in 10s" % searches)
	print("  [feel] 10s round a standing block: %d searches" % searches)


# --- friends on the move give way -----------------------------------------------------

## The worst overlap between two regiments over `seconds`, stepping the battle.
func _closest(bs, a, b, seconds: float) -> float:
	var worst := INF
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()
		worst = minf(worst, BattleState.gap_between(a, b))
	return worst


func test_two_friends_marching_head_on_pass_without_merging(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var b = bs.add(1, &"spear", Vector2(300, 0), PI)
	a.order_move(Vector2(300, 0), 0.0)
	b.order_move(Vector2(-300, 0), PI)
	var worst := _closest(bs, a, b, 60.0)
	t.ok(worst > -3.0, "they never stood in one another (worst gap %.0f)" % worst)
	t.ok(a.pos.distance_to(Vector2(300, 0)) < 2.0, "the first held its line (%s)" % a.pos)
	t.ok(b.pos.distance_to(Vector2(-300, 0)) < 2.0, "the second went round and got there (%s)" % b.pos)


func test_marches_that_cross_do_not_merge(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var b = bs.add(1, &"spear", Vector2(0, -300), PI / 2.0)
	a.order_move(Vector2(300, 0), 0.0)
	b.order_move(Vector2(0, 300), PI / 2.0)
	var worst := _closest(bs, a, b, 60.0)
	t.ok(worst > -3.0, "worst gap %.0f" % worst)
	t.ok(a.pos.distance_to(Vector2(300, 0)) < 2.0 and b.pos.distance_to(Vector2(0, 300)) < 2.0,
		"both arrived (%s, %s)" % [a.pos, b.pos])


func test_two_columns_queue_for_one_bridge(t) -> void:
	# The case that started this: two marching over the same planks were one merged column.
	var bs = BattleState.new()
	var river := [Rules.GROUND_RIVER, 0.0, 0.0, Rules.RIVER_HALF_WIDTH]
	var span := Vector2(BattleState.river_x(river, 0.0), 0.0)
	bs.features = [river, [Rules.GROUND_BRIDGE, span.x, span.y, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH]]
	var first = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var second = bs.add(1, &"spear", Vector2(-450, 0), 0.0)
	first.order_move(Vector2(400, 0), 0.0)
	second.order_move(Vector2(300, 150), 0.0)
	var worst := _closest(bs, first, second, 60.0)
	t.ok(worst > -3.0, "one after the other (worst gap %.0f)" % worst)
	t.ok(second.pos.distance_to(Vector2(300, 150)) < 2.0, "and the second still got over (%s)" % second.pos)


func test_enemies_on_the_move_meet_rather_than_dodge(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var b = bs.add(2, &"spear", Vector2(300, 0), PI)
	a.order_move(Vector2(300, 0), 0.0)
	b.order_move(Vector2(-300, 0), PI)
	_run(bs, 20.0)
	t.eq(a.engaged_with, b.id, "stepping round an enemy is not a thing; meeting him is a fight")


func test_two_sent_to_one_spot_do_not_march_on_it_forever(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-300, 0), 0.0)
	var b = bs.add(1, &"spear", Vector2(-300, 200), 0.0)
	a.order_move(Vector2(200, 100), 0.0)
	b.order_move(Vector2(200, 100), 0.0)
	_run(bs, 40.0)
	t.eq(a.state, Regiment.State.IDLE)
	t.eq(b.state, Regiment.State.IDLE, "the second stops beside the first rather than pacing")
	t.ok(BattleState.gap_between(a, b) > -3.0, "beside, not inside")
