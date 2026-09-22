extends RefCounted
## Reinforcements, the man in command, and the line you set out before the fight.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _army_of(cs, owner := 1) -> Dictionary:
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == owner:
			return cs.armies[id]
	return {}


func _empty_neighbour(cs, tile: int) -> int:
	for n in cs.adjacent(tile):
		if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
			return n
	return -1


# --- reinforcements -------------------------------------------------------
# Armies cannot share a hex, so without this two of your stacks a hex apart fight the
# enemy one at a time and lose to a force neither could beat alone.

func test_a_neighbour_joins_the_fight(t) -> void:
	var cs = _two_player()
	var main: Dictionary = _army_of(cs)
	var beside := _empty_neighbour(cs, int(main["tile"]))
	var helper: Dictionary = cs.add_army(1, beside, [&"sword"])
	var before: int = main["regiments"].size()
	t.eq(cs.reinforce(int(main["id"])), 1)
	t.eq(main["regiments"].size(), before + 1)
	t.ok(not cs.armies.has(helper["id"]), "it walked in entirely, so there is no army left")


func test_the_enemy_next_door_does_not_reinforce_you(t) -> void:
	var cs = _two_player()
	var main: Dictionary = _army_of(cs)
	var beside := _empty_neighbour(cs, int(main["tile"]))
	cs.add_army(2, beside, [&"sword"])
	var before: int = main["regiments"].size()
	t.eq(cs.reinforce(int(main["id"])), 0)
	t.eq(main["regiments"].size(), before)


func test_an_army_that_has_already_marched_stays_where_it_is(t) -> void:
	# It marched and fought somewhere else this turn; it is not also available here.
	var cs = _two_player()
	var main: Dictionary = _army_of(cs)
	var beside := _empty_neighbour(cs, int(main["tile"]))
	var helper: Dictionary = cs.add_army(1, beside, [&"sword"])
	helper["move_left"] = 0
	t.eq(cs.reinforce(int(main["id"])), 0)
	t.ok(cs.armies.has(helper["id"]))


func test_reinforcement_respects_the_regiment_cap(t) -> void:
	# It is `merge`, so the cap, the remainder and the movement are all its rules and
	# there is not a second set of them to keep in step.
	var cs = _two_player()
	var main: Dictionary = _army_of(cs)
	while main["regiments"].size() < Campaign.MAX_REGIMENTS_PER_ARMY:
		main["regiments"].append(Campaign.make_regiment(&"spear"))
	var beside := _empty_neighbour(cs, int(main["tile"]))
	var helper: Dictionary = cs.add_army(1, beside, [&"sword"])
	t.eq(cs.reinforce(int(main["id"])), 0, "there is no room")
	t.eq(main["regiments"].size(), Campaign.MAX_REGIMENTS_PER_ARMY)
	t.ok(cs.armies.has(helper["id"]), "so it stayed outside")


func test_reinforcing_an_army_that_is_not_there_is_harmless(t) -> void:
	t.eq(_two_player().reinforce(9999), 0)


# --- the man in command ---------------------------------------------------

func test_every_army_has_a_named_commander(t) -> void:
	var cs = _two_player()
	var who := Campaign.general_name(int(_army_of(cs)["id"]))
	t.ok(who != "", "somebody is in charge")
	t.eq(who, Campaign.general_name(int(_army_of(cs)["id"])), "and it is the same man twice")


func test_the_name_is_derived_and_never_sent(t) -> void:
	# The same trick the battle general uses: every machine reaches it from something
	# the snapshot already carries, so it costs nothing on the wire.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.eq(Campaign.general_name(int(back.armies[a["id"]]["id"])),
		Campaign.general_name(int(a["id"])))


func test_a_new_commander_is_worth_nothing_extra(t) -> void:
	# The balance the general's three numbers were tuned against has to survive this.
	t.near(Campaign.renown_factor(_army_of(_two_player())), 1.0)


func test_winning_makes_him_better_up_to_a_ceiling(t) -> void:
	var green := {"renown": 0}
	var blooded := {"renown": 1}
	var famous := {"renown": Rules.RENOWN_WINS * 10}
	t.ok(Campaign.renown_factor(blooded) > Campaign.renown_factor(green))
	t.near(Campaign.renown_factor(famous), Rules.RENOWN_BEST,
		0.0001, "a general who kept winning forever would decide the campaign in one battle")


func test_renown_steadies_the_men_harder(t) -> void:
	var plain := _duel(1.0)
	var famous := _duel(Rules.RENOWN_BEST)
	t.ok(famous[1].morale > plain[1].morale,
		"men under a better commander hold together longer (%.1f vs %.1f)" % [
			famous[1].morale, plain[1].morale])


func test_renown_can_never_make_a_regiment_unbreakable(t) -> void:
	# It pushes the drain multiplier further below 1 and must not push it past 0, or a
	# famous enough general would delete morale as a mechanic.
	var bs = BattleState.new()
	bs.renown[1] = Rules.RENOWN_BEST
	var mine = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var theirs = bs.add(2, &"spear", Vector2.ZERO, PI)
	_face_off(bs, mine, theirs)
	for i in Rules.TICK_HZ * 40:
		bs.step()
	t.ok(mine.morale < Rules.MORALE_MAX, "it is still being worn down")


## Two spears front rank to front rank, with one side under a commander of this worth.
func _duel(worth: float) -> Array:
	var bs = BattleState.new()
	bs.renown[1] = worth
	var mine = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var theirs = bs.add(2, &"spear", Vector2.ZERO, PI)
	_face_off(bs, mine, theirs)
	for i in Rules.TICK_HZ * 30:
		bs.step()
	return [bs, mine, theirs]


func _face_off(bs, a, b) -> void:
	var apart := BattleState.reach(a, BattleState.Exposure.FRONT) \
		+ BattleState.reach(b, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	a.pos = Vector2(-apart * 0.5, 0)
	b.pos = Vector2(apart * 0.5, 0)
	a.target = a.pos
	b.target = b.pos


func test_renown_survives_both_wires(t) -> void:
	var cs = _two_player()
	_army_of(cs)["renown"] = 2
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.eq(Campaign.renown_of(back.armies[_army_of(cs)["id"]]), 2)

	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.renown[1] = 1.4
	var mirror = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(mirror != null)
	t.near(mirror.renown_of(1), 1.4)


func test_an_impossible_renown_is_refused(t) -> void:
	# It divides a morale drain, so a peer that could name it could make its army hold.
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.renown[1] = 99.0
	t.eq(Snapshot.decode_battle(Snapshot.encode_battle(bs)), null)


# --- arranging the line ---------------------------------------------------

func test_a_battle_state_fights_by_default(t) -> void:
	# Every test and harness in this tree builds one and calls step() expecting a fight.
	# A deployment phase that had to be dismissed would silently stop all of them.
	t.eq(BattleState.new().phase, BattleState.Phase.FIGHT)


func test_nothing_happens_while_the_line_is_being_arranged(t) -> void:
	var bs = _deploying()
	var mine = bs.regiments[bs.sorted_ids()[0]]
	var theirs = bs.regiments[bs.sorted_ids()[1]]
	var men: int = theirs.strength
	var heart: float = theirs.morale
	for i in Rules.TICK_HZ * 5:
		bs.step()
	t.eq(theirs.strength, men, "nobody is killed")
	t.near(theirs.morale, heart, 0.001, "and nobody's nerve goes")
	t.near(mine.stamina, 1.0, 0.001, "and nobody tires")
	t.eq(bs.phase, BattleState.Phase.DEPLOY, "because it has not started")


func test_the_tick_still_advances_while_deploying(t) -> void:
	# A replay is a tick count and a list of orders. A deployment that consumed no ticks
	# would replay the fight starting at the wrong moment.
	var bs = _deploying()
	bs.step()
	bs.step()
	t.eq(bs.tick, 2)


func test_both_sides_ready_starts_it_at_once(t) -> void:
	var bs = _deploying()
	bs.say_ready(1)
	bs.step()
	t.eq(bs.phase, BattleState.Phase.DEPLOY, "one side is not everybody")
	bs.say_ready(2)
	bs.step()
	t.eq(bs.phase, BattleState.Phase.FIGHT)


func test_the_clock_starts_it_if_nobody_does(t) -> void:
	var bs = _deploying()
	for i in int(Rules.DEPLOY_SECONDS * Rules.TICK_HZ) + 1:
		bs.step()
	t.eq(bs.phase, BattleState.Phase.FIGHT, "somebody who never presses it cannot stall")


func test_deploying_places_a_regiment_rather_than_marching_it(t) -> void:
	var bs = _deploying()
	var mine = bs.regiments[bs.sorted_ids()[0]]
	var to := Vector2(mine.pos.x, 300.0)
	bs.place(mine, to, 1.0)
	t.near(mine.pos.y, 300.0, 0.001, "it is where you put it, this instant")
	t.near(mine.facing, 1.0)
	t.eq(mine.state, Regiment.State.IDLE, "and it is not walking anywhere")


func test_you_cannot_deploy_into_the_enemy_half(t) -> void:
	# It would make the phase a free first move rather than a chance to arrange one.
	var bs = _deploying()
	var mine = bs.regiments[bs.sorted_ids()[0]]
	var side: float = bs.side_of_owner(mine.owner_id)
	bs.place(mine, Vector2(side * -2000.0, 0.0), 0.0)
	t.ok(mine.pos.x * side >= Rules.DEPLOY_MARGIN,
		"clamped back to its own side (%.0f, side %.0f)" % [mine.pos.x, side])


func test_the_two_sides_are_on_opposite_halves(t) -> void:
	var bs = _deploying()
	t.near(bs.side_of_owner(1) * bs.side_of_owner(2), -1.0)


func test_placing_does_nothing_once_the_fight_has_started(t) -> void:
	var bs = _deploying()
	bs.say_ready(1)
	bs.say_ready(2)
	bs.step()
	var mine = bs.regiments[bs.sorted_ids()[0]]
	var was: Vector2 = mine.pos
	bs.place(mine, was + Vector2(0, 400), 0.0)
	t.eq(mine.pos, was, "you arrange the line before the battle, not during it")


func test_the_phase_survives_the_wire(t) -> void:
	# A client has to know not to draw a fight that is not happening yet, and a replay
	# has to reopen in the phase it was recorded in.
	var bs = _deploying()
	bs.say_ready(1)
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	t.eq(back.phase, BattleState.Phase.DEPLOY)
	t.ok(bool(back.ready.get(1, false)))
	t.ok(not bool(back.ready.get(2, false)))


func test_a_phase_nobody_has_heard_of_is_refused(t) -> void:
	var bs = _deploying()
	bs.phase = 77
	t.eq(Snapshot.decode_battle(Snapshot.encode_battle(bs)), null)


func test_the_deployed_order_round_trips(t) -> void:
	t.eq(Orders.decode(Orders.deployed(true))["type"], Orders.Type.DEPLOYED)
	t.eq(Orders.Type.ARMY_STANCE, 14)
	t.eq(Orders.Type.DEPLOYED, 15, "appended, like every other order type")


func test_the_ai_says_it_is_ready_at_once(t) -> void:
	# An AI that never did would sit out DEPLOY_SECONDS at the start of every battle.
	var bs = _deploying()
	var found := false
	for order in Ai.new(1).battle_orders(bs):
		if Orders.decode(order).get("type") == Orders.Type.DEPLOYED:
			found = true
	t.ok(found)


func _deploying():
	var bs = BattleState.new()
	bs.phase = BattleState.Phase.DEPLOY
	bs.add(1, &"spear", Vector2(-Rules.DEPLOY_SEPARATION * 0.5, 0), 0.0)
	bs.add(2, &"spear", Vector2(Rules.DEPLOY_SEPARATION * 0.5, 0), PI)
	for id in bs.sorted_ids():
		bs.regiments[id].target = bs.regiments[id].pos
	return bs
