extends RefCounted
## M14 part 2: soldiers step forward into the fighting line as front-rankers fall.
## bodies.gd touches no scene tree, so it tests headless like anything in sim/.

const Bodies := preload("res://view/battle/bodies.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")
const BattleState := preload("res://sim/battle_state.gd")
const BattleView := preload("res://view/battle/battle_view.gd")

const ID := 7


func _pose(strength: int, pos := Vector2.ZERO, facing := 0.0, hits := [],
		state := Regiment.State.FIGHTING, width := 12,
		threats := PackedVector2Array(), shapes := PackedVector3Array()) -> Dictionary:
	return {ID: {
		"pos": pos, "facing": facing, "owner": 1, "kind": &"spear",
		"strength": strength, "max_strength": 120, "morale": 100.0,
		"stamina": 1.0, "width": width, "state": state, "hits": hits,
		"threats": threats, "shapes": shapes,
	}}


## The footprint of a standard 120-man, 20-file block facing `facing`: half its depth
## along that, half its frontage across it. What the men bend their line around.
func _block(width := 20, facing := PI) -> Vector3:
	return Vector3(Formation.half_depth(120, width, 1.0),
		Formation.frontage(120, width, 1.0), facing)


## Settle a `width`-file regiment fighting a `foe` block at `enemy`, and hand back the men.
func _settle_against(width: int, enemy: Vector2, foe: Vector3) -> Bodies:
	var men = Bodies.new()
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, width), [1], 0.016)
	for i in 400:
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, width,
			PackedVector2Array([enemy]), PackedVector3Array([foe])), [1], 1.0 / 60.0)
	return men


## Men whose file index is at or above `from_file`, by man id.
func _men_in_files(men, from_file: int, to_file: int) -> Array:
	var out := []
	var where: Dictionary = men.places(ID)
	for man in where:
		if where[man].x >= from_file and where[man].x <= to_file:
			out.append(man)
	return out


func _men_at_depths(men, from_depth: int, to_depth: int) -> Array:
	var out := []
	var where: Dictionary = men.places(ID)
	for man in where:
		if where[man].y >= from_depth and where[man].y <= to_depth:
			out.append(man)
	return out


func _mean_angle_error(men, who: Array, want: float) -> float:
	if who.is_empty():
		return 0.0
	var facing: Dictionary = men.facings(ID)
	var worst := 0.0
	for man in who:
		worst = maxf(worst, absf(angle_difference(facing[man], want)))
	return worst


func _mean_y(men, who: Array) -> float:
	var where: Dictionary = men.positions(ID)
	var sum := 0.0
	for man in who:
		sum += where[man].y
	return 0.0 if who.is_empty() else sum / float(who.size())


## Settle with a threat standing off the regiment. IDLE keeps it to the one question --
## which way a man is looking -- with nothing marching anywhere while we ask it.
func _settle_with(men, threat: Vector2, seconds := 4.0, state := Regiment.State.IDLE) -> void:
	for i in int(seconds * 60.0):
		men.build(_pose(120, Vector2.ZERO, 0.0, [], state, 12,
			PackedVector2Array([threat])), [1], 1.0 / 60.0)


func _settle_still(men, seconds := 2.0) -> void:
	for i in int(seconds * 60.0):
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE), [1], 1.0 / 60.0)


func _front_men(men) -> Array:
	var out := []
	for man in men.places(ID):
		if men.places(ID)[man].y == 0:
			out.append(man)
	out.sort()
	return out


func _deepest(men) -> int:
	var worst := 0
	for place in men.places(ID).values():
		worst = maxi(worst, place.y)
	return worst


func _men_at_depth(men, d: int) -> int:
	var n := 0
	for place in men.places(ID).values():
		if place.y == d:
			n += 1
	return n


func _settle(men, strength: int, seconds := 3.0) -> void:
	var steps := int(seconds * 60.0)
	for i in steps:
		men.build(_pose(strength), [1], 1.0 / 60.0)


func _front_x(slots: PackedVector2Array) -> float:
	var best := -INF
	for s in slots:
		best = maxf(best, s.x)
	return best


func _mean_x(slots: PackedVector2Array) -> float:
	if slots.is_empty():
		return 0.0
	var sum := 0.0
	for s in slots:
		sum += s.x
	return sum / float(slots.size())


# --- bookkeeping ----------------------------------------------------------

func test_the_living_count_follows_strength(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	t.eq(men.living(ID), 120)
	men.build(_pose(83), [1], 0.016)
	t.eq(men.living(ID), 83, "men die one for one with the regiment's strength")
	men.build(_pose(0), [1], 0.016)
	t.eq(men.living(ID), 0)


func test_a_regiment_that_leaves_is_forgotten(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	men.build({}, [1], 0.016)
	t.eq(men.living(ID), 0, "no bookkeeping left behind for a regiment that is gone")


func test_the_buffer_carries_one_instance_per_living_man(t) -> void:
	var men = Bodies.new()
	var buffer: PackedFloat32Array = men.build(_pose(97), [1], 0.016)
	t.eq(buffer.size(), 97 * Bodies.FLOATS_PER_INSTANCE)


# --- the fighting line holds ---------------------------------------------

func test_the_front_rank_does_not_move_as_the_regiment_is_worn_down(t) -> void:
	# The whole complaint: slots used to be recomputed from CURRENT strength around a
	# fixed centre, so a regiment's drawn fighting line walked backwards as it bled.
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var fresh := _front_x(men.occupied_slots(ID))

	for strength in [90, 60, 30, 12]:
		men.build(_pose(strength), [1], 0.016)
		t.near(_front_x(men.occupied_slots(ID)), fresh, 0.001,
			"front rank must not budge at %d men" % strength)


func test_losses_are_taken_out_of_the_back_of_the_block(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var full_depth := _front_x(men.occupied_slots(ID)) - _rear_x(men.occupied_slots(ID))
	men.build(_pose(48), [1], 0.016)
	var thin_depth := _front_x(men.occupied_slots(ID)) - _rear_x(men.occupied_slots(ID))
	t.ok(thin_depth < full_depth,
		"a worn block is shallower, not shorter at the front (%.0f vs %.0f)" % [thin_depth, full_depth])


func _rear_x(slots: PackedVector2Array) -> float:
	var worst := INF
	for s in slots:
		worst = minf(worst, s.x)
	return worst if slots.size() > 0 else 0.0


func test_survivors_are_reassigned_forward_when_a_front_ranker_falls(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var before := _mean_x(men.occupied_slots(ID))
	men.build(_pose(108), [1], 0.016)          # one rank's worth of casualties
	var after := _mean_x(men.occupied_slots(ID))
	t.ok(after > before,
		"the survivors' slots must move toward the enemy, not away (%.2f -> %.2f)" % [before, after])


# --- movement -------------------------------------------------------------

func test_men_arrive_already_formed_rather_than_flying_in(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120, Vector2(900, -400)), [1], 0.016)
	var buffer: PackedFloat32Array = men.build(_pose(120, Vector2(900, -400)), [1], 0.016)
	# instance 0's origin is floats 3 and 7 of its block
	var first := Vector2(buffer[3], buffer[7])
	t.ok(first.distance_to(Vector2(900, -400)) < 100.0,
		"a regiment first seen far from the origin should not stream in from it")


func test_men_lag_behind_a_moving_regiment_and_then_catch_up(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	var start: Vector2 = Vector2(men.centre_of(ID, Vector2.ZERO))

	# One frame after a jump, the men should still be behind their regiment...
	men.build(_pose(120, Vector2(60, 0)), [1], 1.0 / 60.0)
	var lagging: Vector2 = men.centre_of(ID, Vector2.ZERO)
	t.ok(lagging.x > start.x, "they have started moving")
	t.ok(lagging.x < 60.0, "but have not teleported with it (%.1f)" % lagging.x)

	# ...and they WALK the rest, which now takes as long as walking it should. The
	# regiment is standing still here, so the men have only their dressing pace to close
	# sixty units with: three seconds of it, not the 0.83 an unbounded ease took for any
	# distance at all. The tolerance clears the idle shuffle, which never settles to
	# exactly zero on purpose.
	var walk := 60.0 / Rules.DRESS_SPEED
	for i in int((walk + 1.5) * 60.0):
		men.build(_pose(120, Vector2(60, 0)), [1], 1.0 / 60.0)
	t.near(men.centre_of(ID, Vector2.ZERO).x, 60.0, 3.0, "and then they catch up")


func test_a_teleported_regiment_snaps_rather_than_streaming(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	men.build(_pose(120, Vector2(5000, 5000)), [1], 1.0 / 60.0)
	t.near(men.centre_of(ID, Vector2.ZERO).x, 5000.0, 50.0,
		"an implausible jump is a teleport, not a sprint")


func test_the_block_turns_with_the_regiment(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	for i in 240:
		men.build(_pose(120, Vector2.ZERO, PI / 2.0), [1], 1.0 / 60.0)
	# Facing +Y, the formation's depth should now run along Y rather than X.
	var slots := men.occupied_slots(ID)
	t.ok(slots.size() > 0)
	t.near(men.centre_of(ID, Vector2.ZERO).length(), 0.0, 6.0,
		"turning in place keeps the block on its own position")


# --- the perf ceiling -----------------------------------------------------

func test_a_full_battle_of_men_fits_in_a_frame(t) -> void:
	# 16 regiments of 120 is a real battle. Each man costs a rotate, a lerp and twelve
	# floats, every frame, in GDScript -- this is the number that decides whether the
	# whole look survives or has to move into a shader.
	var men = Bodies.new()
	var pose := {}
	for i in 16:
		pose[i] = {
			"pos": Vector2(i * 180, 0), "facing": 0.3, "owner": 1 + i % 2, "kind": &"spear",
			"strength": 120, "max_strength": 120, "morale": 100.0,
			"stamina": 1.0, "width": 12, "state": Regiment.State.FIGHTING,
		}
	men.build(pose, [1, 2], 0.016)                 # first frame allocates the sets

	var frames := 30
	var began := Time.get_ticks_usec()
	for f in frames:
		men.build(pose, [1, 2], 1.0 / 60.0)
	var per_frame := float(Time.get_ticks_usec() - began) / float(frames) / 1000.0

	print("  [perf] 16 regiments x 120 men: %.2f ms/frame (%d bodies)" % [per_frame, 16 * 120])
	t.ok(per_frame < 16.0,
		"1920 bodies must fit in a 60fps frame, took %.2f ms" % per_frame)


# --- the file steps up ----------------------------------------------------

func test_the_man_directly_behind_steps_into_the_gap(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var before: Dictionary = men.places(ID)

	men.build(_pose(119), [1], 0.016)              # exactly one casualty
	var after: Dictionary = men.places(ID)
	t.eq(after.size(), 119)

	var fallen := -1
	for man in before:
		if not after.has(man):
			fallen = man
	t.ok(fallen >= 0, "somebody died")
	var lost: Vector2i = before[fallen]
	t.eq(lost.y, 0, "and he was standing at the head of his file")

	# The man who was immediately behind him is now standing in his place.
	var heir := -1
	for man in before:
		if before[man] == Vector2i(lost.x, 1):
			heir = man
	t.ok(heir >= 0, "there was a man behind him")
	if heir >= 0:
		t.eq(after[heir], Vector2i(lost.x, 0),
			"the man DIRECTLY BEHIND takes his place, not one from along the rank")


func test_a_death_leaves_every_other_file_exactly_where_it_was(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var before: Dictionary = men.places(ID)
	men.build(_pose(119), [1], 0.016)
	var after: Dictionary = men.places(ID)

	var lost_file := -1
	for man in before:
		if not after.has(man):
			lost_file = before[man].x
	for man in after:
		if before[man].x != lost_file:
			t.eq(after[man], before[man],
				"a man in another file must not so much as shuffle (man %d)" % man)


func test_a_worn_regiment_keeps_a_full_front_rank(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	for strength in [100, 80, 60, 40, 24]:
		men.build(_pose(strength), [1], 0.016)
		t.eq(_front_men(men).size(), 12,
			"all twelve files should still have a man in the line at %d" % strength)


func test_the_line_stays_dressed_as_it_is_worn_down(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	for strength in range(119, 47, -1):
		men.build(_pose(strength), [1], 0.016)
	var per_file: PackedInt32Array = men.men_per_file(ID)
	var deepest := 0
	var shallowest := 1 << 20
	for n in per_file:
		deepest = maxi(deepest, n)
		shallowest = mini(shallowest, n)
	t.ok(deepest - shallowest <= 2,
		"the file-closer should keep the files within a man or two (%d vs %d)" % [deepest, shallowest])


# --- hit from every side --------------------------------------------------

func test_a_flank_attack_eats_the_block_from_that_side(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	for strength in range(119, 99, -1):
		men.build(_pose(strength, Vector2.ZERO, 0.0, [BattleState.Side.LEFT]), [1], 0.016)

	var per_file: PackedInt32Array = men.men_per_file(ID)
	t.eq(per_file[0], 0, "the file on the struck side should be gone")
	t.eq(per_file[11], 10, "and the far side untouched")


func test_the_other_flank_eats_the_other_side(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	for strength in range(119, 99, -1):
		men.build(_pose(strength, Vector2.ZERO, 0.0, [BattleState.Side.RIGHT]), [1], 0.016)

	var per_file: PackedInt32Array = men.men_per_file(ID)
	t.eq(per_file[11], 0, "struck from the other side, the other end goes")
	t.eq(per_file[0], 10)


func test_a_rear_attack_takes_men_off_the_back(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var front_before := _front_men(men)
	var rear_rank := _deepest(men)
	var rear_before := _men_at_depth(men, rear_rank)

	for strength in range(119, 99, -1):
		men.build(_pose(strength, Vector2.ZERO, 0.0, [BattleState.Side.REAR]), [1], 0.016)

	t.eq(_front_men(men), front_before,
		"nobody in the front rank should have died to an attack from behind")
	t.ok(_men_at_depth(men, rear_rank) < rear_before,
		"the back rank is where the losses land (%d men there, was %d)" % [
			_men_at_depth(men, rear_rank), rear_before])
	t.eq(men.men_per_file(ID).size(), 12, "and the block is no narrower for it")


func test_a_frontal_attack_changes_who_is_standing_in_the_line(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var front_before := _front_men(men)
	for strength in range(119, 99, -1):
		men.build(_pose(strength, Vector2.ZERO, 0.0, [BattleState.Side.FRONT]), [1], 0.016)
	t.ok(_front_men(men) != front_before,
		"the men who were at the front should be the ones who fell")


# --- a man keeps his place --------------------------------------------------

## Files used to rotate while fighting -- the front man to the back, everyone else up
## one -- and he walked STRAIGHT BACK THROUGH HIS OWN FILE to get there, overlapping his
## file-mates on the way. A block of men constantly swapping places reads as a scatter
## rather than as a formation, so it is gone.
##
## This is the guard on that deletion: a man's place changes when somebody in front of
## him dies, and at no other time.
func test_nobody_swaps_places_while_fighting(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120), [1], 0.016)
	var before := men.places(ID)
	for i in 600:                          # ten seconds of standing in a melee
		men.build(_pose(120), [1], 1.0 / 60.0)
	t.eq(men.places(ID), before, "a man holds his file and his depth while he is fighting")
	t.eq(men.living(ID), 120, "and nobody is lost doing it")


func test_a_regiment_standing_idle_does_not_rotate(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE), [1], 0.016)
	var before := men.places(ID)
	for i in 600:
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE), [1], 1.0 / 60.0)
	t.eq(men.places(ID), before, "nobody swaps places when there is nothing to do")


# --- the re-dress clock -----------------------------------------------------

## Changing frontage costs nothing in the sim and gates nothing, but it is not instant to
## LOOK at. The clock is the client's, derived from the width it sees in the mirror.
func test_a_frontage_change_starts_a_re_dress_clock(t) -> void:
	var men = Bodies.new()
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 12), [1], 0.016)
	t.near(men.dressing(ID), 0.0, 0.001, "standing still, nothing to re-dress")

	# The clock is the WALK, not a constant: how far the end man goes over the pace he
	# goes it. Twelve files to twenty moves him 28 units, so it is 1.4s, and a bigger
	# reshape is a longer clock. It used to be a flat 3.0 whatever you asked for.
	var walk := absf(Formation.frontage(120, 20, 1.0) - Formation.frontage(120, 12, 1.0))
	var expect := walk / Rules.DRESS_SPEED
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 20), [1], 1.0 / 60.0)
	t.near(men.dressing(ID), expect, 0.05, "a new frontage starts a clock the size of the walk")
	t.eq(men.living(ID), 120, "and it is only a clock -- it loses nobody")

	var places := men.places(ID)
	for i in int((expect + 1.0) * 60.0):
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 20), [1], 1.0 / 60.0)
	t.near(men.dressing(ID), 0.0, 0.001, "it runs down and stops at zero")
	t.eq(men.places(ID), places, "and changes nobody's place on its way")


# --- re-forming, which M17 hands to the player ----------------------------

func test_changing_frontage_makes_the_men_walk_rather_than_teleport(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	var before: Vector2 = men.centre_of(ID, Vector2.ZERO)

	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 20), [1], 1.0 / 60.0)
	t.eq(men.living(ID), 120, "re-forming loses nobody")
	t.ok(men.centre_of(ID, Vector2.ZERO).distance_to(before) < 12.0,
		"one frame into a new frontage they should have barely moved")

	for i in 240:
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 20), [1], 1.0 / 60.0)
	var per_file: PackedInt32Array = men.men_per_file(ID)
	t.eq(per_file.size(), 20, "and then they are standing twenty across")
	t.eq(per_file[0], 6, "120 men in 20 files is six deep")


# --- men turn, the block does not -----------------------------------------

func test_with_nobody_about_every_man_keeps_the_regiments_facing(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	t.near(_mean_angle_error(men, men.facings(ID).keys(), 0.0), 0.0, 0.001,
		"no threat, no reason for anyone to look anywhere else")


func test_the_struck_flank_turns_and_the_far_side_does_not(t) -> void:
	# Regiment faces +X. Local +Y is toward higher files, so a threat at +Y is off its
	# right, and the right-hand files are the ones that should come round.
	var men = Bodies.new()
	_settle(men, 120)
	_settle_with(men, Vector2(0, 200))

	var struck := _men_in_files(men, 9, 11)
	var far := _men_in_files(men, 0, 2)
	t.ok(_mean_angle_error(men, struck, PI / 2.0) < deg_to_rad(25.0),
		"the files being hit should be facing their attacker")
	t.ok(_mean_angle_error(men, far, 0.0) < deg_to_rad(5.0),
		"the far end of the line has no business turning round")


func test_the_other_flank_turns_the_other_way(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	_settle_with(men, Vector2(0, -200))
	t.ok(_mean_angle_error(men, _men_in_files(men, 0, 2), -PI / 2.0) < deg_to_rad(25.0),
		"hit on the left, the left files come round")
	t.ok(_mean_angle_error(men, _men_in_files(men, 9, 11), 0.0) < deg_to_rad(5.0))


func test_something_behind_turns_the_back_ranks_about(t) -> void:
	var men = Bodies.new()
	_settle_still(men)
	_settle_with(men, Vector2(-320, 0))
	t.ok(_mean_angle_error(men, _men_at_depths(men, 8, 9), PI) < deg_to_rad(25.0),
		"the back ranks should face what is behind them")
	t.ok(_mean_angle_error(men, _men_at_depths(men, 0, 1), 0.0) < deg_to_rad(5.0),
		"while the front rank keeps fighting its own fight")


func test_turning_takes_time(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, 12,
		PackedVector2Array([Vector2(0, 200)])), [1], 1.0 / 60.0)
	t.ok(_mean_angle_error(men, _men_in_files(men, 9, 11), PI / 2.0) > deg_to_rad(60.0),
		"one frame in, nobody should have snapped round")


func test_the_struck_edge_leans_into_the_attack(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	var struck := _men_in_files(men, 10, 11)
	var before := _mean_y(men, struck)
	_settle_with(men, Vector2(0, 200))
	var after := _mean_y(men, struck)
	t.ok(after > before + 1.0,
		"the struck files should edge toward the fight (%.1f -> %.1f)" % [before, after])

	var far := _men_in_files(men, 0, 1)
	t.near(_mean_y(men, far), -38.5, 4.0, "the far files stay where they were standing")


func test_a_man_in_the_middle_of_the_block_is_left_alone(t) -> void:
	# The notice band is measured from the regiment's own closest approach, so a threat
	# at one end must not drag the whole formation round to look at it.
	var men = Bodies.new()
	_settle(men, 120)
	_settle_with(men, Vector2(0, 400))
	# Files 4 and 5 are genuinely inside the band at this range; 0 to 3 are not, and
	# nothing that far from the fighting should be looking at it.
	t.ok(_mean_angle_error(men, _men_in_files(men, 0, 3), 0.0) < deg_to_rad(5.0),
		"the far half of the line should not be rubbernecking at something 400 units away")


# --- the line bends round what it is fighting -------------------------------

## Distance from `enemy` to every front-rank man, as [closest, furthest].
func _front_rank_range(men, enemy: Vector2) -> Array:
	var where: Dictionary = men.positions(ID)
	var lo := INF
	var hi := -INF
	for man in _men_at_depths(men, 0, 0):
		var d: float = where[man].distance_to(enemy)
		lo = minf(lo, d)
		hi = maxf(hi, d)
	return [lo, hi]


## A flat line is NOT all the same distance from a point in front of it -- the middle is
## nearer than the ends. Bending it onto an arc of that radius is what brings the ends
## FORWARD, and the spread between nearest and furthest man collapsing is that crescent,
## as one number.
func test_a_wider_line_bows_round_a_narrower_enemy(t) -> void:
	# A flat line is NOT all one distance from a point in front of it -- the middle is
	# nearer than the ends. Bending it round him is what brings the ENDS forward, and the
	# spread between nearest and furthest man collapsing is that crescent, as one number.
	var enemy := Vector2(150, 0)
	var narrow := _block(10)                               # somebody half our width

	var flat = Bodies.new()
	flat.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, 24), [1], 0.016)
	for i in 240:
		flat.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, 24), [1], 1.0 / 60.0)
	var straight := _front_rank_range(flat, enemy)

	var bowed := _settle_against(24, enemy, narrow)
	var curved := _front_rank_range(bowed, enemy)

	t.ok(curved[1] - curved[0] < (straight[1] - straight[0]) * 0.75,
		"the front rank closes toward an even distance: spread %.0f, was %.0f" % [
			curved[1] - curved[0], straight[1] - straight[0]])
	t.ok(curved[1] < straight[1] - 4.0,
		"and the ENDS are the ones that came forward (%.0f, was %.0f)" % [
			curved[1], straight[1]])
	print("  [feel] a wider line: front rank %.0f..%.0f from the enemy, was %.0f..%.0f" % [
		curved[0], curved[1], straight[0], straight[1]])


func test_two_lines_of_the_same_width_do_not_both_wrap(t) -> void:
	# Both sides bending is self-defeating -- each is outside the other's block and they
	# meet in the open ground beside it, standing in one another. You envelop somebody by
	# OVERLAPPING him, and two lines of a width overlap nowhere.
	var enemy := Vector2(150, 0)
	var same := _block(20)
	var flat = Bodies.new()
	flat.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, 20), [1], 0.016)
	for i in 240:
		flat.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.FIGHTING, 20), [1], 1.0 / 60.0)
	var straight := _front_rank_range(flat, enemy)
	var level := _front_rank_range(_settle_against(20, enemy, same), enemy)
	t.near(level[1] - level[0], straight[1] - straight[0], 3.0,
		"an even matchup meets flat, and neither of them wraps")


func test_the_middle_of_the_line_does_not_move(t) -> void:
	# It has no offset along the line, so there is no "round" for it to go. If the centre
	# shifts, the bend is shoving the regiment about rather than curving it.
	var enemy := Vector2(100, 0)
	var flat = Bodies.new()
	_settle(flat, 120)
	var before := _mean_y(flat, _men_in_files(flat, 5, 6))

	var bowed = Bodies.new()
	_settle(bowed, 120)
	_settle_with(bowed, enemy)
	t.near(_mean_y(bowed, _men_in_files(bowed, 5, 6)), before, 6.0,
		"the middle files stay where they were standing")


func test_the_men_hug_the_enemy_without_walking_into_him(t) -> void:
	# The ends of the line are meant to come round onto his flanks -- that is the whole
	# manoeuvre. What they must never do is end up INSIDE him, which is what bending
	# round a regiment's CENTRE at a constant radius does: a block is 133 across and 45
	# deep, so an arc that clears its front by a comfortable margin is well inside its
	# flanks by the time it gets there. Two armies drawn on top of one another is the
	# opposite of looking like contact.
	var enemy := Vector2(120, 0)
	var shape := _block(10)                                # a narrow block to go round
	var half_d: float = shape.x
	var half_w: float = shape.y

	var men := _settle_against(40, enemy, shape)

	var wrapped := 0
	for man in men.positions(ID).values():
		var o: Vector2 = man - enemy
		t.ok(absf(o.x) > half_d - 1.0 or absf(o.y) > half_w - 1.0,
			"a man at (%.0f, %.0f) is standing inside a block that is %.0f by %.0f" % [
				o.x, o.y, half_d, half_w])
		if absf(o.y) > half_w * 0.6:
			wrapped += 1
	t.ok(wrapped > 0, "and some of them did come round onto his flank (%d of them)" % wrapped)


## The other side of that fight: a block at `at`, `width` files wide, facing back at the
## origin and bending round us exactly as we bend round it.
func _facing_us(at: Vector2, width: int) -> Bodies:
	var men = Bodies.new()
	men.build(_pose(120, at, PI, [], Regiment.State.FIGHTING, width), [1], 0.016)
	for i in 400:
		men.build(_pose(120, at, PI, [], Regiment.State.FIGHTING, width,
			PackedVector2Array([Vector2.ZERO]),
			PackedVector3Array([_block(width, 0.0)])), [1], 1.0 / 60.0)
	return men


## "Soldiers still overlap into each other though", as two numbers.
##
## Clearing the enemy's BOX is not the same as clearing his MEN: his front rank leans LEAN
## units out of its own box toward us while ours leans the same distance back at him, and
## CONTACT_GAP is 14 -- so seven units from each side closes the whole of it and the two
## front ranks land in the same square yard. `KEEP_CLEAR` is the clamp that stops it,
## applied last and against every enemy in contact rather than only the one a man is
## dealing with, because somebody caught between two of them is otherwise clear of one and
## standing inside the other. Nothing measured it, while CLAUDE.md quoted a figure from it.
func test_no_man_stands_on_an_enemy(t) -> void:
	# At the distance the SIM puts them, which is front rank to front rank and not centre
	# to centre -- two blocks placed at a fixed gap may be locked or not touching at all.
	var apart := Formation.half_depth(120, 20, 1.0) * 2.0 + Rules.CONTACT_GAP
	var theirs := Vector2(apart, 0)

	var ours := _settle_against(20, theirs, _block(20, PI))
	var them := _facing_us(theirs, 20)

	var closest := INF
	var overlapping := 0
	for mine in ours.positions(ID).values():
		for his in them.positions(ID).values():
			var d: float = mine.distance_to(his)
			closest = minf(closest, d)
			if d < BattleView.BODY_SIZE:
				overlapping += 1

	t.eq(overlapping, 0, "no man of ours stands on a man of theirs")
	t.ok(closest >= BattleView.BODY_SIZE,
		"the nearest pair is %.1f units apart, against a body %.0f across" % [
			closest, BattleView.BODY_SIZE])
	print("  [feel] closest man to an enemy man: %.1f units, %d overlapping pairs" % [
		closest, overlapping])


func test_the_bend_never_re_files_anybody(t) -> void:
	# The whole licence for this is that it is decoration. The moment it changed who
	# stood where, every invariant above it would be up for grabs.
	var flat = Bodies.new()
	_settle(flat, 120)
	var bowed = Bodies.new()
	_settle(bowed, 120)
	_settle_with(bowed, Vector2(100, 0))
	t.eq(bowed.places(ID), flat.places(ID), "same men, same files, same depths")
	t.eq(bowed.living(ID), flat.living(ID))


func test_with_nobody_there_the_block_is_a_block(t) -> void:
	# The curl must cost nothing when nothing is happening, or a regiment standing alone
	# would sit in a permanent bend around an enemy that is not there.
	var men = Bodies.new()
	_settle(men, 120)
	_settle_still(men, 4.0)
	var where: Dictionary = men.positions(ID)
	var slots: Dictionary = men.slots(ID)
	for man in where:
		t.ok(where[man].distance_to(slots[man]) < 1.0,
			"a man with nobody near him stands on his slot")


# --- turning right round is a relabel, not a rotation -----------------------

## The whole point. A rectangle rotated 180 degrees about its centre stands on exactly the
## same ground, so an about-face costs no rotation whatever -- the men hold their places
## and the rear rank becomes the front rank. Rotating them instead swings the end files
## 140 units across the field, which is what a spinning block looks like.
func test_turning_right_round_moves_nobody(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)
	var before: Dictionary = men.positions(ID)
	var places_before: Dictionary = men.places(ID)

	# The sim flips facing in a single tick; this is what the mirror then shows.
	for i in 120:
		men.build(_pose(120, Vector2.ZERO, PI, [], Regiment.State.IDLE), [1], 1.0 / 60.0)

	var after: Dictionary = men.positions(ID)
	var worst := 0.0
	for man in before:
		worst = maxf(worst, before[man].distance_to(after[man]))
	t.ok(worst < 1.0, "every man holds his ground through an about-face (worst %.3f)" % worst)
	t.eq(men.living(ID), 120, "and nobody is lost doing it")

	# ...and the ranks really did reverse: the man who led is now at the back.
	var places_after: Dictionary = men.places(ID)
	var ranks := int(ceil(120.0 / 12.0))
	var flipped := 0
	for man in places_before:
		if places_after[man].y == ranks - 1 - places_before[man].y \
				and places_after[man].x == 12 - 1 - places_before[man].x:
			flipped += 1
	t.eq(flipped, 120, "every man's file and depth turned end for end")


func test_a_quarter_turn_really_does_wheel(t) -> void:
	# The other half of the rule: 90 degrees is a genuine change of ground, so the block
	# must move. If this passed as well, the relabel would be firing on everything.
	var men = Bodies.new()
	_settle(men, 120)
	var before: Dictionary = men.positions(ID)
	for i in 240:
		men.build(_pose(120, Vector2.ZERO, PI / 2.0, [], Regiment.State.IDLE), [1], 1.0 / 60.0)
	var after: Dictionary = men.positions(ID)
	var worst := 0.0
	for man in before:
		worst = maxf(worst, before[man].distance_to(after[man]))
	t.ok(worst > 40.0, "a quarter turn is a wheel and the men go with it (%.0f)" % worst)


# --- the men have weight ----------------------------------------------------

## How far the fastest man ACTUALLY moved over one frame, as units a second.
##
## Measured from his position, never from whatever the code believes his speed to be: the
## first version of this asked `paces()` and passed happily with the speed limit deleted,
## because the intended speed is still computed whether or not anything obeys it.
func _step_fastest(men, pose: Dictionary, delta: float) -> float:
	var before: Dictionary = men.positions(ID)
	men.build(pose, [1], delta)
	var after: Dictionary = men.positions(ID)
	var top := 0.0
	for man in after:
		if before.has(man):
			top = maxf(top, before[man].distance_to(after[man]) / delta)
	return top


## The test that would have caught it. A man had NO speed limit: his pace was
## proportional to how far he was from his slot, so one 100 units out moved at 349 u/s and
## one 200 units out at 699, against a regiment that marches at 45. Rotation has always
## had a governor; translation had none.
func test_a_man_never_outruns_his_own_regiment(t) -> void:
	var men = Bodies.new()
	_settle(men, 120)

	# A reshape big enough that the end man has a hundred units to cover.
	var wide := _pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, 40)
	var worst := 0.0
	for i in 600:
		worst = maxf(worst, _step_fastest(men, wide, 1.0 / 60.0))
	t.ok(worst <= Rules.DRESS_SPEED * 1.6,
		"nobody exceeds a dressing pace while the regiment stands still (%.0f u/s)" % worst)

	# ...and the same through a quarter turn, where the outer files have furthest to go.
	var wheel = Bodies.new()
	_settle(wheel, 120)
	var turned := _pose(120, Vector2.ZERO, PI / 2.0, [], Regiment.State.IDLE)
	var spun := 0.0
	for i in 600:
		spun = maxf(spun, _step_fastest(wheel, turned, 1.0 / 60.0))
	t.ok(spun <= Rules.DRESS_SPEED * 1.6,
		"nor while the block wheels round (%.0f u/s)" % spun)
	print("  [feel] fastest man: %.0f u/s re-forming, %.0f u/s wheeling, against a %.0f u/s march" % [
		worst, spun, Rules.MOVE_SPEED])


## A bigger change takes longer. It used to take 0.83s whatever you asked for, because an
## exponential closes the same FRACTION of any gap per second -- which is exactly why
## re-forming looked instant however drastic it was.
func test_a_bigger_reshape_takes_longer(t) -> void:
	t.ok(_reshape_seconds(12, 14) > 0.0, "a small change still takes some time")
	var small := _reshape_seconds(12, 14)
	var large := _reshape_seconds(12, 40)
	t.ok(large > small * 2.0,
		"twelve files to forty takes far longer than twelve to fourteen (%.1fs against %.1fs)" % [
			large, small])
	print("  [feel] reshape: 12->14 files %.1fs, 12->40 files %.1fs" % [small, large])


## How long the men take to settle into `to` files, coming from `from`.
func _reshape_seconds(from: int, to: int) -> float:
	var men = Bodies.new()
	men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, from), [1], 0.016)
	for i in 240:
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, from), [1], 1.0 / 60.0)
	var slots: Dictionary = men.slots(ID)
	for i in 900:
		men.build(_pose(120, Vector2.ZERO, 0.0, [], Regiment.State.IDLE, to), [1], 1.0 / 60.0)
		var settled := true
		var where: Dictionary = men.positions(ID)
		slots = men.slots(ID)
		for man in where:
			# Five units, which is less than a file apart: "visibly standing in his
			# place", not "the exponential tail has finished". The approach eases in on
			# purpose, so the last unit takes as long as the first twenty.
			if where[man].distance_to(slots[man]) > 5.0:
				settled = false
				break
		if settled:
			return float(i) / 60.0
	return 15.0
