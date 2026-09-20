extends RefCounted

const Snapshot := preload("res://net/snapshot.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Rules := preload("res://sim/rules.gd")


func _random_battle(n: int, seed_value: int):
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var bs = BattleState.new()
	var kinds := Rules.KINDS.keys()
	for i in n:
		var r = bs.add(
			1 if i % 2 == 0 else 2,
			kinds[rng.randi_range(0, kinds.size() - 1)],
			Vector2(rng.randf_range(-2000, 2000), rng.randf_range(-2000, 2000)),
			rng.randf_range(-PI, PI))
		r.strength = rng.randi_range(0, r.max_strength)
		r.morale = rng.randf_range(0.0, Rules.MORALE_MAX)
		r.state = rng.randi_range(0, Regiment.State.size() - 1)
		r.target = Vector2(rng.randf_range(-2000, 2000), rng.randf_range(-2000, 2000))
		r.target_facing = rng.randf_range(-PI, PI)
		r.engaged_with = rng.randi_range(-1, n)
	bs.tick = rng.randi_range(0, 100000)
	return bs


func _assert_same(t, a, b, label: String) -> void:
	t.eq(a.tick, b.tick, label + " tick")
	t.eq(a._next_id, b._next_id, label + " next id")
	t.eq(a.regiments.size(), b.regiments.size(), label + " regiment count")
	for id in a.sorted_ids():
		var x = a.regiments[id]
		var y = b.regiments.get(id)
		if y == null:
			t.ok(false, "%s: regiment %d vanished" % [label, id])
			continue
		for field in Snapshot.REGIMENT_FIELDS:
			t.eq(x.get(field[0]), y.get(field[0]), "%s: regiment %d field %s" % [label, id, field[0]])


func test_round_trip_preserves_every_field(t) -> void:
	for seed_value in [1, 7, 99]:
		var bs = _random_battle(12, seed_value)
		var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
		t.ok(back != null, "seed %d decoded" % seed_value)
		if back != null:
			_assert_same(t, bs, back, "seed %d" % seed_value)


func test_empty_battle_round_trips(t) -> void:
	var back = Snapshot.decode_battle(Snapshot.encode_battle(BattleState.new()))
	t.ok(back != null, "an empty battle is still a valid snapshot")
	t.eq(back.regiments.size(), 0)


func test_hundred_regiment_snapshot_size(t) -> void:
	var bs = _random_battle(100, 42)
	var bytes := Snapshot.encode_battle(bs)
	print("  [size] 100-regiment battle snapshot: %d bytes (%d B/regiment, %.1f KB/s at %d Hz)" % [
		bytes.size(), bytes.size() / 100,
		bytes.size() * (Rules.TICK_HZ / Rules.SNAPSHOT_EVERY_N_TICKS) / 1024.0,
		Rules.TICK_HZ / Rules.SNAPSHOT_EVERY_N_TICKS])
	t.ok(Snapshot.decode_battle(bytes) != null, "100 regiments round-trip")


func test_malformed_input_is_rejected_not_crashed(t) -> void:
	t.eq(Snapshot.decode_battle(PackedByteArray()), null, "empty")
	t.eq(Snapshot.decode_battle(var_to_bytes("not a snapshot")), null, "wrong root type")
	t.eq(Snapshot.decode_battle(var_to_bytes([1, 2])), null, "too few members")
	t.eq(Snapshot.decode_battle(var_to_bytes([999, 0, 1, []])), null, "wrong version")
	t.eq(Snapshot.decode_battle(var_to_bytes([Snapshot.VERSION, "x", 1, []])), null, "tick not an int")
	t.eq(Snapshot.decode_battle(var_to_bytes([Snapshot.VERSION, 0, 1, [[1, 2]]])), null, "short regiment row")
	t.eq(Snapshot.decode_battle(var_to_bytes([Snapshot.VERSION, 0, 1, ["nope"]])), null, "regiment not a row")


func test_duplicate_ids_are_rejected(t) -> void:
	var bs = _random_battle(2, 5)
	var data = bytes_to_var(Snapshot.encode_battle(bs))
	data[3][1][0] = data[3][0][0]               # second regiment claims the first one's id
	t.eq(Snapshot.decode_battle(var_to_bytes(data)), null, "duplicate ids would silently drop a regiment")


func test_wrong_field_type_is_rejected(t) -> void:
	var bs = _random_battle(1, 3)
	var data = bytes_to_var(Snapshot.encode_battle(bs))
	data[3][0][6] = "here"                      # pos, a Vector2
	t.eq(Snapshot.decode_battle(var_to_bytes(data)), null, "pos must be a Vector2")
