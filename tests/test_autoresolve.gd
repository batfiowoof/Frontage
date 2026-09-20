extends RefCounted

const Autoresolve := preload("res://sim/autoresolve.gd")
const Rules := preload("res://sim/rules.gd")


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func _army(n: int, kind := &"spear") -> Array:
	var out := []
	for i in n:
		out.append(kind)
	return out


func test_power_adds_up_its_regiments(t) -> void:
	t.eq(Autoresolve.power([]), 0)
	t.eq(Autoresolve.power([&"spear", &"spear"]), 2 * int(Rules.KINDS[&"spear"]["strength"]))


func test_an_empty_army_never_wins(t) -> void:
	var r := Autoresolve.resolve([], _army(3), _rng(1))
	t.ok(not r["attacker_wins"], "nothing does not beat something")
	t.eq(r["defender_losses"], 0, "and the defender loses nobody to it")

	var r2 := Autoresolve.resolve(_army(3), [], _rng(1))
	t.ok(r2["attacker_wins"])
	t.eq(r2["attacker_losses"], 0)


func test_overwhelming_force_reliably_wins(t) -> void:
	var wins := 0
	for seed_value in 60:
		if Autoresolve.resolve(_army(8), _army(1), _rng(seed_value))["attacker_wins"]:
			wins += 1
	t.eq(wins, 60, "8 regiments against 1 must not lose to a lucky roll")


func test_an_even_fight_goes_both_ways(t) -> void:
	var wins := 0
	for seed_value in 60:
		if Autoresolve.resolve(_army(4), _army(4), _rng(seed_value))["attacker_wins"]:
			wins += 1
	t.ok(wins > 10 and wins < 50, "an even fight should not be decided by who moved first (%d/60)" % wins)


func test_losses_never_exceed_the_army(t) -> void:
	for seed_value in 100:
		var a := 1 + seed_value % 8
		var d := 1 + (seed_value * 3) % 8
		var r := Autoresolve.resolve(_army(a), _army(d), _rng(seed_value))
		t.ok(r["attacker_losses"] >= 0 and r["attacker_losses"] <= a,
			"attacker lost %d of %d" % [r["attacker_losses"], a])
		t.ok(r["defender_losses"] >= 0 and r["defender_losses"] <= d,
			"defender lost %d of %d" % [r["defender_losses"], d])


func test_the_winner_always_bleeds_less_in_proportion(t) -> void:
	for seed_value in 100:
		var a := 2 + seed_value % 7
		var d := 2 + (seed_value * 5) % 7
		var r := Autoresolve.resolve(_army(a), _army(d), _rng(seed_value))
		var attacker_share := float(r["attacker_losses"]) / float(a)
		var defender_share := float(r["defender_losses"]) / float(d)
		if r["attacker_wins"]:
			t.ok(attacker_share <= defender_share, "winner bled more, seed %d" % seed_value)
		else:
			t.ok(defender_share <= attacker_share, "winner bled more, seed %d" % seed_value)


func test_a_winner_is_never_wiped_out(t) -> void:
	# Otherwise both armies vanish and the tile is decided by nobody, which the
	# campaign has no rule for.
	for seed_value in 100:
		var a := 1 + seed_value % 8
		var d := 1 + (seed_value * 3) % 8
		var r := Autoresolve.resolve(_army(a), _army(d), _rng(seed_value))
		if r["attacker_wins"]:
			t.ok(a - r["attacker_losses"] >= 1, "the winning attacker kept somebody, seed %d" % seed_value)
		else:
			t.ok(d - r["defender_losses"] >= 1, "the winning defender kept somebody, seed %d" % seed_value)


func test_the_same_seed_gives_the_same_battle(t) -> void:
	t.eq(Autoresolve.resolve(_army(5), _army(4), _rng(77)),
		Autoresolve.resolve(_army(5), _army(4), _rng(77)),
		"a replayable battle is a debuggable battle")
