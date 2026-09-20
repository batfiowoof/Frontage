extends RefCounted
## The battle sim's combat resolution: contact, attrition, flanking, morale, rout.
## This is where the game lives or dies, so it gets checked before it gets drawn.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _facing_each_other(gap := 30.0) -> Array:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-gap * 0.5, 0), 0.0)       # faces +X, at the enemy
	var b = bs.add(2, &"spear", Vector2(gap * 0.5, 0), PI)         # faces -X, at the enemy
	return [bs, a, b]


func _run(bs, ticks: int) -> void:
	for i in ticks:
		bs.step()


# --- contact --------------------------------------------------------------

func test_regiments_out_of_reach_do_not_fight(t) -> void:
	var s := _facing_each_other(Rules.CONTACT_RANGE * 4.0)
	_run(s[0], Rules.TICK_HZ)
	t.eq(s[1].strength, s[1].max_strength, "nobody within reach, nobody hurt")
	t.eq(s[1].state, Regiment.State.IDLE)


func test_contact_stops_a_march_and_starts_a_fight(t) -> void:
	var s := _facing_each_other()
	s[1].order_move(Vector2(1000, 0), 0.0)
	_run(s[0], 2)
	t.eq(s[1].state, Regiment.State.FIGHTING, "you do not march through an enemy")
	t.eq(s[1].engaged_with, s[2].id)


func test_a_player_can_always_order_a_disengage(t) -> void:
	var s := _facing_each_other()
	_run(s[0], 2)
	t.eq(s[1].state, Regiment.State.FIGHTING)
	s[1].order_move(Vector2(-2000, 0), PI)
	t.eq(s[1].state, Regiment.State.MOVING, "a fight is not a trap")
	t.eq(s[1].engaged_with, -1)


func test_friends_do_not_fight_each_other(t) -> void:
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2(-10, 0), 0.0)
	bs.add(1, &"spear", Vector2(10, 0), PI)
	_run(bs, Rules.TICK_HZ)
	for id in bs.sorted_ids():
		t.eq(bs.regiments[id].strength, bs.regiments[id].max_strength)


# --- attrition ------------------------------------------------------------

func test_an_even_fight_bleeds_both_sides_equally(t) -> void:
	var s := _facing_each_other()
	_run(s[0], Rules.TICK_HZ * 2)
	t.ok(s[1].strength < s[1].max_strength, "somebody died")
	t.eq(s[1].strength, s[2].strength, "a symmetric fight must be symmetric")
	t.near(s[1].morale, s[2].morale, 0.001)


func test_casualties_are_not_decided_by_regiment_id(t) -> void:
	# Same fight, ids swapped. If resolution leaked iteration order, the lower id
	# would win by swinging first, and no player would ever be able to see why.
	var bs = BattleState.new()
	bs.add(2, &"spear", Vector2(15, 0), PI)
	bs.add(1, &"spear", Vector2(-15, 0), 0.0)
	_run(bs, Rules.TICK_HZ * 2)
	t.eq(bs.regiments[1].strength, bs.regiments[2].strength)


func test_a_weakened_regiment_kills_more_slowly(t) -> void:
	var strong := _facing_each_other()
	_run(strong[0], Rules.TICK_HZ)
	var losses_to_full: int = strong[1].max_strength - strong[1].strength

	var weak := _facing_each_other()
	weak[2].strength = int(weak[2].max_strength * 0.25)
	_run(weak[0], Rules.TICK_HZ)
	var losses_to_quarter: int = weak[1].max_strength - weak[1].strength
	t.ok(losses_to_quarter < losses_to_full,
		"a quarter-strength regiment should not hit as hard (%d vs %d)" % [losses_to_quarter, losses_to_full])


# --- the flank ------------------------------------------------------------

func test_exposure_is_measured_from_the_defenders_facing(t) -> void:
	var bs = BattleState.new()
	var d = bs.add(1, &"spear", Vector2.ZERO, 0.0)        # facing +X
	var front = bs.add(2, &"spear", Vector2(100, 0), PI)
	var side = bs.add(2, &"spear", Vector2(0, 100), -PI / 2)
	var back = bs.add(2, &"spear", Vector2(-100, 0), 0.0)
	t.eq(BattleState.exposure_of(d, front), BattleState.Exposure.FRONT)
	t.eq(BattleState.exposure_of(d, side), BattleState.Exposure.FLANK)
	t.eq(BattleState.exposure_of(d, back), BattleState.Exposure.REAR)


func test_being_hit_in_the_rear_hurts_more_than_being_hit_in_the_front(t) -> void:
	var front := _facing_each_other()
	_run(front[0], Rules.TICK_HZ)
	var frontal_losses: int = front[1].max_strength - front[1].strength
	var frontal_morale: float = front[1].morale

	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)              # facing +X
	bs.add(2, &"spear", Vector2(-25, 0), 0.0)                        # hitting its back
	_run(bs, Rules.TICK_HZ)
	var rear_losses: int = victim.max_strength - victim.strength

	t.ok(rear_losses > frontal_losses,
		"a rear attack must cost more men (%d vs %d)" % [rear_losses, frontal_losses])
	t.ok(victim.morale < frontal_morale,
		"and must cost more nerve (%.1f vs %.1f)" % [victim.morale, frontal_morale])


func test_a_flanked_regiment_breaks_before_a_fronted_one(t) -> void:
	var front := _facing_each_other()
	var flanked = BattleState.new()
	var victim = flanked.add(1, &"spear", Vector2.ZERO, 0.0)
	flanked.add(2, &"spear", Vector2(0, -25), PI / 2)                # from the side

	var front_broke := -1
	var flank_broke := -1
	for i in Rules.TICK_HZ * 30:
		front[0].step()
		flanked.step()
		if front_broke < 0 and front[1].state == Regiment.State.ROUTING:
			front_broke = i
		if flank_broke < 0 and victim.state == Regiment.State.ROUTING:
			flank_broke = i
		if front_broke >= 0 and flank_broke >= 0:
			break
	t.ok(flank_broke >= 0, "a flanked regiment must eventually break")
	t.ok(front_broke < 0 or flank_broke < front_broke,
		"and must break sooner than one fighting to its front (%d vs %d)" % [flank_broke, front_broke])


func test_a_regiment_wheels_to_face_its_attacker(t) -> void:
	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)              # facing +X
	bs.add(2, &"spear", Vector2(0, -25), PI / 2)                     # attacking from -Y
	_run(bs, 2)
	var before: float = absf(angle_difference(victim.facing, -PI / 2))
	_run(bs, Rules.TICK_HZ)
	var after: float = absf(angle_difference(victim.facing, -PI / 2))
	t.ok(after < before, "it should be turning to meet the threat, not standing still")


# --- routing --------------------------------------------------------------

func test_a_broken_regiment_stops_fighting_back(t) -> void:
	var s := _facing_each_other()
	s[2].shock(Rules.MORALE_MAX)                     # side 2 breaks immediately
	t.eq(s[2].state, Regiment.State.ROUTING)
	var before: int = s[1].strength
	_run(s[0], Rules.TICK_HZ)
	t.eq(s[1].strength, before, "a routing regiment does no damage")


func test_running_a_router_down_is_faster_than_a_fair_fight(t) -> void:
	var fair := _facing_each_other()
	_run(fair[0], Rules.TICK_HZ)
	var fair_losses: int = fair[2].max_strength - fair[2].strength

	var chase := _facing_each_other()
	chase[2].shock(Rules.MORALE_MAX)
	chase[2].target = chase[2].pos                   # cornered, so contact is kept
	var before: int = chase[2].strength
	for i in Rules.TICK_HZ:
		chase[2].pos = Vector2(15, 0)                # hold it in contact
		chase[0].step()
	var chased_losses: int = before - chase[2].strength
	t.ok(chased_losses > fair_losses,
		"a broken regiment should be cut down faster (%d vs %d)" % [chased_losses, fair_losses])


func test_routers_do_not_recover_while_being_chased(t) -> void:
	var s := _facing_each_other()
	s[2].shock(Rules.MORALE_MAX)
	_run(s[0], 4)
	t.eq(s[2].state, Regiment.State.ROUTING, "no rallying with a spear in your back")


# --- the end --------------------------------------------------------------

func test_a_battle_ends_when_one_side_will_not_stand(t) -> void:
	var s := _facing_each_other()
	t.ok(not s[0].is_over())
	for i in Rules.TICK_HZ * 60:
		s[0].step()
		if s[0].is_over():
			break
	t.ok(s[0].is_over(), "an even fight still has to end within a minute")
	# A perfectly mirrored fight breaks on the same tick for both sides, and a mutual
	# collapse is the honest answer -- there is no tie-break in the rules and inventing
	# one here would only hide it.
	t.eq(s[0].winner(), 0, "nobody holds the field after a mutual collapse")


func test_the_stronger_side_carries_the_field(t) -> void:
	var bs = BattleState.new()
	for i in 3:
		bs.add(1, &"spear", Vector2(-20, (i - 1) * 18), 0.0)
	bs.add(2, &"spear", Vector2(20, 0), PI)
	for i in Rules.TICK_HZ * 60:
		bs.step()
		if bs.is_over():
			break
	t.ok(bs.is_over(), "three against one has to finish")
	t.eq(bs.winner(), 1, "and the three have to be the ones left standing")


func test_a_whole_battle_is_reproducible(t) -> void:
	# Same setup, same ticks, same outcome: no randomness has crept into the sim, so
	# a desync or a surprising result can always be replayed.
	var first := _facing_each_other()
	var second := _facing_each_other()
	_run(first[0], Rules.TICK_HZ * 10)
	_run(second[0], Rules.TICK_HZ * 10)
	for id in first[0].sorted_ids():
		t.eq(first[0].regiments[id].strength, second[0].regiments[id].strength, "strength of %d" % id)
		t.eq(first[0].regiments[id].pos, second[0].regiments[id].pos, "position of %d" % id)
		t.near(first[0].regiments[id].morale, second[0].regiments[id].morale, 0.0001)
