extends RefCounted
## A regiment carries what it learned into the next battle.
##
## Before this, the only thing an army brought home from a fight was a smaller headcount,
## so a regiment raised fresh at full strength was strictly better than one that had
## survived two battles, and there was never a reason to pull a battered unit out of the
## line rather than spend it.

const Campaign := preload("res://sim/campaign_state.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Rules := preload("res://sim/rules.gd")


## Two spears placed front rank to front rank, exactly as test_techs does it: positioned
## from reach(), never from a fixed gap, because a regiment's shape decides how far
## forward it stands.
func _duel(my_xp: int, seconds := 50.0) -> Array:
	var bs = BattleState.new()
	var mine = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	var theirs = bs.add(2, &"spear", Vector2.ZERO, PI)
	var apart := BattleState.reach(mine, BattleState.Exposure.FRONT) \
		+ BattleState.reach(theirs, BattleState.Exposure.FRONT) + Rules.CONTACT_GAP * 0.5
	mine.pos = Vector2(-apart * 0.5, 0)
	theirs.pos = Vector2(apart * 0.5, 0)
	mine.target = mine.pos
	theirs.target = theirs.pos
	mine.xp = my_xp
	for i in int(seconds * Rules.TICK_HZ):
		bs.step()
	return [bs, mine, theirs]


# --- the reading ----------------------------------------------------------

func test_a_green_regiment_is_worth_exactly_what_it_always_was(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	t.near(r.seasoning(), 0.0)
	t.near(r.veteran_attack(), 1.0, 0.0001, "no xp changes nothing at all")
	t.near(r.veteran_resolve(), 1.0)


func test_seasoning_is_capped(t) -> void:
	var r = Regiment.make(1, 1, &"spear", Vector2.ZERO)
	r.xp = int(Rules.VETERAN_KILLS) * 100
	t.near(r.seasoning(), 1.0, 0.0001, "a regiment that has killed an army is not a god")
	t.near(r.veteran_attack(), Rules.VETERAN_ATTACK)
	t.near(r.veteran_resolve(), Rules.VETERAN_RESOLVE)


# --- what it is worth in a fight ------------------------------------------

func test_a_veteran_beats_an_identical_green_regiment(t) -> void:
	var green := _duel(0)
	var blooded := _duel(int(Rules.VETERAN_KILLS))
	t.ok(blooded[1].strength > green[1].strength,
		"a veteran keeps more men (%d vs %d)" % [blooded[1].strength, green[1].strength])
	t.ok(blooded[2].strength < green[2].strength,
		"and leaves fewer of them (%d vs %d)" % [blooded[2].strength, green[2].strength])
	t.ok(blooded[1].morale > green[1].morale, "and holds together better")
	print("  [feel] 50s duel: green keeps %d men and leaves the enemy %d;" % [
		green[1].strength, green[2].strength])
	print("         a full veteran keeps %d and leaves them %d" % [
		blooded[1].strength, blooded[2].strength])


func test_it_is_worth_about_as_much_as_a_tech_and_not_more(t) -> void:
	# The bar that keeps this from deciding campaigns in the first fight: a veteran
	# should win a duel, not walk through one. If a full bar ever leaves the enemy at
	# less than half what a green regiment leaves them, it has stopped being an edge.
	var green := _duel(0)
	var blooded := _duel(int(Rules.VETERAN_KILLS))
	t.ok(blooded[2].strength > green[2].strength / 2,
		"a veteran is an edge, not a different game (%d vs %d)" % [
			blooded[2].strength, green[2].strength])


# --- earning it -----------------------------------------------------------

func test_fighting_earns_it(t) -> void:
	var fought := _duel(0, 20.0)
	t.ok(fought[1].xp > 0, "a regiment that killed men has learned something")
	t.ok(fought[1].xp <= fought[2].max_strength - fought[2].strength + 1,
		"and never more than the men it actually killed (%d xp, %d dead)" % [
			fought[1].xp, fought[2].max_strength - fought[2].strength])


func test_standing_about_earns_nothing(t) -> void:
	var bs = BattleState.new()
	var idle = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	for i in Rules.TICK_HZ * 10:
		bs.step()
	t.eq(idle.xp, 0, "there is no xp for being on the field")


func test_archers_learn_their_trade(t) -> void:
	# Shooting kills men too, and an archer that could never earn a chevron would be
	# the one unit in the game whose veterancy depended on it running out of arrows.
	var bs = BattleState.new()
	var bows = bs.add(1, &"archer", Vector2.ZERO, 0.0)
	var mark = bs.add(2, &"spear", Vector2(float(Rules.KINDS[&"archer"]["range"]) * 0.5, 0), PI)
	mark.target = mark.pos
	for i in Rules.TICK_HZ * 12:
		bs.step()
	t.ok(mark.strength < mark.max_strength, "the volley landed")
	t.ok(bows.xp > 0, "and the archers are the better for it")


# --- carrying it home -----------------------------------------------------

func test_a_campaign_regiment_carries_three_things(t) -> void:
	var r := Campaign.make_regiment(&"spear")
	t.eq(r.size(), 3, "[kind, strength, xp]")
	t.eq(r[0], &"spear")
	t.eq(r[1], int(Rules.KINDS[&"spear"]["strength"]))
	t.eq(r[2], 0, "raised green")


func test_xp_survives_the_wire(t) -> void:
	var cs = Campaign.generate([1, 2], 12345)
	var army: Dictionary = cs.armies[cs.sorted_army_ids()[0]]
	army["regiments"][0][2] = 137
	var back = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.ok(back != null, "a campaign with a veteran in it still decodes")
	t.eq(back.armies[army["id"]]["regiments"][0][2], 137)


func test_a_regiment_with_a_nonsense_xp_is_refused(t) -> void:
	# It arrives off the network like everything else, and an uncapped xp is an
	# arbitrary damage multiplier for the asking.
	var cs = Campaign.generate([1, 2], 12345)
	var army: Dictionary = cs.armies[cs.sorted_army_ids()[0]]
	army["regiments"][0][2] = -5
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_the_two_element_regiment_no_longer_decodes(t) -> void:
	# Every save and recording made before veterancy is a [kind, strength] world. The
	# VERSION bump is what refuses them; this proves the shape check does too.
	var cs = Campaign.generate([1, 2], 12345)
	var army: Dictionary = cs.armies[cs.sorted_army_ids()[0]]
	army["regiments"][0] = [&"spear", 100]
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


func test_xp_survives_the_battle_wire(t) -> void:
	# It has to be on the battle wire as well, or a replay -- which rebuilds the fight
	# from its opening snapshot -- would fight it with green regiments.
	var bs = BattleState.new()
	var r = bs.add(1, &"spear", Vector2.ZERO, 0.0)
	r.xp = 99
	var back = Snapshot.decode_battle(Snapshot.encode_battle(bs))
	t.ok(back != null)
	t.eq(back.regiments[r.id].xp, 99)
