extends RefCounted
## Formations as SHAPES: a wedge is a point that bites in, a square is four faces.
##
## Every formation used to be the same rectangle with different numbers on it, so a
## wedge and a square were both just "a narrow block" -- on the screen and in the fight.
## These measure what the shapes DO, not only where the men stand.

const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Formation := preload("res://sim/formation.gd")
const Rules := preload("res://sim/rules.gd")
const Bodies := preload("res://view/battle/bodies.gd")


func _pair(a_form := &"line", b_form := &"line", a_kind := &"spear", b_kind := &"spear") -> Array:
	var bs = BattleState.new()
	var a = bs.add(1, a_kind, Vector2.ZERO, 0.0)
	var b = bs.add(2, b_kind, Vector2.ZERO, PI)
	a.formation = a_form
	a.width = a.natural_width()
	b.formation = b_form
	b.width = b.natural_width()
	var apart := BattleState.reach(a, BattleState.Exposure.FRONT) \
		+ BattleState.reach(b, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	_stand(a, Vector2(-apart * 0.5, 0))
	_stand(b, Vector2(apart * 0.5, 0))
	return [bs, a, b]


func _stand(r, at: Vector2) -> void:
	r.pos = at
	r.target = at


func _run(bs, seconds: float) -> void:
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()


## Seconds until `who` routs, or -1.
func _breaks(bs, who, limit: float) -> float:
	for i in int(limit * Rules.TICK_HZ):
		bs.step()
		if who.state == Regiment.State.ROUTING:
			return float(i) / Rules.TICK_HZ
	return -1.0


# --- the geometry ---------------------------------------------------------

func test_a_block_is_still_exactly_the_old_rectangle(t) -> void:
	# The guard on everything measured before shapes existed.
	for f in 12:
		for d in 10:
			t.eq(Formation.shaped_slot(&"block", f, d, 12, 10, 1.0),
				Formation.slot(f, d, 12, 10, 1.0), "file %d depth %d" % [f, d])


func test_a_wedge_leads_with_its_point(t) -> void:
	var middle := Formation.shaped_slot(&"wedge", 6, 0, 13, 10, 1.0)
	var end := Formation.shaped_slot(&"wedge", 0, 0, 13, 10, 1.0)
	t.ok(middle.x > end.x + Rules.RANK_SPACING,
		"the middle file's front man stands ahead of the end file's (%.0f vs %.0f)" % [middle.x, end.x])
	t.near(Formation.extent(&"wedge", 130, 13, 1.0).x, middle.x, 0.01,
		"and the point is exactly as far forward as the wedge reaches")


func test_a_hollow_square_reaches_the_same_every_way(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	r.formation = &"square"
	r.width = r.natural_width()
	var front := BattleState.reach(r, BattleState.Exposure.FRONT)
	t.near(BattleState.reach(r, BattleState.Exposure.FLANK), front, 0.001, "flank")
	t.near(BattleState.reach(r, BattleState.Exposure.REAR), front, 0.001, "rear")


func test_a_hollow_square_stands_on_four_faces(t) -> void:
	var faces := {}
	for s in 120:
		var at := Formation.shaped_slot(&"hollow", s % 11, s / 11, 11, 11, 1.0, 120)
		# Whichever axis he is further out along is the face he stands on.
		faces[Vector2i(signi(roundi(at.x)), 0) if absf(at.x) > absf(at.y) else Vector2i(0, signi(roundi(at.y)))] = true
		t.ok(at.length() > Rules.FILE_SPACING * 2.0, "nobody stands in the middle of it")
	t.eq(faces.size(), 4, "men on all four faces")


# --- the wedge in a fight ---------------------------------------------------

func test_a_wedge_meets_a_line_with_its_point_and_bites_in(t) -> void:
	var s := _pair(&"wedge")
	var wedge = s[1]
	var line = s[2]
	var apart: float = wedge.pos.distance_to(line.pos)
	s[0].step()
	t.eq(BattleState.files_engaged(wedge, BattleState.Exposure.FRONT), Rules.WEDGE_POINT_FILES,
		"only the point is in contact at first")
	_run(s[0], Rules.WEDGE_BITE_SECONDS)
	t.ok(wedge.bite > 0.9, "a pushing wedge drives in (bite %.2f)" % wedge.bite)
	t.ok(BattleState.files_engaged(wedge, BattleState.Exposure.FRONT) > Rules.WEDGE_POINT_FILES * 2,
		"and brings more of itself into the fight as it does")
	var now: float = wedge.pos.distance_to(line.pos)
	t.ok(now < apart - 10.0, "it is physically inside their line (%.0f from %.0f)" % [now, apart])
	t.eq(wedge.state, Regiment.State.FIGHTING, "and still in contact, not bounced off")
	print("  [feel] a wedge drives %.0f units into a line in %.0fs" % [apart - now, Rules.WEDGE_BITE_SECONDS])


func test_a_wedge_breaks_a_line_sooner_than_a_line_does(t) -> void:
	var wedge := _pair(&"wedge")
	var line := _pair()
	var by_wedge := _breaks(wedge[0], wedge[2], 120.0)
	var by_line := _breaks(line[0], line[2], 120.0)
	t.ok(by_wedge >= 0.0, "a line with a wedge in it breaks")
	t.ok(by_line < 0.0 or by_wedge < by_line, "and sooner (%.0fs vs %.0fs)" % [by_wedge, by_line])
	t.ok(wedge[1].state != Regiment.State.ROUTING, "and the wedge is still standing when it does")
	print("  [feel] a line breaks at %.0fs to a wedge, %s to a line" % [by_wedge,
		"never in 120s" if by_line < 0.0 else "%.0fs" % by_line])


func test_a_wedge_taken_in_the_side_suffers_for_it(t) -> void:
	var losses := {}
	for shape in [&"line", &"wedge"]:
		var bs = BattleState.new()
		var victim = bs.add(1, &"spear", Vector2.ZERO, 0.0)
		victim.formation = shape
		victim.width = victim.natural_width()
		var flanker = bs.add(2, &"spear", Vector2.ZERO, PI / 2)
		_stand(flanker, Vector2(0, -(BattleState.reach(victim, BattleState.Exposure.FLANK)
			+ BattleState.reach(flanker, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5)))
		_run(bs, 6.0)
		losses[shape] = victim.max_strength - victim.strength
	t.ok(losses[&"wedge"] > losses[&"line"],
		"the price of the point (%d lost against %d)" % [losses[&"wedge"], losses[&"line"]])


func test_a_wedge_wheels_rather_than_turning_about(t) -> void:
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.set_formation(&"wedge")
	r.reforming = 0.0
	r.target_facing = PI
	bs.step()
	t.ok(absf(angle_difference(r.facing, 0.0)) < 0.2,
		"one tick later it has barely turned (%.2f rad)" % r.facing)
	_run(bs, 20.0)
	t.ok(absf(angle_difference(r.facing, PI)) < 0.05, "and it does get there")


func test_changing_formation_takes_the_bite_away(t) -> void:
	var s := _pair(&"wedge")
	_run(s[0], 3.0)
	t.ok(s[1].bite > 0.0)
	s[1].reforming = 0.0
	s[1].set_formation(&"line")
	t.eq(s[1].bite, 0.0)


# --- the square in a fight --------------------------------------------------

func test_a_square_suffers_the_same_from_any_side(t) -> void:
	var losses := []
	for side in [0.0, PI / 2]:
		var bs = BattleState.new()
		var square = bs.add(1, &"spear", Vector2.ZERO, 0.0)
		square.formation = &"square"
		square.width = square.natural_width()
		var foe = bs.add(2, &"spear", Vector2.ZERO, side + PI)
		var d := BattleState.reach(square, BattleState.Exposure.FRONT) \
			+ BattleState.reach(foe, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
		_stand(foe, Vector2.from_angle(side) * d)
		_run(bs, 8.0)
		losses.append(square.max_strength - square.strength)
	t.ok(absi(losses[0] - losses[1]) <= 1, "front %d, flank %d" % [losses[0], losses[1]])


func test_horse_that_rides_into_a_square_loses_more_than_it_kills(t) -> void:
	var s := _pair(&"square", &"line", &"spear", &"cavalry")
	_run(s[0], 8.0)
	var square_lost: int = s[1].max_strength - s[1].strength
	var horse_lost: int = s[2].max_strength - s[2].strength
	t.ok(horse_lost > square_lost, "horse %d down, square %d" % [horse_lost, square_lost])
	print("  [feel] 8s of horse against a square: horse lose %d, square %d" % [horse_lost, square_lost])


# --- what the view draws ----------------------------------------------------

func _pose(formation: StringName, strength := 120) -> Dictionary:
	return {"pos": Vector2.ZERO, "facing": 0.0, "owner": 1, "kind": &"spear",
		"strength": strength, "max_strength": 120, "width": 12, "formation": formation,
		"spacing": float(Rules.FORMATIONS[formation]["spacing"]), "state": Regiment.State.IDLE}


func test_the_ghost_has_everybody_in_it(t) -> void:
	var row := {"target": Vector2(300, 40), "face": 0.0, "width": 12, "formation": &"line"}
	var men := Bodies.ghost_places(_pose(&"line", 97), row)
	t.eq(men.size(), 97, "one ghost a man")
	var mean := Vector2.ZERO
	for m in men:
		mean += m
	mean /= float(men.size())
	t.ok(mean.distance_to(row["target"]) < Rules.RANK_SPACING * 2.0,
		"centred on where the order sends them (%.1f off)" % mean.distance_to(row["target"]))


func test_a_wedge_ghost_is_a_wedge(t) -> void:
	var row := {"target": Vector2.ZERO, "face": 0.0, "width": 13, "formation": &"wedge"}
	var men := Bodies.ghost_places(_pose(&"wedge"), row)
	var front := men[0]
	for m in men:
		if m.x > front.x:
			front = m
	t.ok(absf(front.y) < Rules.FILE_SPACING, "its foremost man is on the middle file (y %.1f)" % front.y)


func test_no_tints_draws_exactly_what_it_always_did(t) -> void:
	var p := {1: _pose(&"line")}
	var plain := Bodies.new().build(p, [1], 0.016)
	var tinted := Bodies.new().build(p, [1], 0.016, {})
	t.eq(plain.size(), tinted.size())
	t.ok(plain == tinted, "byte for byte")
