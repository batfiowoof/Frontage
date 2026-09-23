extends RefCounted
## Four peoples: who may raise what, who may learn what, and that none of it is lost on
## the wire, in a save, or in a battle.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const Save := preload("res://net/save.gd")
const Rules := preload("res://sim/rules.gd")


func _as(civ: StringName):
	var cs = Campaign.generate([1, 2], 12345, {1: civ})
	cs.gold[1] = 100000
	cs.research[1] = 100000
	return cs


func _capital(cs, owner := 1) -> int:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return s["tile"]
	return -1


# --- rosters --------------------------------------------------------------

func test_every_civ_has_its_own_and_nobody_elses(t) -> void:
	for civ: StringName in Rules.CIVS:
		var roster: Array = _as(civ).roster_of(1)
		var own := 0
		for kind: StringName in Rules.KINDS:
			var spec: Dictionary = Rules.KINDS[kind]
			var theirs: StringName = spec.get("civ", &"")
			if theirs == civ:
				own += 1
				t.ok(roster.has(kind), "%s raises %s" % [civ, kind])
				var gone: StringName = spec.get("replaces", &"")
				if gone != &"":
					t.ok(not roster.has(gone), "%s gave up %s for %s" % [civ, gone, kind])
			elif theirs != &"":
				t.ok(not roster.has(kind), "%s cannot raise %s's %s" % [civ, theirs, kind])
		t.eq(own, 2, "%s has two units of its own" % civ)


func test_nobody_in_particular_gets_the_generic_roster(t) -> void:
	var cs = _as(&"rome")
	for kind: StringName in cs.roster_of(Rules.BARBARIAN_SEAT):
		t.eq(Rules.KINDS[kind].get("civ", &""), &"", "a barbarian has no people: %s" % kind)


func test_the_starting_army_is_the_civs_own(t) -> void:
	var cs = _as(&"gauls")
	var kinds := []
	for a in cs.armies.values():
		if a["owner"] == 1:
			for r: Array in a["regiments"]:
				kinds.append(r[0])
	t.ok(kinds.has(&"warband"), "Gauls march out with warbands: %s" % [kinds])
	t.ok(not kinds.has(&"spear"))


# --- recruiting -----------------------------------------------------------

func test_a_foreign_unit_is_refused(t) -> void:
	var cs = _as(&"rome")
	t.ok(not cs.recruit(1, _capital(cs), &"warband"), "Rome cannot raise a Gaulish warband")
	t.ok(not cs.recruit(1, _capital(cs), &"sword"), "nor the swords it traded for legions")
	t.ok(cs.recruit(1, _capital(cs), &"legionary"))


func test_a_tech_gated_unit_waits_for_its_tech(t) -> void:
	var cs = _as(&"gauls")
	t.ok(not cs.recruit(1, _capital(cs), &"gaesatae"), "not before the druids")
	t.ok(cs.learn(1, &"druids"))
	t.ok(cs.recruit(1, _capital(cs), &"gaesatae"), "and then yes")


func test_the_barracks_unlocks_a_peoples_own_horse(t) -> void:
	# Every capital starts with a barracks beside it.
	var cs = _as(&"carthage")
	t.ok(cs.recruitable_at(_capital(cs)).has(&"numidian"))
	t.ok(not cs.recruitable_at(_capital(cs)).has(&"cavalry"), "numidians replace it")


func test_a_ram_can_be_raised_beside_a_barracks(t) -> void:
	# It could not, before: `recruitable_at` read the barracks' `unlocks` list, which
	# named no ram, so a kind that "requires a barracks" was raisable nowhere.
	var cs = _as(&"rome")
	t.ok(cs.recruitable_at(_capital(cs)).has(Rules.RAM))


# --- the trees ------------------------------------------------------------

func test_another_peoples_tech_cannot_be_learned(t) -> void:
	var cs = _as(&"rome")
	t.ok(not cs.can_learn(1, &"druids"), "Rome has no druids")
	t.ok(not cs.learn(1, &"druids"))
	for name: StringName in cs.learnable(1):
		var civ: StringName = Rules.TECHS[name].get("civ", &"")
		t.ok(civ == &"" or civ == &"rome", "never offered %s" % name)


func test_every_civ_has_a_tech_in_each_tree(t) -> void:
	for civ: StringName in Rules.CIVS:
		var trees := []
		for name: StringName in Rules.TECHS:
			if Rules.TECHS[name].get("civ", &"") == civ:
				trees.append(Rules.TECHS[name]["tree"])
		t.ok(trees.has("economy") and trees.has("battle"), "%s: %s" % [civ, trees])


func test_every_unit_gating_tech_belongs_to_that_unit_s_people(t) -> void:
	for kind: StringName in Rules.KINDS:
		var tech: StringName = Rules.KINDS[kind].get("tech", &"")
		if tech != &"":
			t.eq(Rules.TECHS[tech].get("civ", &""), Rules.KINDS[kind]["civ"], "%s" % kind)


# --- dealing and picking --------------------------------------------------

func test_unpicked_seats_are_dealt_by_seat(t) -> void:
	var cs = Campaign.generate([5, 9, 12], 1)
	t.eq(cs.civ_of(5), Rules.CIV_ORDER[0])
	t.eq(cs.civ_of(9), Rules.CIV_ORDER[1])
	t.eq(cs.civ_of(12), Rules.CIV_ORDER[2])


func test_a_pick_is_kept(t) -> void:
	var cs = Campaign.generate([5, 9], 1, {9: &"carthage"})
	t.eq(cs.civ_of(9), &"carthage")
	t.eq(cs.civ_of(5), Rules.CIV_ORDER[0])


func test_the_pick_order_round_trips_and_a_forged_civ_is_refused(t) -> void:
	var o := Orders.decode(Orders.pick_civ(-1, &"parthia"))
	t.eq(o["type"], Orders.Type.PICK_CIV)
	t.eq(o["seat"], -1)
	t.eq(o["civ"], &"parthia")
	t.ok(Orders.decode(Orders.pick_civ(1, &"atlantis")).is_empty(), "no such people")


# --- the wire and the save ------------------------------------------------

func test_civs_survive_the_campaign_wire(t) -> void:
	var cs = Campaign.generate([1, 2], 12345, {1: &"parthia", 2: &"carthage"})
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null)
	t.eq(back.civs, cs.civs)
	# ...and each player's own slice carries them too, or a client's roster is generic.
	var slice = Snapshot.decode_campaign(Snapshot.encode_campaign(cs, 1))
	t.eq(slice.civ_of(2), &"carthage")


func test_a_forged_civ_on_the_wire_is_refused(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	cs.civs[1] = &"atlantis"
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_a_save_hands_each_people_to_the_right_seat(t) -> void:
	var cs = Campaign.generate([7001, 7002], 771, {7001: &"gauls", 7002: &"rome"})
	var after = Save.of(cs, [7001, 7002]).restore([31, 4242])
	t.eq(after.civ_of(31), &"gauls")
	t.eq(after.civ_of(4242), &"rome")
	t.ok(not after.civs.has(7001), "nothing left on the old id")


# --- in battle ------------------------------------------------------------

func _duel(a: StringName, b: StringName, seconds := 30.0) -> Array:
	var bs = BattleState.new()
	var mine = bs.add(1, a, Vector2.ZERO, 0.0)
	var theirs = bs.add(2, b, Vector2.ZERO, PI)
	var apart := BattleState.reach(mine, BattleState.Exposure.FRONT) \
		+ BattleState.reach(theirs, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	mine.pos = Vector2(-apart * 0.5, 0)
	theirs.pos = Vector2(apart * 0.5, 0)
	mine.target = mine.pos
	theirs.target = theirs.pos
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()
	return [mine, theirs]


func test_a_legion_is_more_than_a_sword_with_a_new_name(t) -> void:
	var even := _duel(&"sword", &"sword")
	var legion := _duel(&"legionary", &"sword")
	var lost_even: int = even[0].max_strength - even[0].strength
	var lost_legion: int = legion[0].max_strength - legion[0].strength
	var killed_even: int = even[1].max_strength - even[1].strength
	var killed_legion: int = legion[1].max_strength - legion[1].strength
	print("  [feel] 30s against swords: a sword loses %d and kills %d, a legion loses %d and kills %d" % [
		lost_even, killed_even, lost_legion, killed_legion])
	t.ok(lost_legion < lost_even, "armour: fewer lost")
	t.ok(killed_legion > killed_even, "attack: more killed")


func test_the_missile_tech_is_read(t) -> void:
	var kills := []
	for learned in [[], [&"archery"]]:
		var bs = BattleState.new()
		bs.techs[1] = learned
		var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
		var mark = bs.add(2, &"spear", Vector2(bows.range_of() * 0.5, 0), PI)
		for i in int(8.0 * Rules.TICK_HZ):
			bs.step()
		kills.append(mark.max_strength - mark.strength)
	t.ok(kills[1] > kills[0], "archery kills more: %s" % [kills])
