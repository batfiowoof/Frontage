extends RefCounted
## Attack THAT one.
##
## `focus` was complete from encoder to sim -- validated, replayed, unit tested -- and
## had no caller anywhere in the view, so there was no way for a player to use it. It
## also steered nothing but arrows: melee picked whichever enemy was most nearly in
## front and never looked at it.
##
## Now it means "the enemy this regiment has been told to deal with", read in three
## places: the volley target, the melee opponent, and a chase that walks the regiment
## across the field to get there.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const Orders := preload("res://net/orders.gd")
const Snapshot := preload("res://net/snapshot.gd")


## Put a regiment somewhere and leave it there. `target` comes from `pos` in
## Regiment.make, so moving one without the other orders it to march back.
func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


func _run(bs, ticks: int) -> void:
	for i in ticks:
		bs.step()


# --- the wire -------------------------------------------------------------

func test_focus_survives_the_wire(t) -> void:
	var o := Orders.decode(Orders.focus(PackedInt32Array([4, 9]), 17))
	t.eq(o.get("type"), Orders.Type.FOCUS)
	t.eq(Array(o.get("ids")), [4, 9])
	t.eq(o.get("mark"), 17)


func test_the_mark_reaches_the_mirror(t) -> void:
	# It used to be server-side only, which was fine while it only chose whom to shoot.
	# Now that it sends a regiment across the field, a client has to be able to draw it.
	var bs = BattleState.new()
	var a = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var b = bs.add(2, &"spear", Vector2(400, 0), PI)
	a.focus = b.id
	var mirror = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(mirror != null, "it decodes")
	t.eq(mirror.regiments[a.id].focus, b.id, "and the mark came with it")


# --- melee ----------------------------------------------------------------

func test_a_regiment_fights_the_enemy_it_was_told_to(t) -> void:
	# Two enemies both in contact. Without a mark it takes whichever is squarest on;
	# with one it takes the man it was named.
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var square_on = bs.add(2, &"spear", Vector2.ZERO, PI)
	var off_to_one_side = bs.add(2, &"spear", Vector2.ZERO, PI)
	# Both at the distance that puts them in contact head-on, one of them swung round to
	# the side. The side one is comfortably inside contact at that radius because `ours`
	# reaches half its FRONTAGE sideways, which is much further than half its depth.
	var apart := BattleState.contact_distance(ours, square_on, Rules.CONTACT_GAP * 0.5)
	_stand(square_on, Vector2(apart, 0.0))
	_stand(off_to_one_side, Vector2(apart, 0.0).rotated(deg_to_rad(60.0)))

	_run(bs, 2)
	t.eq(ours.engaged_with, square_on.id, "by default, whoever is most nearly in front")

	ours.focus = off_to_one_side.id
	_run(bs, 2)
	t.eq(ours.engaged_with, off_to_one_side.id, "told otherwise, the one it was told")


func test_a_mark_that_is_not_in_contact_is_not_fought(t) -> void:
	# Naming somebody across the field must not reach through the man in front of you.
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var here = bs.add(2, &"spear", Vector2.ZERO, PI)
	var far = bs.add(2, &"spear", Vector2(2000.0, 0.0), PI)
	_stand(here, Vector2(BattleState.contact_distance(ours, here, Rules.CONTACT_GAP * 0.5), 0.0))
	ours.focus = far.id
	_run(bs, 2)
	t.eq(ours.engaged_with, here.id, "you fight who you can reach")


# --- the chase ------------------------------------------------------------

func test_a_marked_regiment_goes_after_it(t) -> void:
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(900.0, 0.0), PI)
	var before: float = ours.pos.distance_to(mark.pos)
	ours.focus = mark.id
	_run(bs, Rules.TICK_HZ * 8)
	t.ok(ours.pos.distance_to(mark.pos) < before - 100.0,
		"it closed the distance (%.0f -> %.0f)" % [before, ours.pos.distance_to(mark.pos)])


func test_the_chase_follows_a_moving_target(t) -> void:
	# Recomputed in the SIM each tick rather than re-issued as orders. A unit re-ordered
	# every tick at a point worked out from a moving enemy never arrives -- the archers,
	# the cavalry sweep and the withdrawal step have all been bitten by that.
	var bs = BattleState.new()
	var ours = bs.add(1, &"cavalry", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(700.0, 0.0), PI)
	ours.focus = mark.id
	for i in Rules.TICK_HZ * 14:
		mark.order_move(mark.pos + Vector2(0.0, 40.0), PI)
		bs.step()
	# It stops at contact range rather than on top of him, and he is still running, so
	# "caught" means closed from 700 to within a couple of regiment depths.
	t.ok(ours.pos.distance_to(mark.pos) < 200.0,
		"the horse ran the runner down (700 -> %.0f apart)" % ours.pos.distance_to(mark.pos))


func test_an_archer_that_can_already_reach_it_stands_still(t) -> void:
	# Chasing would keep it MOVING, and a regiment on the move never looses an arrow --
	# so the quiver would never empty and the whole point of naming a target is lost.
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(bows.range_of() * 0.7, 0.0), PI)
	bows.focus = mark.id
	var was: Vector2 = bows.pos
	_run(bs, Rules.TICK_HZ * 3)
	t.ok(bows.pos.distance_to(was) < 1.0, "it held its ground")
	t.ok(bows.ammo < int(Rules.KINDS[&"archer"]["ammo"]), "and it shot")


func test_the_mark_is_forgotten_when_he_is_gone(t) -> void:
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(900.0, 0.0), PI)
	ours.focus = mark.id
	mark.take_casualties(mark.strength)
	_run(bs, 2)
	t.eq(ours.focus, -1, "nothing to chase, so it stops chasing")


func test_a_router_does_not_chase(t) -> void:
	var bs = BattleState.new()
	var ours = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(900.0, 0.0), PI)
	ours.focus = mark.id
	ours.morale = Rules.MORALE_ROUT_THRESHOLD + 1.0
	ours.shock(2.0)
	t.eq(ours.state, Regiment.State.ROUTING)
	var before: float = ours.pos.distance_to(mark.pos)
	_run(bs, Rules.TICK_HZ * 2)
	t.ok(ours.pos.distance_to(mark.pos) > before, "broken men run away, orders or not")
