extends RefCounted

const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _spearmen():
	return Regiment.make(1, 100, &"spear", Vector2.ZERO, 0.0)


func test_make_reads_its_kind(t) -> void:
	var r = _spearmen()
	t.eq(r.strength, Rules.KINDS[&"spear"]["strength"])
	t.eq(r.strength, r.max_strength)
	t.eq(r.width, Rules.KINDS[&"spear"]["width"])
	t.near(r.morale, Rules.MORALE_MAX)
	t.eq(r.state, Regiment.State.IDLE)


func test_move_order_switches_to_moving(t) -> void:
	var r = _spearmen()
	r.engaged_with = 7
	t.ok(r.order_move(Vector2(100, 0), 1.5), "idle regiment accepts orders")
	t.eq(r.state, Regiment.State.MOVING)
	t.eq(r.target, Vector2(100, 0))
	t.eq(r.engaged_with, -1, "marching away breaks the engagement")


func test_routing_and_dead_regiments_ignore_orders(t) -> void:
	var r = _spearmen()
	r.shock(Rules.MORALE_MAX)                       # straight to breaking point
	t.eq(r.state, Regiment.State.ROUTING)
	t.ok(not r.order_move(Vector2(9, 9), 0.0), "you cannot steer a rout")
	t.ok(r.target != Vector2(9, 9))

	var d = _spearmen()
	d.take_casualties(d.strength)
	t.eq(d.state, Regiment.State.DEAD)
	t.ok(not d.order_move(Vector2(9, 9), 0.0), "the dead take no orders")


func test_casualties_clamp_and_kill(t) -> void:
	var r = _spearmen()
	t.eq(r.take_casualties(30), 30)
	t.eq(r.strength, 90)
	t.near(r.fraction(), 0.75)
	t.eq(r.take_casualties(1000), 90, "cannot lose more men than it has")
	t.eq(r.strength, 0)
	t.eq(r.state, Regiment.State.DEAD)
	t.eq(r.take_casualties(10), 0, "the dead take no further casualties")


func test_casualties_erode_morale_into_a_rout(t) -> void:
	var r = _spearmen()
	var breaking_fraction := (Rules.MORALE_MAX - Rules.MORALE_ROUT_THRESHOLD) / Rules.MORALE_DRAIN_PER_FRACTION
	t.ok(breaking_fraction < 0.9, "a regiment must break before it is wiped out, or morale is decoration")
	r.take_casualties(int(ceil(breaking_fraction * r.max_strength)) + 1)
	t.ok(r.strength > 0, "the test is about morale, not annihilation")
	t.eq(r.state, Regiment.State.ROUTING, "bleeding men breaks a regiment before it dies")


func test_routers_run_away_from_their_facing(t) -> void:
	var r = _spearmen()
	r.facing = 0.0                                   # facing +X
	r.shock(Rules.MORALE_MAX)
	t.ok(r.target.x < r.pos.x, "it runs the other way")


func test_rally_needs_more_than_the_rout_threshold(t) -> void:
	var r = _spearmen()
	r.shock(Rules.MORALE_MAX)
	r.recover(Rules.MORALE_ROUT_THRESHOLD + 1.0)
	t.eq(r.state, Regiment.State.ROUTING, "a hair above breaking is not rallied")
	r.recover(Rules.MORALE_RALLY_THRESHOLD)
	t.eq(r.state, Regiment.State.IDLE)
	t.ok(r.morale <= Rules.MORALE_MAX, "morale never exceeds the cap")
