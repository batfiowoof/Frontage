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
	r.order_move(Vector2(Rules.MOVE_SPEED, 0), 0.0)     # exactly one second away
	for i in Rules.TICK_HZ + 1:
		bs.step()
	t.near(r.pos.x, Rules.MOVE_SPEED, 1.0, "arrives in about a second")
	t.eq(r.state, Regiment.State.IDLE, "and stops there")
	t.eq(bs.tick, Rules.TICK_HZ + 1)


func test_movement_speed_is_frame_rate_independent(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(100000, 0), 0.0)
	for i in Rules.TICK_HZ:
		bs.step()
	t.near(r.pos.x, Rules.MOVE_SPEED, 0.01, "one second of ticks is one second of marching")


func test_a_regiment_turns_to_face_where_it_is_going(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)      # facing +X
	r.order_move(Vector2(0, 1000), 0.0)                 # ordered to march +Y
	for i in Rules.TICK_HZ:
		bs.step()
	t.near(r.facing, PI / 2.0, 0.05, "it should be facing its line of march")


func test_routers_outrun_marchers_and_do_not_stop(t) -> void:
	var bs = BattleState.new()
	var marcher = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var router = bs.add(2, &"spear", Vector2.ZERO, PI)  # facing -X, so it runs +X
	marcher.order_move(Vector2(100000, 0), 0.0)
	router.shock(Rules.MORALE_MAX)
	for i in Rules.TICK_HZ:
		bs.step()
	t.ok(router.pos.length() > marcher.pos.length(), "routers run faster than men march")
	t.eq(router.state, Regiment.State.ROUTING, "and they do not stop when they arrive")


func test_idle_regiments_recover_morale(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO)
	r.morale = 50.0
	for i in Rules.TICK_HZ:
		bs.step()
	t.near(r.morale, 50.0 + Rules.MORALE_RECOVERY, 0.01, "a second of standing about")


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
