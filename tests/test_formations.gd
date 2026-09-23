extends RefCounted
## M18: formations, and a frontage the player sets.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Formation := preload("res://sim/formation.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")


func _pair(a_form := &"line", b_form := &"line", a_kind := &"spear", b_kind := &"spear") -> Array:
	var bs = BattleState.new()
	var a = bs.add(1, a_kind, Vector2.ZERO, 0.0)
	var b = bs.add(2, b_kind, Vector2.ZERO, PI)
	a.formation = a_form
	a.width = a.natural_width()
	b.formation = b_form
	b.width = b.natural_width()
	_close_up(a, b)
	return [bs, a, b]


## Stand them just touching. A fixed gap will not do: contact is measured front rank to
## front rank, so a wider regiment is a shallower one and reaches less far forward. Two
## formations placed at the same centre distance may be locked together or not in contact
## at all depending only on their shapes.
func _close_up(a, b) -> void:
	var apart := BattleState.reach(a, BattleState.Exposure.FRONT) 		+ BattleState.reach(b, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	a.pos = Vector2(-apart * 0.5, 0)
	b.pos = Vector2(apart * 0.5, 0)
	a.target = a.pos
	b.target = b.pos


func _run(bs, seconds: float) -> void:
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()


# --- changing shape -------------------------------------------------------

func test_picking_a_formation_sets_the_frontage_it_wants(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	t.eq(r.formation, Rules.DEFAULT_FORMATION)
	var line_width: int = r.width
	t.ok(r.set_formation(&"column"))
	t.eq(r.formation, &"column")
	t.ok(r.width < line_width, "a column is narrower than a line (%d vs %d)" % [r.width, line_width])
	t.near(r.reforming, Rules.FORMATION_CHANGE_SECONDS, 0.001)


func test_re_forming_cannot_be_started_twice(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	t.ok(r.set_formation(&"column"))
	t.ok(not r.set_formation(&"square"), "one manoeuvre at a time")
	# Frontage is the exception, and deliberately so. Changing SHAPE is a manoeuvre and
	# costs; widening the line is dressing it, and costs nothing -- so it is never
	# refused, not even in the middle of a change of shape. Charging for it made the drag
	# that sets it expensive and silently rate-limited [ and ] to one press per six
	# seconds, with nothing anywhere to say why the second press did nothing.
	t.ok(r.set_width(30), "but the frontage is free, even mid-change")
	t.eq(r.width, 30)
	t.near(r.reforming, Rules.FORMATION_CHANGE_SECONDS, 0.001,
		"and it neither pays for the privilege nor extends what is already running")
	t.eq(r.formation, &"column")


func test_asking_for_the_shape_it_is_already_in_does_nothing(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	t.ok(not r.set_formation(&"line"))
	t.near(r.reforming, 0.0, 0.001, "and costs nothing")


func test_the_player_sets_the_frontage_within_bounds(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	t.ok(r.set_width(30))
	t.eq(r.width, 30)
	t.near(r.reforming, 0.0, 0.001, "dressing the line is free")
	t.near(r.order_factor(), 1.0, 0.001, "and costs nothing in the fight either")
	r.set_width(9999)
	t.eq(r.width, mini(Rules.MAX_WIDTH, r.max_strength), "capped, not absurd")
	r.set_width(-4)
	t.eq(r.width, Rules.MIN_WIDTH, "and never narrower than a file")


func test_re_forming_wears_off(t) -> void:
	var s := _pair()
	s[1].set_formation(&"square")
	t.ok(s[1].reforming > 0.0)
	_run(s[0], Rules.FORMATION_CHANGE_SECONDS + 1.0)
	t.near(s[1].reforming, 0.0, 0.001)
	t.near(s[1].order_factor(), 1.0, 0.001)


func test_a_regiment_caught_re_forming_fights_worse(t) -> void:
	var settled := _pair()
	_run(settled[0], 6.0)
	var settled_losses: int = settled[2].max_strength - settled[2].strength

	var caught := _pair()
	caught[1].reforming = Rules.FORMATION_CHANGE_SECONDS   # same shape, caught mid-change
	_run(caught[0], 6.0)
	var caught_losses: int = caught[2].max_strength - caught[2].strength
	t.ok(caught_losses < settled_losses,
		"changing shape in front of the enemy should cost you (%d dealt vs %d)" % [caught_losses, settled_losses])


# --- the shapes actually differ -------------------------------------------

func test_width_buys_output_and_depth_buys_endurance(t) -> void:
	# The whole reason a player is given the frontage to set.
	var wide := _pair()
	wide[1].width = 24
	_close_up(wide[1], wide[2])
	var narrow := _pair()
	narrow[1].width = 6
	_close_up(narrow[1], narrow[2])

	_run(wide[0], 12.0)
	_run(narrow[0], 12.0)
	var by_wide: int = wide[2].max_strength - wide[2].strength
	var by_narrow: int = narrow[2].max_strength - narrow[2].strength
	t.ok(by_wide > by_narrow,
		"a wider front kills faster (%d vs %d)" % [by_wide, by_narrow])
	print("  [feel] 12s: 24 files dealt %d, 6 files dealt %d" % [by_wide, by_narrow])


func test_a_column_moves_faster_than_a_line(t) -> void:
	var bs = BattleState.new()
	# Side by side, not on one spot: friends on the move now give way to each other, and
	# two stood on top of one another would be measuring that instead.
	var line = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var column = bs.add(1, &"spear", Vector2(0, 400), 0.0)
	column.formation = &"column"
	line.order_move(Vector2(100000, 0), 0.0)
	column.order_move(Vector2(100000, 400), 0.0)
	_run(bs, 1.0)
	t.ok(column.pos.x > line.pos.x * 1.15,
		"a column is on the road, not in a fight (%.0f vs %.0f)" % [column.pos.x, line.pos.x])


func test_a_square_has_no_flank_to_find(t) -> void:
	var bs = BattleState.new()
	var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	victim.formation = &"square"
	var flanker = bs.add(2, &"spear", Vector2(0, -75), PI / 2)
	t.eq(BattleState.exposure_of(victim, flanker), BattleState.Exposure.FLANK,
		"the geometry still says flank")

	var open := _pair()
	var open_victim = open[1]
	open[0].regiments[open[2].id].pos = Vector2(0, -75)
	open_victim.pos = Vector2.ZERO

	_run(bs, 10.0)
	t.ok(victim.morale > Rules.MORALE_MAX * 0.8,
		"but a square should barely notice (morale %.0f)" % victim.morale)


func test_loose_order_stands_wider_for_the_same_men(t) -> void:
	var tight = Regiment.make(1, 1, &"archer", Vector2.ZERO)
	var loose = Regiment.make(2, 1, &"archer", Vector2.ZERO)
	loose.formation = &"loose"
	t.ok(Formation.frontage(loose.max_strength, loose.width, loose.spacing())
		> Formation.frontage(tight.max_strength, tight.width, tight.spacing()),
		"loose order takes up more ground")
	t.ok(BattleState.reach(loose, BattleState.Exposure.FLANK)
		> BattleState.reach(tight, BattleState.Exposure.FLANK),
		"and is reached from further out")


func test_loose_order_is_poor_in_a_melee(t) -> void:
	var formed := _pair()
	var scattered := _pair(&"loose")
	_run(formed[0], 10.0)
	_run(scattered[0], 10.0)
	t.ok(scattered[2].max_strength - scattered[2].strength
		< formed[2].max_strength - formed[2].strength,
		"scattered men do not hold a fighting line")


# --- spears against horses ------------------------------------------------

func test_a_braced_formation_hurts_cavalry_and_is_hurt_less_by_it(t) -> void:
	# Shield wall rather than square: both brace, but a square is deliberately narrow, so
	# its seven files cannot out-kill a full twelve-file line however well it is set. The
	# square's job is not being flanked; the shield wall's is standing in front of horses.
	var open := _pair(&"line", &"line", &"spear", &"cavalry")
	var braced := _pair(&"shield", &"line", &"spear", &"cavalry")
	_run(open[0], 8.0)
	_run(braced[0], 8.0)

	var horses_lost_to_line: int = open[2].max_strength - open[2].strength
	var horses_lost_to_square: int = braced[2].max_strength - braced[2].strength
	t.ok(horses_lost_to_square > horses_lost_to_line,
		"set spears should cost a horseman more (%d vs %d)" % [horses_lost_to_square, horses_lost_to_line])

	var line_lost: int = open[1].max_strength - open[1].strength
	var square_lost: int = braced[1].max_strength - braced[1].strength
	t.ok(square_lost < line_lost,
		"and the bracing regiment should suffer less (%d vs %d)" % [square_lost, line_lost])
	print("  [feel] vs cavalry over 8s: a line loses %d and kills %d; a shield wall loses %d and kills %d" % [
		line_lost, horses_lost_to_line, square_lost, horses_lost_to_square])


func test_a_square_is_also_hard_for_cavalry_to_hurt(t) -> void:
	var open := _pair(&"line", &"line", &"spear", &"cavalry")
	var boxed := _pair(&"square", &"line", &"spear", &"cavalry")
	_run(open[0], 8.0)
	_run(boxed[0], 8.0)
	t.ok(boxed[1].max_strength - boxed[1].strength < open[1].max_strength - open[1].strength,
		"a square brings fewer spears to bear but is still set against a charge")


func test_bracing_does_nothing_against_infantry(t) -> void:
	var line := _pair(&"line", &"line", &"spear", &"sword")
	var square := _pair(&"square", &"line", &"spear", &"sword")
	_run(line[0], 8.0)
	_run(square[0], 8.0)
	# A square is a worse killer generally, so it must not somehow out-damage a line here.
	t.ok(square[2].max_strength - square[2].strength <= line[2].max_strength - line[2].strength,
		"bracing is for horses, not for men on foot")


# --- orders and the wire --------------------------------------------------

func test_the_formation_order_validates(t) -> void:
	var order: Dictionary = Orders.decode(Orders.set_formation(PackedInt32Array([3]), &"square", 14))
	t.eq(order.get("type"), Orders.Type.SET_FORMATION)
	t.eq(order.get("formation"), &"square")
	t.eq(order.get("width"), 14)

	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.SET_FORMATION,
		PackedInt32Array([1]), &"testudo", 10])), {}, "a formation that does not exist")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.SET_FORMATION,
		PackedInt32Array([1]), &"line", 9999])), {}, "an absurd frontage")
	t.eq(Orders.decode(var_to_bytes([Orders.VERSION, Orders.Type.SET_FORMATION,
		PackedInt32Array(), &"line", 10])), {}, "nobody to order")


func test_formation_survives_the_wire(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.set_formation(&"shield")
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	if back != null:
		t.eq(back.regiments[r.id].formation, &"shield")
		t.eq(back.regiments[r.id].width, r.width)
		t.near(back.regiments[r.id].reforming, r.reforming, 0.001)


func test_a_nonsense_formation_off_the_wire_is_refused(t) -> void:
	var bs = BattleState.new()
	bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var d = bytes_to_var(Snapshot.encode_battle(bs))
	var field := -1
	for i in Snapshot.REGIMENT_FIELDS.size():
		if Snapshot.REGIMENT_FIELDS[i][0] == "formation":
			field = i
	d[3][0][field] = &"testudo"
	t.eq(Snapshot.decode_battle(var_to_bytes(d)), null, "a formation nobody has heard of")

	var wide = bytes_to_var(Snapshot.encode_battle(bs))
	for i in Snapshot.REGIMENT_FIELDS.size():
		if Snapshot.REGIMENT_FIELDS[i][0] == "width":
			wide[3][0][i] = 5000
	t.eq(Snapshot.decode_battle(var_to_bytes(wide)), null, "a frontage wider than the field")
