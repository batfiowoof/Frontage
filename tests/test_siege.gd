extends RefCounted
## Walls on the battlefield instead of as one number, and starving a town out.
##
## `defense` in STRUCTURES multiplied into an ordinary open-field fight, which made a
## siege the same battle with a modifier. A wall is a LINE the attacker cannot cross and
## cannot fight across, with one gate -- and under frontage-limited combat a gate IS the
## mechanic: a twenty-file line arrives at the gap and fights as however many files the
## gap is wide.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Rules := preload("res://sim/rules.gd")


## A defender behind a wall on the +x side, an attacker outside it on the -x side.
func _besieged() -> Array:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var attacker = bs.add(1, &"spear", Vector2(-Rules.DEPLOY_SEPARATION * 0.5, 0), 0.0)
	var defender = bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 120.0, 0), PI)
	attacker.target = attacker.pos
	defender.target = defender.pos
	return [bs, attacker, defender]


# --- the wall stands ------------------------------------------------------

func test_a_field_has_no_walls_on_it(t) -> void:
	# The default, and it has to be: every other battle in the tree is fought in the open.
	t.ok(BattleState.new().walls.is_empty())


func test_a_wall_is_two_segments_and_a_gap(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	t.eq(bs.walls.size(), 2)
	for w: Array in bs.walls:
		t.near(float(w[0]), Rules.WALL_STANDOFF, 0.001, "it stands in front of the defender")
		t.near(float(w[2]), Rules.WALL_STANDOFF)
		t.eq(float(w[4]), 0.0, "and it starts intact")
	t.ok(not bs.crosses_a_wall(Vector2(-400, 0), Vector2(400, 0)),
		"straight through the middle is the gate, and the gate is open")


func test_the_wall_is_on_the_defenders_side(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(-1.0)
	t.near(float(bs.walls[0][0]), -Rules.WALL_STANDOFF)


func test_you_cannot_walk_through_a_wall(t) -> void:
	var trio: Array = _besieged()
	var bs = trio[0]
	var attacker = trio[1]
	# Straight at the defender, well off the centre line so the gate is not the answer.
	attacker.pos = Vector2(-400, 300)
	attacker.order_move(Vector2(600, 300), 0.0)
	for i in Rules.TICK_HZ * 30:
		bs.step()
	t.ok(attacker.pos.x < Rules.WALL_STANDOFF,
		"it is still outside (x = %.0f, wall at %.0f)" % [attacker.pos.x, Rules.WALL_STANDOFF])


func test_you_can_walk_through_the_gate(t) -> void:
	var trio: Array = _besieged()
	var bs = trio[0]
	var attacker = trio[1]
	attacker.pos = Vector2(-400, 0)
	attacker.order_move(Vector2(Rules.WALL_STANDOFF + 60.0, 0), 0.0)
	for i in Rules.TICK_HZ * 40:
		bs.step()
	t.ok(attacker.pos.x > Rules.WALL_STANDOFF, "the gap is a way in (x = %.0f)" % attacker.pos.x)


func test_nobody_fights_through_a_wall(t) -> void:
	# Blocking only movement would have two regiments either side of one killing each
	# other across it, which is exactly what a wall exists to stop.
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var out = bs.add(1, &"spear", Vector2(Rules.WALL_STANDOFF - 20.0, 300), 0.0)
	var inside = bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 20.0, 300), PI)
	out.target = out.pos
	inside.target = inside.pos
	var men: int = inside.strength
	for i in Rules.TICK_HZ * 20:
		bs.step()
	t.eq(inside.strength, men, "close enough to touch, and a wall in between")
	t.eq(out.strength, out.max_strength)


func test_they_do_fight_in_the_gateway(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var out = bs.add(1, &"spear", Vector2(Rules.WALL_STANDOFF - 20.0, 0), 0.0)
	var inside = bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 20.0, 0), PI)
	out.target = out.pos
	inside.target = inside.pos
	for i in Rules.TICK_HZ * 20:
		bs.step()
	t.ok(inside.strength < inside.max_strength, "the gap is where the battle happens")


# --- breaching ------------------------------------------------------------

func test_a_ram_opens_a_wall(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var ram = bs.add(1, Rules.RAM, Vector2(Rules.WALL_STANDOFF - 20.0, 300), 0.0)
	ram.target = ram.pos
	t.ok(BattleState.standing(bs.walls[1]) and BattleState.standing(bs.walls[0]))
	for i in int(Rules.BREACH_SECONDS * Rules.TICK_HZ) + Rules.TICK_HZ:
		bs.step()
	var open := 0
	for w: Array in bs.walls:
		if not BattleState.standing(w):
			open += 1
	t.eq(open, 1, "one ram opens the one segment it was standing against")


func test_a_breached_wall_stops_blocking(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var through := Vector2(Rules.WALL_STANDOFF, 300)
	t.ok(bs.crosses_a_wall(Vector2(-400, 300), Vector2(400, 300)), "it is in the way")
	for w: Array in bs.walls:
		w[4] = 1.0
	t.ok(not bs.crosses_a_wall(Vector2(-400, 300), Vector2(400, 300)),
		"and once it is down it is not")


func test_a_spearman_cannot_knock_a_wall_down(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var foot = bs.add(1, &"spear", Vector2(Rules.WALL_STANDOFF - 20.0, 300), 0.0)
	foot.target = foot.pos
	for i in int(Rules.BREACH_SECONDS * Rules.TICK_HZ) * 2:
		bs.step()
	t.ok(BattleState.standing(bs.walls[0]), "that is what the ram is for")


func test_siegecraft_opens_it_faster(t) -> void:
	# The tech used to only divide the old flat wall number. It is the same idea applied
	# to the thing the wall actually became.
	var plain := _breach_progress([])
	var skilled := _breach_progress([&"armoury", &"siegecraft"])
	t.ok(skilled > plain, "trained engineers get through sooner (%.2f vs %.2f)" % [skilled, plain])


func _breach_progress(learned: Array) -> float:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	bs.techs[1] = learned
	var ram = bs.add(1, Rules.RAM, Vector2(Rules.WALL_STANDOFF - 20.0, 300), 0.0)
	ram.target = ram.pos
	for i in Rules.TICK_HZ * 8:
		bs.step()
	# Whichever segment it happened to be standing against: walls[0] runs down one side
	# of the gate and walls[1] up the other, and which one a given y falls on is not the
	# thing this test is about.
	return maxf(float(bs.walls[0][4]), float(bs.walls[1][4]))


func test_a_routing_ram_does_no_work(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var ram = bs.add(1, Rules.RAM, Vector2(Rules.WALL_STANDOFF - 20.0, 300), 0.0)
	ram.target = ram.pos
	ram.state = Regiment.State.ROUTING
	for i in Rules.TICK_HZ * 10:
		bs.step()
	t.eq(float(bs.walls[0][4]), 0.0, "men running away are not working the ram")


# --- deploying behind it --------------------------------------------------

func test_the_defender_cannot_set_up_in_front_of_his_own_wall(t) -> void:
	# It would hand the attacker the open-field fight the wall exists to refuse, and the
	# geometry makes it the easy mistake.
	var trio: Array = _besieged()
	var bs = trio[0]
	var defender = trio[2]
	bs.phase = BattleState.Phase.DEPLOY
	bs.place(defender, Vector2(20.0, 0), PI)
	t.ok(defender.pos.x >= Rules.WALL_STANDOFF + Rules.WALL_CLEAR,
		"clamped back behind it (x = %.0f)" % defender.pos.x)


func test_the_attacker_is_still_clamped_to_his_own_half(t) -> void:
	var trio: Array = _besieged()
	var bs = trio[0]
	var attacker = trio[1]
	bs.phase = BattleState.Phase.DEPLOY
	bs.place(attacker, Vector2(900.0, 0), 0.0)
	t.ok(attacker.pos.x <= -Rules.DEPLOY_MARGIN)


# --- the wire -------------------------------------------------------------

func test_walls_survive_the_wire(t) -> void:
	# A replay rebuilds the fight from its opening snapshot, and a battle fought through
	# a gate is a completely different battle from one fought in the open.
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	bs.walls[0][4] = 0.5
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	t.eq(back.walls.size(), 2)
	t.near(float(back.walls[0][4]), 0.5)


func test_a_wall_off_the_field_is_refused(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.walls[0][1] = Rules.BATTLE_HALF_EXTENT * 10.0
	t.eq(Snapshot.decode_battle(Snapshot.encode_battle(bs)), null)


func test_an_impossible_breach_is_refused(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	bs.walls[0][4] = 4.0
	t.eq(Snapshot.decode_battle(Snapshot.encode_battle(bs)), null)


# --- starving one out -----------------------------------------------------

func _with_a_town() -> Array:
	var cs = Campaign.generate([1, 2], 12345)
	var theirs := -1
	for s: Dictionary in cs.settlements:
		if s["owner"] == 2:
			theirs = int(s["tile"])
	# Their army is standing on it; move it off so ours can be there instead.
	for id in cs.sorted_army_ids():
		if cs.armies[id]["tile"] == theirs:
			cs.armies.erase(id)
	var mine: Dictionary = cs.add_army(1, theirs, [&"spear"])
	return [cs, mine, theirs]


func test_you_can_only_besiege_somebody_elses_town(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var a: Dictionary = cs.armies[cs.sorted_army_ids()[0]]
	t.ok(not cs.set_stance(1, a["id"], Campaign.Stance.BESIEGE),
		"there is no enemy town under it")


func test_besieging_starves_the_town(t) -> void:
	var trio: Array = _with_a_town()
	var cs = trio[0]
	var mine: Dictionary = trio[1]
	var town = cs.settlement_at(trio[2])
	town["pop"] = Rules.MAX_POP
	t.ok(cs.set_stance(1, mine["id"], Campaign.Stance.BESIEGE))
	var before: int = Campaign.pop_of(town)
	cs.end_turn()
	t.ok(Campaign.pop_of(town) < before, "the people leave")
	t.ok(Campaign.unrest_of(town) > 0, "and the rest lose patience")


func test_a_siege_eventually_takes_the_town(t) -> void:
	# It is the other half of a siege, and the half that needs no battle at all.
	var trio: Array = _with_a_town()
	var cs = trio[0]
	var mine: Dictionary = trio[1]
	var town = cs.settlement_at(trio[2])
	for i in 40:
		cs.set_stance(1, mine["id"], Campaign.Stance.BESIEGE)
		cs.end_turn()
		if town["owner"] != 2:
			break
	t.eq(town["owner"], 1, "starved out, and it goes to the besieger -- somebody was "
		+ "sitting outside the gate waiting for exactly this")
	t.eq(Campaign.unrest_of(town), Rules.UNREST_ON_CAPTURE,
		"with the same resentment any other conquest comes with")


func test_besieging_costs_the_turn(t) -> void:
	var trio: Array = _with_a_town()
	var cs = trio[0]
	var mine: Dictionary = trio[1]
	t.ok(cs.set_stance(1, mine["id"], Campaign.Stance.BESIEGE))
	t.eq(mine["move_left"], 0, "sitting down in front of a town is what you do that turn")


func test_the_stance_survives_the_wire(t) -> void:
	var trio: Array = _with_a_town()
	var cs = trio[0]
	var mine: Dictionary = trio[1]
	cs.set_stance(1, mine["id"], Campaign.Stance.BESIEGE)
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.eq(Campaign.stance_of(back.armies[mine["id"]]), Campaign.Stance.BESIEGE)
	var d := Orders.decode(Orders.army_stance(mine["id"], Campaign.Stance.BESIEGE))
	t.eq(d["stance"], Campaign.Stance.BESIEGE, "and the order still validates")


# --- the AI ---------------------------------------------------------------

func test_the_ai_sends_its_ram_at_the_wall_and_the_rest_at_the_gate(t) -> void:
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var ram = bs.add(1, Rules.RAM, Vector2(-400, 200), 0.0)
	var foot = bs.add(1, &"spear", Vector2(-400, -200), 0.0)
	bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 120.0, 0), PI)
	for r in [ram, foot]:
		r.target = r.pos
	var moves := {}
	for order in Ai.new(1).battle_orders(bs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.BATTLE_MOVE:
			moves[d["ids"][0]] = d["target"]
	t.ok(moves.has(ram.id) and moves.has(foot.id), "both were given somewhere to be")
	t.ok(absf(moves[foot.id].y) < Rules.WALL_GATE_HALF + 1.0,
		"the foot is going for the gate (y = %.0f)" % moves[foot.id].y)
	t.ok(absf(moves[ram.id].y) > Rules.WALL_GATE_HALF,
		"and the ram for the wall itself (y = %.0f)" % moves[ram.id].y)


func test_the_defender_does_not_assault_its_own_wall(t) -> void:
	# It is already where it wants to be, and coming out through its own gate throws
	# away the entire advantage.
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	var inside = bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 120.0, 0), PI)
	bs.add(1, &"spear", Vector2(-400, 0), 0.0)
	inside.target = inside.pos
	for order in Ai.new(2).battle_orders(bs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.BATTLE_MOVE:
			t.ok(d["target"].x > Rules.WALL_STANDOFF,
				"it stayed behind the wall (x = %.0f)" % d["target"].x)


func test_once_it_is_breached_the_ai_fights_the_ordinary_battle(t) -> void:
	# The assault is a branch and not a mode: the moment the last segment is open the AI
	# goes back to the fight it knows how to fight.
	var bs = BattleState.new()
	bs.lay_walls(1.0)
	for w: Array in bs.walls:
		w[4] = 1.0
	var foot = bs.add(1, &"spear", Vector2(-400, -300), 0.0)
	var mark = bs.add(2, &"spear", Vector2(Rules.WALL_STANDOFF + 120.0, 0), PI)
	foot.target = foot.pos
	mark.target = mark.pos
	var went := Vector2.INF
	for order in Ai.new(1).battle_orders(bs):
		var d := Orders.decode(order)
		if d.get("type") == Orders.Type.BATTLE_MOVE and d["ids"][0] == foot.id:
			went = d["target"]
	t.ok(went != Vector2.INF, "it was ordered somewhere")
	t.ok(went.x > Rules.WALL_STANDOFF, "and it is going at the enemy, not at a gap")
