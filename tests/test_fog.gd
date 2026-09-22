extends RefCounted
## Fog of war. What a player knows is a slice of the world, cut on the server.
##
## The slice is the point: the campaign snapshot used to go out as one blob to everybody,
## so hiding anything in the view would have been a curtain a modified client walks
## straight through. `armies_visible_to` is the one rule, and the wire and the campaign
## map's own drawing both call it -- the host's window has to hide exactly what a joined
## client was never sent, or this is the listen-server bug all over again.

const Campaign := preload("res://sim/campaign_state.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Save := preload("res://net/save.gd")
const Rules := preload("res://sim/rules.gd")


func _two_player():
	return Campaign.generate([1, 2], 12345)


func _town_of(cs, owner: int) -> int:
	for s: Dictionary in cs.settlements:
		if s["owner"] == owner:
			return int(s["tile"])
	return -1


func _army_of(cs, owner: int) -> Dictionary:
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == owner:
			return cs.armies[id]
	return {}


# --- what you can see -----------------------------------------------------

func test_you_see_the_ground_you_stand_on(t) -> void:
	var cs = _two_player()
	t.ok(cs.can_see(1, _town_of(cs, 1)), "your own capital")
	t.ok(cs.can_see(1, _army_of(cs, 1)["tile"]), "and where your army is standing")


func test_you_do_not_see_the_other_end_of_the_map(t) -> void:
	var cs = _two_player()
	t.ok(not cs.can_see(1, _town_of(cs, 2)), "the enemy capital is across the map")
	t.ok(not cs.can_see(2, _town_of(cs, 1)), "and it is mutual")


func test_sight_reaches_exactly_the_radius(t) -> void:
	var cs = _two_player()
	var home := _town_of(cs, 1)
	var near := 0
	var far := 0
	for tile in cs.terrain.size():
		var d := Campaign.hex_distance(home, tile)
		if d <= Rules.SIGHT_RADIUS:
			near += 1
			t.ok(cs.can_see(1, tile), "hex %d is %d away and should be seen" % [tile, d])
		elif not cs.can_see(1, tile):
			far += 1
	t.ok(near > 1 and far > 0, "the map is neither all seen nor all dark")


func test_what_you_have_seen_stays_seen(t) -> void:
	# The difference between fog of war and blindness: ground you walked over stays on
	# your map after you walk away.
	var cs = _two_player()
	var a: Dictionary = _army_of(cs, 1)
	var was: int = a["tile"]
	var onward: int = cs.adjacent(was)[0]
	cs.move_army(a["id"], onward)
	cs.observe(1)
	t.ok(cs.can_see(1, was), "the hex it marched off")
	t.ok(cs.can_see(1, onward), "and the one it marched to")


func test_an_unobserved_campaign_sees_everything(t) -> void:
	# Fog is something a campaign ACQUIRES by calling observe(), never a default. Every
	# test and harness written before this file builds a CampaignState by hand and must
	# keep getting the whole world.
	var cs = Campaign.new()
	cs.terrain = PackedByteArray()
	cs.terrain.resize(Rules.MAP_W * Rules.MAP_H)
	t.ok(cs.can_see(1, 0), "no memory at all reads as omniscient")
	t.ok(cs.can_see(7, 100))


# --- what goes on the wire ------------------------------------------------

func test_an_army_you_cannot_see_is_not_sent_to_you(t) -> void:
	var cs = _two_player()
	var theirs: Dictionary = _army_of(cs, 2)
	t.ok(not cs.can_see(1, int(theirs["tile"])), "precondition: it is out of sight")
	var mine = Snapshot.decode_campaign(Snapshot.encode_campaign(cs, 1))
	t.ok(mine != null)
	t.ok(not mine.armies.has(theirs["id"]),
		"the enemy army is absent from my snapshot, not merely undrawn")
	t.ok(mine.armies.has(_army_of(cs, 1)["id"]), "and my own is still there")


func test_your_own_army_is_always_sent_to_you(t) -> void:
	# Even standing somewhere nobody is looking: an army you cannot see is an army you
	# cannot order, and losing your own units to your own fog is not a mechanic.
	var cs = _two_player()
	var mine: Dictionary = _army_of(cs, 1)
	var dark := PackedByteArray()
	dark.resize(cs.terrain.size())
	cs.seen[1] = dark
	var sliced = Snapshot.decode_campaign(Snapshot.encode_campaign(cs, 1))
	t.ok(sliced.armies.has(mine["id"]))
	t.eq(sliced.armies.size(), 1, "and nobody else's")


func test_an_omniscient_snapshot_is_still_the_whole_world(t) -> void:
	var cs = _two_player()
	var whole = Snapshot.decode_campaign(Snapshot.encode_campaign(cs))
	t.eq(whole.armies.size(), cs.armies.size(), "no owner means no slicing")


func test_you_are_sent_your_own_memory_and_nobody_elses(t) -> void:
	var cs = _two_player()
	var mine = Snapshot.decode_campaign(Snapshot.encode_campaign(cs, 1))
	t.ok(mine.seen.has(1), "my own row")
	t.ok(not mine.seen.has(2), "sending the whole book would hand me the enemy's map")


func test_a_structure_you_have_not_found_is_blanked(t) -> void:
	var cs = _two_player()
	var hidden := -1
	for tile in cs.structures.size():
		if cs.structures[tile] != 0 and not cs.can_see(1, tile):
			hidden = tile
			break
	t.ok(hidden >= 0, "precondition: somebody has a barracks I have not found")
	var mine = Snapshot.decode_campaign(Snapshot.encode_campaign(cs, 1))
	t.eq(mine.structures[hidden], 0, "blanked, not merely undrawn")
	t.ok(cs.structures[hidden] != 0, "and the server still knows it is there")


func test_the_snapshot_still_round_trips(t) -> void:
	var cs = _two_player()
	cs.observe_all()
	var bytes := Snapshot.encode_campaign(cs)
	var back = Snapshot.decode_campaign(bytes)
	t.ok(back != null)
	t.eq(Snapshot.encode_campaign(back), bytes, "encode(decode(x)) == x, fog included")


func test_a_fog_row_of_the_wrong_length_is_refused(t) -> void:
	# It comes off the network like everything else.
	var cs = _two_player()
	cs.seen[1] = PackedByteArray([1, 2, 3])
	t.eq(Snapshot.decode_campaign(Snapshot.encode_campaign(cs)), null)


# --- carrying it across a save --------------------------------------------

func test_a_save_remembers_what_each_player_had_seen(t) -> void:
	# A save that dropped the fog would hand back a revealed map, which is the one way
	# this feature could be undone without anything failing.
	var cs = _two_player()
	var explored: int = _army_of(cs, 1)["tile"]
	var file = Save.of(cs, [1, 2])
	var back = Save.from_bytes(file.to_bytes()).restore([1, 2])
	t.ok(back != null)
	t.ok(back.can_see(1, explored), "player 1 still knows the ground it had walked")
	t.ok(not back.can_see(1, _town_of(cs, 2)), "and still does not know the enemy capital")


func test_loading_into_different_seats_takes_the_right_map_along(t) -> void:
	# Peer ids are random per session, so `seen` has to be remapped with the treasuries
	# and the settlements. Missing it would give somebody another player's map -- which
	# nothing else in the game would notice.
	var cs = _two_player()
	var mine: int = _army_of(cs, 1)["tile"]
	var theirs: int = _army_of(cs, 2)["tile"]
	var file = Save.of(cs, [1, 2])
	var back = Save.from_bytes(file.to_bytes()).restore([77, 88])
	t.ok(back != null)
	t.ok(back.can_see(77, mine), "seat 1's map followed seat 1")
	t.ok(not back.can_see(77, theirs), "and is not seat 2's")
	t.ok(back.can_see(88, theirs))
