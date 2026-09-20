extends RefCounted
## M14 part 2: soldiers step forward into the fighting line as front-rankers fall.
## bodies.gd touches no scene tree, so it tests headless like anything in sim/.

const Bodies := preload("res://view/battle/bodies.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")

const ID := 7


func _pose(strength: int, pos := Vector2.ZERO, facing := 0.0) -> Dictionary:
	return {ID: {
		"pos": pos, "facing": facing, "owner": 1, "kind": &"spear",
		"strength": strength, "max_strength": 120, "morale": 100.0,
		"stamina": 1.0, "width": 12, "state": Regiment.State.FIGHTING,
	}}


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

	# ...and a couple of seconds later they should have arrived. The tolerance has to
	# clear the idle shuffle, which never settles to exactly zero on purpose.
	for i in 120:
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
