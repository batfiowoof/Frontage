extends RefCounted
## M19: archers, and why where you put them is the whole question.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")


## Archers at the origin, a target standing off at `range_fraction` of their reach.
func _range_pair(range_fraction := 0.5, mark_form := &"line") -> Array:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var reach := bows.range_of() * range_fraction
	var mark = bs.add(2, &"spear", Vector2(reach, 0), PI)
	mark.formation = mark_form
	return [bs, bows, mark]


func _run(bs, seconds: float) -> void:
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()


# --- shooting at all ------------------------------------------------------

func test_archers_shoot_what_is_in_front_of_them(t) -> void:
	var s := _range_pair()
	var ammo_before: int = s[1].ammo
	_run(s[0], 10.0)
	t.ok(s[2].strength < s[2].max_strength, "somebody should have been hit")
	t.ok(s[1].ammo < ammo_before, "and it should have cost arrows (%d -> %d)" % [ammo_before, s[1].ammo])
	print("  [feel] 10s of shooting at half range: %d of %d men down, %d volleys spent" % [
		s[2].max_strength - s[2].strength, s[2].max_strength, ammo_before - s[1].ammo])


func test_nothing_is_shot_out_of_range(t) -> void:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	bs.add(2, &"spear", Vector2(bows.range_of() * 2.0, 0), PI)
	_run(bs, 10.0)
	t.eq(bows.ammo, int(Rules.KINDS[&"archer"]["ammo"]), "no arrows wasted on the horizon")


func test_a_volley_takes_time_to_reload(t) -> void:
	var s := _range_pair()
	_run(s[0], 1.0)
	t.eq(s[1].ammo, int(Rules.KINDS[&"archer"]["ammo"]) - 1, "one volley in the first second")
	_run(s[0], 1.0)
	t.eq(s[1].ammo, int(Rules.KINDS[&"archer"]["ammo"]) - 1, "and not another until it has reloaded")


func test_arrows_run_out(t) -> void:
	# The target is propped up between volleys. Left alone it breaks and runs out of
	# range long before the quiver is empty, which is the right outcome and the wrong
	# experiment for this question.
	var s := _range_pair()
	for i in int(60.0 * Rules.TICK_HZ):
		s[2].strength = s[2].max_strength
		s[2].morale = Rules.MORALE_MAX
		s[2].state = Regiment.State.IDLE
		s[0].step()
	t.eq(s[1].ammo, 0, "a quiver is finite")

	var standing: int = s[2].strength
	_run(s[0], 20.0)
	t.eq(s[2].strength, standing, "and after that they are just bad infantry")


func test_shooting_frightens_as_well_as_kills(t) -> void:
	var s := _range_pair()
	_run(s[0], 10.0)
	t.ok(s[2].morale < Rules.MORALE_MAX, "being shot at is demoralising (%.0f)" % s[2].morale)


func test_closer_volleys_hit_harder(t) -> void:
	# Not closer than 0.3: a bow at fifteen percent of its reach is standing in the
	# enemy's front rank, and melee would be answering the question instead.
	var near := _range_pair(0.3)
	var far := _range_pair(0.98)
	_run(near[0], 12.0)
	_run(far[0], 12.0)
	t.ok(near[2].max_strength - near[2].strength > far[2].max_strength - far[2].strength,
		"point blank should beat extreme range (%d vs %d)" % [
			near[2].max_strength - near[2].strength, far[2].max_strength - far[2].strength])


# --- where you put them ---------------------------------------------------

func test_archers_do_not_shoot_through_their_own_line(t) -> void:
	var clear := _range_pair(0.5)
	var blocked := _range_pair(0.5)
	# A friendly regiment planted squarely between the bows and the enemy.
	blocked[0].add(1, &"spear", Vector2(blocked[1].range_of() * 0.25, 0), 0.0)

	_run(clear[0], 10.0)
	_run(blocked[0], 10.0)
	t.ok(clear[1].ammo < int(Rules.KINDS[&"archer"]["ammo"]), "the clear ones shot")
	t.eq(blocked[1].ammo, int(Rules.KINDS[&"archer"]["ammo"]),
		"and the blocked ones did not loose a single arrow into their own backs")


func test_a_friendly_off_to_one_side_does_not_block(t) -> void:
	var s := _range_pair(0.5)
	s[0].add(1, &"spear", Vector2(s[1].range_of() * 0.25, 400), 0.0)
	_run(s[0], 6.0)
	t.ok(s[1].ammo < int(Rules.KINDS[&"archer"]["ammo"]), "a man standing well aside is not in the way")


func test_a_friendly_behind_the_target_does_not_block(t) -> void:
	var s := _range_pair(0.5)
	s[0].add(1, &"spear", Vector2(s[1].range_of() * 1.5, 0), 0.0)
	_run(s[0], 6.0)
	t.ok(s[1].ammo < int(Rules.KINDS[&"archer"]["ammo"]), "what is past the enemy cannot be hit by mistake")


func test_archers_in_a_melee_stop_shooting(t) -> void:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var far_mark = bs.add(2, &"spear", Vector2(bows.range_of() * 0.5, 0), PI)
	# ...and somebody in their faces.
	bs.add(2, &"sword", Vector2(70, 0), PI)
	_run(bs, 8.0)
	t.eq(bows.ammo, int(Rules.KINDS[&"archer"]["ammo"]),
		"both hands are busy")
	t.ok(far_mark.strength == far_mark.max_strength or bows.state == Regiment.State.FIGHTING)


func test_archers_on_the_march_do_not_shoot(t) -> void:
	var s := _range_pair(0.5)
	s[1].order_move(Vector2(0, 600), PI / 2.0)
	_run(s[0], 4.0)
	t.eq(s[1].ammo, int(Rules.KINDS[&"archer"]["ammo"]), "a bow needs a moment and both hands")


# --- formation against arrows ---------------------------------------------

func test_loose_order_blunts_arrows_and_a_square_invites_them(t) -> void:
	var formed := _range_pair(0.5, &"line")
	var scattered := _range_pair(0.5, &"loose")
	var packed := _range_pair(0.5, &"square")
	_run(formed[0], 16.0)
	_run(scattered[0], 16.0)
	_run(packed[0], 16.0)

	var hit_line: int = formed[2].max_strength - formed[2].strength
	var hit_loose: int = scattered[2].max_strength - scattered[2].strength
	var hit_square: int = packed[2].max_strength - packed[2].strength
	t.ok(hit_loose < hit_line, "spread out, fewer are hit (%d vs %d)" % [hit_loose, hit_line])
	t.ok(hit_square > hit_line, "packed tight, more are (%d vs %d)" % [hit_square, hit_line])
	print("  [feel] 16s under arrows: line %d down, loose %d, square %d" % [hit_line, hit_loose, hit_square])


# --- aiming ---------------------------------------------------------------

func test_a_focus_order_picks_the_target(t) -> void:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var near_mark = bs.add(2, &"spear", Vector2(120, 0), PI)
	var far_mark = bs.add(2, &"spear", Vector2(300, 260), PI)
	bows.focus = far_mark.id
	_run(bs, 8.0)
	t.ok(far_mark.strength < far_mark.max_strength, "it shot what it was told to")
	t.eq(near_mark.strength, near_mark.max_strength, "and left the nearer one alone")


func test_focus_falls_back_when_the_target_is_gone(t) -> void:
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(150, 0), PI)
	bows.focus = 9999                       # a regiment that does not exist
	_run(bs, 6.0)
	t.ok(mark.strength < mark.max_strength, "an order to shoot at nobody is not an order to stand there")


func test_the_focus_order_validates(t) -> void:
	var order: Dictionary = Orders.decode(Orders.focus(PackedInt32Array([2]), 7))
	t.eq(order.get("type"), Orders.Type.FOCUS)
	t.eq(order.get("mark"), 7)
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FOCUS, PackedInt32Array(), 3])), {},
		"nobody to aim")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.FOCUS, PackedInt32Array([1]), "x"])), {},
		"a target that is not a regiment id")


func test_ammo_survives_the_wire(t) -> void:
	var s := _range_pair()
	_run(s[0], 8.0)
	var back = Snapshot.decode_battle(Snapshot.encode_battle(s[0]))
	t.ok(back != null)
	if back != null:
		t.eq(back.regiments[s[1].id].ammo, s[1].ammo)
		t.ok(back.regiments[s[1].id].ammo < int(Rules.KINDS[&"archer"]["ammo"]))
