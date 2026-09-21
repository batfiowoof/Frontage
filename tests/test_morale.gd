extends RefCounted
## Morale as a thing you manage, not a bar that drains.
##
## Two fixes and one feature live here. Morale used to be measured by the clock: a flat
## MORALE_DRAIN_FIGHTING and a casualty term were summed, each tuned to break a regiment
## on its own, and the shock was scaled by one multiplier where damage was scaled by ten.
## A regiment broke at 75s having lost a quarter of its men. Now the casualties carry the
## frontal fight and shock scales with how hard the attacker can actually press.
##
## The rally was written and unreachable: `Regiment.recover()` has always known how to
## rally at MORALE_RALLY_THRESHOLD, but the sim only called it in the IDLE branch and a
## router is never IDLE, so a rout was permanent.
##
## And the biggest regiment on each side now carries the general.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Snapshot := preload("res://net/snapshot.gd")


## Two blocks just touching. The centre distance has to be ASKED for, not assumed: a
## wider regiment is a shallower one and reaches less far forward, so a constant here
## silently stops being contact the moment a default frontage changes.
func _duel(gap := -1.0) -> Array:
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var b = bs.add(2, &"spear", Vector2.ZERO, PI)
	if gap < 0.0:
		gap = BattleState.contact_distance(a, b, Rules.CONTACT_GAP * 0.5)
	_stand(a, Vector2(-gap * 0.5, 0))
	_stand(b, Vector2(gap * 0.5, 0))
	return [bs, a, b]


## `target` comes from `pos` in Regiment.make, so moving one without the other orders
## the regiment to march straight back where it came from.
func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


func _run(bs, ticks: int) -> void:
	for i in ticks:
		bs.step()


# --- morale tracks the blood, not the clock -------------------------------

func test_a_frontal_fight_costs_less_morale_than_it_used_to(t) -> void:
	var s := _duel()
	_run(s[0], Rules.TICK_HZ * 60)
	var r: Regiment = s[1]
	var lost_men := float(r.max_strength - r.strength) / float(r.max_strength)
	var lost_morale := (Rules.MORALE_MAX - r.morale) / Rules.MORALE_MAX
	# It used to be 26% of the men for 80% of the morale -- a regiment collapsing while
	# visibly barely scratched. Morale may still outrun casualties, but not threefold.
	t.ok(lost_morale < lost_men * 2.2,
		"morale (%.0f%%) must not run away from casualties (%.0f%%)" % [
			lost_morale * 100.0, lost_men * 100.0])
	print("  [feel] 60s head-on: %d%% of the men, %d%% of the morale" % [
		lost_men * 100.0, lost_morale * 100.0])


func test_a_worn_out_attacker_frightens_people_less(t) -> void:
	# The structural fix. Damage passes through ten multipliers and shock used to pass
	# through one, so an exhausted regiment broke a man's nerve exactly as fast as a
	# fresh one did.
	var fresh := _duel()
	fresh[1].stamina = 1.0
	fresh[2].stamina = 1.0
	_run(fresh[0], Rules.TICK_HZ * 8)

	var spent := _duel()
	spent[1].stamina = 0.0
	spent[2].stamina = 1.0
	_run(spent[0], Rules.TICK_HZ * 8)
	# Regiment 2 is the one being hit by a tired attacker in the second case.
	t.ok(spent[2].morale > fresh[2].morale,
		"a knackered attacker shakes them less (%.1f vs %.1f)" % [spent[2].morale, fresh[2].morale])


# --- the rally that was unreachable ---------------------------------------

func test_a_router_that_gets_clear_pulls_itself_together(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.morale = Rules.MORALE_ROUT_THRESHOLD + 1.0
	r.shock(2.0)                       # tip it over the threshold
	t.eq(r.state, Regiment.State.ROUTING, "it has broken")
	# Alone on the field, nothing chasing it.
	# A rally is the better part of a minute now: RALLY_DELAY to steady itself, then the
	# climb at MORALE_RECOVERY. It used to be six seconds, which is what made a broken
	# regiment a temporary inconvenience rather than a hole in the line.
	_run(bs, int((Rules.RALLY_DELAY + Rules.MORALE_MAX / Rules.MORALE_RECOVERY + 5.0) * Rules.TICK_HZ))
	t.eq(r.state, Regiment.State.IDLE, "and with nobody after it, it comes back")
	t.ok(r.morale >= Rules.MORALE_RALLY_THRESHOLD, "at the rally threshold or better")


func test_a_router_still_being_cut_down_does_not_rally(t) -> void:
	var s := _duel()
	s[1].morale = Rules.MORALE_ROUT_THRESHOLD + 1.0
	s[1].shock(2.0)
	t.eq(s[1].state, Regiment.State.ROUTING)
	_run(s[0], Rules.TICK_HZ * 4)
	t.eq(s[1].state, Regiment.State.ROUTING, "no rallying with a spear in your back")


# --- the general ----------------------------------------------------------

func test_the_biggest_regiment_carries_the_general(t) -> void:
	var bs = BattleState.new()
	var small = bs.add(1, &"cavalry", Vector2.ZERO, 0.0)          # 70 men
	var big = bs.add(1, &"pike", Vector2(200, 0), 0.0)            # 140 men
	var theirs = bs.add(2, &"spear", Vector2(900, 0), PI)
	bs.commission_generals()
	t.eq(int(bs.generals[1]), big.id, "the biggest of ours, not the first of ours")
	t.eq(int(bs.generals[2]), theirs.id, "and each side has its own")
	t.ok(small.id != int(bs.generals[1]), "the cavalry is not in charge")


func test_the_general_does_not_change_hands_when_he_dies(t) -> void:
	# Computed over the dead as well as the living. Promoting the next-biggest the
	# instant he fell would mean an army loses its general and immediately has another,
	# and a client decoding a mid-battle snapshot would name a different man.
	var bs = BattleState.new()
	var big = bs.add(1, &"pike", Vector2.ZERO, 0.0)
	bs.add(1, &"spear", Vector2(200, 0), 0.0)
	bs.commission_generals()
	t.eq(int(bs.generals[1]), big.id)
	big.take_casualties(big.strength)
	t.eq(big.state, Regiment.State.DEAD)
	bs.commission_generals()
	t.eq(int(bs.generals[1]), big.id, "he is still the man who was in charge")


func test_the_general_steadies_the_men_who_can_see_him(t) -> void:
	var near := _under_pressure(Rules.GENERAL_RADIUS * 0.4)
	var far := _under_pressure(Rules.GENERAL_RADIUS * 3.0)
	t.ok(near > far, "morale holds better beside the general (%.1f vs %.1f)" % [near, far])


## One regiment of ours is ground down by an enemy while our general stands `away`
## from it. Returns the pressed regiment's morale after eight seconds.
func _under_pressure(away: float) -> float:
	var bs = BattleState.new()
	var pressed = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var enemy = bs.add(2, &"spear", Vector2.ZERO, PI)
	var apart := BattleState.contact_distance(pressed, enemy, Rules.CONTACT_GAP * 0.5)
	_stand(pressed, Vector2(-apart * 0.5, 0.0))
	_stand(enemy, Vector2(apart * 0.5, 0.0))
	# A bigger regiment of ours, out of the fight, carrying the general.
	bs.add(1, &"pike", Vector2(-apart * 0.5, away), 0.0)
	bs.commission_generals()
	for i in Rules.TICK_HZ * 8:
		bs.step()
	return pressed.morale


func test_losing_the_general_shakes_the_whole_army_once(t) -> void:
	var bs = BattleState.new()
	var big = bs.add(1, &"pike", Vector2(900, 900), 0.0)
	var other = bs.add(1, &"spear", Vector2(-900, -900), 0.0)   # far away, undisturbed
	bs.commission_generals()
	bs.step()
	var before: float = other.morale
	big.take_casualties(big.strength)
	bs.step()
	var after: float = other.morale
	t.ok(after < before, "the news reaches a regiment nowhere near him")
	bs.step()
	bs.step()
	t.ok(absf(other.morale - after) < 0.5, "and it is felt once, not every tick after")


# --- it costs nothing on the wire -----------------------------------------

func test_a_decoded_mirror_names_the_same_general(t) -> void:
	# Derived from max_strength and the ids, both of which are already in the rows, so
	# the server and the mirror reach the same answer with no byte spent on it.
	var bs = BattleState.new()
	bs.add(1, &"cavalry", Vector2.ZERO, 0.0)
	bs.add(1, &"pike", Vector2(200, 0), 0.0)
	bs.add(2, &"spear", Vector2(900, 0), PI)
	bs.commission_generals()
	var mirror = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(mirror != null, "it decodes")
	t.eq(mirror.generals, bs.generals, "and picks the same men out of the same bytes")


# --- the flow of a battle ---------------------------------------------------

## A line of `n` of ours along Y, far from any enemy, all steady.
func _a_line(n: int) -> Array:
	var bs = BattleState.new()
	var line := []
	for i in n:
		line.append(bs.add(1, &"spear", Vector2(0, float(i) * Rules.SHOULDER_RADIUS * 0.7), 0.0))
	return [bs, line]


## The one that gives a battle its shape. `Regiment.shock()` has always documented
## "seeing a neighbour break" as one of its callers; nothing ever called it for that, so
## every regiment's morale was entirely its own business and two lines simply ground each
## other down until one happened to cross a threshold.
func test_a_break_at_one_end_travels_down_the_line(t) -> void:
	var s := _a_line(4)
	var line: Array = s[1]
	line[0].shock(Rules.MORALE_MAX)                 # the end regiment breaks
	t.eq(line[0].state, Regiment.State.ROUTING, "it has gone")
	_run(s[0], Rules.TICK_HZ * 4)

	t.ok(line[1].morale < Rules.MORALE_MAX, "its neighbour feels it (%.0f)" % line[1].morale)
	t.ok(line[1].morale < line[3].morale,
		"and the far end feels it less (%.0f against %.0f)" % [line[1].morale, line[3].morale])

	# ...and with nobody broken, the same line holds. Or this is measuring gravity.
	var calm := _a_line(4)
	_run(calm[0], Rules.TICK_HZ * 4)
	t.near(calm[1][1].morale, Rules.MORALE_MAX, 0.001, "a line with nobody broken is steady")


func test_a_regiment_that_breaks_too_often_is_finished(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	for i in Rules.ROUTS_BEFORE_SHATTERED - 1:
		r.shock(Rules.MORALE_MAX)
		t.eq(r.state, Regiment.State.ROUTING, "it breaks")
		t.ok(not r.shattered(), "but it is not finished yet")
		r.recover(Rules.MORALE_MAX)
		t.eq(r.state, Regiment.State.IDLE, "and it comes back")

	r.shock(Rules.MORALE_MAX)
	t.ok(r.shattered(), "once too often and it is shattered")
	r.recover(Rules.MORALE_MAX)
	t.eq(r.state, Regiment.State.ROUTING, "and it never comes back, however calm it gets")
	t.ok(r.morale > Rules.MORALE_RALLY_THRESHOLD,
		"even well above the rally threshold (%.0f)" % r.morale)


func test_a_wreck_never_gets_a_full_bar_back(t) -> void:
	# There was no permanent morale damage of any kind: a regiment that broke at 41%
	# casualties climbed all the way back to 100 in twenty seconds and returned as though
	# nothing had happened to it.
	var s := _a_line(2)
	var r: Regiment = s[1][0]
	r.take_casualties(r.max_strength / 2)
	r.rally_wait = 0.0
	_run(s[0], Rules.TICK_HZ * 200)
	t.ok(r.morale <= r.morale_ceiling() + 0.001,
		"half a regiment can only be half as steady (%.0f, ceiling %.0f)" % [
			r.morale, r.morale_ceiling()])
	t.ok(r.morale < Rules.MORALE_MAX * 0.9, "and nowhere near a full bar")


func test_an_army_that_has_lost_most_of_itself_wavers(t) -> void:
	# On the COUNT, not on each regiment's own morale: "if the entire army has lost many
	# of its units, this causes every unit to waver regardless of Leadership".
	var bs = BattleState.new()
	var survivor = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var mate = bs.add(1, &"spear", Vector2(0, Rules.SHOULDER_RADIUS * 0.5), 0.0)
	for i in 4:
		bs.add(1, &"spear", Vector2(0, -600.0 - float(i) * 40.0), 0.0).shock(Rules.MORALE_MAX)
	t.near(survivor.morale, Rules.MORALE_MAX, 0.001, "it has not been touched")
	_run(bs, Rules.TICK_HZ * 4)
	t.ok(survivor.morale < Rules.MORALE_MAX - 4.0,
		"but its army is going and it knows (%.0f)" % survivor.morale)
	t.ok(mate.morale < Rules.MORALE_MAX, "and so does the man beside it")


func test_pulling_a_regiment_out_of_the_line_lets_it_recover(t) -> void:
	# Recovery used to be gated on the STATE, not on safety: a router recovered at 4.0/s
	# while a regiment merely repositioning recovered nothing, so running away restored
	# morale and manoeuvring did not.
	var s := _a_line(2)
	var r: Regiment = s[1][0]
	r.morale = 50.0
	r.rally_wait = 0.0
	r.order_move(Vector2(0, -900), 0.0)
	_run(s[0], Rules.TICK_HZ * 10)
	t.eq(r.state, Regiment.State.MOVING, "it is still marching")
	t.ok(r.morale > 50.0, "and catching its breath while it goes (%.0f)" % r.morale)


func test_how_many_times_it_has_run_survives_the_wire(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.shock(Rules.MORALE_MAX)
	r.recover(Rules.MORALE_MAX)
	r.shock(Rules.MORALE_MAX)
	t.eq(r.routs, 2, "it has broken twice")
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	if back != null:
		t.eq(back.regiments[r.id].routs, 2, "and the mirror knows, or it draws a banner it should not")
