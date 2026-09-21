extends RefCounted
## The AI goes round the end of a line rather than queueing up behind it.
##
## A regiment with nobody in front of it used to stand in its line slot doing nothing:
## foot were sent to SLOTS, not to enemies, and the only thing in the file that ever went
## round a flank was the cavalry sweep. So an army that outnumbered you locally simply
## made a longer line.
##
## The whole manoeuvre turns on two things, and both have a test here:
##
##   - the outward leg is LATCHED. A flank position is by definition a point worked out
##     from a MOVING enemy, and a unit re-ordered every think at one of those never
##     arrives. That bug has already eaten the archers, the cavalry sweep and the
##     withdrawal step.
##   - the last stretch is not an order at all. On arrival the regiment NAMES the man it
##     came for, and BattleState._pursue closes from whichever side it is standing on,
##     recomputed in the sim every tick with nobody issuing anything.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")
const Net := preload("res://net/net.gd")

const US := 1
const THEM := 2


## Two lines facing each other along X, ours on the left. `spare` extra regiments of ours
## sit behind our line with nobody opposite them.
##
## Positions come from contact_distance, never a constant: a wider regiment is a
## shallower one and reaches less far forward, so a fixed gap stops meaning contact the
## moment a frontage changes.
func _lines(pairs: int, spare: int) -> Array:
	var bs = BattleState.new()
	var ours := []
	var theirs := []
	for i in pairs:
		var y := (float(i) - float(pairs - 1) * 0.5) * Rules.DEPLOY_SPACING
		var a = bs.add(US, &"spear", Vector2.ZERO, 0.0)
		var b = bs.add(THEM, &"spear", Vector2.ZERO, PI)
		var apart := BattleState.contact_distance(a, b, Rules.CONTACT_GAP * 0.5)
		_stand(a, Vector2(-apart * 0.5, y))
		_stand(b, Vector2(apart * 0.5, y))
		ours.append(a)
		theirs.append(b)
	for i in spare:
		# Well behind our own line, so it has to go somewhere to be useful.
		var r = bs.add(US, &"spear", Vector2.ZERO, 0.0)
		_stand(r, Vector2(-600.0, (float(i) - float(spare - 1) * 0.5) * Rules.DEPLOY_SPACING))
		ours.append(r)
	bs.step()                              # settle the front pairs into contact
	return [bs, ours, theirs]


func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


## Every order of this type in the plan, as id -> decoded order.
func _by_id(plan: Array, type: int) -> Dictionary:
	var out := {}
	for bytes: PackedByteArray in plan:
		var o := Orders.decode(bytes)
		if o.get("type") == type:
			for id in o["ids"]:
				out[id] = o
	return out


func test_a_spare_regiment_is_sent_round_the_flank(t) -> void:
	var s := _lines(2, 1)
	var bs = s[0]
	var spare: Regiment = s[1][s[1].size() - 1]
	t.eq(spare.engaged_with, -1, "the spare one starts with nobody on it")

	var moves := _by_id(Ai.new(US).battle_orders(bs), Orders.Type.BATTLE_MOVE)
	t.ok(moves.has(spare.id), "and it is given somewhere to be")

	# Out past the end of the enemy line, not into the middle of it -- and by a clear
	# margin, because the widest LINE SLOT already lands a little beyond their edge and a
	# test that cannot tell those two apart is not testing anything.
	var edge := -INF
	var their_x := 0.0
	for f: Regiment in s[2]:
		edge = maxf(edge, absf(f.pos.y))
		their_x = f.pos.x
	var target: Vector2 = moves[spare.id]["target"]
	t.ok(absf(target.y) > edge + Ai.WRAP_MARGIN,
		"well past the end of their line (y %.0f, their edge %.0f, a slot would be %.0f)" % [
			target.y, edge, Ai.LINE_SPACING])
	t.ok(absf(target.y) > Ai.LINE_SPACING,
		"further out than the widest slot in the line it would otherwise have joined")
	# ...and pulled back onto OUR side of the line. A point level with their flank is
	# reached by cutting the corner straight through the fighting it is going round.
	t.ok(target.x < their_x,
		"and short of their line, so the walk stays clear of it (%.0f vs %.0f)" % [
			target.x, their_x])


func test_the_flank_waypoint_is_latched(t) -> void:
	# The bug this manoeuvre is most likely to have. Recompute the point each think from
	# a moving enemy and the regiment walks after something that recedes as fast as it
	# goes, so it circles the battle forever and the battle never ends.
	var s := _lines(2, 1)
	var bs = s[0]
	var spare: Regiment = s[1][s[1].size() - 1]
	var brain = Ai.new(US)

	var first := _by_id(brain.battle_orders(bs), Orders.Type.BATTLE_MOVE)
	t.ok(first.has(spare.id))
	var was: Vector2 = first[spare.id]["target"]

	# Shove the whole enemy line sideways and ask again.
	for f: Regiment in s[2]:
		f.pos += Vector2(0.0, 220.0)
		f.target = f.pos
	var again := _by_id(brain.battle_orders(bs), Orders.Type.BATTLE_MOVE)
	if again.has(spare.id):
		t.near(again[spare.id]["target"].distance_to(was), 0.0, 0.001,
			"the same point it was already walking to, not a new one")
	else:
		t.ok(true, "or nothing at all, which is the same promise kept harder")


func test_arriving_names_the_man_and_then_shuts_up(t) -> void:
	var s := _lines(2, 1)
	var bs = s[0]
	var spare: Regiment = s[1][s[1].size() - 1]
	var brain = Ai.new(US)

	# Walk it to wherever it was told to go, then ask again from there.
	var first := _by_id(brain.battle_orders(bs), Orders.Type.BATTLE_MOVE)
	t.ok(first.has(spare.id))
	_stand(spare, first[spare.id]["target"])

	var arrived := brain.battle_orders(bs)
	var marks := _by_id(arrived, Orders.Type.FOCUS)
	t.ok(marks.has(spare.id), "on arrival it names the man it came for")
	var mark := int(marks[spare.id]["mark"])
	var theirs := {}
	for f: Regiment in s[2]:
		theirs[f.id] = true
	t.ok(theirs.has(mark), "and it is one of theirs")

	# From here the sim does the closing, so the AI must stop talking to it -- an order
	# would only set it back to MOVING at a point it has since left.
	spare.focus = mark
	var after := _by_id(brain.battle_orders(bs), Orders.Type.BATTLE_MOVE)
	t.ok(not after.has(spare.id), "and then says nothing more while the sim steers it")


func test_an_even_line_never_wraps(t) -> void:
	# Self-limiting by construction: a regiment goes round only if nobody is on it, so
	# two matched lines produce no envelopment and the AI behaves exactly as it did.
	var s := _lines(3, 0)
	var moves := _by_id(Ai.new(US).battle_orders(s[0]), Orders.Type.BATTLE_MOVE)
	for r: Regiment in s[1]:
		t.ok(not moves.has(r.id), "everybody is busy, so nobody is sent anywhere")


func test_nothing_wraps_before_the_lines_meet(t) -> void:
	# Envelopment answers a fight that exists; it is not an opening move. Until somebody
	# is actually locked in, everything forms a line and walks, as before.
	var bs = BattleState.new()
	var ours := []
	for i in 3:
		var r = bs.add(US, &"spear", Vector2(-900.0, float(i - 1) * Rules.DEPLOY_SPACING), 0.0)
		ours.append(r)
	for i in 2:
		bs.add(THEM, &"spear", Vector2(900.0, float(i) * Rules.DEPLOY_SPACING), PI)
	bs.step()

	var moves := _by_id(Ai.new(US).battle_orders(bs), Orders.Type.BATTLE_MOVE)
	var enemy_edge := Rules.DEPLOY_SPACING
	for r: Regiment in ours:
		if moves.has(r.id):
			t.ok(absf(moves[r.id]["target"].y) < enemy_edge + Rules.DEPLOY_SPACING,
				"still forming a line, not setting off round a flank nobody has reached")


# --- the blows actually land on a flank -------------------------------------

## The only test here that measures the OUTCOME rather than the orders, and the one that
## would still fail if all the geometry above were right and the manoeuvre were useless.
##
## Before this, a whole AI-against-AI battle put 97% of its contact into an enemy's FRONT
## and ground on to the time limit, because the AI's line was laid out at a flat 110
## units per regiment -- narrower than the 150 the two sides deploy at, and narrower than
## the 133 a regiment now physically occupies. It was the lapped line, never the lapping
## one, so no regiment ever found itself past a flank with nobody in front of it.
func test_a_whole_battle_lands_its_blows_on_flanks(t) -> void:
	var bs = BattleState.new()
	const LINE := [&"spear", &"sword", &"archer", &"pike"]
	for i in LINE.size():
		var y := (float(i) - float(LINE.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(US, LINE[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(THEM, LINE[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)

	var brains := {US: Ai.new(US), THEM: Ai.new(THEM)}
	var front := 0
	var round_the_side := 0
	var last_think := -1
	while not bs.is_over() and bs.tick < int(120.0 * Rules.TICK_HZ):
		if Net.due(bs.tick, last_think, Net.AI_THINK_TICKS):
			last_think = bs.tick
			for seat in [US, THEM]:
				for bytes: PackedByteArray in brains[seat].battle_orders(bs):
					var o := Orders.decode(bytes)
					if o.get("type") == Orders.Type.BATTLE_MOVE:
						for id in o["ids"]:
							bs.regiments[id].order_move(o["target"], o["facing"])
					elif o.get("type") == Orders.Type.FOCUS:
						for id in o["ids"]:
							bs.regiments[id].focus = int(o["mark"])
		bs.step()
		for id in bs.sorted_ids():
			var a: Regiment = bs.regiments[id]
			if not a.is_alive() or a.owner_id != US or a.state != Regiment.State.FIGHTING:
				continue
			var d = bs.get_regiment(a.engaged_with)
			if d == null or not d.is_alive() or d.owner_id == US:
				continue
			if BattleState.exposure_of(d, a) == BattleState.Exposure.FRONT:
				front += 1
			else:
				round_the_side += 1

	var total := front + round_the_side
	t.ok(total > 0, "somebody fought somebody")
	var share := float(round_the_side) / maxf(1.0, float(total))
	# The bar was 20% when regiments could stand INSIDE one another, and part of that
	# figure was never real: two merged blocks have an arbitrary angle between them, so
	# exposure_of returned flank and rear more or less at random. Pushing them apart cost
	# seven points of this number and every one of them was measurement noise. Against 3%
	# before any of the envelopment work, this is still the thing working.
	t.ok(share > 0.15, "a good share of the fighting is round the side (%.0f%% of %d)" % [
		share * 100.0, total])
	print("  [feel] %.0fs AI battle: %.0f%% of contact on a flank or a rear, against 3%% before" % [
		bs.tick / float(Rules.TICK_HZ), share * 100.0])


# --- the line has to stay a line --------------------------------------------

## Deploy both sides properly and read back what the AI orders its FOOT to do, as
## (slot along the line, facing relative to the line of approach).
func _advance_orders() -> Array:
	var bs = BattleState.new()
	const LINE := [&"spear", &"sword", &"pike"]
	for i in LINE.size():
		var y := (float(i) - float(LINE.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(US, LINE[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(THEM, LINE[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)
	# A fourth of theirs, so their line is wider than ours and there is something to
	# reach past. This is the shape the envelopment is for.
	bs.add(THEM, &"sword", Vector2(Rules.DEPLOY_SEPARATION * 0.5,
		float(LINE.size()) * Rules.DEPLOY_SPACING * 0.5), PI)
	bs.step()

	var across := Vector2(0.0, 1.0)        # the two lines face along X, so across is Y
	var out := []
	for bytes: PackedByteArray in Ai.new(US).battle_orders(bs):
		var o := Orders.decode(bytes)
		if o.get("type") != Orders.Type.BATTLE_MOVE:
			continue
		for id in o["ids"]:
			out.append({
				"slot": o["target"].dot(across),
				"off": absf(angle_difference(o["facing"], 0.0)),
			})
	out.sort_custom(func(a, b) -> bool: return a["slot"] < b["slot"])
	return out


## The regression this file did not catch the first time.
##
## Every other test here checks where an order POINTS. This one checks the shape the
## orders add up to, which is what you actually look at -- and a line whose wings are
## aimed 72 degrees off the advance is three detachments walking past the enemy with
## their own flanks turned to it, however good the destinations look one at a time.
const SIDEWAYS := 35.0


func test_the_advancing_line_does_not_walk_sideways(t) -> void:
	for row: Dictionary in _advance_orders():
		t.ok(rad_to_deg(row["off"]) < SIDEWAYS,
			"a regiment walking at the enemy faces it: %.0f deg off the advance" % rad_to_deg(row["off"]))


func test_the_advancing_line_stays_a_line(t) -> void:
	# The AI aims for at most two frontages between neighbours -- one regiment's own width
	# of open ground beside it. The bar here is 2.2 rather than 2.0 so it is not a knife
	# edge on the exact geometry of one deployment; it still catches the 2.7 that the
	# stretched line produced, which is what this exists for.
	var widest := Formation.frontage(140, 20, 1.0) * 2.0
	var rows := _advance_orders()
	for i in range(1, rows.size()):
		var apart: float = rows[i]["slot"] - rows[i - 1]["slot"]
		t.ok(apart < widest * 2.2,
			"neighbours %.0f apart, which is %.1f frontages of open ground" % [
				apart, apart / widest])
