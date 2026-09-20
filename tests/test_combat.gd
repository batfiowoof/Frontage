extends RefCounted
## The battle sim's combat resolution: contact, attrition, flanking, morale, rout.
## This is where the game lives or dies, so it gets checked before it gets drawn.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")


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


func test_output_follows_frontage_not_headcount(t) -> void:
	# Under frontage-limited combat a half-strength regiment still fills its front
	# rank, so it hits just as hard. That is the point: attrition does not spiral.
	var full := _facing_each_other()
	_run(full[0], Rules.TICK_HZ * 20)
	var losses_to_full: int = full[1].max_strength - full[1].strength

	var half := _facing_each_other()
	half[2].strength = int(half[2].max_strength / 2)
	_run(half[0], Rules.TICK_HZ * 20)
	var losses_to_half: int = half[1].max_strength - half[1].strength
	t.eq(losses_to_half, losses_to_full, "half the men, same frontage, same output")


func test_a_regiment_worn_below_its_frontage_hits_less_hard(t) -> void:
	# Once there are fewer men than files, it cannot fill its own front any more.
	var full := _facing_each_other()
	_run(full[0], Rules.TICK_HZ * 20)
	var losses_to_full: int = full[1].max_strength - full[1].strength

	var remnant := _facing_each_other()
	remnant[2].strength = 3                       # width is 12
	_run(remnant[0], Rules.TICK_HZ * 20)
	var losses_to_remnant: int = remnant[1].max_strength - remnant[1].strength
	t.ok(losses_to_remnant < losses_to_full,
		"a 3-man remnant cannot hit like a full front (%d vs %d)" % [losses_to_remnant, losses_to_full])


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


## A victim pinned from the front and taken in the flank -- the actual manoeuvre.
## A lone regiment attacked from the side is allowed to turn and face it, and should.
func _pinned_and_flanked() -> Array:
	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)              # facing +X
	bs.add(2, &"spear", Vector2(30, 0), PI)                          # pins its front
	var flanker = bs.add(2, &"spear", Vector2(0, -30), PI / 2)       # hits its side
	return [bs, victim, flanker]


func test_a_flanked_regiment_breaks_before_a_fronted_one(t) -> void:
	var front := _facing_each_other()
	var flank := _pinned_and_flanked()

	var front_broke := -1
	var flank_broke := -1
	for i in Rules.TICK_HZ * 200:
		front[0].step()
		flank[0].step()
		if front_broke < 0 and front[1].state == Regiment.State.ROUTING:
			front_broke = i
		if flank_broke < 0 and flank[1].state == Regiment.State.ROUTING:
			flank_broke = i
		if front_broke >= 0 and flank_broke >= 0:
			break
	t.ok(flank_broke >= 0, "a pinned and flanked regiment must break")
	t.ok(front_broke < 0 or flank_broke < front_broke,
		"and far sooner than one fighting only to its front (%.0fs vs %.0fs)" % [
			flank_broke / float(Rules.TICK_HZ), front_broke / float(Rules.TICK_HZ)])
	print("  [feel] pinned+flanked breaks at %.0fs; frontal %s" % [
		flank_broke / float(Rules.TICK_HZ),
		"never in 200s" if front_broke < 0 else "%.0fs" % (front_broke / float(Rules.TICK_HZ))])


func test_a_pinned_regiment_keeps_facing_the_enemy_in_front(t) -> void:
	var s := _pinned_and_flanked()
	_run(s[0], Rules.TICK_HZ * 5)
	t.ok(absf(angle_difference(s[1].facing, 0.0)) < deg_to_rad(40.0),
		"it must not turn its back on the regiment pinning it")
	t.eq(BattleState.exposure_of(s[1], s[2]), BattleState.Exposure.FLANK,
		"so the flanker is still hitting a flank five seconds later")


func test_a_lone_regiment_may_turn_to_meet_a_flanker(t) -> void:
	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var flanker = bs.add(2, &"spear", Vector2(0, -30), PI / 2)
	for i in Rules.TICK_HZ * 40:
		bs.step()
	t.eq(BattleState.exposure_of(victim, flanker), BattleState.Exposure.FRONT,
		"with nothing pinning it, it should eventually face the threat")


func test_a_flank_kills_several_times_faster(t) -> void:
	var front := _facing_each_other()
	var flank := _pinned_and_flanked()
	# Measured over 8s: a flanked regiment BREAKS at around eleven, and after that it
	# is running rather than dying, so a longer window would measure its absence.
	_run(front[0], Rules.TICK_HZ * 8)
	_run(flank[0], Rules.TICK_HZ * 8)
	var frontal: int = front[1].max_strength - front[1].strength
	var flanked: int = flank[1].max_strength - flank[1].strength
	t.ok(flanked > frontal * 2,
		"a flank must be worth manoeuvring for (%d dead vs %d in 8s)" % [flanked, frontal])
	print("  [feel] 8s of fighting: %d lost frontally, %d lost pinned+flanked" % [frontal, flanked])


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

func test_an_even_fight_locks_instead_of_collapsing(t) -> void:
	# The headline change. Two identical regiments head-on used to wipe each other out
	# in under half a minute; now neither can break the other, and the fight has to be
	# decided by something the player does.
	var s := _facing_each_other()
	_run(s[0], Rules.TICK_HZ * 60)
	t.ok(not s[0].is_over(), "a head-on tie must still be a tie after a minute")
	t.ok(s[1].strength > s[1].max_strength / 2, "and both sides must still be armies")
	t.eq(s[1].strength, s[2].strength, "taking identical losses, as they should")
	print("  [feel] 60s head-on: %d/%d men left, morale %.0f, stamina %.2f" % [
		s[1].strength, s[1].max_strength, s[1].morale, s[1].stamina])


func test_an_even_fight_still_ends_eventually(t) -> void:
	# Locked is not the same as endless: attrition and exhaustion still get there.
	var s := _facing_each_other()
	var ticks := 0
	for i in int(Rules.TICK_HZ * Rules.BATTLE_TIME_LIMIT):
		s[0].step()
		ticks = i
		if s[0].is_over():
			break
	t.ok(s[0].is_over(), "it still has to finish inside the battle time limit")
	print("  [feel] head-on tie resolves itself at %.0fs" % (ticks / float(Rules.TICK_HZ)))


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


# --- depth, stamina and relief --------------------------------------------

func test_depth_buys_endurance(t) -> void:
	# Same frontage, three times the men. Both take casualties at the same rate, so
	# the deep one lasts about three times as long. This is what makes a formation
	# decision matter and what stops a battle being decided in ten seconds.
	var deep = BattleState.new()
	var deep_block = deep.add(1, &"spear", Vector2(-15, 0), 0.0)
	deep.add(2, &"spear", Vector2(15, 0), PI)

	var thin = BattleState.new()
	var thin_block = thin.add(1, &"spear", Vector2(-15, 0), 0.0)
	thin_block.strength = thin_block.max_strength / 3
	thin.add(2, &"spear", Vector2(15, 0), PI)

	t.eq(Formation.files_across(deep_block.strength, deep_block.width),
		Formation.files_across(thin_block.strength, thin_block.width), "same frontage")
	t.ok(Formation.ranks_deep(deep_block.strength, deep_block.width)
		> Formation.ranks_deep(thin_block.strength, thin_block.width), "different depth")

	var deep_broke := -1
	var thin_broke := -1
	for i in Rules.TICK_HZ * 300:
		deep.step()
		thin.step()
		if deep_broke < 0 and deep_block.state == Regiment.State.ROUTING:
			deep_broke = i
		if thin_broke < 0 and thin_block.state == Regiment.State.ROUTING:
			thin_broke = i
		if deep_broke >= 0 and thin_broke >= 0:
			break
	t.ok(thin_broke > 0, "the thin block should break inside 300s")
	t.ok(deep_broke < 0 or deep_broke > thin_broke * 1.8,
		"depth must buy real endurance (deep %.0fs vs thin %.0fs)" % [
			deep_broke / float(Rules.TICK_HZ), thin_broke / float(Rules.TICK_HZ)])
	print("  [feel] same frontage: 3-deep breaks at %.0fs, 10-deep at %s" % [
		thin_broke / float(Rules.TICK_HZ),
		"never in 300s" if deep_broke < 0 else "%.0fs" % (deep_broke / float(Rules.TICK_HZ))])


func test_stamina_drains_in_melee_and_recovers_at_rest(t) -> void:
	var s := _facing_each_other()
	t.near(s[1].stamina, 1.0)
	_run(s[0], Rules.TICK_HZ * 10)
	var tired: float = s[1].stamina
	t.ok(tired < 1.0, "ten seconds of melee should tell")
	t.near(tired, 1.0 - Rules.STAMINA_DRAIN_FIGHTING * 10.0, 0.02)

	s[1].order_move(Vector2(-3000, 0), PI)        # pull it out of the line
	_run(s[0], Rules.TICK_HZ * 4)
	t.eq(s[1].state, Regiment.State.MOVING, "a withdrawal order must survive contact")
	_run(s[0], Rules.TICK_HZ * 90)
	t.ok(s[1].stamina > tired, "and standing clear should give some of it back")


func test_an_exhausted_regiment_hits_softer(t) -> void:
	var fresh = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	var spent = Regiment.make(2, 1, &"spear", Vector2.ZERO)
	spent.stamina = 0.0
	t.near(fresh.readiness(), 1.0)
	t.near(spent.readiness(), Rules.TIRED_EFFECTIVENESS)
	t.ok(spent.readiness() < fresh.readiness() * 0.6, "exhaustion has to be worth avoiding")


func test_relieving_a_tired_unit_turns_a_stalled_fight(t) -> void:
	# The tie-breaker the whole milestone exists for: two lines locked, one side feeds
	# in a fresh regiment and pulls the spent one out, and the balance actually moves.
	var bs = BattleState.new()
	var tired = bs.add(1, &"spear", Vector2(-15, 0), 0.0)
	var enemy = bs.add(2, &"spear", Vector2(15, 0), PI)
	var reserve = bs.add(1, &"spear", Vector2(-400, 0), 0.0)
	_run(bs, Rules.TICK_HZ * 40)                  # both sides grind down

	t.ok(tired.stamina < 0.5, "the front rank should be spent by now")
	var enemy_before: int = enemy.strength

	tired.order_move(Vector2(-600, 0), 0.0)       # withdraw the spent regiment
	reserve.order_move(Vector2(15 - 25, 0), 0.0)  # feed the fresh one in
	_run(bs, Rules.TICK_HZ * 30)

	var enemy_losses: int = enemy_before - enemy.strength
	t.ok(reserve.stamina > enemy.stamina, "the relief arrives fresher than what it faces")
	t.ok(enemy_losses > 0, "and the fight goes on rather than stalling (%d lost)" % enemy_losses)
	print("  [feel] after relief: reserve stamina %.2f vs enemy %.2f, enemy lost %d more" % [
		reserve.stamina, enemy.stamina, enemy_losses])


func test_contact_files_cannot_exceed_what_the_enemy_offers(t) -> void:
	# Twenty files cannot all land on a two-file target, or a wide unit would delete
	# a narrow one instantly instead of merely beating it.
	var bs = BattleState.new()
	var wide = bs.add(1, &"archer", Vector2(-15, 0), 0.0)        # width 16
	var narrow = bs.add(2, &"sword", Vector2(15, 0), PI)         # width 10
	narrow.strength = 4
	var files := BattleState.contact_files(wide, narrow,
		BattleState.Exposure.FRONT, BattleState.Exposure.FRONT)
	t.ok(files <= ceili(4 * Rules.WRAP_ALLOWANCE),
		"capped by the enemy's edge plus a lap round the ends, got %d" % files)
	t.ok(files > 0, "but never nothing")
