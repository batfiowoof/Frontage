extends RefCounted
## Giving up the field.
##
## A battle used to end only by one side being wiped out or routed, or by running into
## BATTLE_TIME_LIMIT. Since morale started tracking casualties rather than the clock, a
## formed head-on fight runs past four minutes, so an army being taken apart had no way
## to save what was left of itself and an AI that was losing simply ground the fight out
## to the limit.
##
## Forfeiting is a real ending: survivors go home, the ground goes to the other side, and
## breaking contact costs the men who did not get away.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")
const Ai := preload("res://sim/ai.gd")
const Replay := preload("res://net/replay.gd")
const Snapshot := preload("res://net/snapshot.gd")


# --- the order ------------------------------------------------------------

func test_a_forfeit_survives_the_wire(t) -> void:
	var o := Orders.decode(Orders.forfeit(true))
	t.eq(o.get("type"), Orders.Type.FORFEIT)
	t.eq(o.get("confirm"), true)
	t.eq(Orders.decode(Orders.forfeit(false)).get("confirm"), false)


func test_a_forfeit_carries_no_owner(t) -> void:
	# Which seat quit is the sender the transport reports, never a field in the packet.
	# An owner on the wire would let anyone end anyone else's battle.
	var o := Orders.decode(Orders.forfeit(true))
	t.ok(not o.has("owner"), "no owner in the payload")
	t.ok(not o.has("seat"), "nor a seat")


func test_a_malformed_forfeit_is_refused(t) -> void:
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FORFEIT, 1])), {},
		"an int where the confirm flag belongs")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FORFEIT])), {},
		"and a payload too short to be an order at all")


func test_the_new_type_did_not_disturb_the_old_ones(t) -> void:
	# The ints go on the wire and into saved .rpl files, so FORFEIT had to be appended.
	# If this fails, every recording ever made now decodes as something else.
	t.eq(Orders.Type.BATTLE_MOVE, 0)
	t.eq(Orders.Type.READY, 3)
	t.eq(Orders.Type.SPLIT, 10)
	t.eq(Orders.Type.FORFEIT, 11, "appended, not inserted")


# --- falling back ---------------------------------------------------------

func _army_in_the_open(cs, owner := 1) -> Dictionary:
	for tile in cs.structures.size():
		if not cs.passable(tile) or cs.army_at(tile) != null or cs.settlement_at(tile) != null:
			continue
		var room := 0
		for n in cs.adjacent(tile):
			if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
				room += 1
		if room > 0:
			return cs.add_army(owner, tile, [&"spear", &"spear", &"archer"])
	return {}


func test_a_beaten_army_falls_back_to_an_adjacent_hex(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var a := _army_in_the_open(cs)
	var was: int = a["tile"]
	var to: int = cs.retreat(a["id"])
	t.ok(to >= 0, "it found somewhere to go")
	t.ok(to != was, "and it is not where the fight was")
	t.ok(Array(cs.adjacent(was)).has(to), "one hex, not a rout across the map")
	t.eq(int(a["tile"]), to, "the army actually moved")


func test_falling_back_costs_the_men_who_did_not_get_away(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var a := _army_in_the_open(cs)
	var before := Campaign.army_men(a)
	cs.retreat(a["id"])
	var after := Campaign.army_men(a)
	t.ok(after < before, "breaking contact costs men (%d -> %d)" % [before, after])
	t.ok(after > before / 2, "but it is stragglers, not a massacre")


func test_it_never_falls_back_onto_another_army(t) -> void:
	# Two armies cannot share a hex: army_at() returns the first one there, and movement,
	# collision and razing all lean on that.
	var cs = Campaign.generate([1, 2], 12345)
	var a := _army_in_the_open(cs)
	for n in cs.adjacent(int(a["tile"])):
		if cs.passable(n) and cs.army_at(n) == null and cs.settlement_at(n) == null:
			cs.add_army(2, n, [&"spear"])
	var to: int = cs.retreat(a["id"])
	t.ok(to < 0, "walled in by their armies, it stays where it is")
	t.ok(cs.armies.has(a["id"]), "and is not deleted for being cornered")


func test_a_cornered_army_is_not_destroyed(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var a := _army_in_the_open(cs)
	var men := Campaign.army_men(a)
	cs.retreat(a["id"])
	t.ok(cs.armies.has(a["id"]), "it survives to fight another turn")
	t.ok(Campaign.army_men(a) > 0, "with men in it (%d of %d)" % [Campaign.army_men(a), men])


func test_a_retreat_ends_the_army_turn(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var a := _army_in_the_open(cs)
	a["move_left"] = 3
	cs.retreat(a["id"])
	t.eq(int(a["move_left"]), 0, "you do not fall back and then go somewhere else")


# --- where a battle is allowed to end --------------------------------------

func test_a_battle_must_not_end_on_a_tick_it_has_already_taken_orders_on(t) -> void:
	# The trap the forfeit fell into. `Replay.replay()` runs `while bs.tick < ticks`, so
	# orders recorded AT the closing tick are never applied when it plays back. End a
	# battle from the order handler and the closing snapshot has that tick's orders in it
	# while the replay does not -- the recording no longer reproduces itself, and
	# `_keep_the_recording()` blames the sim for it.
	#
	# net.gd ends battles inside the tick loop, straight after a step, precisely so this
	# cannot happen. This test is here because nothing else would notice if it moved.
	var ids := PackedInt32Array()
	var bs = BattleState.new()
	ids.append(bs.add(1, &"spear", Vector2(-200, 0), 0.0).id)
	bs.add(2, &"spear", Vector2(200, 0), PI)

	var honest = Replay.new()
	honest.begin(Snapshot.encode_battle(bs))
	for n in 40:
		bs.step()
	honest.finish(Snapshot.encode_battle(bs), bs.tick)
	t.ok(honest.verify(), "closed straight after a step, it reproduces")

	var meddled = Replay.new()
	meddled.begin(Snapshot.encode_battle(bs))
	for n in 10:
		bs.step()
	var bytes := Orders.battle_move(ids, Vector2(300, 0), 0.0)
	meddled.note(bs.tick, 1, bytes)
	Replay.apply_order(bs, 1, bytes)
	meddled.finish(Snapshot.encode_battle(bs), bs.tick)
	t.ok(not meddled.verify(),
		"closed after taking an order on the same tick, it does NOT -- which is why a "
		+ "forfeit flags the battle and lets the tick loop end it")


# --- the AI knows when it is beaten ----------------------------------------

func _field(mine: Array, theirs: Array) -> Array:
	var bs = BattleState.new()
	var ours := []
	for i in mine.size():
		ours.append(bs.add(-1, mine[i], Vector2(-200.0, float(i) * 120.0), 0.0))
	for i in theirs.size():
		bs.add(2, theirs[i], Vector2(200.0, float(i) * 120.0), PI)
	return [bs, ours]


func _forfeits(bs) -> bool:
	for bytes: PackedByteArray in Ai.new(-1).battle_orders(bs):
		if Orders.decode(bytes).get("type") == Orders.Type.FORFEIT:
			return true
	return false


func test_an_even_fight_is_not_given_up(t) -> void:
	var f := _field([&"spear", &"spear"], [&"spear", &"spear"])
	t.ok(not _forfeits(f[0]), "nobody quits a fight they might win")


func test_being_outnumbered_alone_is_not_a_reason_to_quit(t) -> void:
	# A smaller army that is still formed can hold. Resigning on the headcount alone
	# would have the AI give up fights it was winning on ground it had chosen.
	var f := _field([&"spear"], [&"spear", &"spear", &"spear", &"pike"])
	t.ok(not _forfeits(f[0]), "still formed, still fighting")


func test_an_army_coming_apart_gives_up(t) -> void:
	var f := _field([&"spear", &"spear", &"spear"], [&"pike", &"pike", &"pike", &"pike"])
	var ours: Array = f[1]
	for r: Regiment in ours:
		r.strength = 12                    # cut to pieces
	ours[0].state = Regiment.State.ROUTING
	ours[1].state = Regiment.State.ROUTING
	t.ok(_forfeits(f[0]), "outnumbered AND coming apart is a beaten army")


func test_a_forfeiting_ai_says_nothing_else(t) -> void:
	# No point dressing a line that is about to walk off the field.
	var f := _field([&"spear", &"spear", &"spear"], [&"pike", &"pike", &"pike", &"pike"])
	var ours: Array = f[1]
	for r: Regiment in ours:
		r.strength = 12
	ours[0].state = Regiment.State.ROUTING
	ours[1].state = Regiment.State.ROUTING
	var out: Array = Ai.new(-1).battle_orders(f[0])
	t.eq(out.size(), 1, "one order, and the battle is over")
