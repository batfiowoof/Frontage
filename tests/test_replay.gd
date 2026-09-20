extends RefCounted
## M17: a battle you can watch twice.

const Replay := preload("res://net/replay.gd")
const Snapshot := preload("res://net/snapshot.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Orders := preload("res://net/orders.gd")
const Rules := preload("res://sim/rules.gd")

const LINE := [&"spear", &"sword", &"pike", &"archer", &"cavalry"]


## Fight a battle, recording it exactly the way net.gd does: note the order against the
## tick it was applied on, then apply it, then step.
func _fight_and_record(seconds: float, meddle := true) -> Array:
	var bs = BattleState.new()
	for i in LINE.size():
		var y := (float(i) - float(LINE.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(1, LINE[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(2, LINE[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)

	var r = Replay.new()
	r.begin(Snapshot.encode_battle(bs))

	var steps := int(seconds * Rules.TICK_HZ)
	for n in steps:
		if meddle and n % 37 == 0:
			# Both sides keep shoving regiments at each other, so the recording has
			# orders scattered across the whole fight rather than a tidy opening move.
			for seat in [1, 2]:
				var ids := PackedInt32Array()
				for id in bs.sorted_ids():
					if bs.regiments[id].owner_id == seat and bs.regiments[id].is_alive():
						ids.append(id)
				if ids.is_empty():
					continue
				var target := Vector2(120.0 if seat == 1 else -120.0, float((n % 5) - 2) * 60.0)
				var bytes := Orders.battle_move(ids, target, 0.0 if seat == 1 else PI)
				r.note(bs.tick, seat, bytes)
				Replay.apply_order(bs, seat, bytes)
		bs.step()

	r.finish(Snapshot.encode_battle(bs), bs.tick)
	return [r, bs]


# --- the point of the whole thing -----------------------------------------

func test_a_recorded_battle_replays_to_the_same_final_state(t) -> void:
	var fight := _fight_and_record(25.0)
	var r = fight[0]
	t.ok(r.orders.size() > 10, "the recording should have orders in it (%d)" % r.orders.size())
	t.ok(r.verify(), "a battle must reproduce itself exactly, or the format is worthless")

	var again = r.replay()
	t.ok(again != null)
	if again == null:
		return
	t.eq(again.tick, fight[1].tick)
	for id in fight[1].sorted_ids():
		t.eq(again.regiments[id].strength, fight[1].regiments[id].strength, "strength of %d" % id)
		t.eq(again.regiments[id].pos, fight[1].regiments[id].pos, "position of %d" % id)
		t.near(again.regiments[id].morale, fight[1].regiments[id].morale, 0.0001)


func test_replaying_twice_gives_the_same_answer_twice(t) -> void:
	var r = _fight_and_record(15.0)[0]
	t.eq(Snapshot.encode_battle(r.replay()), Snapshot.encode_battle(r.replay()))


func test_a_battle_with_no_orders_in_it_still_replays(t) -> void:
	var r = _fight_and_record(12.0, false)[0]
	t.eq(r.orders.size(), 0)
	t.ok(r.verify(), "two lines standing still is still a battle")


func test_the_orders_are_what_make_the_difference(t) -> void:
	# Drop the orders and the replay must come out somewhere else, or they were never
	# being applied and the whole thing only looks like it works.
	var r = _fight_and_record(25.0)[0]
	var without = Replay.new()
	without.opening = r.opening
	without.closing = r.closing
	without.ticks = r.ticks
	t.ok(not without.verify(), "a replay missing its orders must not match")


func test_a_recording_is_small(t) -> void:
	var r = _fight_and_record(25.0)[0]
	var bytes: PackedByteArray = r.to_bytes()
	print("  [size] a 25s battle recording: %d bytes (%d orders)" % [bytes.size(), r.orders.size()])
	t.ok(bytes.size() < 200000, "a battle should not cost a megabyte to remember")


# --- storage --------------------------------------------------------------

func test_a_recording_round_trips_through_bytes(t) -> void:
	var r = _fight_and_record(15.0)[0]
	var back = Replay.from_bytes(r.to_bytes())
	t.ok(back != null, "decodes")
	if back == null:
		return
	t.eq(back.opening, r.opening)
	t.eq(back.closing, r.closing)
	t.eq(back.ticks, r.ticks)
	t.eq(back.orders.size(), r.orders.size())
	t.ok(back.verify(), "and still reproduces the battle after a round trip")


func test_a_recording_survives_a_file(t) -> void:
	var r = _fight_and_record(10.0)[0]
	var path: String = r.save("user://replays/test_round_trip.rpl")
	t.ok(not path.is_empty(), "written")
	var back = Replay.load_from(path)
	t.ok(back != null, "read back")
	if back != null:
		t.ok(back.verify())
	DirAccess.remove_absolute(path)


func test_a_broken_recording_is_refused_rather_than_crashed(t) -> void:
	t.eq(Replay.from_bytes(PackedByteArray()), null, "empty")
	t.eq(Replay.from_bytes(var_to_bytes("nope")), null, "not an array")
	t.eq(Replay.from_bytes(var_to_bytes([Replay.VERSION, 1, 2])), null, "too few members")
	t.eq(Replay.from_bytes(var_to_bytes([99, PackedByteArray(), [], PackedByteArray(), 0])), null,
		"wrong version")
	t.eq(Replay.from_bytes(var_to_bytes([Replay.VERSION, PackedByteArray(), [], PackedByteArray(), -5])), null,
		"negative length")
	t.eq(Replay.from_bytes(var_to_bytes([Replay.VERSION, PackedByteArray(),
		[[0, 1]], PackedByteArray(), 10])), null, "a short order row")
	t.eq(Replay.from_bytes(var_to_bytes([Replay.VERSION, PackedByteArray(),
		[[9999, 1, PackedByteArray()]], PackedByteArray(), 10])), null,
		"an order stamped after the battle ended")
	t.eq(Replay.load_from("user://replays/there_is_no_such_file.rpl"), null, "a file that is not there")


func test_an_unrecorded_replay_saves_nothing(t) -> void:
	var r = Replay.new()
	t.ok(not r.recording())
	t.eq(r.save("user://replays/should_not_exist.rpl"), "", "nothing to save, nothing written")
	t.ok(not FileAccess.file_exists("user://replays/should_not_exist.rpl"))
