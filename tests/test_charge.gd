extends RefCounted
## The charge, and the two stances.
##
## Cavalry costs more than anything else on the field and had no moment that was its
## own: with no impact bonus a horse was fast infantry, and `brace` was a continuous
## spear-versus-horse modifier rather than something that stopped a charge. Arriving at
## a run now hits hard for CHARGE_SECONDS and then it is over, which is what makes WHEN
## you release the cavalry the decision -- and what makes the frontage a square or a
## shield wall gives up worth giving up.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Orders := preload("res://net/orders.gd")
const Snapshot := preload("res://net/snapshot.gd")


func _run(bs, ticks: int) -> void:
	for i in ticks:
		bs.step()


## Horse and foot far enough apart that the horse arrives at a gallop, stepped forward
## to the tick it lands on. Measuring from the start instead would count the ride in
## with the fight -- it takes nearly three seconds, which is the whole charge window.
func _a_charge(shape := &"line") -> Array:
	var bs = BattleState.new()
	var horse = bs.add(1, &"cavalry", Vector2(-300.0, 0.0), 0.0)
	var foot = bs.add(2, &"spear", Vector2(0.0, 0.0), PI)
	if shape != &"line":
		foot.set_formation(shape)
		foot.reforming = 0.0               # already formed; we are testing the impact
	# Ordered to where its front rank meets theirs, worked out AFTER any change of shape,
	# because the shape is what decides how far forward a regiment reaches. A constant
	# here stopped being contact at all the moment the default frontages moved.
	horse.order_move(Vector2(-BattleState.contact_distance(horse, foot,
		Rules.CONTACT_GAP * 0.5), 0.0), 0.0)
	# Twelve seconds, not six: the horse starts three hundred units out and the march is
	# slower than it was. It still arrives at a gallop, it just takes a gallop's time.
	for i in Rules.TICK_HZ * 12:
		bs.step()
		if horse.charge > 0.0:
			break
	return [bs, horse, foot]


## The same two regiments already locked together, so the horse never gets an impact.
func _a_shoving_match(shape := &"line") -> Array:
	var bs = BattleState.new()
	var horse = bs.add(1, &"cavalry", Vector2.ZERO, 0.0)
	var foot = bs.add(2, &"spear", Vector2(0.0, 0.0), PI)
	if shape != &"line":
		foot.set_formation(shape)
		foot.reforming = 0.0
	var at := Vector2(-BattleState.contact_distance(horse, foot, Rules.CONTACT_GAP * 0.5), 0.0)
	horse.pos = at
	horse.target = at
	bs.step()                              # settles both into FIGHTING without a march
	return [bs, horse, foot]


# --- the impact -----------------------------------------------------------

func test_arriving_at_a_run_is_a_charge(t) -> void:
	var s := _a_charge()
	t.ok(float(s[1].charge) > 0.0, "it arrived at a run")
	t.eq(s[1].state, Regiment.State.FIGHTING, "and the march became a fight")


func test_a_charge_hits_harder_than_a_shoving_match(t) -> void:
	# Same two regiments, same eight seconds. The only difference is whether the horse
	# arrived at a run or was already standing in the line.
	var window := int(Rules.CHARGE_SECONDS * Rules.TICK_HZ)
	var charged := _a_charge()
	_run(charged[0], window)
	var by_charge: int = charged[2].max_strength - charged[2].strength

	var standing := _a_shoving_match()
	_run(standing[0], window)
	var by_standing: int = standing[2].max_strength - standing[2].strength

	t.ok(by_charge > by_standing,
		"a charge is worth more than walking into them (%d dead vs %d)" % [by_charge, by_standing])
	print("  [feel] %.0fs of contact: a charge kills %d, a shoving match %d" % [
		Rules.CHARGE_SECONDS, by_charge, by_standing])


func test_it_is_over_in_a_few_seconds(t) -> void:
	var window := int(Rules.CHARGE_SECONDS * Rules.TICK_HZ)
	var s := _a_charge()
	_run(s[0], window)
	var early: int = s[2].max_strength - s[2].strength
	t.near(s[1].charge, 0.0, 0.06, "the charge has burnt out")
	var was: int = s[2].strength
	_run(s[0], window)
	var late: int = was - s[2].strength
	t.ok(early > late, "the first seconds are the expensive ones (%d then %d)" % [early, late])


func test_set_spears_stop_a_charge(t) -> void:
	# The whole reason to give up the frontage a square costs.
	var window := int(Rules.CHARGE_SECONDS * Rules.TICK_HZ)
	var open := _a_charge(&"line")
	_run(open[0], window)
	var through_a_line: int = open[2].max_strength - open[2].strength

	var braced := _a_charge(&"square")
	_run(braced[0], window)
	var through_a_square: int = braced[2].max_strength - braced[2].strength

	t.ok(through_a_square < through_a_line,
		"a braced block takes the sting out (%d dead vs %d)" % [through_a_square, through_a_line])
	print("  [feel] 4s of charge: a line loses %d, a square %d" % [
		through_a_line, through_a_square])


func test_a_regiment_already_fighting_does_not_re_charge(t) -> void:
	# Only a MOVING regiment gets the impact. Taking it whenever the contact list
	# changed would turn a one-off bonus into a permanent one.
	var s := _a_charge()
	_run(s[0], Rules.TICK_HZ * 6)
	t.near(s[1].charge, 0.0, 0.001, "spent")
	_run(s[0], Rules.TICK_HZ * 2)
	t.near(s[1].charge, 0.0, 0.001, "and it does not come back while it stands there")


# --- the stances ----------------------------------------------------------

func test_a_stance_survives_the_wire(t) -> void:
	var o := Orders.decode(Orders.stance(PackedInt32Array([3]), Regiment.Stance.GUARD))
	t.eq(o.get("type"), Orders.Type.STANCE)
	t.eq(o.get("mask"), Regiment.Stance.GUARD)
	t.eq(Orders.decode(Orders.stance(PackedInt32Array([3]), 99)), {}, "only the bits that exist")


func test_the_stance_reaches_the_mirror(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	r.stance = Regiment.Stance.SKIRMISH
	var mirror = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.eq(mirror.regiments[r.id].stance, Regiment.Stance.SKIRMISH)


func test_guard_holds_its_ground(t) -> void:
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(900.0, 0.0), PI)
	ours.focus = mark.id
	ours.stance = Regiment.Stance.GUARD
	var was: Vector2 = ours.pos
	_run(bs, Rules.TICK_HZ * 3)
	t.ok(ours.pos.distance_to(was) < 1.0, "told to hold, it holds, mark or no mark")


func test_skirmishers_give_ground(t) -> void:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var them = bs.add(2, &"spear", Vector2(bows.range_of() * 0.2, 0.0), PI)
	bows.stance = Regiment.Stance.SKIRMISH
	var before: float = bows.pos.distance_to(them.pos)
	_run(bs, Rules.TICK_HZ * 2)
	t.ok(bows.pos.distance_to(them.pos) > before, "it backs away from what is closing")


func test_an_empty_quiver_stops_the_skirmishing(t) -> void:
	# Out of arrows they are ordinary bad infantry and there is nothing left to
	# preserve, so they stop running and take their place in the line.
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	bs.add(2, &"spear", Vector2(120.0, 0.0), PI)
	bows.stance = Regiment.Stance.SKIRMISH
	bows.ammo = 0
	var was: Vector2 = bows.pos
	_run(bs, Rules.TICK_HZ * 2)
	t.ok(bows.pos.distance_to(was) < 40.0, "nothing left to protect, so it stands")
