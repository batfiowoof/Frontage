extends RefCounted
## The battle sim's combat resolution: contact, attrition, flanking, morale, rout.
## This is where the game lives or dies, so it gets checked before it gets drawn.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")


## Two blocks that have just met, rather than two blocks standing inside each other.
##
## The centre distance CANNOT be a constant here, which is what it used to be. Contact is
## front rank to front rank, so a wider regiment is a shallower one and reaches less far
## forward: the 91 units that locked two 10-deep spear blocks together leaves two 6-deep
## ones with 46 units of open ground between them, and every fight in this file quietly
## became two regiments staring at each other. Ask for the distance instead.
## Pass a gap explicitly only to place them deliberately out of reach.
func _facing_each_other(gap := -1.0) -> Array:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2.ZERO, 0.0)                 # faces +X, at the enemy
	var b = bs.add(2, &"spear", Vector2.ZERO, PI)                  # faces -X, at the enemy
	if gap < 0.0:
		gap = BattleState.contact_distance(a, b, Rules.CONTACT_GAP * 0.5)
	_stand(a, Vector2(-gap * 0.5, 0))
	_stand(b, Vector2(gap * 0.5, 0))
	return [bs, a, b]


## Put a regiment somewhere and leave it there. `target` comes from `pos` in
## Regiment.make, so moving one without the other orders it to march back.
func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


func _run(bs, ticks: int) -> void:
	for i in ticks:
		bs.step()


# --- contact --------------------------------------------------------------

func test_regiments_out_of_reach_do_not_fight(t) -> void:
	var s := _facing_each_other(400.0)
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
	remnant[2].strength = 3                       # far fewer men than it has files
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
	# Six seconds, not one. A shallower regiment turns fewer ranks toward a rear attack
	# than a deep one does, so the gap in MEN is narrower than it used to be and a
	# one-second window cannot resolve it at whole casualties -- both sides read 1.
	# The gap in NERVE is as wide as ever, which is the mechanism that matters.
	var front := _facing_each_other()
	_run(front[0], Rules.TICK_HZ * 6)
	var frontal_losses: int = front[1].max_strength - front[1].strength
	var frontal_morale: float = front[1].morale

	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)              # facing +X
	var behind = bs.add(2, &"spear", Vector2.ZERO, 0.0)              # hitting its back
	_stand(behind, Vector2(-(BattleState.reach(victim, BattleState.Exposure.REAR)
		+ BattleState.reach(behind, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5), 0))
	_run(bs, Rules.TICK_HZ * 6)
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
	var pin = bs.add(2, &"spear", Vector2.ZERO, PI)                  # pins its front
	var flanker = bs.add(2, &"spear", Vector2.ZERO, PI / 2)          # hits its side
	# Front-on to the victim's front, but front-on to its FLANK for the flanker: the
	# victim reaches half its frontage sideways and half its depth forward, and those are
	# different numbers, so the two are not placed at the same distance.
	_stand(pin, Vector2(BattleState.contact_distance(victim, pin, Rules.CONTACT_GAP * 0.5), 0))
	_stand(flanker, Vector2(0, -(BattleState.reach(victim, BattleState.Exposure.FLANK)
		+ BattleState.reach(flanker, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5)))
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
	# 1.8 and not 2.0: at whole casualties over eight seconds the ratio lands on 17-to-8
	# or 18-to-9 depending on where the rounding falls, so a bar of exactly twice was
	# passing on luck rather than on the model.
	t.ok(float(flanked) > float(frontal) * 1.8,
		"a flank must be worth manoeuvring for (%d dead vs %d in 8s, %.1fx)" % [
			flanked, frontal, float(flanked) / maxf(1.0, float(frontal))])
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
	# Forty seconds, not sixty. Exhaustion now makes a spent regiment easier to kill
	# (TIRED_VULNERABILITY) as well as slower to swing, so the tie breaks at about 53s
	# where it used to run to 68s. Measured: with the tired-morale term switched off
	# entirely it still breaks at 55s, so it is the casualties doing this, not the nerve.
	var s := _facing_each_other()
	_run(s[0], Rules.TICK_HZ * 40)
	t.ok(not s[0].is_over(), "a head-on tie is still a tie well after both sides are spent")
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

	# A SHORT step back, not a route march. Marching tires a regiment now, so ordering it
	# three thousand units away had it running for over a minute and arriving worse off
	# than it left -- which is true, and not what this test is about.
	s[1].order_move(Vector2(-260, 0), PI)         # pull it out of the line
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


# --- where the fighting line actually is -----------------------------------

func test_reach_is_depth_to_the_front_and_frontage_to_the_side(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	t.near(BattleState.reach(r, BattleState.Exposure.FRONT),
		Formation.half_depth(r.max_strength, r.width))
	t.near(BattleState.reach(r, BattleState.Exposure.REAR),
		Formation.half_depth(r.max_strength, r.width), 0.0001, "a block is as deep behind as in front")
	t.near(BattleState.reach(r, BattleState.Exposure.FLANK),
		Formation.frontage(r.max_strength, r.width), 0.0001, "sideways it is only as wide as its line")


func test_reach_does_not_shrink_as_a_regiment_is_worn_down(t) -> void:
	# The whole complaint: the engagement distance used to walk backwards as men died.
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var fresh := BattleState.reach(r, BattleState.Exposure.FRONT)
	r.strength = 10
	t.near(BattleState.reach(r, BattleState.Exposure.FRONT), fresh, 0.0001,
		"a battered regiment holds the same ground it started on")


func test_a_deeper_block_engages_further_out(t) -> void:
	var bs = BattleState.new()
	var deep = bs.add(1, &"pike", Vector2.ZERO, 0.0)        # 140 men, 14 wide -> 10 ranks
	var shallow = bs.add(1, &"archer", Vector2.ZERO, 0.0)   # 80 men, 16 wide -> 5 ranks
	t.ok(BattleState.reach(deep, BattleState.Exposure.FRONT)
		> BattleState.reach(shallow, BattleState.Exposure.FRONT),
		"depth has to reach further, or the deep block's front rank stands inside the enemy")


func test_two_blocks_charging_stop_with_their_fronts_touching(t) -> void:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2(-600, 0), 0.0)
	var b = bs.add(2, &"spear", Vector2(600, 0), PI)
	a.order_move(b.pos, 0.0)
	b.order_move(a.pos, PI)
	for i in Rules.TICK_HZ * 40:
		bs.step()
		if a.state == Regiment.State.FIGHTING and b.state == Regiment.State.FIGHTING:
			break
	t.eq(a.state, Regiment.State.FIGHTING, "they should have met")

	var gap := BattleState.gap_between(a, b)
	t.ok(gap <= Rules.CONTACT_GAP, "in contact: gap %.1f" % gap)
	t.ok(gap > -Rules.RANK_SPACING * 2.0,
		"but not standing inside each other: gap %.1f" % gap)
	var depth: float = Formation.half_depth(a.max_strength, a.width)
	t.ok(a.pos.distance_to(b.pos) > depth * 2.0 - Rules.RANK_SPACING * 2.0,
		"centres at least two half-depths apart (%.0f vs %.0f)" % [a.pos.distance_to(b.pos), depth * 2.0])
	print("  [feel] two blocks meet: centres %.0f apart, front gap %.1f" % [
		a.pos.distance_to(b.pos), gap])


func test_side_of_tells_the_two_flanks_apart(t) -> void:
	var bs = BattleState.new()
	var d = bs.add(1, &"spear", Vector2.ZERO, 0.0)        # facing +X
	var ahead = bs.add(2, &"spear", Vector2(200, 0), PI)
	var behind = bs.add(2, &"spear", Vector2(-200, 0), 0.0)
	# Local +Y runs toward higher files, so an enemy at +Y is off the regiment's RIGHT.
	var right = bs.add(2, &"spear", Vector2(0, 200), -PI / 2)
	var left = bs.add(2, &"spear", Vector2(0, -200), PI / 2)

	t.eq(BattleState.side_of(d, ahead), BattleState.Side.FRONT)
	t.eq(BattleState.side_of(d, behind), BattleState.Side.REAR)
	t.eq(BattleState.side_of(d, right), BattleState.Side.RIGHT)
	t.eq(BattleState.side_of(d, left), BattleState.Side.LEFT)


func test_both_flanks_are_the_same_to_the_damage_maths(t) -> void:
	# The men care which flank; the fight does not. If these ever disagree, one side of
	# a regiment is quietly tougher than the other.
	var bs = BattleState.new()
	var d = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var right = bs.add(2, &"spear", Vector2(0, 200), -PI / 2)
	var left = bs.add(2, &"spear", Vector2(0, -200), PI / 2)
	t.eq(BattleState.exposure_of(d, right), BattleState.Exposure.FLANK)
	t.eq(BattleState.exposure_of(d, left), BattleState.Exposure.FLANK)


# --- the ground -----------------------------------------------------------

func test_open_field_does_nothing(t) -> void:
	var bs = BattleState.new()
	var here := bs.ground_at(Vector2.ZERO)
	t.near(here["speed"], 1.0)
	t.near(here["damage"], 1.0)
	t.near(here["cover"], 0.0)


func test_ground_only_applies_where_it_is(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_WOOD, 0.0, 0.0, 120.0]]
	t.ok(bs.ground_at(Vector2.ZERO)["speed"] < 1.0, "inside the wood")
	t.near(bs.ground_at(Vector2(400, 0))["speed"], 1.0, 0.0001, "and not outside it")


func test_a_wood_slows_men_down_and_hides_them(t) -> void:
	var bs = BattleState.new()
	bs.features = [[Rules.GROUND_WOOD, 0.0, 0.0, 600.0]]
	var inside = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	inside.order_move(Vector2(100000, 0), 0.0)

	var open = BattleState.new()
	var outside = open.add(1, &"spear", Vector2.ZERO, 0.0)
	outside.order_move(Vector2(100000, 0), 0.0)
	for i in Rules.TICK_HZ:
		bs.step()
		open.step()
	t.ok(inside.pos.x < outside.pos.x * 0.85, "marching through a wood is slower")
	t.ok(bs.ground_at(Vector2.ZERO)["cover"] > 0.0, "and there is something to hide behind")


func test_high_ground_hits_harder(t) -> void:
	var low := _facing_each_other()
	var high = BattleState.new()
	var uphill = high.add(1, &"spear", Vector2.ZERO, 0.0)
	var downhill = high.add(2, &"spear", Vector2.ZERO, PI)
	var apart := BattleState.contact_distance(uphill, downhill, Rules.CONTACT_GAP * 0.5)
	_stand(uphill, Vector2(-apart * 0.5, 0))
	_stand(downhill, Vector2(apart * 0.5, 0))
	# Centred on the uphill regiment and too small to reach the other one, so only the
	# first one stands on it -- which is the whole comparison.
	high.features = [[Rules.GROUND_HILL, -apart * 0.5, 0.0, apart * 0.45]]

	_run(low[0], 20)
	for i in Rules.TICK_HZ * 20:
		high.step()
	t.ok(downhill.max_strength - downhill.strength > low[2].max_strength - low[2].strength,
		"the man on the hill should be doing more damage")


func test_the_ground_is_the_same_every_time_for_the_same_meeting(t) -> void:
	# A replay of a battle has to find the same wood in the same place.
	var a = BattleState.new()
	var b = BattleState.new()
	a.lay_ground(1, 4242)
	b.lay_ground(1, 4242)
	t.eq(a.features, b.features)
	var elsewhere = BattleState.new()
	elsewhere.lay_ground(1, 99)
	t.ok(elsewhere.features != a.features, "a different meeting, a different field")


func test_wooded_country_gives_a_woodier_field(t) -> void:
	var wood = BattleState.new()
	wood.lay_ground(1, 7)                     # forest
	var plain = BattleState.new()
	plain.lay_ground(0, 7)                    # plains
	t.ok(wood.features.size() > plain.features.size(),
		"a battle in the woods should be fought among more of them")
	for f: Array in wood.features:
		t.eq(int(f[0]), Rules.GROUND_WOOD)


# --- exhaustion reaches the rest of the model -------------------------------

func test_marching_tires_a_regiment_and_standing_rests_it(t) -> void:
	# Crossing the field used to be free, which put no price at all on a flanking march.
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.order_move(Vector2(100000, 0), 0.0)
	_run(bs, Rules.TICK_HZ * 30)
	var marched: float = r.stamina
	t.ok(marched < 1.0, "thirty seconds of marching should tell (%.2f)" % marched)

	r.order_move(r.pos, 0.0)
	_run(bs, Rules.TICK_HZ * 40)
	t.ok(r.stamina > marched, "and standing gets it back (%.2f)" % r.stamina)


func test_a_rout_tires_faster_than_a_march(t) -> void:
	# Scaled by the pace actually kept, so running costs more than walking.
	var bs = BattleState.new()
	var marcher = bs.add(1, &"spear", Vector2(0, -900), 0.0)
	var router = bs.add(2, &"spear", Vector2(0, 900), PI)
	marcher.order_move(Vector2(100000, -900), 0.0)
	router.shock(Rules.MORALE_MAX)
	# Eight seconds, and sampled while it is still running. A router recovers morale at
	# MORALE_RECOVERY once it is clear, so given twenty-five it rallies, goes IDLE and
	# rests all the way back to full -- which measures the rally, not the running.
	_run(bs, Rules.TICK_HZ * 8)
	t.eq(router.state, Regiment.State.ROUTING, "it is still running at this point")
	t.ok(router.stamina < marcher.stamina,
		"running is harder work than marching (%.3f against %.3f)" % [
			router.stamina, marcher.stamina])


func test_a_spent_regiment_is_worse_in_every_way(t) -> void:
	var fresh = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	var spent = Regiment.make(2, 1, &"spear", Vector2.ZERO)
	spent.stamina = 0.0
	t.ok(spent.readiness() < fresh.readiness(), "it hits softer")
	t.ok(spent.vulnerability() > fresh.vulnerability(), "it is easier to kill")
	t.ok(spent.legs() < fresh.legs(), "it cannot keep up")
	t.ok(spent.nerve() > fresh.nerve(), "and it breaks sooner")
	t.near(fresh.vulnerability(), 1.0, 0.001, "a fresh one is the baseline for all of them")
	t.near(fresh.legs(), 1.0, 0.001)
	t.near(fresh.nerve(), 1.0, 0.001)


func test_an_exhausted_regiment_marches_slower(t) -> void:
	var bs = BattleState.new()
	var fit = bs.add(1, &"spear", Vector2(0, -900), 0.0)
	var spent = bs.add(2, &"spear", Vector2(0, 900), 0.0)
	fit.order_move(Vector2(100000, -900), 0.0)
	spent.order_move(Vector2(100000, 900), 0.0)
	for i in Rules.TICK_HZ * 10:
		spent.stamina = 0.0                # hold it on its knees
		bs.step()
	t.ok(spent.pos.x < fit.pos.x * 0.8,
		"a spent regiment falls behind a fresh one (%.0f against %.0f)" % [
			spent.pos.x, fit.pos.x])


# --- turning -----------------------------------------------------------------

func test_a_wheel_never_outruns_the_men(t) -> void:
	# The number this whole change turns on. At the old TURN_SPEED a 20-wide block
	# wheeling put its end file through 209 units in a second -- 200 u/s, three times
	# marching pace. Men cannot be flung sideways faster than they can walk.
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	var half := Formation.frontage(r.max_strength, r.width, r.spacing())
	var quarter_turn := (PI * 0.5) / (Rules.TURN_SPEED * float(r.form()["turn"]))
	var sweep := half * (PI * 0.5) / quarter_turn
	t.ok(sweep < Rules.MOVE_SPEED,
		"the end file sweeps at %.0f u/s, slower than the %.0f they march" % [
			sweep, Rules.MOVE_SPEED])


func test_a_regiment_in_contact_may_not_turn_about(t) -> void:
	# Load-bearing. A regiment taken in the rear that could flip to face its attacker
	# would delete the flank-and-rear mechanic outright: it has to wheel round slowly and
	# eat the rear attack while it does.
	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)          # facing +X
	var behind = bs.add(2, &"spear", Vector2.ZERO, 0.0)          # coming from -X
	_stand(behind, Vector2(-(BattleState.reach(victim, BattleState.Exposure.REAR)
		+ BattleState.reach(behind, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5), 0))
	_run(bs, Rules.TICK_HZ * 3)
	t.eq(BattleState.exposure_of(victim, behind), BattleState.Exposure.REAR,
		"it is still being taken in the rear three seconds later")
	t.ok(absf(angle_difference(victim.facing, 0.0)) < deg_to_rad(60.0),
		"it has not flipped round to face him (%.0f deg)" % rad_to_deg(victim.facing))
